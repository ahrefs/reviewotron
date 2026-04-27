# Review-comment trigger design — 2026-04-27

## Context

Reviewotron currently reviews on `pull_request` (opened/synchronize/etc.) and
`push` (to `develop`) webhook events. `issue_comment` deliveries arrive at the
webhook endpoint but `Github.parse_event` falls through to `Unknown _`, and
the reviewer's `process_event` discards them.

We want a manual trigger: someone comments `REVIEW` on a PR, and the bot runs
the same review pipeline as a PR-open event. Existing automatic triggers also
get their defaults flipped to off so a fresh repo with no `.reviewotron.json`
is silent until explicitly opted in.

## Decisions

- **Trigger phrase:** the comment body, after trimming leading/trailing
  whitespace, must equal exactly `REVIEW`. No `@`, uppercase, exact match.
  Anything else (including `REVIEW please`) does not trigger.
- **Gating:** four independent boolean flags in `.reviewotron.json`, all
  default `false`:
  - `auto_review_pr_open` (was `true`) — review on PR opened/reopened/ready.
  - `auto_review_pr_sync` (was `true`) — review on new commits to a PR.
  - `review_pushes_to_develop` (was `true`) — review pushes to `develop`.
  - `auto_review_on_comment` (new) — review on `REVIEW` PR comments.
- **Authorisation:** anyone who can post a top-level PR comment can trigger,
  filtered only by the existing `is_bot_sender` (suffix `[bot]`) and
  `ignored_authors` checks. No org/membership/permission API calls.
- **Re-review semantics:** a `REVIEW` comment re-triggers a review even on a
  head SHA already reviewed before. The `State.is_pr_reviewed` dedup that
  protects PR-open/synchronize from double-reviewing the same SHA is
  bypassed on the comment trigger path — manual trigger means the user
  wants a fresh review.

## Section 1 — Webhook intake and event typing

### Payload field shapes (verified against GitHub REST/webhook docs, 2026-04-27)

`issue_comment` top-level: `action`, `issue`, `comment`, `repository`,
`sender`, `installation`. Action enum: `created | edited | deleted |
pinned | unpinned`. We act only on `created`.

`issue` object: `number` (int), `title` (string), `state` (string,
`open|closed`), `user` (object or null), `html_url` (string),
`pull_request` (object or null — present-but-null on regular issues,
non-null on PRs). The inner `pull_request` carries `url`, `html_url`,
`diff_url`, `patch_url`, `merged_at`; we don't dereference any of these,
we use the field's mere non-null-ness as the "is this a PR comment?"
discriminator.

`comment` object: `id` (int), `body` (string, never null in webhook
deliveries), `user` (object or null), `html_url` (string), plus other
fields we ignore (`created_at`, `updated_at`, `author_association`,
`reactions`, `node_id`, etc.).

`repository`, `sender`, `installation`: identical shape to the existing
`pr_notification`/`commit_pushed_notification` fields. Reused as-is.

### Types added in `lib/github_types.ml`/`.mli`

```ocaml
type issue_pull_request_ref = { url : string }
[@@deriving json] [@@json.allow_extra_fields]

type issue = {
  number : int;
  title : string;
  state : string;
  user : github_user option;
  html_url : string;
  pull_request : issue_pull_request_ref option;
}
[@@deriving json] [@@json.allow_extra_fields]

type issue_comment = {
  id : int;
  body : string;
  user : github_user option;
  html_url : string;
}
[@@deriving json] [@@json.allow_extra_fields]

type issue_comment_notification = {
  action : string;
  issue : issue;
  comment : issue_comment;
  repository : repository;
  sender : github_user;
  installation : installation option;
}
[@@deriving json] [@@json.allow_extra_fields]
```

`[@@json.allow_extra_fields]` everywhere because GitHub adds new fields
over time. `user` fields are `option` because the schema permits null
(deleted users); in practice a freshly-created comment's user is set.

