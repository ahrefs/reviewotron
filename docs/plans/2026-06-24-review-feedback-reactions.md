# Review Feedback via GitHub Reactions - Spec

Date: 2026-06-24
Status: Implemented and manually validated with GitHub PR review feedback

## Status Notes

- 2026-06-29: Stages 1-5 were implemented locally on
  `review-feedback-fixes`.
- 2026-06-30: Manual validation confirmed that a GitHub PR review with inline
  feedback markers writes target records, evidence bundles, and collected
  reaction counts.
- Quality gates pass with `dune build @fmt` and `dune runtest`.
- Remote GitHub feedback list calls paginate with `per_page=100`.
- Feedback webhook persistence failures are logged and do not block normal
  Reviewotron webhook processing.
- `feedback-report` can summarize collected feedback and emit filtered,
  bounded JSON worklists for a later feedback-review agent.

## Context

Reviewotron currently posts GitHub PR review comments for findings, issue
comments for quiet success or review failures, and commit comments for push
reviews. The durable state file is intentionally narrow: it records which
changes were reviewed so Reviewotron can avoid duplicate work. Feedback data
must not be added to `state.json`.

The feedback goal is to let users give a simple thumbs-up or thumbs-down on
Reviewotron review comments, then persist that signal on disk so it can be
queried later to improve review quality.

The preferred disk layout is sibling files next to the configured state file:

```text
/path/to/state.json
/path/to/reviewotron-feedback-targets.json
/path/to/reviewotron-feedback-events.jsonl
```

If `--state` is not configured, feedback persistence should be disabled by
default. A future explicit `--feedback-dir` flag may enable feedback without a
state file, but that is not required for the first implementation.

## Findings From Investigation

- GitHub reactions do not currently arrive as webhook events in our test. On
  2026-06-23, a raw webhook capture server on port `28600` received `status`,
  `pull_request`, and `issue_comment` deliveries while multiple reactions were
  added, but no reaction delivery.
- GitHub's REST API exposes reaction listing endpoints for issue comments and
  pull request review comments.
- Therefore the implementation must use REST polling for reaction counts.
- We should still consume ordinary PR activity webhooks to decide when polling
  can stop early.

## Goals

1. Persist feedback targets for Reviewotron's GitHub inline review comments.
2. Poll GitHub reaction counts for those targets.
3. Store aggregate `+1` and `-1` counts only.
4. Never persist user logins, names, emails, sender objects, author objects, or
   raw webhook payloads.
5. Stop polling each feedback target after:
   - 5 days from the target creation time, or
   - 24 hours after the first qualifying user interaction with the PR after the
     target was created,
   whichever happens first.
6. If the PR is closed or merged earlier, do one final poll and mark the target
   closed.
7. Keep feedback persistence separate from the review dedup state.

## Non-Goals

- Do not train, fine-tune, or automatically adjust prompts in this change.
- Do not store individual reaction authors.
- Do not store raw webhook JSON.
- Do not collect feedback for push commit comments in the first version.
- Do not build an in-app UI.
- Do not add distributed locking for multiple Reviewotron processes sharing
  the same feedback files. The first version only needs process-local safety.

## Definitions

### Feedback Target

A posted Reviewotron comment that can receive feedback. For the first version,
this means a GitHub pull request review inline comment created from a
`Review_types.finding`.

### Feedback Event

An append-only aggregate observation about a feedback target, such as reaction
counts changing or a target being finalized.

### Qualifying User Interaction

The first non-Reviewotron, non-bot interaction on the PR after a feedback target
was created. It shortens the polling window to 24 hours after that interaction.

Qualifying interactions:

- `issue_comment` on a PR: `created` or `edited`
- `pull_request_review`: `submitted`, `edited`, or `dismissed`
- `pull_request_review_comment`: `created` or `edited`
- `pull_request`: `synchronize`, `reopened`, or `ready_for_review`

Non-qualifying interactions:

- `status`
- labels, assignees, milestones, project changes
- events sent by Reviewotron itself
- events where the sender is a bot
- events performed via a GitHub App, unless later product requirements decide
  that app-generated interaction should count

Do not persist the sender used to make this decision. It is only inspected
transiently while handling the webhook.

