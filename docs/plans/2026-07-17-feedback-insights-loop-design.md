# Feedback Insights Loop — Design

**Date:** 2026-07-17
**Status:** Approved design, not yet implemented
**Goal owner:** José
**Executor:** a fresh Claude session picking this up in `/home/me/code/opensource/reviewotron`

---

## 1. Purpose and framing

A Reviewotron deployment on `dev-sg` (`/home/user/reviewotron/var`) has been
collecting feedback on posted PR reviews: per-comment 👍/👎 reactions plus an
immutable evidence bundle per review batch. This project turns that raw
feedback into two documents — `INSIGHTS.md` and `ACTIONABLES.md` — whose single
purpose is to **fine-tune the review engine**: raise review quality, cut noise,
and identify where the engine consistently produces bad results.

Framing decisions already made (do not re-litigate):

- **Dual goal, weighted to tuning.** Produce quality metrics *and* tuning
  recommendations; the narrative emphasis is "what to change next".
- **This is detection-engine root-cause analysis, not comment grading.**
  Findings are detections; 👎 reactions are analyst FP labels. False positives
  cluster — the core deliverable is a Pareto-ranked offender list of
  failure-mode cells, each mapped to a concrete tunable knob.
- **This loop measures precision only — recall is structurally invisible.**
  Reaction data carries *zero* signal about findings the engine *should* have
  made and didn't: you cannot 👎 a comment that was never posted. Every failure
  mode in the taxonomy (§6.4) and every knob it maps to (§6.5) therefore
  *reduces* what the engine emits, so `ACTIONABLES.md` is inherently a
  "say-less" list. Applying it monotonically trades precision up and recall
  down, and the loop will never warn you. This is an accepted, unavoidable
  consequence of the available data — not a defect to design around — but it
  imposes two obligations: (a) every tightening actionable must carry an
  explicit "recall risk: manual FN sanity-check required" flag, and (b) the
  pipeline builds a **protection set** of known-good findings (👍 *and*
  adjudicated-valid) that any proposed change must be checked against (§7a,
  §7c). Without the protection set, this loop is a one-directional ratchet
  toward a timid engine.
