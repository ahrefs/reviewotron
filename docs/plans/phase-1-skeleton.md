# Phase 1: Skeleton + Webhook Parsing

## Goal
Create the project skeleton with build system, ATD type definitions, webhook parsing, HTTP server, and CLI entry point. At the end of this phase, the app compiles, starts an HTTP server, and can receive + parse GitHub webhook payloads.

## Prerequisites
- Read `.cursor/rules/backend-developer.mdc` for code style
- Use context7 MCP for cmdliner and ATD documentation
- Use serena MCP for navigating monorobot's code

## Tasks

### 1.1 Create project structure

Create the directory layout:

```
experimental/reviewotron/
  Makefile
  dune-project
  lib/
    dune
  src/
    dune
  test/
    dune
    mock_payloads/
    mock_api_responses/
      github/
      claude/
    expected/
  mock_states/
  secrets.json.example
```

**Makefile** — follow the pattern from `backend/slack_of_ics/Makefile`:
```makefile
DEFAULT_TARGET = @all
include ../../backend/shared-makefiles/dune.mk
```

Note: Since we're in `experimental/`, verify that `../../backend/shared-makefiles/dune.mk` resolves correctly. If not, create a standalone Makefile with `dune build` targets.

**dune-project**:
```lisp
(lang dune 3.0)
(name reviewotron)
```

**lib/dune**:
```lisp
(library
 (name reviewotron_lib)
 (libraries
  containers
  devkit
  lwt
  lwt.unix
  lwt_ppx
  yojson
  atdgen-runtime
  digestif
  one_llm
  curl.lwt
  re2
  ptime
  ptime.clock.os)
 (preprocess (pps lwt_ppx)))
```

Note: The `one_llm` library dependency path needs verification — check how other `experimental/` projects reference `backend/` libraries in their dune files.

**src/dune**:
```lisp
(executable
 (name reviewotron)
 (libraries
  reviewotron_lib
  cmdliner
  devkit
  lwt.unix))
```

**test/dune**:
```lisp
(test
 (name test)
 (libraries
  reviewotron_lib
  alcotest
  lwt
  lwt.unix))
```

### 1.2 Define ATD types — `github_types.atd`

Adapt from monorobot's `subrepo/monorobot/lib/github.atd`. We need a subset:

```
type commit_hash = string

type git_user = {
  name: string;
  email: string;
  ?username: string option;
}

type github_user = {
  login: string;
  id: int;
  url: string;
  html_url: string;
  avatar_url: string;
}

type repository = {
  name: string;
  full_name: string;
  html_url <ocaml name="url"> : string;
  commits_url: string;
  contents_url: string;
  pulls_url: string;
}

type commit = {
  id: commit_hash;
  distinct: bool;
  message: string;
  timestamp: string;
  url: string;
  author: git_user;
  committer: git_user;
  added: string list;
  removed: string list;
  modified: string list;
}

type commit_pushed_notification = {
  ref: string;
  before: commit_hash;
  after: commit_hash;
  created: bool;
  deleted: bool;
  forced: bool;
  commits: commit list;
  ?head_commit: commit option;
  repository: repository;
  compare: string;
  pusher: git_user;
  sender: github_user;
}

type pr_action = string  (* opened, synchronize, reopened, closed, etc. *)

type pull_request = {
  number: int;
  title: string;
  body <ocaml default="\"\""> : string;
  html_url: string;
  diff_url: string;
  state: string;
  user: github_user;
  ?head: pr_head option;
  ?base: pr_base option;
  additions: int;
  deletions: int;
  changed_files: int;
}

type pr_head = {
  sha: commit_hash;
  ref: string;
}

type pr_base = {
  sha: commit_hash;
  ref: string;
}

type pr_notification = {
  action: pr_action;
  number: int;
  pull_request: pull_request;
  repository: repository;
  sender: github_user;
}

(* Types for GitHub API responses *)
type pull_request_file = {
  sha: string;
  filename: string;
  status: string;
  additions: int;
  deletions: int;
  changes: int;
  ?patch: string option;
}

(* Types for posting reviews *)
type review_comment_req = {
  path: string;
  ?position: int option;
  ?line: int option;
  ?side: string option;
  body: string;
}

type create_review_req = {
  ?commit_id: string option;
  body: string;
  event: string;
  ~comments <ocaml default="[]">: review_comment_req list;
}

type commit_comment_req = {
  body: string;
  ?path: string option;
  ?position: int option;
  ?line: int option;
}
```

Add ATDgen generation rules to `lib/dune`:
```lisp
(rule
 (targets github_types_t.ml github_types_t.mli github_types_j.ml github_types_j.mli)
 (deps github_types.atd)
 (action (run atdgen %{deps})))
```

Note: Check monorobot's `lib/dune` for the exact ATDgen rule pattern — it may use separate `-t` and `-j` invocations.

### 1.3 Define ATD types — `config.atd`