## Deadline Semantics

Every target starts with:

```text
poll_until = target.created_at + 5 days
first_user_interaction_at = null
```

When the first qualifying user interaction occurs after `target.created_at`:

```text
first_user_interaction_at = interaction.received_at
poll_until = min(existing poll_until, interaction.received_at + 24 hours)
```

The first interaction is the only one that matters. Later interactions do not
extend the window. The 5 day deadline is a hard cap.

Examples:

- Review posted Monday 10:00, no later user interaction:
  stop after final poll on Saturday 10:00.
- Review posted Monday 10:00, user comments Monday 12:00:
  stop after final poll on Tuesday 12:00.
- Review posted Monday 10:00, user comments Friday 09:30:
  stop after final poll on Saturday 10:00, because the 5 day cap wins.
- PR closes Monday 15:00:
  do one final poll, then mark closed.

## Current Code Touch Points

Current relevant modules:

- `lib/state.ml` and `lib/state_types.ml`: review dedup state. Do not extend
  this schema for feedback.
- `lib/context.ml`: currently owns secrets, config cache, and state. Add an
  optional feedback store handle here.
- `src/reviewotron.ml`: parses CLI flags and constructs contexts.
- `src/request_handler.ml`: receives webhooks and dispatches
  `Reviewer.Make.process_event`.
- `lib/github.ml` and `lib/github_types.ml`: parse GitHub webhook payloads.
- `lib/api.ml`, `lib/api_remote.ml`, `lib/api_local.ml`: GitHub API boundary.
- `lib/github_sink.ml`: converts neutral review comments into GitHub review
  comments and posts PR reviews.
- `lib/review_engine.ml`: routes findings to neutral `Review_comment.t`.
- `lib/reviewer.ml`: orchestrates GitHub review flow and records review state.

## Disk Files

### `reviewotron-feedback-targets.json`

Mutable JSON file. It stores the current polling state for all known targets.

Target shape:

```json
{
  "schema": 1,
  "targets": [
    {
      "feedback_id": "rvf_...",
      "review_batch_id": "rvb_...",
      "status": "active",
      "stop_reason": null,

      "repo_url": "https://github.com/org/repo",
      "pr_number": 42,
      "head_sha": "abc123...",

      "target_kind": "pr_review_comment",
      "review_id": 123456,
      "comment_id": 987654,

      "created_at": "2026-06-24T10:00:00Z",
      "poll_until": "2026-06-29T10:00:00Z",
      "first_user_interaction_at": null,
      "last_polled_at": null,
      "final_polled_at": null,

      "path": "lib/example.ml",
      "line": 123,
      "start_line": null,
      "severity": "warning",
      "category": "security",
      "confidence": "high",

      "finding": {},
      "comment_body_sha256": "...",
      "last_counts": {
        "plus_one": 0,
        "minus_one": 0
      }
    }
  ]
}
```

Notes:

- `finding` may contain the Reviewotron-generated finding data needed for later
  analysis. It must not contain GitHub users or webhook sender data.
- `repo_url` is persisted because the collector needs it to authenticate and
  query GitHub. It is review identity metadata, not reaction-user metadata.
- `comment_id` may be `null` immediately after posting if the implementation
  resolves comment IDs later by listing review comments and matching the hidden
  feedback marker.
- Store UTC RFC3339 timestamps.
- `status` values:
  - `active`: still eligible for polling.
  - `final_due`: target should receive one final poll, then stop.
  - `closed`: PR closed or merged and final poll completed.
  - `expired`: polling deadline elapsed and final poll completed.
  - `missing`: target comment no longer exists or GitHub repeatedly returns
    not found.
  - `error`: repeated API errors prevent collection; keep enough error text to
    debug, but no raw response bodies containing users.
- `stop_reason` values:
  - `pr_closed`
  - `poll_window_elapsed`
  - `comment_missing`
  - `api_error`

### `reviewotron-feedback-events.jsonl`

Append-only JSONL. It stores aggregate observations, not users.

Reaction count event:

```json
{
  "schema": 1,
  "kind": "reaction_counts_changed",
  "feedback_id": "rvf_...",
  "observed_at": "2026-06-24T12:00:00Z",
  "plus_one": 3,
  "minus_one": 1
}
```

