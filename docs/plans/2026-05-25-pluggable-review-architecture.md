# Pluggable Review Architecture Plan

Status: Stage 2 complete; Stage 3 next
Date: 2026-05-25

## Progress Notes

- 2026-05-25: Stage 0 baseline completed. Initial dirty files were
  `.serena/project.yml` plus the plan documents from creating this plan.
  `make fmt` found pre-existing formatting drift and auto-promoted
  `lib/agent_runner.ml`, `lib/agent_runner.mli`, and `test/test.ml`.
  A second `make fmt` passed. `make build` and `make test` passed.
- 2026-05-26: Stage 1 completed. Added neutral `Review_comment` types and
  changed finding routing to produce `Review_comment.t`. Kept the
  `finding_to_comment` GitHub compatibility wrapper and GitHub PR publishing
  behavior unchanged by converting neutral comments at the boundary.
  `make fmt`, `make build`, and `make test` passed.
- 2026-05-26: Stage 2 completed. Added `Review_engine` for core review
  mechanics: deduplication, diff preparation, neutral finding routing, plugin
  execution, and PR-style report construction. `Reviewer.Make` now delegates
  core review work to `Review_engine` while keeping GitHub event policy,
  acquisition, publishing, retry, and state updates in the compatibility
  wrapper. `make fmt`, `make build`, and `make test` passed.

## Goal

Reviewotron currently works as a GitHub webhook service: it receives GitHub
events, fetches a PR or push diff, runs the review plugins, and posts results
back to GitHub and optionally Slack.

The goal is to split this into three clear layers:

1. Source adapters: acquire a change to review.
2. Core review engine: run the review mechanism against a normalized job.
3. Sink adapters: publish or return the review result.

This should let us keep the existing GitHub webhook behavior while adding other
modes, such as local diff review, GitLab merge request review, scheduled branch
comparison, a CLI JSON output mode, or other future acquisition and publication
paths.

Every implementation stage must leave the repository in a working state. The
existing GitHub flow must continue to pass tests unless a stage explicitly
documents a tested behavior change.

## Current Architecture Summary

The current production path is:

```text
HTTP /github
  -> GitHub signature validation
  -> GitHub webhook parsing
  -> Reviewer.Make.process_event
  -> GitHub config/diff/file-content fetches
  -> diff parsing/filtering/annotation
  -> general and security review plugins
  -> finding dedupe and anchoring
  -> GitHub PR review or commit comments
  -> optional Slack message for push reviews
```

The code already has useful seams:

- `Reviewer.Make` is a functor over `Api.Github`, `Api.Agent_runner`, and
  `Api.Slack`.
- `Api_remote` and `Api_local` provide production and test implementations.
- `Review_plugin` already models the general/security plugin boundary.
- `Diff_parser`, `Diff_anchor`, `Review_types`, and `Review_format` are already
  mostly core concepts.

The main issue is that the biggest functor still mixes responsibilities:

- GitHub event policy lives in `Reviewer.Make`.
- Diff acquisition lives in `Reviewer.Make`.
- Core review orchestration lives in `Reviewer.Make`.
- Finding routing currently returns `Github_types.review_comment_req`.
- Publishing to GitHub and Slack lives in `Reviewer.Make`.
- `Api.Github` combines source operations and sink operations in one signature.
- `Security_review_plugin.Make` depends on `Api.Github` just to fetch file
  content during tool calls.

## Vocabulary

Use these names in implementation discussions:

- Source adapter: code that turns an external trigger or input into a normalized
  `Review_job.t`.
- Core review engine: code that receives a `Review_job.t`, runs the existing
  review plugins, and returns a `Review_report.t`.
- Sink adapter: code that turns a `Review_report.t` into an external result,
  such as GitHub review comments, Slack messages, stdout, JSON, or check-run
  output.
- GitHub controller: the compatibility layer that keeps existing webhook
  behavior by connecting GitHub source policy to the core engine and GitHub
  sink.

Avoid calling the acquisition side "frontend" in code names. "Source" is more
accurate for this service. Avoid calling the publication side "backend";
"sink" or "publisher" is clearer.

## Target Contracts

Exact field names may change during implementation, but the target shape should
look like this.

### Neutral Review Comment

`Review_comment.t` should not depend on GitHub types.