- **Reviewotron is a diff reviewer, not a code auditor.** Scope discipline
  (does a finding belong in *this diff's* review?) is itself one of the axes
  under test.
- **Dogfood `feedback-report`.** The existing CLI command is the loop's input.
  Part of the deliverable is a verdict on whether that command is adequate for
  feedback processing; every field the pipeline wished it had is recorded as a
  command gap.

## 2. Source data inventory

### On the deployment (`team@dev-sg:/home/user/reviewotron/var/`)

| File | Size (2026-07-17) | Content |
|---|---|---|
| `reviewotron-feedback-targets.json` | ~820 KB | One target per posted comment / review body: finding metadata (path, line, severity, category, confidence, plugin, message), routing outcome, GitHub linkage, reaction counts (+1/−1), derived sentiment, status, poll timestamps, `evidence_dir` pointer. |
| `reviewotron-feedback-events.jsonl` | ~125 KB | Append-only interaction/poll event log. No pipeline stage depends on it beyond the report's `event_count`; snapshot it, but treat it as optional corroboration (e.g. interaction timing), not a required input. |

**Reactor identity is NOT in the stored data (verified 2026-07-17).**
`Feedback_store.reaction_counts` is `{plus_one; minus_one}` — bare counts, no
actor login. Targets carry no reactor. This matters because reaction *quality*
varies by role: a PR author 👎-ing a finding on their own code is a defensive
signal; a third-party reviewer 👎 is a much stronger FP label. The signal is
**recoverable but not free**: each target stores `comment_id` (and
`review_node_id`), so actor logins could be re-fetched live from the GitHub
reactions API (`GET /repos/{o}/{r}/pulls/comments/{comment_id}/reactions`) or
mined from the events log if webhook interaction events recorded actors.
Decision: this is a **preflight check + optional enrichment, not a
dependency** (Stage 0.5). If actors are cheaply recoverable, weight reactions
by role in Pareto ranking; if not, the "events = optional corroboration"
decision stands and reactions stay role-blind. Record the outcome as a
data-quality note either way.
| `reviewotron-feedback-evidence/` | ~189 dirs | One immutable bundle per review batch (see below). |
| `state.json` | ~957 KB | Review dedup state — not needed by this pipeline, but snapshot it anyway for completeness. |

Total ~2 MB. Disk space is a non-issue (local machine has tens of TB free);
snapshot freely and never prune for space reasons.

### Evidence bundle contents (per `review_batch_id` dir)

Written by `lib/feedback_evidence.ml`, schema 1. Deliberately bounded — **no
prompts, transcripts, webhook payloads, or fetched file contents** (those are
redacted to hashes/byte counts):

- `manifest.json` — batch id, created_at, repo_url, pr_number, head_sha,
  source_kind, trigger, config_sha256, diff_sha256, comment_count,
  github_review_id.
- `filtered_diff.patch` — the exact diff text the engine reviewed. **Ground
  truth for adjudication.**
- `posted_review.json` — review body + every posted comment (anchor, body,
  body sha256, full finding JSON).
- `findings.json` — *all* routed findings including non-posted ones, each with
  `routing_outcome` ∈ {inline, unchanged, anchor_failed,
  dropped_unchanged_low_severity}.
- `review_costs.json` — token/cost accounting per review.
- `review_config.json` — the config used (system_prompt_override redacted to
  hash).
- `fetched_files.json` — path + byte_count + sha256 of every file the engine
  fetched for context (contents not stored).

### Finding shape (from `lib/review_types.ml`)

Each finding carries: `path`, `line`, `end_line?`, `severity`
(critical/warning/suggestion/nitpick/praise), `category`
(bug/security/performance/style/logic/error-handling/naming/documentation/other),
`message`, `failure_scenario`, `evidence_snippet`, `why_now`, `confidence`
(high/medium/low), `suggested_fix?`. The three prose fields
(`failure_scenario`, `evidence_snippet`, `why_now`) are what make independent
re-adjudication possible.

### Reviewed repo

All ~200 reviews target **one repo**, already cloned on this machine. Preflight
must derive its `repo_url` from the targets file and locate the local clone
(ask José if ambiguous). PR head SHAs from manifests must be resolvable in that
clone; if any are missing, backfill with
`git fetch origin '+refs/pull/*/head:refs/remotes/pr/*'`.

### Caveats

- `/home/me/code/opensource/reviewotron` (the main clone where this doc lives)
  contains a **small local test feedback dataset** (3 evidence dirs,
  `reviewotron-feedback-targets.json`, etc. at repo root). This is developer
  test data. **Never mix it with the deployment snapshot.** The snapshot lives
  in its own directory outside the repo.
- Known issue (from prior debugging): `evidence_dir` values stored in
  targets.json may be paths relative to the deployment's CWD or absolute
  server paths. After downloading, `feedback-report` may emit "missing
  evidence" warnings that are really path-resolution artifacts. Verify
  resolution behavior against the snapshot early; if it misresolves, that is a
  **command gap finding** (and there may be a `--feedback-dir` or CWD
  workaround). Do not "fix" it by editing snapshot data.
- The deployment is **live and still collecting**. The snapshot is a
  point-in-time copy; record the snapshot timestamp in every artifact. Never
  write to the server.

## 3. Pipeline overview

Four stages, each producing a durable artifact so the expensive middle stage is
resumable. All artifacts live in one working directory outside the repo (e.g.
`~/reviewotron-feedback-analysis/<snapshot-date>/`), never committed.

```
[dev-sg] var/  ──rsync──►  snapshot/                     Stage 0: fetch
snapshot/      ──reactor-identity probe──►  actors note   Stage 0.5: preflight (optional enrichment)
snapshot/      ──feedback-report --output json──►  report.json   Stage 1: index
report.json + snapshot evidence
               ──per-target adjudication loop──►  verdicts.jsonl Stage 2: diagnose
verdicts.jsonl + reactions
               ──deterministic aggregation──►  aggregates.json   Stage 3a
verdicts.jsonl ──re-shape (zero LLM)──►  eval.jsonl (+ protection set)  Stage 3c
aggregates.json + exhibit verdicts + taxonomy-gap note
               ──synthesis agent──►  INSIGHTS.md + ACTIONABLES.md Stage 3b
eval.jsonl + candidate config  ──re-run engine (OPTIONAL, budgeted)──►  replay report  Stage 4
```

**Cost budget (back-of-envelope, set before kickoff):** Stage 2 is
≈100–150 adjudications + ≤20% escalation (Phase 2) + verify pass (disagreements
∪ top-mode members ∪ 10% remainder) at medium/high effort, plus one synthesis
and one taxonomy-gap agent at high effort. Stages 3a/3c/0.5 are zero-LLM. Stage
4 (replay) is the only stage with open-ended engine-run cost and is gated
behind explicit go-ahead. Record a token/$ estimate before Stage 2 and the
actual spend after; stop and reassess if Stage 2 overruns the estimate
materially.

## 4. Stage 0 — Fetch

**Plan:** one `rsync -a` of `user@dev-sg:/home/user/reviewotron/var/` into
`snapshot/`. Read-only mirror; permissions on the server files are 0600/0700
and owned by `user` — José has SSH access as `user`, so fetch as
`user@dev-sg` (not `team@dev-sg`).

**Requirements:**
- Snapshot is byte-identical to the server at copy time (rsync checksums).
- Snapshot dir is treated read-only from then on (no tool ever writes into it).
- Snapshot timestamp recorded in a `SNAPSHOT.txt` marker (host, path, date,
  file sizes, evidence dir count).

**Success criteria:**
- [ ] Local `snapshot/` contains targets, events, evidence root, state.json.
- [ ] Evidence dir count and total size match the server listing.
- [ ] `SNAPSHOT.txt` written.

## 5. Stage 1 — Index via `feedback-report`

**Plan:** run the built CLI (`reviewotron feedback-report --state
snapshot/state.json --feedback-dir <snapshot paths> --output json`) and save
`report.json`. This is both the worklist source and the live test of the
command's adequacy.

**Requirements:**
- Build the CLI from the current repo (dev profile is fine; version tag is
  irrelevant to analysis).
- The JSON must join targets ↔ evidence bundles; investigate every warning it
  emits (esp. missing-evidence warnings — see path caveat above).
- Record command adequacy observations as they occur in a running
  `command_gaps.md` note: fields missing, joins that had to be re-derived
  manually, filters that would have helped, warnings that were misleading.
- **Pre-seeded adequacy observation (confirm during Stage 1):** the original
  decision was to drive the loop from `feedback-report` JSON alone, but its
  target records carry only the finding *message* — not `filtered_diff.patch`,
  `failure_scenario`, `evidence_snippet`, or `why_now` — so adjudication must
  read raw evidence bundles for those (§6.3). If confirmed, this is the first
  `command_gaps` entry: the command is adequate as a **worklist/index** but not
  as a self-contained adjudication input. A possible enhancement to recommend:
  an `--evidence` / per-target bundle-expansion mode.

**Success criteria:**
- [ ] `report.json` parses; review count ≈ evidence dir count; target totals
      match the totals block.
- [ ] Every warning in the report output is either explained or logged as a
      command gap / data-quality note. Zero unexplained warnings.
- [ ] A written worklist exists: one row per target selected for adjudication
      (see §6.1), each resolvable to its evidence bundle dir.

## 6. Stage 2 — Adjudication loop

### 6.1 Worklist selection

- **All reacted targets** (sentiment ∈ {positive, negative, mixed}).
- **Plus a random control sample of ~80–100 unreacted targets.** Human labels
  are sparse and biased (people react when annoyed); the control group
  provides base rates so "the 👎 set differs from the silent mass" is testable
  rather than assumed. Use a fixed seed; record sampled ids.
  **Sizing rationale:** the earlier 30–40 figure cannot survive the slicing
  §7a applies (config-generation × interaction-state), which would shred it
  into single-digit/empty cells with no statistical power. Adjudication is
  cheap (same path as any other item), so the control arm is sized for the
  splits, not the minimum. **Constraint: per-`config_sha256`-generation slices
  are computed on the reacted arm only; the control arm is compared at the
  aggregate level only** (it is not large enough to slice by generation and
  still say anything).
- **Skip `praise`-severity findings** entirely.
- Review-body targets (target_kind = pr_review_body) are adjudicated for
  message quality only (no diff-validity questions apply); they are a small
  minority — if the schema fits poorly, log and exclude rather than distort.

### 6.2 Context-isolation architecture (non-negotiable)

The controller (orchestrating session/workflow) **never reads bundle
contents**; it holds only the worklist, progress state, and appended verdicts.
Every adjudication runs in a **fresh agent context** that sees exactly one
item's evidence, returns one verdict, and is discarded. Item 150 is judged by
an agent that has never seen items 1–149 — drift-by-accumulation is
structurally impossible, and the controller's context stays flat regardless of
dataset size.

Run as a deterministic orchestration (Workflow-style fan-out) with bounded
concurrency and per-item result caching, not a hand-driven chat loop.
**Concurrency: 5–7 adjudicators in parallel.** Items are fully independent
(each agent reads only its own input dir; `git show` escalation reads are
concurrency-safe; verdicts append via the single controller), so parallelism
is free correctness-wise and bounds wall-clock. One orchestration call
managing internal parallelism also keeps the controller session itself
strictly sequential.

**Resumability requirement:** verdicts append to `verdicts.jsonl` keyed by
`feedback_id`; on restart, already-present ids are skipped. The loop must be
killable at any point without losing completed work.

### 6.3 Agent contract

**Persona:** *review-quality auditor* — a senior engineer re-adjudicating one
review comment against the diff it was posted on. Explicitly **not** a code
reviewer: the prompt forbids reporting anything about the diff except the
adjudication of the given finding.

**Model/effort:** inherit the session model at medium/high effort for
adjudication (this is genuine code reasoning — the wrong place to save
tokens). Stage 3a uses no LLM. Stage 3b synthesis uses the session model at
high effort.

**Inputs (and nothing else):**
1. The finding's full record from `findings.json` (incl. routing_outcome).
2. `filtered_diff.patch` (ground truth), truncated at ~1500 lines — over-limit
   items are flagged and adjudicated on the finding's hunk ± generous context.
   **Truncation interacts with the scope axis:** `diff_scope` asks whether the
   flagged code belongs to *this* change, which requires seeing the whole
   diff. On a truncated item the agent cannot reliably tell "in this diff" from
   "pre-existing", so a truncated item **must** return
   `diff_scope: cannot_determine` (§6.4) rather than guessing, and its
   proportionality/scope-creep verdict is treated as provisional in
   aggregation.
3. `manifest.json` context (repo, PR number, trigger, config_sha256).
4. The exact posted comment body from `posted_review.json`.

**Deliberately withheld: the human reaction.** Adjudication is **blind** so it
cannot anchor on the human verdict. Agent-vs-human agreement is computed
deterministically in Stage 3 by joining on `feedback_id`. The interesting
question is directional: *"Reviewotron presented this as good — why did the
human reject it? What failed in the engine?"*

**Three calibrated questions, answered independently** (these separate the
known disagreement cases — relevance inflation, hypothetical issues,
intentional behavior — instead of one mushy "is it good"):

1. **Factual** — is the observation literally true of this diff?
2. **Reachability** — is `failure_scenario` concretely reachable *as evidenced
   by the diff*, or hypothetical?
3. **Proportionality** — are severity/urgency honest? Is `why_now` real — does
   this belong in this diff's review at all (diff-reviewer scope discipline)?

"Not a bug, a feature" = factually true + reachable + **intent mismatch**
(engine lacked the context that the behavior is deliberate) — a distinct root
cause with a distinct knob, cross-checkable against `fetched_files.json`.

**Verbatim success criteria given to each agent:**
> You succeed if a skeptical engineer, given only your evidence_quote and
> reasoning, would reach the same verdict without re-reading the diff. You
> fail if you speculate beyond the diff, judge code quality in general, or
> report anything about the diff other than this one finding.

**Anti-bloat limits:** one item per agent; no tools beyond reading its own
input directory; no git access; no network; reasoning capped (~120 words).

### 6.4 Verdict schema

Schema-enforced structured output (malformed → retried at harness level):

```json
{
  "feedback_id": "...",
  "verdict": {
    "factual":         "correct | incorrect | cannot_determine",
    "reachability":    "evidenced | plausible | hypothetical | not_applicable",
    "proportionality": "proportionate | inflated | understated",
    "diff_scope":      "in_scope | ambient_code | pre_existing_issue | cannot_determine",
    "intent":          "no_conflict | intentional_behavior_flagged | cannot_determine"
  },
  "failure_mode": "none | hypothetical_scenario | severity_inflation | intent_mismatch |
                   scope_creep | wrong_anchor | poor_message | convention_mismatch | duplicate",
  "control_surface": "none | prompt_reachability | prompt_calibration | prompt_style |
                      config_threshold | context_fetch | routing | dedup | per_repo_config",
  "quote_kind": "present | absence",
  "evidence_quote": "<verbatim lines from filtered_diff.patch>",
  "reasoning": "<= 120 words",
  "adjudicator_confidence": "high | medium | low",
  "needs_context": [{"path": "...", "why": "..."}],
  "command_gaps": ["<field feedback-report lacked that this adjudication needed>"]
}
```

### 6.5 Failure-mode → control-surface mapping

Every non-`none` failure mode must name a knob; a complaint without a knob is
not actionable and fails validation.

| Failure mode | Knob (control surface) |
|---|---|
| hypothetical_scenario | prompt: reachability evidence requirements |
| severity_inflation | prompt calibration + severity/confidence thresholds in config |
| intent_mismatch | context fetch policy; prompt humility about intent |
| scope_creep (ambient / pre-existing) | `why_now` enforcement; diff-scope prompt rules |
| wrong_anchor | routing/anchoring code |
| poor_message | message style prompt |
| convention_mismatch | per-repo config |
| duplicate | dedup logic |

### 6.6 Validation gates (deterministic, per verdict, before acceptance)

1. All enums valid (schema-level).
2. `evidence_quote` appears **verbatim** in that item's `filtered_diff.patch`
   — the strongest anti-hallucination check: an agent that can't quote the
   diff didn't read it. **Absence-finding escape:** a large class of valid
   findings is about what is *missing* (no error handling on a new call, no
   null check, no test) — there is no defect line to quote because the defect
   is the absence of one. For these the agent sets `quote_kind: absence` and
   quotes the **anchor line the missing handling should attach to** (e.g. the
   unchecked call site itself). The gate still requires that quote to appear
   verbatim in the diff — the anchor is present even when the fix is not — so
   the anti-hallucination guarantee holds; only the semantics of the quote
   differ. `quote_kind: present` keeps the original meaning (the quoted line
   *is* the defect). Without this escape the pipeline would silently flag every
   missing-handling adjudication `invalid` and drop exactly the finding class
   where calibration matters most.
3. `failure_mode ≠ none` ⇒ `control_surface ≠ none`.
4. Reasoning length cap.
5. Failure → one re-run; second failure → flagged `invalid`, excluded from
   aggregates, never silently patched. Invalid count reported in final doc.
6. `diff_scope: cannot_determine` is accepted (not a failure) only on items
   flagged truncated (§6.3); on a non-truncated item it is a re-run trigger,
   since the agent had the whole diff and should have decided.

### 6.7 Context escalation (Phase 2) — controller-gated, no worktrees

Agents get **no autonomy** to check out code: agents given an escape hatch
overuse it (each fresh context sees *its* case as the edge case), and
worktrees of the huge reviewed repo are the wrong tool anyway. Adjudicators
need to *read a few files at a commit*, which is `git show <head_sha>:<path>`
against the **one shared local clone** — read-only, concurrency-safe, no
checkout, no cleanup.

- Phase 1 agents may return `needs_context` with specific paths (≤5) and a
  one-line justification each, instead of guessing.
- The **controller** (deterministic code) resolves those paths via `git show`,
  writes them into the item's input dir, and spawns a Phase 2 agent with
  bundle + requested files. Agents never touch git.
- **Budget: ≤20% of items escalate.** Over budget → remaining `needs_context`
  verdicts stand and are flagged.
- **The escalation log is itself a primary finding:** every file an
  adjudicator needed is a file the engine arguably should have fetched. High
  escalation on intent_mismatch items = quantified evidence for tuning fetch
  policy.

### 6.8 Verify pass

- Every item where the (blind) adjudication contradicts the human reaction,
  **plus every item in the top Pareto `failure_mode` buckets that drive the
  candidate top-3 actionables (regardless of human agreement)**, plus a random
  10% of the remainder, gets **one independent skeptic agent**. Rationale for
  the influence stratum: human-and-adjudicator agreement that a finding is
  "bad" can still hide a **miscategorized `failure_mode`** — and a
  miscategorized mode in a top cell points José at the wrong knob. The verdicts
  that most move the actionables must be the most-verified, not just the ones a
  human happened to disagree with. (This stratum is computed after a first-pass
  aggregation identifies the leading cells; the verify pass then targets their
  members.)
- **Skeptic contract:** fresh context; persona is an *adversarial verifier*
  instructed to refute the verdict under test. Inputs: the same bundle inputs
  as the original adjudicator **plus the verdict being tested, still minus the
  human reaction** (the skeptic stays blind too). Model: session model, medium
  effort. Verbatim success criteria: "You succeed if you either produce a
  concrete, diff-quoted reason the verdict is wrong, or affirm it. You fail if
  you quibble with wording, re-litigate enum boundaries without evidence, or
  report anything beyond this one verdict." Output: `affirmed | refuted` +
  diff-quoted reason, same verbatim-quote validation gate as §6.6.
- Refuted → item marked **contested**; contested items surface in the final
  doc as open questions and are **never averaged into aggregates**.

**Stage 2 success criteria:**
- [ ] Every worklist item has exactly one accepted verdict, an `invalid` flag,
      or a `contested` flag in `verdicts.jsonl`.
- [ ] 100% of accepted verdicts passed the verbatim-quote gate.
- [ ] Escalation rate reported; ≤20% enforced.
- [ ] Invalid rate < 5% (higher → stop and diagnose the agent prompt before
      trusting any aggregate).
- [ ] Loop demonstrated resumable (kill + restart skips completed ids).

## 7. Stage 3 — Aggregation and synthesis

### 7a. Deterministic aggregation (script, zero LLM)

Join `verdicts.jsonl` × human reactions × target metadata by `feedback_id` →
`aggregates.json` with this fixed pivot set:

- **Pareto offender table — ranked on `failure_mode` alone.** The primary
  Pareto axis is the **9-value `failure_mode`**, ranked by
  `adjudicated-invalid 👎-weight` (see §8 for the metric definition).
  `control_surface` is **demoted from a cross-tab axis to a per-mode
  annotation**: each ranked mode lists its dominant control surface(s)
  underneath, but there is **no 9×9 `failure_mode × control_surface` grid**. At
  the adjudicated N this loop produces (≈100–150), an 81-cell grid is almost
  all empty and a "top-3-cells" concentration claim passes trivially under
  uniform noise; a 9-bucket ranking is a claim the data can actually support.
  Also break out finding count and weight per `finding_source/plugin ×
  category` as a second, coarse table.
- **Calibration curves:** declared `confidence` vs adjudicated validity;
  declared `severity` vs proportionality. (A calibrated engine's `high`
  confidence should almost never be `hypothetical`.)
- **Loved-findings profile (protection-set source):** the mirror of the
  offender table. Over 👍 *and* adjudicated-valid findings, pivot the
  distribution of `category`, `severity`, `confidence`, `plugin`, and
  quote/prose shape — what does a finding people thank you for look like? This
  is not decoration: it defines the **protection set** (§7c) that tightening
  actionables must not break, and it frequently surfaces the cheapest win
  (e.g. "high-confidence bug findings with a concrete `failure_scenario` are
  near-universally 👍'd; the noise is all suggestion-severity style nits" ⇒ the
  knob is severity-gating, not prompt surgery).
- **Reacted vs control:** failure-mode rates in the 👎 set vs the random
  unreacted sample — separates "engine is noisy" from "humans only react to
  the worst". Split unreacted by `first_user_interaction_at` (present on
  targets) where possible: "review never looked at" is a different silence
  than "looked at and ignored". **Computed at the aggregate level only** —
  the control arm is not sliced by config generation (§6.1).