Finalization event:

```json
{
  "schema": 1,
  "kind": "target_finalized",
  "feedback_id": "rvf_...",
  "observed_at": "2026-06-25T12:00:00Z",
  "status": "expired",
  "stop_reason": "poll_window_elapsed",
  "plus_one": 3,
  "minus_one": 1
}
```

Append an event only when:

- reaction counts changed since the last stored counts,
- a target is finalized,
- comment ID resolution succeeds for the first time,
- or an exceptional terminal condition occurs.

Do not append an event on every no-op poll.

## Privacy Requirements

Feedback files must not contain:

- `sender`
- `user`
- `login`
- `name`
- `email`
- `author`
- `committer`
- `pusher`
- `avatar_url`
- raw webhook payloads
- raw reaction objects

The implementation may inspect these fields transiently to decide whether an
event came from Reviewotron, a bot, or a human, but it must not write them to
disk.

Validation must include a test that serializes representative feedback files
and fails if these forbidden field names appear.

## Feedback IDs and Comment Markers

Every inline comment posted by Reviewotron should include a hidden marker:

```markdown
<!-- reviewotron-feedback-id: rvf_... -->
```

The marker should be appended to the comment body after the rendered finding
body. GitHub keeps HTML comments in the API body while hiding them in the UI,
which lets the collector map a GitHub review comment back to a target.

Generate IDs before posting:

```text
review_batch_id = "rvb_" + digest(repo_url, pr_number, head_sha, now, process-local nonce)
feedback_id = "rvf_" + digest(review_batch_id, comment_index, path, line, comment_body)
```

Use an existing digest dependency, such as `Digestif.SHA256`. Do not add a UUID
dependency only for this.

Tests should make ID generation deterministic by injecting `now` and nonce
inputs into the ID helper.

## API Changes

### Created PR Review Result

Change the GitHub review posting boundary so `create_pr_review` returns the
created review ID instead of discarding the response body.

Target type:

```ocaml
type created_pr_review = {
  id : int;
  html_url : string option;
}
[@@deriving json] [@@json.allow_extra_fields]
```

API signature target:

```ocaml
val create_pr_review :
  ctx:Context.t ->
  repo_url:string ->
  number:int ->
  Github_types.create_review_req ->
  (Github_types.created_pr_review, string) result Lwt.t
```

`api_local.ml` should return deterministic fake review IDs and keep logging the
posted JSON for existing tests.

### Feedback API

Add a GitHub feedback API boundary. Keep it separate from generic review source
and sink signatures because this is GitHub-specific collection behavior.

```ocaml
module type Github_feedback = sig
  val list_pr_review_comments :
    ctx:Context.t ->
    repo_url:string ->
    number:int ->
    review_id:int ->
    (Github_types.pr_review_comment list, string) result Lwt.t

  val list_pr_review_comment_reactions :
    ctx:Context.t ->
    repo_url:string ->
    comment_id:int ->
    (Github_types.reaction list, string) result Lwt.t
end
```

Remote endpoint mapping:

- `list_pr_review_comments`: `GET /pulls/{number}/reviews/{review_id}/comments`
- `list_pr_review_comment_reactions`:
  `GET /pulls/comments/{comment_id}/reactions`

Reaction data should be reduced immediately to aggregate counts:

```ocaml
type reaction_counts = {
  plus_one : int;
  minus_one : int;
}
```

Do not persist `Github_types.reaction.user`.

## Store Module

Add `lib/feedback_store.ml` and `lib/feedback_store.mli`.

Responsibilities:

- derive feedback paths from `state_filepath`;
- load empty data when files do not exist;
- save `reviewotron-feedback-targets.json` atomically;
- append events to `reviewotron-feedback-events.jsonl`;
- update targets for posted reviews;
- resolve GitHub comment IDs from marker-bearing comments;
- apply user-interaction deadlines;
- mark closed/final-due targets;
- select pollable targets;
- update counts and status after polling.

Use a process-local `Lwt_mutex.t` or equivalent sequencing so concurrent
webhook handlers in the same Reviewotron process do not clobber each other's
file updates.

Do not use `State.t` or `State_types` for this data.

## Publishing Flow

