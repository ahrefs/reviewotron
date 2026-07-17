# Reviewotron feedback insights — 2026-07-17

Snapshot: dev-sg, `2026-07-17`. 334 targets / 188 reviews / 83 reacted (47 up, 36 down, 0 mixed).
Adjudication worklist: 173 = 83 reacted + 90 seeded unreacted controls. 170 accepted / 3 invalid / 0 contested.
All numbers below are reproducible from `aggregates.json` (+ `synthesis_context.md` for pipeline facts).
Full artifacts (aggregates.json, verdicts.jsonl, eval.jsonl, exhibits, snapshot): ~/reviewotron-feedback-analysis-fable/2026-07-17/

---

## Post-analysis corrections (Stages 4–9)

> **Read this before the original analysis below.** The sections that follow are
> the Stage-3 (precision-only, pre-replay) analysis, preserved verbatim as the
> historical record. Stages 4–9 (counterfactual replay against `eval.jsonl`,
> era-fidelity replay, and a validator-gate crux test) subsequently **measured**
> several things this document could only project — and disproved some of them.
> Where a claim below conflicts with this box, this box wins. Full evidence:
> `REPLAY_BASELINE.md`, `ERA_REPLAY.md`, `VALIDATOR_GATE_TEST.md`, and the
> `STATUS.md` Stage 4–9 log in `~/reviewotron-feedback-analysis-fable/2026-07-17/`.

**1. The engine is a high-variance sampler, not a stable emitter — the "83%
protection-set loss" was a draw-vs-draw artifact.** Stage 4's headline (the
current pipeline held only 4/23 replayed `must_keep_flagging` findings, "dropping
83% of the protection set") read as a catastrophic recall regression. Stage 8
disproved that framing. The label-era engine (commit `c446032`, its own binary +
config + model) **replayed at verified ~1:1 prompt fidelity reproduces only
29–31% of its own labeled findings per run** (union of two runs 40%, stable in
both runs only 20%). The era engine never reliably emitted the protection set
either: a finding posted once in production re-appears on an identical re-roll
with probability ≈ 0.3. Per-run TP recall (era 7 and 10 of 23; every current
pipeline 4–10) shows **no meaningful drift**. The eval protection set is a union
of one-shot samples from a ~0.3-per-row process; judging any single run against
"36 protected TPs" overstates both the era's recall and every candidate's
apparent regression.

**2. FP suppression since the label era is real.** The one genuine drift signal
is on the false-positive side: the era engine re-emits **13–15 of the 52 labeled
FPs per run** (19 across two runs), while every current-code pipeline emits only
**4–8**. Roughly two-thirds of the apparent FP-kill progress survives the
sampler correction — it is genuine engine improvement, not variance. This is the
gain worth protecting.

**3. Single-run `tps_held` deltas of ±2–3 are noise — score in expectation over
≥3 runs against stable cores.** Because the process is a ~0.3 sampler, which
protected finding lands changes every roll (only ~6 TPs and ~9–10 FPs reproduce
across *all* runs). The correct scoring protocol, adopted from Stage 4b onward:
gate candidate PRs on the **stable cores** (the rows that reproduce everywhere)
and score the long tail as an **expected value over ≥3 replay runs per variant**,
never on a single run. `tps_held` (not just `fps_still_emitted`) is a primary
metric — the timidity ratchet §1 warns about is real, but it must be measured,
not inferred from one draw.

**4. What Stages 4–9 disproved (see `ACTIONABLES.md` rank annotations for the
per-action verdicts).**
- **Rank 1 (deep-reviewer file-fetch tool) — retired.** Stage-4b kill-stage
  diagnosis showed the lost TPs are 7 `scout_no_lead` + 9 `deep_dropped`
  (over-refutation of a *visible, correctly-led* defect) + 3 intermittent — not
  context starvation. The fetch tool's addressable ceiling is ≤2/19 (~10%) and
  unproven. The real levers are upstream: scout recall and deep-reviewer
  calibration.