- **Config generations:** metrics split by `config_sha256` **on the reacted
  arm**. This is an *observational* comparison across the deployment's history,
  **not a randomized A/B test**: config changed over calendar time alongside
  the repo's PR content and reviewer behavior, so generation differences are
  confounded with time and diff mix. Report deltas as suggestive, flag the
  confound explicitly, and never state a generation "caused" a rate change.
- **Routing:** outcomes distribution; anchor_failed and
  dropped_unchanged_low_severity rates.
- **Cost efficiency:** tokens per valuable finding by category (from
  `review_costs.json`).
- **Temporal trend:** key rates over `created_at`.
- **Escalation & gaps:** requested-context paths ranked; all `command_gaps`
  collected.

### 7c. Protection set + frozen eval (deterministic, zero LLM)

The same accepted verdicts that feed the offender table are re-shaped, with no
extra model calls, into a **frozen evaluation set** — `eval.jsonl`, one row per
adjudicated item:

```json
{ "feedback_id": "...", "review_batch_id": "...", "head_sha": "...",
  "label": "must_not_flag | must_keep_flagging",
  "source_reaction": "positive | negative | mixed | none",
  "failure_mode": "...", "diff_ref": "<bundle path>", "finding_ref": "..." }
```

- `must_not_flag` = adjudicated-invalid findings (confirmed FPs).
- `must_keep_flagging` = 👍 *and* adjudicated-valid findings (the **protection
  set** — the direct counterweight to the precision-only ratchet of §1).
