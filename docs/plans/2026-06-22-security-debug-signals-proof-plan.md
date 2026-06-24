# Security Debug, Signals, and Proof Plan

**Date:** 2026-06-22
**Status:** Draft

## Goal

Implement the first high-leverage tranche from the Piolium/Shannon review:

1. security debug and metrics observability;
2. deterministic diff signals before LLM triage;
3. proof-by-construction validator output.

The goal is not to turn Reviewotron into a full audit harness. Reviewotron
should remain a bounded diff reviewer. These changes should make the existing
security pipeline easier to tune, cheaper to reason about, and stricter about
what can be reported.

## Non-Goals

- No live exploit execution.
- No repository-wide browsing.
- No Semgrep or CodeQL execution in the webhook path.
- No new finding source that bypasses the validator.
- No user-visible raw debug artifacts.
- No silent long-term retention of prompts, fetched files, or model reasoning by
  default.

## Guiding Decisions

### Metrics vs Full Debug Artifacts

Use two levels of observability:

- **Stage metrics:** compact counters with no source code or prompt bodies. These
  can be logged on normal runs and optionally written as JSON.
- **Full debug artifacts:** model inputs, outputs, candidate findings, validator
  decisions, and fetched-context summaries. These are sensitive and should be
  opt-in.

Full debug artifacts stay off by default because they can contain proprietary
code, secrets in diffs, PII, and details of real security bugs. The performance
cost is expected to be small relative to LLM calls; the main concerns are data
retention, disk growth, and access control.

### Default Behavior

- Webhook/server mode should not write full security artifacts unless explicitly
  configured.
- Local runs may expose an easy flag later, but the first implementation can use
  config only.
- Logs should receive low-sensitivity stage metrics by default.
- Persisted `metrics.json` should be enabled by config, not silently written for
  every webhook review.

### Artifact Scope

Artifacts live under the existing per-review debug directory:

```text
debug/<repo-slug>/<sha>/security/
```

The normal review output, review comments, and cost records continue to flow
through the current `Review_engine` path. Artifacts are a side channel for
offline tuning only.

## Phase 1: Security Metrics and Debug Artifacts

### Configuration

Add security plugin config fields:

```json
{
  "review_plugins": {
    "security": {
      "metrics_artifacts": false,
      "debug_artifacts": false
    }
  }
}
```

Meanings:

- `metrics_artifacts`: write compact `metrics.json` and `manifest.json`.
- `debug_artifacts`: write full per-stage inputs/outputs in addition to metrics.

Both default to `false`. Stage metrics should still be logged in normal runs.

### Artifact Files

When `metrics_artifacts` or `debug_artifacts` is enabled:

```text
manifest.json
metrics.json
fetch_stats.json
```

When `debug_artifacts` is enabled:

```text
deterministic_signals.json
triage_input.md
triage_output.json
analysis_<vuln_class>_input.md
analysis_<vuln_class>_output.json
validator_input.md
validator_output.json
final_findings.json
memory_observations.json
```

### Metrics Contents

`metrics.json` should summarize:

- changed file count;
- deterministic signal counts by category and vuln-class hint;
- triage signal count;
- actionable triage signal count;
- analysis agents run;
- raw candidates produced;
- candidates kept after deduplication;
- duplicate candidates dropped;
- validator results confirmed/rejected;
- final findings produced;
- findings anchored inline, on unchanged code, or anchor-failed if available;
- security file-fetch and related-file stats;
- per-agent token/cost summary copied from existing `Cost_tracking` records.

If routing outcomes are only available after `Review_engine.route_findings`, add
them later. The first version can record final security findings before engine
routing.

### Redaction

Before writing full artifacts, redact obvious secret-like values:

- API keys and bearer tokens;
- GitHub tokens;
- `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, and similar env-style names;
- long high-entropy quoted strings;
- common password/secret/private-key field names.

Redaction is best effort. It reduces accidental leakage but does not make full
artifacts safe for broad retention.

### Implementation Shape

- Add a small `Security_artifacts` module.
- Create an artifact context at the start of `Security_review_plugin.Make.run`.
- Thread that context through triage, analysis, validator, and memory
  observation construction.
- Write artifacts best-effort: I/O failures log warnings and never change review
  behavior.
- Reuse existing `debug_dir`; do not add a second root path.

### Tests

- Disabled config writes no artifacts.
- Metrics config writes `manifest.json`, `metrics.json`, and `fetch_stats.json`
  without prompt bodies.
- Debug config writes stage inputs/outputs.
- Redaction removes obvious secret values.
- Artifact write failure does not fail the review.

## Phase 2: Deterministic Diff Signals

### Purpose

Add a cheap native pass over changed files and changed hunks before LLM triage.
The pass emits structured signals that guide triage. Signals are not findings
and never bypass analysis or validation.

### Signal Type

Add a type such as:

```ocaml
type signal_category =
  | Dangerous_api
  | Risky_path
  | Sensitive_file
  | Changed_security_control
  | Stateful_operation