When `Github_sink.publish_pr_review` is about to post a review:

1. Build a `review_batch_id`.
2. Attach a `feedback_id` to every inline review comment.
3. Append the hidden marker to each comment body.
4. Post the PR review.
5. If posting succeeds, record feedback targets in `Feedback_store`.
6. Record the normal PR review state exactly as today.
7. If posting fails, do not record feedback targets.

The first implementation may create targets with `comment_id = null` and
resolve the IDs in the collector. That reduces synchronous post-review API
calls.

The first implementation should collect inline finding comments only. It may
skip:

- top-level PR review body reactions,
- quiet `LGTM :+1:` issue comments,
- review-failure issue comments,
- push commit comments.

## Webhook Interaction Flow

Webhook handling should update feedback target deadlines independently of
whether the webhook triggers a new review.

For every parsed GitHub webhook event:

1. If feedback is disabled, do nothing.
2. If the event is a PR close/merge event:
   - mark active targets for the PR as `final_due` with stop reason
     `pr_closed`;
   - the collector will perform the final poll and mark them `closed`.
3. If the event is a qualifying user interaction:
   - for active targets on that PR with no `first_user_interaction_at`, set
     `first_user_interaction_at` and shrink `poll_until` as specified above.
4. Continue normal Reviewotron event processing.

Parsing requirements:

- Existing `issue_comment` support can be reused for PR issue comments.
- Add minimal webhook payload types for `pull_request_review` and
  `pull_request_review_comment`.
- Existing `pull_request` payloads can identify `closed`, `synchronize`,
  `reopened`, and `ready_for_review`.

## Collector Command

Add a one-shot command:

```text
reviewotron collect-feedback --secrets secrets.json --state state.json
```

The command:

1. Loads secrets and feedback files.
2. Selects active or final-due targets that are due for polling.
3. Resolves missing `comment_id` values by listing comments for `review_id` and
   matching the hidden marker.
4. Lists reactions for each resolved review comment.
5. Reduces reactions to `+1` and `-1` counts.
6. Updates target state.
7. Appends events only for changed counts, resolved IDs, or finalization.
8. Exits.

Run this command from cron/systemd every 30 to 60 minutes. The exact external
schedule is not part of Reviewotron.

Polling due logic:

- Use a default `poll_interval` of 1 hour.
- A target is due when `last_polled_at = null`.
- A target is due when `now - last_polled_at >= poll_interval`.
- A target is final-due when `status = final_due`.
- A target whose active deadline has elapsed should receive one final poll and
  then become `expired`.
- A target already in `closed`, `expired`, `missing`, or terminal `error` is
  never polled again.

## Error Handling

Per-target failures should not abort the whole collector run.

Recommended behavior:

- `404` on a review comment:
  - mark target `missing`;
  - append `target_finalized` with `stop_reason = comment_missing`.
- transient HTTP or auth failure:
  - keep target active;
  - log the error;
  - do not append an event unless a retry policy later marks terminal `error`.
- malformed API response:
  - keep target active;
  - log enough context to diagnose endpoint and target ID;
  - do not write raw response bodies to feedback files.

## Success Criteria

Functional success:

1. When Reviewotron posts a PR review with inline comments, each inline comment
   contains a hidden feedback marker.
2. A sibling `reviewotron-feedback-targets.json` file is created when feedback
   is enabled.
3. The target file records one target per inline review comment.
4. No target is recorded when PR review posting fails.
5. The collector can resolve GitHub review comment IDs from hidden markers.
6. The collector records aggregate `+1` and `-1` counts.
7. Counts changing appends a `reaction_counts_changed` JSONL event.
8. No-op polls update `last_polled_at` without appending noisy events.
9. A qualifying user interaction shrinks the target's `poll_until` to at most
   24 hours after that interaction.
10. The 5 day hard cap is always respected.
11. Closing or merging a PR triggers one final poll and then stops collection.
12. Expired and closed targets are not polled again.
13. Feedback data remains separate from `state.json`.
14. Feedback files do not persist user logins, names, emails, sender objects, or
    raw webhook payloads.

Operational success:

1. Existing review behavior is unchanged when feedback is disabled.
2. Existing dedup state behavior is unchanged.
3. Collector failures for one target do not prevent other targets from being
   polled.