- `contested`/`invalid` items are excluded (they carry a note, not a label).

This is the highest-ROI output in the plan and the real answer to the recall
blind spot: it turns each actionable from a hope ("~N 👎s trace here") into a
*scoreable hypothesis*. Any future prompt/config change can be evaluated
against `eval.jsonl` — FPs removed vs protected TPs broken — before it ships,
and the set outlives this one analysis run as a persistent regression benchmark.
It is a static labeled dataset (diff + finding + label); it requires no engine
runs to build. Actually *executing* the engine against it is the optional
Stage 4 (§7d).

### 7d. Counterfactual replay (OPTIONAL, budget-gated Stage 4)

The bundles carry `filtered_diff.patch` + `review_config.json` + per-finding
plugin identity — enough to **re-run the engine** on the same diffs with a
candidate tuned prompt/config and measure, against `eval.jsonl` (§7c), whether
a targeted FP disappears *and* the protection set survives. This graduates an
actionable from "I think this wording change kills these 12 FPs" to "it killed
11/12 and broke 0/40 protected TPs".

- **Cost:** real engine runs = real tokens; gate behind an explicit budget and
  José's go-ahead. Not part of the default deliverable.
- **Fidelity caveat (must be recorded):** `system_prompt_override` is stored
  **hashed** in the bundles (`review_config.json`, redacted by
  `redact_prompt_overrides`). If the deployment used a prompt override for any
  review, that review's exact engine input **cannot be reconstructed** and its
  replay result is not faithful. Detect override-bearing configs up front,
  exclude or flag those items from replay, and report the covered fraction.