type candidate_signal = {
  category : signal_category;
  vuln_class_hint : Config_types.vuln_class option;
  path : string;
  start_line : int;
  end_line : int;
  pattern : string;
  rationale : string;
}
```

Keep the type small and deterministic. If a signal can plausibly map to
multiple vuln classes, either emit multiple signals or leave
`vuln_class_hint = None`.

### Initial Signal Families

- Dangerous APIs: shell execution, raw SQL, HTML sinks, outbound URL fetches,
  file path joins, deserialization, JWT/session calls.
- Risky paths: `auth`, `middleware`, `payment`, `billing`, `webhook`, `admin`,
  `parser`, `proxy`, `upload`, `tenant`, `policy`.
- Sensitive file kinds: route definitions, middleware/policy files, workflow
  files, Docker/Terraform/Kubernetes config, package manifests.
- Changed security controls: sanitizers, allowlists, permission checks,
  escaping helpers, request validation.
- Stateful operations: balances, quotas, inventory, counters, credits, seats,
  limits, status transitions, idempotency, transactions, locks, retries.

The stateful family is included here so the later state/concurrency probe has a
deterministic trigger substrate. It should not introduce a new model call in
this tranche.

### Prompt Integration

Extend `Triage_agent.build_input` with an optional deterministic signal summary:

```text
## Deterministic Diff Signals

- <category> <path>:<line-range> [<vuln-class-hint>] <pattern>
  Rationale: ...