```ocaml
type side =
  | Left
  | Right

type t = {
  path : string;
  line : int;
  side : side;
  start_line : int option;
  start_side : side option;
  body : string;
}
```

GitHub conversion should live outside this neutral module, either in the GitHub
sink or as a temporary helper inside the GitHub compatibility path.

### Review Job

`Review_job.t` is the normalized input to the core engine.

```ocaml
type trigger =
  | Pull_request
  | Push
  | Manual
  | Local
  | Other of string

type source_kind =
  | Github
  | Local
  | Other of string

type fetch_file = path:string -> (string option, string) result Lwt.t

type t = {
  repo_key : string;
  change_key : string;
  title : string;
  description : string;
  head_sha : string;
  diff_text : string;
  config : Config_types.config;
  file_contents : (string * string) list;
  fetch_file : fetch_file;
  trigger : trigger;
  source_kind : source_kind;
}
```

Initially, `repo_key` can continue to be the GitHub repo URL. Do not rename all
`repo_url` usage in the first stages. That would create too much churn before
the core split is proven.

### Review Report

`Review_report.t` is the normalized output from the core engine.

```ocaml
type t = {
  body : string;
  comments : Review_comment.t list;
  findings : Review_types.finding list;
  unchanged_findings : Review_types.finding list;
  anchor_failed_findings : Review_types.finding list;
  costs : Cost_tracking.review_cost list;
  security_error : bool;
}
```

Sinks decide what to do with each field. A GitHub PR sink should publish
`comments` as inline review comments and include the report body as the review
body. A JSON sink can serialize everything. A stdout sink can print markdown.

## Working-State Protocol

Each implementation stage must finish with:

```bash
make fmt
make build
make test
```

If a stage only edits markdown, running tests is optional, but the final answer
for that stage must say that no code was changed and tests were not run.

Do not begin the next stage until the current stage is green or the blocking
failure is documented.

## Stage 0: Baseline Audit

Purpose: establish a clean starting point before architectural edits.

Tasks:

- Run `git status --short`.
- Run `make build`.
- Run `make test`.
- Note any pre-existing dirty files or failures before changing code.

Working state:

- No source files changed.
- Any existing failures are documented before Stage 1 starts.

## Stage 1: Add Neutral Review Comments

Purpose: remove the most obvious GitHub type leak from core finding routing.

Tasks:

- Add `lib/review_comment.ml` and `lib/review_comment.mli`.
- Define neutral `side` and `t` types.
- Change internal finding routing to produce `Review_comment.t` instead of
  `Github_types.review_comment_req`.
- Keep the public `Reviewer.Make.finding_to_comment` API returning
  `Github_types.review_comment_req option` for now, so existing tests and
  callers remain compatible.
- Add a small conversion helper in the GitHub compatibility path:
  `Review_comment.t -> Github_types.review_comment_req`.
- Keep all GitHub publishing behavior unchanged.

Files likely touched:

- `lib/review_comment.ml`
- `lib/review_comment.mli`
- `lib/reviewer.ml`
- `lib/reviewer.mli`
- `lib/dune`
- Existing tests only if type exposure requires minor updates.

Working state:

- Existing PR inline comment tests still pass.
- Existing `Reviewer.Make.finding_to_comment` behavior remains available.
- No new source or sink abstraction is introduced yet.

Verification:

```bash
make fmt
make build
make test
```

## Stage 2: Extract a Core Engine Module, Still GitHub-Compatible

Purpose: move core review orchestration out of `Reviewer.Make` while preserving
the existing GitHub controller.

Tasks:

- Add `lib/review_engine.ml` and `lib/review_engine.mli`.
- Move these responsibilities from `Reviewer.Make` into the engine:
  - diff preparation
  - plugin execution
  - finding dedupe use
  - neutral finding routing
  - review body construction
  - cost aggregation/logging
- Keep enough GitHub-specific conversion in `Reviewer.Make` so publication
  remains unchanged.
- At this stage it is acceptable if `Review_engine.Make` is still functorized
  over the existing dependencies. The point is to separate "run a review" from
  "handle a GitHub event".

Files likely touched:

- `lib/review_engine.ml`
- `lib/review_engine.mli`
- `lib/reviewer.ml`
- `lib/reviewer.mli`
- `lib/dune`
- Tests around reviewer behavior.