### 7b. Synthesis (one fresh agent, high effort)

**Contract:** persona is an *engine-tuning analyst writing for the
maintainer* — its reader is the person who will edit prompts/config next week,
not a stakeholder audience. Model: session model, high effort. Sees **only**
`aggregates.json` + ~15 highest-signal verdicts verbatim as exhibits (top
Pareto modes + contested items) + the **taxonomy-gap note** (below). Never raw
bundles — it cannot drift into re-reviewing code. Verbatim success criteria:
"You succeed if every claim cites a number reproducible from aggregates.json
and every recommendation names a concrete file/field/code location in this
repo. You fail if you introduce any claim not derivable from your inputs,
soften findings into generalities, or emit a recommendation without its
Pareto-cell evidence."

**Taxonomy-gap discovery pass (one cheap critic agent, precedes synthesis).**
The 9-value `failure_mode` enum is deliberately closed (compiler-warn
discipline; §6.4). But if the dominant *real* failure mode isn't in the enum,
adjudicators jam it into the nearest bucket and point synthesis at the wrong
knob. Mitigation: one agent reads only the free-text `reasoning` fields of the
`invalid` / `contested` / low-`adjudicator_confidence` verdicts and answers a
single question — *"what failure did items keep describing that no enum value
names?"* Output is a short note (candidate missing modes + example
`feedback_id`s), fed to synthesis as context and recorded as a proposed
taxonomy revision. This keeps the enum closed for *this* run while catching the
mode we didn't name, for the next one.

