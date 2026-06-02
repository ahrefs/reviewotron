# Review failure notifications — design

## Problem

When `review_pr` cannot produce a review because of a limit, it silently
logs and returns. The user gets no signal on the PR about *why* the review
did not happen. Two classes of failure:

- **External:** GitHub API refuses to serve the diff — e.g. HTTP 406
  `"diff exceeded the maximum number of files (300)"`, 404, network errors.
- **Internal:** diff exceeds our own limits — `max_diff_lines` (default 2000),
  `max_files` (default 50, currently defined but never enforced).

## Goal

On a PR review failure, post an issue comment to the PR explaining the cause,
with enough context to act on. Treat "all files filtered out by
`ignored_paths`" as a *successful* review (add a 👍 reaction, no comment).

Scope: `review_pr` only. This covers both webhook PR events and the manual
`REVIEW` comment trigger (`review_pr_from_comment` delegates to `review_pr`).
`review_push` is left as-is (it already has a Slack failure path and has no PR
to comment on).

## Design

### 1. New API: `create_issue_comment`

`github_types.ml`:

```ocaml
type issue_comment_req = { body : string } [@@deriving json]
```

`api.ml` (`Github` module type):

```ocaml
val create_issue_comment :
  ctx:Context.t -> repo_url:string -> number:int ->
  Github_types.issue_comment_req -> (unit, string) result Lwt.t
```

- `api_remote.ml`: POST `/issues/%d/comments`, mirroring `create_commit_comment`.
- `api_local.ml`: append to the write log; add `fail_next_issue_comment` ref
  (+ set/reset) mirroring the existing `fail_next_*` test hooks.

### 2. Enforce `max_files` in `prepare_diff`

Add a file-count check (before the line check) and a new error variant:

```ocaml
match filtered_diff with
| [] -> Error `Empty
| _ when List.compare_length_with filtered_diff config.max_files > 0 ->
    Error (`Too_many_files (List.length filtered_diff))
| _ when total_lines > config.max_diff_lines -> Error (`Too_large total_lines)
| _ -> Ok (filtered_diff, Diff_parser.to_string_annotated filtered_diff)
```

`review_push` also calls `prepare_diff`; it gets a match arm for
`` `Too_many_files `` that logs-and-returns (same shape as its existing
`` `Too_large `` arm) — no behaviour change beyond honouring the new limit.

### 3. `Review_failure` module (`review_failure.ml` + `.mli`)

Captures every failure cause and formats the comment body. Keeps message
strings out of the orchestration code.

```ocaml
type t =
  | Diff_too_large_remote of string   (* GitHub 406 / too_large *)
  | Fetch_failed of string            (* other diff-fetch errors *)
  | Too_many_lines of { actual : int; limit : int }
  | Too_many_files of { actual : int; limit : int }

val classify_fetch_error : string -> t   (* maps a raw diff-fetch error string *)
val to_comment : t -> string             (* Markdown issue-comment body *)
```

`classify_fetch_error` detects the known remote-too-large case via substring
match (`too_large` / `exceeded the maximum number of files`) using
`CCString` (no new dependency); everything else is `Fetch_failed`.

`to_comment` renders a Markdown body prefixed with a clear marker, e.g.
`🤖 **reviewotron** couldn't review this PR`, then a cause-specific line:

- `Diff_too_large_remote` → "The diff is too large for the GitHub API to
  serve (over 300 files). Consider splitting this PR." + raw detail.
- `Fetch_failed` → "Couldn't fetch the diff from GitHub." + raw error.
- `Too_many_lines` → "The diff is N lines, over reviewotron's limit of L."
- `Too_many_files` → "The diff touches N files, over reviewotron's limit of L."

### 4. Wiring in `review_pr`

A `post_failure` helper posts the comment with `retry_once` (mirroring other
post calls), logging on failure:

```ocaml
let post_failure ~ctx ~repo_url ~number failure =
  let body = Review_failure.to_comment failure in
  let%lwt result =
    retry_once ~label:(...) (fun () ->
      GH.create_issue_comment ~ctx ~repo_url ~number { body })
  in
  (match result with Ok () -> log#info ... | Error msg -> log#error ...);
  Lwt.return_unit
```

Match arms in `review_pr`:

```ocaml
| Error msg ->            (* diff fetch *)
    log#error "failed to fetch diff for PR #%d: %s" number msg;
    post_failure ~ctx ~repo_url ~number (Review_failure.classify_fetch_error msg)
| Error `Empty ->
    log#info "PR #%d: all files filtered out, nothing to review" number;
    add_success_reaction ~ctx ~repo_url reaction_target  (* 👍 directly *)
| Error (`Too_large n) ->
    post_failure ~ctx ~repo_url ~number (Too_many_lines { actual = n; limit = config.max_diff_lines })
| Error (`Too_many_files n) ->
    post_failure ~ctx ~repo_url ~number (Too_many_files { actual = n; limit = config.max_files })
```

`add_success_reaction` adds `+1` directly to the `reaction_target` (no prior
`eyes` needed, since the empty-diff branch runs before
`start_progress_reaction`). When `reaction_target` is `None`, it is a no-op.

### 5. Tests

`api_local`'s write-log drives the integration tests. Add cases that exercise
the failure paths and assert a `[create_issue_comment]` entry with the right
message text appears (and that empty-diff produces a `+1` reaction, no
comment). `Review_failure.classify_fetch_error` / `to_comment` get direct
inline tests for the 406 vs generic split.

Verification caveat: `test/test.ml` is known not to compile on `main` due to
ocaml-ai-sdk drift (see memory `project_test_binary_sdk_drift`). Build the
library (`dune build lib`) to confirm compilation, run whatever test subset
builds, and report honestly what could and couldn't run.