### Event variant

`Github.event` gains `Issue_comment of Github_types.issue_comment_notification`.
`repo_url_of_event` gets the matching arm. `parse_event` gets a
`"issue_comment"` arm that decodes the JSON and logs at info level
matching the existing PR/push log format.

## Section 2 — Config flag, dispatch, and trigger logic

### Config

`Config_types.config` gains `auto_review_on_comment : bool` defaulting to
`false`. The three existing flags (`auto_review_pr_open`,
`auto_review_pr_sync`, `review_pushes_to_develop`) flip their defaults
from `true` to `false`.

### Skip-reason helper

`comment_skip_reason : ctx -> issue_comment_notification -> string option`,
mirroring `pr_skip_reason`/`push_skip_reason`. Returns `Some reason` to
skip with a log line, `None` to proceed. Order:

1. `action <> "created"` → `"comment action <X> not reviewable"`
2. `issue.pull_request = None` → `"comment is on an issue, not a PR"`
3. `issue.state <> "open"` → `"PR state is <X>"`
4. `not config.auto_review_on_comment` → `"auto_review_on_comment disabled"`
5. `is_bot_sender sender.login` → `"bot sender <X>"`
6. `sender.login` ∈ `ignored_authors` → `"ignored author <X>"`
7. otherwise → `None`

The trigger-phrase check (`String.trim body = "REVIEW"`) lives in the
dispatch site, *before* `comment_skip_reason` is called, and silently
returns without logging when the body doesn't match. This avoids log
spam from regular conversation comments. Skip reasons are only logged
when an actual `REVIEW` comment is rejected.

### API extension

`Api.Github` gains:

```ocaml
val get_pull_request :
  ctx:Context.t -> repo_url:string -> number:int ->
  (Github_types.pull_request, string) result Lwt.t
```

Implemented in `Api_remote` as `GET /repos/{owner}/{repo}/pulls/{number}`,
parsed via the existing `pull_request_of_json`. Stubbed in `Api_local`
via the existing fixture-lookup pattern.

Why this is needed: `issue_comment` payloads carry the `issue` shape, not
the `pull_request` shape. Crucially they lack `head.sha`, which the
review pipeline needs as the git ref for `fetch_key_files` and
file-content lookups in the security plugin. The PR-event path doesn't
need this fetch because GitHub ships the full `pull_request` inline on
PR webhooks. One extra HTTP call per comment trigger is the cost.

### Dispatch flow

The existing `review_pr` is split into two pieces:

- `do_review_pr ~ctx pr_notif` — the body of the current `review_pr`,
  no skip checks. Runs the diff fetch, plugin pipeline, and posts the
  review.
- `review_pr ~ctx pr_notif` — calls `do_review_pr` after `pr_skip_reason`
  passes (existing `process_event` PR-arm flow, behaviour-preserving).

New on the comment trigger path:

```ocaml
let review_pr_from_comment ~ctx (n : issue_comment_notification) =
  match%lwt GH.get_pull_request ~ctx ~repo_url:n.repository.url ~number:n.issue.number with
  | Error msg ->
    log#error "failed to fetch PR #%d for comment trigger: %s" n.issue.number msg;
    Lwt.return_unit
  | Ok pr ->
    let synthesised : pr_notification = {
      action = "comment_review";
      number = n.issue.number;
      pull_request = pr;
      repository = n.repository;
      sender = n.sender;
      installation = n.installation;
    } in
    do_review_pr ~ctx synthesised
```

The synthesised `action = "comment_review"` is never matched by
`pr_action_of_string` (falls into `Other _`); we never run it through
`pr_skip_reason`, so this is fine. Bypassing `pr_skip_reason` also
bypasses the `State.is_pr_reviewed` dedup — exactly the re-review
semantics we want for manual triggers.

`process_event` gains:

```ocaml
| Github.Issue_comment n ->
  if String.trim n.comment.body <> "REVIEW" then Lwt.return_unit
  else (
    match comment_skip_reason ~ctx n with
    | None -> review_pr_from_comment ~ctx n
    | Some reason ->
      log#info "comment on PR #%d skipped: %s" n.issue.number reason;
      Lwt.return_unit)
```

## Section 3 — Tests

### Webhook parsing (new fixtures + parser tests)

- `issue_comment_review.json`: `action: "created"`, body `"REVIEW"`,
  `issue.pull_request: { url: "..." }`. Asserts `parse_event` produces
  `Issue_comment _` with the expected fields.
- `issue_comment_on_issue.json`: same shape but `issue.pull_request: null`.
  Asserts the parser still succeeds; dispatch will reject downstream.
- `issue_comment_null_user.json`: `comment.user: null`. Asserts no crash.

### Unit tests for `comment_skip_reason`

Each scenario constructs an in-memory `issue_comment_notification` and
asserts the expected `Some reason | None`:

- All gates pass with `auto_review_on_comment: true` → `None`.
- `auto_review_on_comment: false` → `Some "auto_review_on_comment disabled"`.
- `issue.state = "closed"` → `Some "PR state is closed"`.
- `action = "edited"` → `Some "comment action edited not reviewable"`.
- `issue.pull_request = None` → `Some "comment is on an issue, not a PR"`.
- `sender.login = "dependabot[bot]"` → `Some "bot sender ..."`.
- `sender.login` in `ignored_authors` → `Some "ignored author ..."`.

### End-to-end (added to `reviewer_e2e` group)

- `comment trigger reviews PR`: sets `auto_review_on_comment: true`,
  mocks `get_pull_request`, mocks general/security agents, sends an
  `issue_comment.created` event with body `"REVIEW"`, asserts
  `[create_pr_review]` appears in the write log.
- `comment trigger disabled`: same event, `auto_review_on_comment: false`.
  Asserts no `[create_pr_review]` write.
- `comment with non-trigger body`: same event, `body: "looks good"`.
  Asserts no review and no skip-reason log line.

### Default-flip regression

Every existing test that depended on the old `true` defaults gets its
config fixture edited explicitly. Approach: option (a) from brainstorming
— edit the fixtures rather than alter test-helper defaults, so each
test declares its dependence on a flag explicitly. Inline configs are
edited in place; shared `mock_payloads/` config fixtures get edited if
no test reads the old defaults, otherwise a new fixture is added for
the tests that need explicit-true.

## Section 4 — Documentation

In `docs/README.md`:

- Supported-events table gains a row for `issue_comment` (created, on a PR,
  body equals `REVIEW`).
- A new "Defaults" callout under "How It Works" makes plain that all four
  automatic triggers are off by default and lists the four flags with
  one-liner descriptions.
- Config fields table: defaults of the three existing flags flip from
  `true` to `false`; new `auto_review_on_comment: false` row added.
- Example JSON in the config reference section updated to reflect the
  new field and new defaults.

No CHANGELOG / breaking-change subsection — users who upgrade and find
the bot silent will read the README and opt in.

## Section 5 — Implementation order

Five commits, each one builds and passes tests on its own:

1. **Add `Issue_comment` event variant + types + parser arm.** No
   handler yet; `process_event` falls through with a debug log.
   Tests: new parser fixtures.
2. **Add `get_pull_request` to `Api.Github` + implementations.** No
   reviewer changes. Tests: `Api_local` fixture support, existing
   tests still pass.
3. **Flip the existing flag defaults to `false` + edit test fixtures.**
   Tests: full suite passes with explicit-true fixtures wherever the
   old defaults were relied on.
4. **Wire up the comment trigger.** Adds `auto_review_on_comment`,
   `comment_skip_reason`, `review_pr_from_comment`, dispatch arm.
   Tests: unit tests for the helper, e2e tests for the trigger path.
5. **Documentation update** per Section 4.

Each commit is independently reviewable and revertible.