**Outputs:**
- `INSIGHTS.md` — what the data shows, with the numbers: Pareto table (ranked
  on `failure_mode`, control surface annotated), calibration verdict,
  **loved-findings / protection-set profile**, control-group comparison,
  config-generation comparison (with the observational-confound caveat),
  trend, cost efficiency, data-quality/command-gap appendix, contested-items
  appendix, **taxonomy-gap note**, and a **recall-blind-spot statement** (§1:
  this analysis measures precision only).
- `ACTIONABLES.md` — ranked list; **every entry must** cite its Pareto mode,
  name the exact control surface (which prompt file / config field / code path
  in this repo), state expected impact ("~N of the adjudicated-invalid 👎s
  trace here"), and — for any entry that *tightens* the engine — carry a
  **`recall risk` flag naming the protection-set slice it could break** and
  prescribing the manual FN sanity-check (or the §7d replay check) before it
  ships. Human decisions (e.g. "convention_mismatch implies a per-repo config
  the team must write") are listed as decisions, not silently converted into
  recommendations.

**Stage 3 success criteria:**
- [ ] Every number in `INSIGHTS.md` is reproducible from `aggregates.json`
      (spot-check at least 5).
- [ ] Every actionable names a concrete knob and cites its evidence cell; zero
      unactionable complaints.
- [ ] Contested and invalid items visibly excluded, with counts.
- [ ] Command adequacy verdict on `feedback-report` delivered with the
      concrete gap list.

## 8. Overall success criteria

- [ ] José can read `ACTIONABLES.md` top-to-bottom and, for each entry, open
      the named prompt/config/code location and make a change — no further
      investigation needed to know *what* and *where*.
- [ ] **Offender ranking metric:** the Pareto ranks `failure_mode` by
      **`adjudicated-invalid 👎-weight`** — 👎-weight counted *only* on findings
      the blind adjudicator judged actually defective (`failure_mode ≠ none`).
      Raw 👎-weight is **not** the ranking key: a finding the adjudicator upholds
      (`failure_mode: none`) that a human still 👎'd is not an engine defect and
      must not drive a tuning knob. (`mixed` sentiment weighted 0.5 per §10.4.)
- [ ] **Upheld-yet-👎'd bucket:** findings that are adjudicated-valid but 👎'd
      are reported in their own named section (tone / UX / obviousness /
      human-calibration), separate from the offender table — a distinct output,
      not a knob.
- [ ] The top 3 `failure_mode` buckets are backed by ≥60% of
      adjudicated-invalid 👎-weight (Pareto property holds; if it doesn't, the
      doc must say the failure modes are diffuse — that is itself a finding).
- [ ] `eval.jsonl` produced (§7c): every accepted verdict re-shaped into a
      `must_not_flag` / `must_keep_flagging` row; protection-set size reported.
- [ ] Recall blind spot stated in `INSIGHTS.md`; every tightening actionable
      carries a `recall risk` flag naming its protection-set slice.
- [ ] Taxonomy-gap note delivered (candidate missing `failure_mode`s or "none").
- [ ] No context-window casualties: the orchestrating session ends holding
      only worklist + verdicts + aggregates, never bundle bodies.
- [ ] The deployment on dev-sg is untouched (read-only snapshot verified).
- [ ] `feedback-report` adequacy verdict delivered (fit / gaps / recommended
      enhancements).

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Evidence-dir path misresolution against snapshot (known prior bug pattern) | Verify resolution first; treat as command gap, not data to fix. |
| Local test feedback data in the main clone contaminates analysis | Snapshot lives outside the repo; worklist derives only from snapshot paths. |
| Agents hallucinate diff content | Verbatim `evidence_quote` gate (§6.6.2). |
| Verdict drift across items | Fresh context per item (§6.2); closed enums; blind adjudication. |
| Escalation stampede | Controller-gated, budgeted (§6.7). |
| Head SHAs missing locally | Preflight fetch of `refs/pull/*/head`. |
| Sparse/biased human labels over-interpreted | Control sample (≈80–100) + reacted-vs-control pivot (§6.1, §7a). |
| Praise/review-body targets distorting the taxonomy | Excluded / message-quality-only (§6.1). |
| **Recall invisible — loop ratchets engine toward timidity** | Precision-only caveat + `recall risk` flags + protection set / `eval.jsonl` (§1, §7c, §7b). |
| **Raw 👎 conflated with engine defect** | Rank on adjudicated-invalid 👎-weight; upheld-yet-👎'd findings in a separate bucket (§8). |
| **Diff truncation corrupts the scope axis** | Truncated items forced to `diff_scope: cannot_determine`; scope verdict provisional (§6.3, §6.6). |
| **Absence-based findings dropped by the quote gate** | `quote_kind: absence` escape, anchor-line quote still verbatim-checked (§6.6). |
| **Closed taxonomy hides an unnamed dominant failure mode** | Taxonomy-gap critic pass over free-text reasoning (§7b). |
| **Config-generation split misread as a causal A/B test** | Framed observational, confound with time/diff-mix flagged; control arm not sliced (§6.1, §7a). |
| **Reactor role unknown, biasing labels** | Preflight probe; role-weight if cheaply recoverable, else role-blind by decision (§2 Stage 0.5). |
| **Replay infidelity from hashed prompt overrides** | Detect override configs, exclude/flag from replay, report coverage (§7d). |
| **Analysis-run cost overrun** | Back-of-envelope budget before Stage 2; Stage 4 gated on go-ahead (§3). |

## 10. Open questions for José (resolve at pickup)

1. Path of the local clone of the reviewed repo (derive `repo_url` from targets, then confirm). --> /home/me/code/monorepo

2. Working directory for the analysis artifacts: `~/reviewotron-feedback-analysis-fable/2026-07-17/`.
3. Should `ACTIONABLES.md` / `INSIGHTS.md` land in this repo's `docs/` when done, or stay outside? (Recommendation: commit them — they justify future config/prompt changes.) --> yes
4. Control-sample size confirmation and whether `mixed` sentiment is treated as negative for Pareto weighting (recommendation: yes, weight 0.5). --> yes. **Resolved 2026-07-17: control bumped to ~80–100 (was ~30–40) so it survives §7a slicing; `mixed` weighted 0.5.** See §6.1, §8.