Working state:

- `Reviewer.Make.process_event` still supports pull requests, pushes, and
  `REVIEW` comments exactly as before.
- Existing tests pass without changing fixture semantics.
- The new engine can be tested directly with local/mock dependencies.

Verification:

```bash
make fmt
make build
make test
```

## Stage 3: Introduce Review Job and Remove GitHub From Plugin Context

Purpose: make the core engine run from a normalized job rather than from GitHub
event-specific arguments.

Tasks:

- Add `lib/review_job.ml` and `lib/review_job.mli`.
- Add `Review_job.fetch_file` and have source adapters close over the relevant
  ref or SHA.
- Update plugin metadata or plugin call signatures so file fetching is supplied
  by the job, not by `Api.Github`.
- Change `Security_review_plugin.Make` to depend only on `Api.Agent_runner`.
  It should receive `fetch_file` through metadata or an explicit argument.
- Keep `General_review_plugin.Make` behavior unchanged; it can ignore
  `fetch_file`.
- Keep `repo_key` equal to the GitHub repo URL for compatibility with config,
  memory paths, logging, and agent runner call sites.

Files likely touched:

- `lib/review_job.ml`
- `lib/review_job.mli`
- `lib/review_plugin.ml`
- `lib/review_plugin.mli`
- `lib/review_engine.ml`
- `lib/security_review_plugin.ml`
- `lib/security_review_plugin.mli`
- `lib/general_review_plugin.ml`
- `lib/reviewer.ml`
- Tests that instantiate `Security_review_plugin.Make`.

Working state:

- Security review still has `get_file_content` tool behavior.
- GitHub PR and push paths still fetch file content at the correct head SHA.
- Existing security plugin tests still pass.

Verification:

```bash
make fmt
make build
make test
```

## Stage 4: Split Source and Sink Interfaces

Purpose: stop treating GitHub as the single API abstraction.

Tasks:

- Add source/sink module type signatures. The exact module name can be
  `Review_adapter`, `Review_io`, or similar.
- Split concepts currently combined in `Api.Github`:
  - source side: config fetch, diff fetch, pull request fetch, file content
    fetch
  - sink side: create PR review, create commit comments
- Keep `Api.Github` temporarily if that reduces churn, but new code should use
  the split interfaces.
- Do not move all production HTTP code at once unless it stays small and
  mechanical.

Potential signature sketch:

```ocaml
module type Source = sig
  val fetch_config :
    ctx:Context.t -> repo_key:string -> (Config_types.config, string) result Lwt.t
end

module type Sink = sig
  val publish :
    ctx:Context.t -> job:Review_job.t -> report:Review_report.t -> (unit, string) result Lwt.t
end
```

The final signatures may need separate GitHub-specific source helpers for PR
and push jobs. That is fine. Keep the generic core boundary clean.

Files likely touched:

- `lib/api.ml`
- `lib/api_remote.ml`
- `lib/api_local.ml`
- New adapter modules if needed.
- `lib/reviewer.ml`

Working state:

- All current GitHub tests pass.
- `Api_local` still supports existing golden tests.
- No local diff mode is required yet.

Verification:

```bash
make fmt
make build
make test
```

## Stage 5: Make the GitHub Adapter Explicit

Purpose: make GitHub one source/sink pair rather than the architecture itself.

Tasks:

- Add a GitHub source/controller module that handles:
  - PR action policy
  - push policy
  - `REVIEW` comment policy
  - config refresh policy
  - building `Review_job.t` values
- Add a GitHub sink module that handles:
  - converting `Review_comment.t` to `Github_types.review_comment_req`
  - creating PR reviews
  - creating commit comments for push findings
  - retrying transient publication failures
- Keep `Reviewer.Make.process_event` as a compatibility wrapper if useful.
  It can delegate to the new GitHub controller.
- Avoid renaming the command-line or HTTP route in this stage.

Files likely touched:

- New `lib/github_source.ml` / `.mli`, or equivalent name.
- New `lib/github_sink.ml` / `.mli`, or equivalent name.
- `lib/reviewer.ml`
- `src/request_handler.ml` only if the wrapper shape changes.
- Tests for PR, push, comment trigger, duplicates, and ignored authors.

Working state:

- `/github` still behaves as before.
- `reviewotron check` still parses GitHub events as before.
- Existing webhook tests remain the primary regression suite.

Verification:

```bash
make fmt
make build
make test
```

## Stage 6: Add the First Non-GitHub Source/Sink

Purpose: prove the architecture by running the same core engine without GitHub
webhooks or GitHub publication.

Recommended first mode: local diff review.

Candidate CLI:

```bash
reviewotron review-diff \
  --repo-key local \
  --title "Local change" \
  --description-file description.md \
  --diff change.diff \
  --output markdown
```

Tasks:

- Add a CLI command that reads a unified diff from disk.
- Build a `Review_job.t` with:
  - `source_kind = Local`
  - `trigger = Local`
  - `repo_key` from the CLI
  - `change_key` derived from the diff path or an optional argument
  - `fetch_file` implemented from the local filesystem, or returning `Ok None`
    in the first version if local context expansion is deferred.
- Add a stdout or JSON sink.
- Keep this path small. Its purpose is architectural proof, not a complete CLI
  product.

Files likely touched:

- `src/reviewotron.ml`
- New local source/sink modules if useful.
- New tests for CLI-independent local job construction or sink formatting.

Working state:

- Existing GitHub tests still pass.
- Local diff review can run through the same `Review_engine`.
- If the local mode requires an Anthropic key, the test should mock the agent
  runner rather than calling the real API.

Verification:

```bash
make fmt
make build
make test
```

## Stage 7: Generalize Config and State Carefully

Purpose: remove remaining GitHub-shaped assumptions after the core split is
proven.

Tasks:

- Audit `Context` for assumptions around GitHub repo URLs, hook secrets, and
  GitHub auth.
- Introduce neutral identifiers only where they improve adapter support:
  - `repo_key`
  - `change_key`
  - maybe `source_kind`
- Keep GitHub state dedup semantics unchanged:
  - PR dedup by repo URL, PR number, head SHA
  - push dedup by repo URL and after SHA
- Decide whether non-GitHub modes use the same persistent state or provide
  adapter-specific state.
- Avoid changing secrets format until at least one non-GitHub source/sink works.

Files likely touched:

- `lib/context.ml`
- `lib/context.mli`
- `lib/state.ml`
- `lib/state.mli`
- `lib/state_types.ml`
- `lib/config_types.ml`
- `secrets.json.example`
- `docs/README.md`

Working state:

- Existing `secrets.json` remains valid.
- Existing state files remain readable, or a migration/default path is provided.
- Existing GitHub dedup tests pass.

Verification:

```bash
make fmt
make build
make test
```

## Non-Goals For The First Pass

- Do not build a dynamic plugin registry before there are at least two real
  source/sink paths.
- Do not rewrite the whole webhook server.
- Do not rename every `repo_url` occurrence up front.
- Do not change secrets format in the early stages.
- Do not change review prompts unless a stage explicitly needs it.
- Do not introduce a new dependency for the architecture split.

## Risks And Watch Points

- GitHub inline review anchoring is sensitive. Preserve tests around
  multi-line ranges, unchanged-code findings, and anchor failures.
- Security analysis uses file content tools. The fetch callback must preserve
  the current behavior of fetching from the PR head SHA or push after SHA.
- `Security_memory.repo_slug` currently receives repo URLs. If local or GitLab
  keys are introduced, check debug and memory path behavior.
- `Context.get_config` is keyed by repo URL today. Early stages should keep
  GitHub URLs as `repo_key` to avoid breaking config caching.
- `State` is GitHub-shaped. Leave it alone until the engine works with at least
  one non-GitHub source.
- `Lwt.async` is currently used in the webhook handler. This plan does not
  address background execution policy, but future source adapters should avoid
  copying that pattern blindly.

## Pickup Instructions

When resuming this plan:

1. Start at the first incomplete stage.
2. Read this plan and the current `lib/reviewer.ml`, `lib/api.ml`,
   `lib/review_plugin.mli`, and `src/request_handler.ml`.
3. Run the Stage 0 baseline commands if code has changed since the plan was
   written.
4. Make only the changes for the current stage.
5. Run the stage verification commands.
6. Update this plan with a short status note before moving to the next stage.

The next implementation step is Stage 0, followed by Stage 1.