4. Running the collector repeatedly is idempotent except for meaningful JSONL
   events.

## Validation Criteria

### Unit Tests

Add focused tests for:

- feedback path derivation from `--state`;
- feedback target JSON roundtrip;
- JSONL event append shape;
- forbidden-key privacy scan over serialized feedback files;
- feedback ID marker rendering and extraction;
- deadline initialization at `created_at + 5 days`;
- first user interaction sets `poll_until = min(existing, interaction + 24h)`;
- later user interactions do not extend polling;
- interaction after target finalization has no effect;
- close event marks active targets as `final_due`;
- target selection for normal poll, final poll, expired, closed, missing, and
  error states.

### API Local Tests

Extend `api_local.ml` test hooks to support:

- deterministic created review IDs;
- deterministic review comments returned for a review ID;
- deterministic reaction lists or direct reaction count fixtures;
- comment missing / 404 simulation;
- transient error simulation.

### Integration Tests

Add Reviewotron flow tests that assert:

- a normal PR review writes feedback targets when inline comments are posted;
- the posted comment bodies include `reviewotron-feedback-id`;
- a no-finding quiet success comment does not create inline feedback targets in
  the first version;
- a failed PR review post does not create feedback targets;
- `issue_comment.created` on the PR shortens the polling deadline;
- `pull_request.closed` marks targets final-due;
- `collect-feedback` resolves comment IDs and records counts;
- rerunning `collect-feedback` without count changes does not append duplicate
  count events.

### Manual Validation

Against a test GitHub repository:

1. Start Reviewotron with `--state /tmp/reviewotron/state.json`.
2. Trigger a PR review that posts at least one inline comment.
3. Confirm feedback targets are written next to `state.json`.
4. Add `+1` and `-1` reactions to the inline review comment.
5. Run `reviewotron collect-feedback --secrets ... --state ...`.
6. Confirm aggregate counts appear in targets and JSONL events.
7. Add a normal PR comment.
8. Confirm the target polling deadline shrinks to 24 hours after that comment,
   without storing the comment author's login.
9. Close the PR.
10. Run the collector and confirm targets become `closed`.

### Quality Gates

Run:

```text
make fmt
make build
make test
```

If a repository-wide test is already failing for unrelated reasons, document
the failure and run the narrowest relevant test target that covers this feature.

## Implementation Stages

### Stage 1: Feedback Store and Types

- Add feedback target/event types.
- Add `Feedback_store`.
- Add path derivation from state filepath.
- Add privacy tests and deadline tests.

Working state:

- No runtime behavior changes.
- `make fmt`, `make build`, and target tests pass.

### Stage 2: Publish-Time Target Recording

- Add created PR review response parsing.
- Add feedback ID generation.
- Add hidden markers to inline comment bodies.
- Record targets after successful PR review posting.
- Update `api_local` for deterministic review IDs.

Working state:

- Existing review tests still pass after expected fixture updates.
- Feedback disabled preserves old posted comment bodies.

### Stage 3: Webhook Deadline Updates

- Add minimal `pull_request_review` and `pull_request_review_comment` payload
  types.
- Add interaction classification.
- Update target deadlines on qualifying interaction.
- Mark targets final-due on PR close/merge.

Working state:

- Existing webhook behavior remains unchanged.
- New deadline tests pass.

### Stage 4: Collector

- Add GitHub feedback API endpoints.
- Add `collect-feedback` CLI command.
- Resolve comment IDs by marker.
- Poll reaction counts.
- Append events on changes/finalization.

Working state:

- Collector is idempotent.
- API local collector tests pass.

### Stage 5: Documentation

- Update `docs/README.md` with feedback file behavior, privacy guarantees, and
  collector command usage.
- Update this plan's status notes after implementation.

## Open Questions

1. Should feedback be enabled automatically whenever `--state` is present, or
   should there be an explicit `--feedback` opt-in flag? The spec assumes
   automatic when `--state` is present.
2. Should quiet success and failure issue comments become feedback targets in a
   later phase? The first version excludes them.
3. Should `performed_via_github_app` events always be ignored as non-user
   interactions? The spec says yes for the first version.