```

Triage instructions should say:

- deterministic signals are hints, not findings;
- a signal can raise attention but cannot replace source/effect/control
  reasoning;
- triage may ignore a deterministic signal if the diff is not security
  actionable.

### Artifact Integration

- Write `deterministic_signals.json` when `debug_artifacts = true`.
- Include signal counts in `metrics.json` when `metrics_artifacts` or
  `debug_artifacts` is enabled.
- Log signal counts on normal runs.

### Tests

- Signal extraction for representative dangerous APIs.
- Risky path and sensitive file matching.
- Changed security-control matching.
- Stateful operation matching.
- Correct line ranges from annotated diff data.
- Empty-signal diffs.
- Signals do not trigger analysis unless triage returns actionable signals.

## Phase 3: Proof-By-Construction Validator Output

### Purpose

Force the validator to construct a concrete static exploitation sketch before
it can return `confirmed`. This is the static equivalent of Shannon's proof
discipline and should reduce plausible-but-untriggerable findings.

### Type Shape

Add a proof record:

```ocaml
type exploitation_proof = {
  trigger : string;
  preconditions : string list;
  source_to_sink_trace : string list;
  missing_or_inadequate_control : string;
  expected_impact : string;
  assumptions : string list;
}
```

Extend `validated_finding` with:

```ocaml
proof_by_construction : exploitation_proof option;
```

The field is semantically required for `Confirmed`. It may be absent or `null`
for `Rejected`.

Because the JSON schema cannot easily enforce a verdict-dependent field, enforce
this after parsing:

- confirmed with concrete proof stays confirmed;
- confirmed with missing or empty proof is downgraded to rejected, with an
  evidence note explaining the schema violation;
- rejected does not require proof.

### Prompt Changes

Update `Validator_agent.system_prompt`:

- no candidate may be confirmed unless the proof is concrete;
- the trigger must be copy-pasteable or directly reproducible as a request,
  function call, user action, or payload;
- the trace must be tied to file and line evidence;
- unresolved assumptions must be listed explicitly;
- if assumptions are essential to exploitability and cannot be checked, reject.

Update output instructions to include `proof_by_construction`.

### Review Output

First version:

- keep full proof in debug artifacts and validator JSON;
- summarize proof in the developer-facing finding fields:
  - `failure_scenario`: concise trigger plus expected impact;
  - `evidence_snippet`: shortest useful source-to-sink trace, with file/line
    references;
  - `why_now`: how the reviewed change introduces, exposes, or strengthens the
    vulnerable path.

Do not dump the full proof into inline comments by default. Review comments
should remain short and fix-oriented.

### Tests

- JSON parsing for confirmed proof.
- Confirmed result without proof is downgraded/rejected.
- Rejected result without proof remains valid.
- Mock validator responses updated.
- A plausible candidate without a concrete trigger is rejected.
- Existing confirmed security corpus cases include proof.

## Evaluation Loop

The artifact work is only useful if it creates a measurable loop. Before
implementing deterministic signals or proof enforcement, capture a baseline
using the existing security corpus and any locally labeled cases available.

### Baseline Metrics

For each vulnerability class, report:

- triage recall;
- triage precision;
- pipeline true-positive rate;
- clean-case post-validation false-positive rate;
- average and p95 agent count;
- average and p95 tool calls;
- average and p95 fetched files and bytes;
- average and p95 estimated cost.

Also report aggregate metrics across all classes.

### Before/After Reports

After each tranche, produce a short before/after report:

1. after metrics/artifacts only;
2. after deterministic signals;
3. after proof-by-construction enforcement;
4. after developer-facing proof summaries.

Each report should state:

- which corpus cases changed outcome;
- which stage changed the outcome;
- whether false positives increased;
- whether cost, tool calls, or fetched bytes regressed;
- whether any prompt/schema changes caused parse failures.

### Rollout Guardrails

Do not broadly enable a tranche if:

- clean-case false positives increase without a deliberate exception;
- confirmed findings lack concrete proof;
- average cost or tool calls rise materially without a matching recall gain;
- artifacts show that deterministic signals cause triage to flag
  security-adjacent but non-actionable diffs;
- parse failures increase.

An observability-only tranche may ship without recall improvement if behavior is
otherwise unchanged and the new metrics are correct.

### Corpus Expansion

When artifacts expose a false positive or false negative, reduce it to the
smallest useful labeled corpus fixture:

- one vulnerable fixture when a real issue was missed;
- one clean fixture when a false positive was reported;
- expected stage outcome when the bug is specifically in triage, analysis, or
  validator behavior.

Raw debug artifacts are diagnostic input, not the long-term evaluation source.

## How We Use These Artifacts Later

Use artifacts to diagnose pipeline failures by stage:

- **False negative, no deterministic signal:** add or refine scanner rules.
- **Deterministic signal present, no triage signal:** adjust triage prompt or
  signal summary shape.
- **Triage signal present, no analysis candidate:** tighten the class playbook or
  analysis input.
- **Candidate present, wrongly rejected:** improve validator proof rubric or file
  fetch guidance.
- **Candidate wrongly confirmed:** add validator rejection cue and corpus fixture.
- **High cost:** inspect metrics for excess analysis agents, tool calls, fetched
  bytes, or validator turns.

Useful artifacts should be reduced into small labeled corpus fixtures. Do not
keep raw debug artifacts as the long-term evaluation source.

## Suggested Implementation Order

1. Add config fields and `Security_artifacts`.
2. Log stage metrics without persisted artifacts.
3. Persist `manifest.json`, `metrics.json`, and `fetch_stats.json` when enabled.
4. Persist full stage artifacts when `debug_artifacts = true`.
5. Add deterministic signal types and scanner.
6. Inject deterministic signal summary into triage.
7. Add signal metrics and tests.
8. Add `exploitation_proof` and validator schema/prompt updates.
9. Enforce confirmed-proof invariant after validator parsing.
10. Populate `failure_scenario`, `evidence_snippet`, and `why_now` from concise
    proof summaries.
11. Update mocks, corpus expectations, docs, and config help.
12. Run and record before/after corpus metrics for the tranche.

## Acceptance Criteria

- Normal webhook review behavior is unchanged when both artifact flags are
  false.
- Normal logs include compact security stage metrics.
- Persisted metrics contain no source code or prompt bodies.
- Full debug artifacts are opt-in and redacted best-effort.
- Deterministic signals guide triage but never produce findings directly.
- Confirmed validator results include a concrete proof-by-construction.
- Missing proof cannot result in a confirmed user-visible finding.
- Security findings use concise proof summaries in `failure_scenario`,
  `evidence_snippet`, and `why_now`.
- Before/after corpus metrics are recorded for each tranche.
- Existing test suite passes, and new unit tests cover scanner, artifacts, and
  proof enforcement.