```
type config = {
  ~max_diff_lines <ocaml default="2000">: int;
  ~max_files <ocaml default="50">: int;
  ~max_tokens_per_review <ocaml default="100000">: int;
  ~model <ocaml default="\"claude-sonnet-4-5-20250929\"">: string;
  ~ignored_paths <ocaml default="[]">: string list;
  ~ignored_authors <ocaml default="[]">: string list;
  ~auto_review_pr_open <ocaml default="true">: bool;
  ~auto_review_pr_sync <ocaml default="true">: bool;
  ~review_pushes_to_develop <ocaml default="true">: bool;
  ?system_prompt_override: string option;
  ?slack_webhook_url: string option;
  ?slack_channel: string option;
}

type repo_config = {
  url: string;
  gh_token: string;
  ?gh_hook_secret: string option;
  ?config_override: config option;
}

type secrets = {
  repos: repo_config list;
  anthropic_api_key: string;
  ~anthropic_version <ocaml default="\"2023-06-01\"">: string;
}
```

### 1.4 Implement `context.ml`

Application context holding config, secrets, and state. Follow monorobot's `lib/context.ml` pattern:

```ocaml
type t = {
  secrets : Config_t.secrets;
  config : Config_t.config;
  mutable state : State_t.state;
  state_filepath : string option;
}

val create : secrets_filepath:string -> ?config_filepath:string -> ?state_filepath:string -> unit -> t
(** Load secrets from file, optionally load config and state *)

val find_repo_config : t -> repo_url:string -> Config_t.repo_config option
(** Find repo config by URL *)

val get_config : t -> repo_url:string -> Config_t.config
(** Get effective config for a repo (base config + repo override) *)
```

Key patterns from backend-developer.mdc:
- Use `Devkit.Files` for file I/O (atomic saves)
- Use `Result` types for expected errors, exceptions for unexpected
- Labeled arguments for >2 params

### 1.5 Implement `github.ml`

GitHub event parsing and HMAC signature validation. Reference monorobot's `lib/github.ml`:

```ocaml
type event =
  | Pull_request of Github_types_t.pr_notification
  | Push of Github_types_t.commit_pushed_notification
  | Unknown of string

val parse_event : event_type:string -> body:string -> (event, string) result
(** Parse a GitHub webhook payload based on the X-Github-Event header *)

val validate_signature : secret:string -> signature:string -> body:string -> bool
(** Validate X-Hub-Signature-256 HMAC signature *)
```

HMAC validation pattern (from monorobot):
```ocaml
let validate_signature ~secret ~signature ~body =
  let expected = Digestif.SHA256.hmac_string ~key:secret body in
  let expected_hex = "sha256=" ^ Digestif.SHA256.to_hex expected in
  String.equal signature expected_hex
```

### 1.6 Implement `request_handler.ml`

HTTP server following monorobot's `src/request_handler.ml` pattern. Use Httpev for the HTTP server:

```ocaml
val start : ctx:Context.t -> port:int -> unit Lwt.t
```

Endpoints:
- `POST /github` — receive webhook, validate signature, parse event, log it (actual processing comes in Phase 3)
- `GET /ping` — health check returning 200

For now, the `/github` endpoint should:
1. Read `X-Github-Event` and `X-Hub-Signature-256` headers
2. Validate HMAC signature
3. Parse the event
4. Log what was received
5. Return 200 OK

### 1.7 Implement `reviewotron.ml` CLI

Entry point with cmdliner subcommands. Follow monorobot's `src/monorobot.ml`:

```ocaml
(* Subcommands *)
val run : port:int -> secrets:string -> ?config:string -> ?state:string -> unit -> unit
(** Start the HTTP server *)

val check : secrets:string -> ?config:string -> event_type:string -> payload_file:string -> unit -> unit
(** Process a single payload file for testing — prints what would be done *)
```

Use `Cmd.group` with `Cmd.info "reviewotron"` and subcommands `run` and `check`.

### 1.8 Create example secrets file

`secrets.json.example`:
```json
{
  "repos": [
    {
      "url": "https://github.com/org/repo",
      "gh_token": "ghp_xxxxxxxxxxxx",
      "gh_hook_secret": "your-webhook-secret"
    }
  ],
  "anthropic_api_key": "sk-ant-xxxxxxxxxxxx",
  "anthropic_version": "2023-06-01"
}
```

### 1.9 Create initial mock payloads

Create `test/mock_payloads/pr_opened.json` and `test/mock_payloads/push_develop.json` with realistic GitHub webhook payloads for testing. Reference monorobot's `mock_payloads/` for the correct structure.

## Verification

1. `dune build` compiles without errors
2. `./reviewotron run --secrets=secrets.json.example --port=8080` starts the server
3. `curl -X POST http://localhost:8080/ping` returns 200
4. `curl -X POST http://localhost:8080/github -H "X-Github-Event: pull_request" -d @test/mock_payloads/pr_opened.json` parses and logs the event (signature check skipped if no secret configured for repo)
5. `./reviewotron check --secrets=secrets.json.example --event-type=pull_request --payload=test/mock_payloads/pr_opened.json` prints parsed event info

## QA Checklist
- [ ] All files follow backend-developer.mdc code style
- [ ] ATDgen types generate correctly
- [ ] No use of banned operations (Str, Obj.magic, etc.)
- [ ] Labeled arguments used for functions with >2 params
- [ ] Result types for expected errors
- [ ] No hardcoded values — config-driven