- **The validator cannot be tightened into a clean FP separator (Stage 9,
  NO-GO).** `fps_still_emitted` lives at the validator, but a validator-gate crux
  test over the k-run union pool showed the gate trades TPs for FPs ~1:1 or
  worse, and one protected finding (`apiv3_ppx.ml:44`) is refuted on groundedness
  by even the *loosest* variant. The stable FP floor is *grounded-but-wrong*
  findings whose evidence is visible in the diff — catching them needs
  re-derivation, which is outside the validator's mandate. **Do not build a
  k-run sampling-union architecture on a post-hoc validator gate.**
- **Deep-reviewer-only calibration (PR #25) — negative result.** Both scored
  variants failed the guard on both axes; the change is structural + variance,
  not wording, and moving FPs requires touching the validator in the *same* PR.
  PR #25 is preserved as a documented negative result, not merged.

**5. What actually shipped, and what remains genuinely open.**
- **Shipped (merged to `main`):** PR #23 (local-mode key-file embedding — makes
  local `review-diff` faithful to production) and PR #24 (scout recall on
  omission-in-context and sibling-divergence defects; replay-scored +3 TPs with
  the FP guard held at 4/65). These are the two real wins of the program.
- **Still open, handed to the next feedback cycle:** the feedback-loop
  enhancements this analysis's §13 flags (record reactor identity at poll time;
  put review `created_at` in the report; carry PR title/body into evidence
  bundles; persist non-posted findings' routing outcomes) plus, for tuning, a
  **paired deep-reviewer-recall + validator-tightening PR scored over ≥3
  replays**, and multi-draw protection sets so the sampler variance is designed
  around rather than fought. The optional thread-mining of the 36 downvoted
  comments (§3 upheld bucket) also remains unstarted.

---

## 1. Headline summary

- The engine's invalid output is **concentrated, not diffuse**: 3 of 6 failure modes carry
  94.1% of the adjudicated-invalid 👎-weight (`pareto_property.top3_share = 0.9412`, total weight 17.0).
- The single dominant mode is **`hypothetical_scenario`** — 30 adjudicated-invalid members, 11.0 👎-weight
  (65% of all invalid weight). Every one of its 11 downvoted members is `plugin: general`.
- The mode is a **precision defect rooted in missing context**: the engine asserts a failure mechanism it
  never verified against a checkable fact (a helper signature, a sibling file, a schema, a called module).
  See exhibits `rvf_c51f0aa…`, `rvf_962a2b77…`, `rvf_dea8044…` — each a confident `critical`/`warning` claim
  disproved by one line just outside the diff hunk.
- Humans react to the worst but **not exclusively**: downvoted defective_rate 0.545 vs control 0.427 vs
  upvoted 0.281. The engine is genuinely noisy in the control arm too (42.7%), so reaction data understates
  the FP surface — it is a biased sample, not a full census.
- **The whole analysis is precision-only.** Reaction and adjudication data say nothing about findings the
  engine should have made and didn't (§12). Every actionable in `ACTIONABLES.md` makes the engine say *less*.

---

## 2. Pareto offender table

