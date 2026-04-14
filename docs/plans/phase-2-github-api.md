# Phase 2: GitHub API + Diff Parser

## Goal
Implement the GitHub API client (real + mock), the diff parser module, and the module type signatures that enable the functor-based architecture. At the end of this phase, we can fetch PR diffs from GitHub and parse them into structured data with line-to-position mappings.

## Prerequisites
- Phase 1 complete and passing QA
- Read `.cursor/rules/backend-developer.mdc` for code style
- Use serena to study monorobot's `lib/api.ml` for the functor pattern

## Tasks

### 2.1 Define module type signatures — `api.ml`

Follow monorobot's functor pattern (`subrepo/monorobot/lib/api.ml`). Define three module types:

```ocaml
module type Github = sig
  val get_pr_files :
    ctx:Context.t -> repo_url:string -> number:int ->
    Github_types_t.pull_request_file list Lwt.t

  val get_pr_diff :
    ctx:Context.t -> repo_url:string -> number:int ->
    string Lwt.t

  val get_compare_diff :
    ctx:Context.t -> repo_url:string -> base:string -> head:string ->
    string Lwt.t

  val get_file_content :
    ctx:Context.t -> repo_url:string -> path:string -> ref_:string ->
    string option Lwt.t

  val create_pr_review :
    ctx:Context.t -> repo_url:string -> number:int ->
    Github_types_t.create_review_req -> unit Lwt.t

  val create_commit_comment :
    ctx:Context.t -> repo_url:string -> sha:string ->
    Github_types_t.commit_comment_req -> unit Lwt.t
end

module type Claude = sig
  val review_code :
    ctx:Context.t ->
    diff:string ->
    files:(string * string) list ->
    description:string ->
    Review_types_t.review_output Lwt.t
end

module type Slack = sig
  val post_message :
    ctx:Context.t ->
    text:string ->
    ?attachments:Yojson.Safe.t list ->
    unit -> unit Lwt.t
end
```

### 2.2 Implement `api_remote.ml` — GitHub functions

Real HTTP implementations using `curl.lwt`. Reference monorobot's `lib/api_remote.ml` for the HTTP request pattern.

**Helper functions:**
```ocaml
(** Extract owner/repo from full_name or URL *)
val parse_repo : string -> (string * string) option

(** Make authenticated GitHub API request *)
val github_request :
  ctx:Context.t -> repo_url:string -> path:string ->
  ?headers:(string * string) list -> ?body:string ->
  ?meth:string -> unit -> (string, string) result Lwt.t
```

**GitHub API endpoints used:**

| Function | Method | Endpoint | Accept Header |
|----------|--------|----------|---------------|
| `get_pr_files` | GET | `/repos/{owner}/{repo}/pulls/{number}/files` | `application/json` |
| `get_pr_diff` | GET | `/repos/{owner}/{repo}/pulls/{number}` | `application/vnd.github.v3.diff` |
| `get_compare_diff` | GET | `/repos/{owner}/{repo}/compare/{base}...{head}` | `application/vnd.github.v3.diff` |
| `get_file_content` | GET | `/repos/{owner}/{repo}/contents/{path}?ref={ref}` | `application/vnd.github.v3.raw` |
| `create_pr_review` | POST | `/repos/{owner}/{repo}/pulls/{number}/reviews` | `application/json` |
| `create_commit_comment` | POST | `/repos/{owner}/{repo}/commits/{sha}/comments` | `application/json` |

**Auth**: Use `Authorization: Bearer {gh_token}` header from repo config.

**Important**: Use `Devkit.Web.http_request_lwt'` or `Curl_lwt` for HTTP — do NOT use `Unix.sleep` or blocking calls. Follow backend-developer.mdc Lwt patterns.

### 2.3 Implement `api_local.ml` — Mock GitHub functions

File-based mock implementations for testing:

```ocaml
module Github_local : Api.Github = struct
  (** Read mock response from test/mock_api_responses/github/{name}.json *)
  val get_pr_files ~ctx ~repo_url ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d_files.json" number in
    (* read and parse file *)

  val get_pr_diff ~ctx ~repo_url ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d.diff" number in
    (* read diff file *)

  (* ... etc *)

  val create_pr_review ~ctx ~repo_url ~number ~review =
    (* Print/record what would be posted — for golden file comparison *)
    Lwt.return_unit

  val create_commit_comment ~ctx ~repo_url ~sha ~comment =
    (* Print/record what would be posted *)
    Lwt.return_unit
end
```

The mock `create_pr_review` and `create_commit_comment` should output the review/comment JSON to stdout or a buffer — this output is what golden file tests compare against.

### 2.4 Implement `diff_parser.ml`

This is the most critical module in Phase 2. GitHub's PR review API uses `position` (the line offset within the diff), not absolute file line numbers. We must parse unified diffs and provide accurate mappings.

```ocaml
type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  lines : diff_line list;
}

type diff_line =
  | Context of string      (* line present in both old and new *)
  | Addition of string     (* line added in new *)
  | Deletion of string     (* line removed from old *)

type file_diff = {
  path : string;
  old_path : string option;   (* for renames *)
  status : string;             (* added, deleted, modified, renamed *)
  hunks : hunk list;
}

type t = file_diff list

val parse : string -> t
(** Parse a unified diff string into structured file diffs *)

val line_to_position : file_diff -> line:int -> side:[ `Left | `Right ] -> int option
(** Convert an absolute line number to a diff position for GitHub's API.
    Position is 1-indexed from the start of the diff for that file.
    The @@ hunk header is position 1. *)

val position_to_line : file_diff -> position:int -> (int * [ `Left | `Right ]) option
(** Reverse mapping: diff position to absolute line number *)

val total_lines : t -> int
(** Total number of diff lines across all files *)

val filter_paths : t -> ignored:string list -> t
(** Remove file diffs matching ignored glob patterns *)

val estimate_tokens : t -> int
(** Rough token estimate (~4 chars per token) *)
```

**Position mapping rules** (GitHub docs):
- Position 1 = the `@@` hunk header line
- Each subsequent line increments position by 1
- Context lines, additions, and deletions all count
- For multi-hunk files, positions are continuous (no reset between hunks)

**Parsing approach:**
1. Split on `^diff --git` to get per-file sections
2. Extract file paths from `--- a/` and `+++ b/` lines
3. Parse `@@ -old_start,old_count +new_start,new_count @@` headers
4. Classify each line as Context/Addition/Deletion based on first character

**Use Re2** for regex (not Str — banned per backend-developer.mdc).

### 2.5 Create mock API response files

Create realistic mock files for testing:

- `test/mock_api_responses/github/pr_1_files.json` — list of files in a PR
- `test/mock_api_responses/github/pr_1.diff` — unified diff for a PR
- `test/mock_api_responses/github/compare_abc123_def456.diff` — compare diff for push

### 2.6 Write diff parser unit tests

Create `test/test_diff_parser.ml` with tests for:

1. **Basic parsing**: Single file, single hunk
2. **Multi-hunk**: Single file with multiple hunks
3. **Multi-file**: Multiple files in one diff
4. **Position mapping**: Verify line_to_position for various cases
5. **Edge cases**: Empty diff, binary files, renamed files, new files, deleted files
6. **Filtering**: Verify `filter_paths` removes matching files
7. **Token estimation**: Verify rough accuracy

Use Alcotest for test framework (consistent with monorobot).

## Verification

1. `dune build` compiles
2. `dune runtest` — diff parser unit tests pass
3. Manual test: use `check` CLI command with a mock payload + mock API responses to verify the full parse → fetch flow works
4. Verify position mapping is correct by comparing with a known GitHub PR diff

## QA Checklist
- [ ] Module type signatures are clean and minimal
- [ ] `api_remote.ml` handles HTTP errors gracefully (Result types)
- [ ] `api_local.ml` outputs deterministic results for golden files
- [ ] `diff_parser.ml` handles all edge cases (renames, binary, empty)
- [ ] Position mapping matches GitHub's documented behavior
- [ ] Re2 used for regex, not Str
- [ ] No blocking calls in Lwt code
- [ ] Unit tests cover critical paths