Ranked by adjudicated-invalid 👎-weight (`pareto_failure_modes`). "Weight" = summed downvote weight of
invalid members (mixed-weight rule 0.5 unexercised — 0 mixed targets — so weight == count of invalid 👎'd members).

| Rank | failure_mode          | invalid_count | 👎-weight | 👎 members | dominant control surface(s)                       |
|------|-----------------------|---------------|-----------|-----------|---------------------------------------------------|
| 1    | `hypothetical_scenario` | 30          | **11.0**  | 11        | `prompt_reachability` (23), `context_fetch` (7)   |
| 2    | `poor_message`        | 12            | **4.0**   | 4         | `prompt_style` (12)                               |
| 3    | `severity_inflation`  | 11            | **1.0**   | 1         | `prompt_calibration` (11)                         |
| 4    | `intent_mismatch`     | 8             | 1.0       | 1         | `context_fetch` (8)                               |
| 5    | `wrong_anchor`        | 3             | 0.0       | 0         | `routing` (3)                                     |
| 6    | `scope_creep`         | 1             | 0.0       | 0         | `prompt_reachability` (1)                         |

**Pareto property:** top-3 modes (`hypothetical_scenario` + `poor_message` + `severity_inflation`) =
16.0 of 17.0 total invalid weight = **94.1%**. Tuning them addresses nearly all downvote-weighted noise.

Surface reading:
- Modes 1, 3, 6 are **prompt** surfaces (reachability discipline, calibration wording) — cheap to change.
- Modes 1 (partial) and 4 are **`context_fetch`** — the engine reasons on a premise it could have resolved
  by fetching a file. This is a pipeline/architecture surface, not just prompt wording.
- Mode 2 is **`prompt_style`** — the review-body / suggestion prose channel.
- Mode 5 is **`routing`** (anchor placement); note it carries **0** downvote weight — see §9.

---

## 3. Upheld-yet-👎'd bucket (NOT a tuning knob)

`upheld_yet_downvoted.size = 18`. These are findings the author downvoted but the blind adjudicator upheld
as **valid and proportionate** (`by_proportionality: {proportionate: 18}` — 18/18). Composition:

- By kind: `pr_review_comment` 10, `pr_review_body` 8.
- By category: `logic` 3, `bug` 3, `security` 2, `error-handling` 2, `null` (body-level) 8.
- By severity: `warning` 8, `critical` 2, `null` (body) 8.

**This bucket is tone / UX / obviousness / human-calibration, not an engine defect.** The finding was correct;
the author disagreed, found it obvious, or resented being flagged (all 83 reactions are author-defensive —
§13). **Do NOT convert this bucket into a tuning knob.** Suppressing correct findings to placate authors is a
recall regression disguised as a precision win. It is reported here only to keep the 36-item downvote count
honest: 18 of the 36 downvotes were on findings the engine got right.

---

## 4. Calibration verdict

Declared confidence vs adjudicated validity (`calibration.declared_confidence_vs_adjudication`):

| declared confidence | valid | defective | defective share |
|---------------------|-------|-----------|-----------------|
| high                | 52    | 36        | **40.9%**       |
| medium              | 32    | 23        | 41.8%           |

**High confidence is barely more reliable than medium** (40.9% vs 41.8% defective). The `high` label is not
earning its meaning — the prompt defines `high` as "you can show the exact input/state, changed line,
execution path, and bad outcome" (`lib/review_prompt.ml`, `calibration`), yet 36 high-confidence findings were
adjudicated defective.

Declared confidence vs reachability (`declared_confidence_vs_reachability`):

| declared confidence | evidenced | plausible | hypothetical |
|---------------------|-----------|-----------|--------------|
| high                | 30        | 43        | **15**       |
| medium              | 9         | 31        | 15           |

**Yes — high confidence is routinely hypothetical.** 15 high-confidence findings had `reachability =
hypothetical` (the failure path was asserted, never demonstrated). Confidence is being set from the model's
*belief* in its reasoning, not from whether it *verified* the premise. This is the mechanistic root of mode 1.

Declared severity vs proportionality (`declared_severity_vs_proportionality`):

| declared severity | proportionate | inflated | inflated share |
|-------------------|---------------|----------|----------------|
| warning           | 87            | 25       | 22.3%          |
| critical          | 19            | 11       | **36.7%**      |
| suggestion        | 1             | 0        | 0%             |

**`critical` is the most over-declared tier** — 11 of 30 criticals (36.7%) were inflated. A `critical` label
should predict real breakage; here it predicts an inflated warning-or-less more than a third of the time.

---

## 5. Loved-findings / protection-set profile

`loved_profile.size = 36` — 👍'd **and** adjudicated-valid. This is the **protection set**: the shape of
output any tuning change must not break (`must_keep_flagging` in `eval.jsonl`, §13).

- By kind: `pr_review_comment` 23, `pr_review_body` 13.
- By category: `logic` 11, `bug` 8, `error-handling` 4, `null` (body) 13.
- By severity: `warning` 19, `critical` 4, `null` (body) 13.
- By confidence: `high` 14, `medium` 9, `null` (body) 13.
- By plugin: `general` 23, `null` (body) 13. **Zero `security` comments are loved.**
- By reachability: `evidenced` 11, `plausible` 12, `not_applicable` (body) 13.

**A loved finding looks like:** a `general`-plugin `logic` or `bug` inline comment, `warning` severity,
`high`/`medium` confidence, reachability **`evidenced` or `plausible` — never `hypothetical`**. Exhibits
`rvf_27cec580…` and `rvf_42cfc090…` are the archetype: new-file stale-state bugs, `evidenced` by the diff
itself, concrete fix, `warning`+`high`. The evidenced/plausible split (11/12, 0 hypothetical among inline
loved comments) is the discriminator: **the protection set lives entirely in the reachability tiers that
mode-1 tuning targets for the invalid set.** Any reachability tightening must spare evidenced/plausible.

---

## 6. Reacted vs control comparison

Defective rate = adjudicated-defective / n (`reacted_vs_control`):

| arm                       | n  | defective_rate |
|---------------------------|----|----------------|
| downvoted                 | 22 | **0.545**      |
| control                   | 89 | 0.427          |
| control_interacted        | 69 | 0.420          |
| control_never_interacted  | 20 | 0.450          |
| upvoted                   | 32 | 0.281          |

**Answer: the engine is noisy overall AND humans react to the worst.** Both are true:
- Downvoted (0.545) > control (0.427) > upvoted (0.281): reactions carry real signal — authors downvote
  findings that are ~1.3× more defective than baseline and upvote findings ~0.66× baseline.
- But the control arm sits at **42.7% defective with no human touching it**, and the never-interacted control
  slice (0.450) is essentially identical to the interacted slice (0.420). **Interaction does not predict
  defectiveness in the control arm** — the noise is ambient, present whether or not a human looked. The
  downvote lift is real but modest; most FPs are never reacted to at all.
- Downvoted defect modes: `hypothetical_scenario` 10, `none` 10 (the §3 upheld bucket), `severity_inflation`
  1, `intent_mismatch` 1. So even inside the downvoted arm, half the downvotes are on non-defective findings.

---

## 7. Config generations (reacted arm only)

`config_generations_reacted_only` — **observational, confounded with time and diff mix. NOT causal.** These
are three engine config hashes observed at different periods over different PRs; the deltas below cannot be
attributed to the config change itself.

| generation | n  | defective_rate | neg_share |
|------------|----|----------------|-----------|
| `58ae9644` | 8  | 0.125          | 0.125     |
| `91a33a6c` | 26 | 0.346          | 0.308     |
| `38db8250` | 47 | 0.362          | 0.553     |

Descriptively, defective_rate and neg_share both rise across the three hashes, with `38db8250` (the largest,
n=47) showing the highest negative share (0.553). **Do not read this as "the config got worse."** n=8 for
`58ae9644` is too small to compare, and the diff mix (which PRs each generation reviewed) is uncontrolled.
This is a flag to investigate under a counterfactual replay (§7d), not a conclusion.

---

## 8. Temporal trend by month

`temporal_trend_by_month`: a single bucket, `2026-07` — n=170, defective=65, neg=35. Overall
defective_rate = **65/170 = 0.382**; negative fraction = 35/170 = 0.206. `created_at` had to be recovered
from raw `targets.json` because the report drops it (command gap #4, §13); once recovered, the entire
dataset falls inside one month (deployment window ≈ Jul 7–17), so **no multi-month trend is derivable from
this snapshot** — the config-generation split (§7) is the only within-window temporal axis available.

---

## 9. Routing outcomes & cost efficiency

**Routing outcomes** (`routing_outcomes_all_findings`): `inline: 202`. The bundles' `findings.json` contain
exactly the 202 posted findings, all `inline` — either nothing was ever anchor-failed/dropped in this window,
or non-posted findings are not being persisted to the bundles (the design doc §2 expects
`unchanged`/`anchor_failed`/`dropped_unchanged_low_severity` entries; none exist in any of the 188 bundles —
if drops did occur, this is an evidence-bundle gap worth checking in `lib/feedback_evidence.ml`). This matches mode 5
(`wrong_anchor`) carrying **0 downvote weight** — anchoring is not a live precision problem. The routing code
(`lib/review_engine.ml`, `route_finding` → `Positioned | File_not_in_diff | Anchor_failed`) is working; the 3
`wrong_anchor` invalids were all unreacted controls with mild placement drift, not misrouted posts.

**Cost efficiency** (`cost_efficiency`) — *costs are totals over ALL 188 reviews; valid/loved counts cover
only the 173-item sample. Ratios are indicative, not exact* (per the aggregate's own note):

| plugin   | in tokens   | out tokens | total USD | valid comments (sample) | loved (sample) |
|----------|-------------|------------|-----------|-------------------------|----------------|
| general  | 12,208,316  | 831,770    | $115.97   | 79                      | 23             |
| security | 73,649,131  | 366,690    | $345.90   | 5                       | 0              |

- **Security is the cost sink with near-zero endorsed yield**: $345.90 (3× general's spend, 6× its input
  tokens) for **5** adjudicated-valid comments and **0** loved comments in-sample. Indicative cost/valid ≈
  **$69/valid** for security vs **$1.47/valid** for general.
- General is the value engine: $115.97 → 79 valid, 23 loved. Cost/loved ≈ $5.04.
- Caveat holds: security's token volume is dominated by tool-loop file fetching (`Analysis_agent.tools`,
  `Security_tools.make_get_file_content`) across all 188 reviews, while its valid count is measured only on
  the 12 in-sample security comments — so the ratio overstates but the order-of-magnitude gap is real.

---

## 10. Escalation analysis (context-fetch tuning signal)

`escalation`: adjudicators requested repo context for **74** of 167 phase-1 verdicts (44%); budget 34 (20%);
28 executed with files (all 28 accepted); 6 selected-but-unresolvable; **40 over-budget requests flagged**;
22 requested paths did not exist at the reviewed SHA (adjudicators guess paths).

Request rate by failure mode (`requested_by_failure_mode`):

| failure_mode          | context requests |
|-----------------------|------------------|
| `none` (valid)        | 36               |
| `hypothetical_scenario` | 19             |
| `poor_message`        | 6                |
| `intent_mismatch`     | 6                |
| `severity_inflation`  | 5                |
| `scope_creep`         | 1                |
| `wrong_anchor`        | 1                |

**Reading:** `hypothetical_scenario` (19) is the top *defective* mode requesting context — confirming that
these findings were adjudicable **only after fetching a file the engine also never fetched**. `intent_mismatch`
(6) is entirely `context_fetch`-surfaced. The engine and the adjudicator hit the same wall: the diff hunk
alone is insufficient, and neither the general pipeline nor the report bundle carried the needed sibling/
schema/caller. 36 requests on `none`-mode (valid) findings show context-hunger is not purely a defect signal.

Top requested paths (`top_requested_paths`, count):
`frontend/packages/ahkit/src/agent/AgentChat.re` (4);
`frontend/packages/keywords-explorer/src/KeRouteData.re` (3);
`backend/api/src/apiv3/apiv3_helpers.ml` (2), `backend/social_media_management/postValidation.ml` (2),
`backend/devtools/linting/rulah/ambient.ml` (2), `backend/api/apilib/auth_spec.ml` (2),
`backend/api/apilib/define.ml` (2); then 18 paths at count 1. **22 unresolvable path requests** — adjudicators
(and by extension the engine) guessed paths that did not exist at the SHA. The repeated `apiv3_helpers.ml` /
`apiv3_*` cluster is the same file family behind exhibits `rvf_c51f0aa…` and `rvf_73d915bc…` (the
`of_endpoint_result_private_error` misreads).

---

## 11. Taxonomy-gap note (candidate new failure modes)

Three recurring phenomena had no enum value and were jammed into the nearest bucket
(reproduced from `taxonomy_gap_note.md`):

1. **`unverified_premise`** (currently jammed into `hypothetical_scenario`). The failure claim hinges on a
   *checkable* fact (helper signature, sibling file, schema, called module) the engine never fetched; it
   posted an explicitly conditional scenario ("if X is implemented as Y…") instead of resolving it. Distinct
   from a true hypothetical (a realistic-but-rare input): here the scenario may be realistic; the defect is
   asserting it on an unchecked premise. Adjudicators repeatedly note "fetching <file> would have resolved it
   either way." Examples: `rvf_1a0fee37…`, `rvf_a9e95a6e…`, `rvf_b7d9963f…`, `rvf_aeb80c89…`.

2. **`false_mechanism`** (jammed into `hypothetical_scenario` / `severity_inflation`). The causal mechanism is
   *demonstrably wrong* — the failure cannot occur as described (stronger than "unlikely"). Two sub-species:
   - **Stale external knowledge**: `rvf_19b1676e…` (setup-node v6 "does not exist"), `rvf_a6c1da3e…` (retired
     YouTube per-part quota), `rvf_a7283f28…` (apt_preferences), `rvf_9ecc9ccf…` (GNU date -d "").
   - **Misread code semantics**: `rvf_c51f0aa…`, `rvf_73d915bc…`, `rvf_68a490c5…`, `rvf_1f7f8d79…`.

3. **`broken_suggestion`** (jammed into `poor_message`, or riding along other modes). The GitHub
   ` ```suggestion``` ` payload is mechanically defective/harmful if applied: byte-identical no-ops, literal
   `\n` escapes, prose replacing code, duplicated lines, doesn't typecheck, behaviorally inert. Distinct from
   bad prose — this is a defective *actionable payload*. Primary: `rvf_2b065d4c…`, `rvf_816446bd…`,
   `rvf_434c3e89…`. Secondary (inside other modes): `rvf_43d023c8…`, `rvf_f96ad02d…`.

**Recommendation:** split the taxonomy so mode-1 tuning can be measured against `unverified_premise` (fetch a
file) and `false_mechanism` (verify/ground) separately — they need different fixes (context pipeline vs
prompt+knowledge grounding), and `broken_suggestion` needs a payload validator, not prose tuning.

---

## 12. RECALL BLIND SPOT (read before acting)

**This analysis measures precision only.** Every metric above is computed over findings the engine *did*
emit and a human *did* react to. The dataset carries **zero signal** about:

- Real defects the engine **should have flagged and did not** (false negatives / missed bugs).
- Real defects in files or hunks the engine never fetched context for.
- Whether a "quieter" engine would have stayed silent on the loved-set-shaped bugs it currently catches.

Reaction data cannot see a comment that was never posted. **Every actionable in `ACTIONABLES.md` reduces what
the engine says.** There is no recall counter-metric in this snapshot to detect over-tightening. That is why
each tightening action carries a mandatory `Recall risk:` flag naming the protection-set slice it could break,
and prescribes an `eval.jsonl` `must_keep_flagging` replay (§7d) before shipping. Ship nothing that has not
been shown to leave the 36-item protection set intact.

---

## 13. Data-quality & command-gap appendix

**Reaction provenance.** All **83** reactions are PR-**author** reactions (26 distinct authors, 0 third-party;
verified live via GitHub API, Stage 0.5). Labels are uniformly "author-defensive" caliber — a downvote may
mean "wrong", "obvious", or "don't nag me", and the data cannot distinguish. Treat 👎 as a weak precision
prior, never as ground truth (the adjudicator, not the reaction, is truth).

**Adjudication integrity.** 170 accepted / **3 invalid** (`rvf_43d023c8…`, `rvf_eb7d8a4d…`, `rvf_038bff15…` —
all failed the verbatim diff-quote gate twice) / **0 contested**. Blind adjudication (never saw reactions),
schema-enforced, verbatim diff-quote gate.

**100%-affirmation caveat.** The adversarial verify pass ran an 81-item stratum (43 top-3-mode members + 28
human/adjudicator disagreements + 10 random): **81/81 AFFIRMED, 0 refuted.** 100% affirmation is *suspicious*
— it may reflect skeptic leniency rather than perfect adjudication. The quote gates held, so we retain the
verdicts, but treat borderline calibration claims (§4) as directionally, not exactly, precise.

**Truncation.** 23/173 items had diffs >1500 lines, truncated by the *analysis pipeline* (finding's file
section kept; this is an adjudication-input bound, not an engine config); their `diff_scope` is
**provisional**. Any diff_scope-dependent claim on those items is soft.

**UTF-8.** One invalid UTF-8 byte in `targets.json` (0xe2 @ 221177) was tolerated silently; `report.json`
output is valid UTF-8. Silent tolerance is arguably itself a gap (no malformed-input warning emitted).

**Snapshot.** dev-sg, `2026-07-17`. 1 target status=missing (`rvf_44a081e0…`, comment deleted on GitHub).
No praise/nitpick severities in the dataset (165 warning / 36 critical / 1 suggestion among comment targets).

### feedback-report command adequacy — VERDICT

**Fit:** Usable as an aggregation/indexing layer. Evidence-dir re-rooting worked (`--feedback-dir` re-rooted
all 188 dirs, zero missing-evidence warnings; the design's §2 caveat did not materialize). Totals block is
internally consistent (334 targets = sum of nested review targets; 188 reviews = 188 evidence dirs; sentiment
47/36/0 matches raw `last_counts`). `finding_id` joins cleanly to `findings.json`.

**Gaps (concrete, from `command_gaps.md` + verified against `lib/feedback_report.ml`):**
1. **Not a self-contained adjudication input.** The report `target_summary`
   (`lib/feedback_report.ml`, `type target_summary`) carries the finding `message` only — it drops
   `failure_scenario`, `evidence_snippet`, `why_now`, `suggested_fix` (present inline in raw
   `targets.json`), and never includes the diff. Adjudication had to read raw evidence bundles.
   **Enhancement:** an `--evidence` / bundle-expansion mode emitting the full finding record + a
   `filtered_diff.patch` path per target.
2. **No per-target reacted export with reactor identity.** `sentiment` is derived from bare `plus_one` /
   `minus_one` counts (`sentiment_of_counts`); reactor identity is not stored at all (events log kinds are
   `target_finalized` / `comment_id_resolved` / `reaction_counts_changed` — bare counts). The pipeline had to
   re-fetch actors from the GitHub API (Stage 0.5). **Enhancement:** record actor login (or at least
   author-vs-other) at poll time.
3. **No routing_outcome for non-posted findings.** `routing_outcome` IS exposed for posted findings
   (`target_summary.routing_outcome`), but `anchor_failed` / `file_not_in_diff` outcomes live only in the
   bundles; routing analysis had to read bundles directly. **Enhancement:** surface non-posted routing
   outcomes in the report.
4. **No review timestamp field.** There is no PR/review timestamp in the target record, so temporal bucketing
   collapses to one empty-key month (§8) and the "current date at review time" had to be inferred from the run
   date (drove the mode-4 exhibit `rvf_7256e05e…`, "July, 2026" false-typo). **Enhancement:** stamp review
   time per target.
5. **Silent malformed-byte tolerance.** No warning on the invalid UTF-8 input byte (see above).
6. **PR title/description not captured** (evidence-bundle gap, `lib/feedback_evidence.ml`): several
   adjudicators needed the PR's own description to judge intent ("declared as scaffolding", "caution note
   says revert before merge") — the same context the engine itself lacked in the `intent_mismatch` cell.
   **Enhancement:** persist PR title/body (or their hashes + a fetch pointer) in `manifest.json`.

**eval.jsonl (frozen eval set):** 101 rows = 65 `must_not_flag` + 36 `must_keep_flagging` (protection set).
69 adjudicated-valid-but-unendorsed items carry no label by design. Stage 4 (counterfactual replay) was NOT
run (budget-gated, no go-ahead) — all impact estimates in `ACTIONABLES.md` are pre-replay projections.
