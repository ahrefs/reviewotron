# Reviewotron engine-tuning actionables — 2026-07-17

Ranked by adjudicated-invalid 👎-weight recovered (Pareto, `aggregates.json`). Every entry cites a real,
verified file/field in `the reviewotron repo`. Protection set = 36 loved+valid findings
(`loved_profile`); `eval.jsonl` = 65 `must_not_flag` + 36 `must_keep_flagging`. "Stage 4 replay" / "§7d"
below refer to the counterfactual-replay protocol, now in `tools/replay/` (once #27 merges).

Precision-only caveat applies (INSIGHTS §12): every action below makes the engine say *less*. No recall
counter-metric exists in this snapshot — replay against `eval.jsonl` before shipping any of them.
**Provenance:** the method and labels (`eval.jsonl` + replay harness + protocol) are reproducible from `tools/replay/`
once #27 merges. The raw run outputs and the deployment snapshot stay archived at `the private analysis archive`
and are deliberately *not* committed — it contains private-repository diffs and reviewer comments (private
data), so it must remain external by design.

---

## Post-analysis corrections (Stages 4–9) — outcome of each rank

> **Read this before the ranked actions below.** The rankings that follow are the
> Stage-3 pre-replay projections, preserved verbatim as the historical record.
> Stages 4–9 then ran the counterfactual replays (`eval.jsonl`), an era-fidelity
> replay, and a validator-gate crux test that these projections called for. Each
> rank below now carries an **`OUTCOME:`** line at its head with the measured
> verdict; where a projection conflicts with its outcome, the outcome wins.
> Cross-cutting correction (see `INSIGHTS.md` post-analysis box for the full
> version): the engine is a **~0.3-per-row sampler**, so single-run `tps_held`
> deltas of ±2–3 are noise — decisions require scoring in **expectation over ≥3
> runs against the stable cores**, and `tps_held` is a primary metric alongside
> FP kills. Evidence: `REPLAY_BASELINE.md`, `ERA_REPLAY.md`,
> `VALIDATOR_GATE_TEST.md`, `STATUS.md` (Stages 4–9).

**Verdict summary by rank:**

| Rank | Action | Outcome |
|------|--------|---------|
| 1 | Deep-reviewer file-fetch tool | **RETIRED** — kill-stage diagnosis: lost TPs are scout/over-refutation, not context starvation; addressable ceiling ≤2/19 (~10%), unproven. |
| 2 | Bind `confidence` to verified reachability | **SHELVED** — precision (FP suppression) is already achieved vs the era; reachability tightening risks the timidity ratchet with no measured FP win to justify it. |
| 3 | `broken_suggestion` / message-quality validator gate | **UNTESTED — optional** — the only rank never contradicted by replay (rejects payloads, not findings); a candidate for the next cycle if `suggested_fix` is serialized (it currently is not — see Stage-9 fidelity gap). |
| 4 | Tighten `critical` proportionality | **SHELVED** — same reason as Rank 2: precision already achieved; a downgrade-only change with no measured invalid-weight left to recover on this sampler. |
| 5 | Broaden `fetch_key_files` | **SHELVED** — subordinate to Rank 1 (its own fallback); superseded by PR #23, which made local-mode key-file embedding faithful, and by the finding that context is not the lost-TP lever. |
| 6 | Ground external-tool/platform knowledge | **SHELVED** — a `false_mechanism` sub-species fix with no measured FP win on the sampler; folded into the "stable FP floor of grounded-but-wrong findings" that Stage 9 showed the validator cannot separate. |

**Sampling-union architecture (proposed as a way to beat the sampler): NO-GO
(Stage 9, structural).** Unioning k runs does lift pre-gate recall to 10/23, but
the validator — at any strictness between today's prompt and a taxonomy-tightened
one — cannot strip the added FP drag without shedding the recovered TPs, and
cannot in any case reach TP ≥ 10 (one protected finding is refuted on
groundedness by even the loosest gate). Do not build it on a post-hoc validator
gate.

**What actually shipped:** PR #23 (local-mode key-file embedding) and PR #24
(scout recall on omission-in-context / sibling-divergence — replay-scored +3 TPs,
FP guard held). PR #25 (deep-reviewer calibration) is a preserved negative
result, not merged.

**What remains genuinely open (next feedback cycle):** the feedback-loop
enhancements in `INSIGHTS.md` §13 (reactor identity at poll time, review
`created_at` in the report, PR title/body in bundles, persisted non-posted
routing outcomes), a **paired deep-reviewer-recall + validator-tightening PR
scored over ≥3 replays**, multi-draw protection sets, and the optional
thread-mining of the 36 downvoted comments.

---

## Original ranked actionables (2026-07-17) — 5 of 6 since retired

Each heading below leads with its Stages 4–9 outcome; the bullets under it are the verbatim Stage-3 pre-replay
projection, preserved as the historical record. Where the two conflict, the outcome (and the `OUTCOME:` box) wins.

### Rank 1 — RETIRED (Stage-4b: addressable ceiling ≤2/19) — was: give the general deep reviewer a file-fetch tool

> **OUTCOME: RETIRED (Stage-4b kill-stage diagnosis).** Wrong lever. The 19 lost
> replayed TPs break down as 7 `scout_no_lead` + 9 `deep_dropped` + 3 intermittent
> — and the 9 `deep_dropped` were *not* context-starved: 7/9 had the anchor file
> already embedded and the scout led on/beside the exact anchor, so the deep
> reviewer refuted a *visible, correctly-led* defect (disprove-first
> over-refutation). The fetch tool's addressable ceiling is ≤2/19 (~10%) and
> unproven. Real levers are upstream: scout recall (shipped, PR #24) and
> deep-reviewer calibration (attempted, PR #25 — negative result). Evidence:
> `tp_loss_diagnosis.md`.

- **Pareto cell:** `hypothetical_scenario` — 30 adjudicated-invalid, **11.0 👎-weight** (65% of all invalid
  weight); `context_fetch` is its #2 control surface (7 members) and the whole of `intent_mismatch`
  (8 invalid, `context_fetch` 8). ~11 of the 11 downvoted `hypothetical_scenario` members trace here, all
  `plugin: general`. Escalation confirms it: 19 context requests on `hypothetical_scenario`, 6 on
  `intent_mismatch` (`escalation.requested_by_failure_mode`).
- **Control surface:** `lib/general_deep_reviewer_agent.ml` (`config`, `max_steps = 1`; `build_input` /
  `relevant_file_contents`) + `lib/github_source.ml` (`fetch_key_files`) → `lib/review_job.ml`
  (`select_key_files`, capped at `CCList.take max_key_files` = 5, keeps ONLY Added/Modified changed files —
  never siblings/callers/callees/schemas). The `fetch_file` capability
  (`lib/review_job.ml` `type fetch_file`; `Security_tools.make_get_file_content`) is wired ONLY into the
  security agents (`lib/analysis_agent.ml:862`, `lib/validator_agent.ml:211`); the general pipeline cannot
  fetch a file on demand.
- **Proposed change:** wire `Security_tools.make_get_file_content ~fetch_file` into the general deep reviewer
  as a tool and raise its `max_steps` from 1 to a small bound (e.g. 3) so it can fetch the exact file its
  lead's premise depends on before confirming. Amend the deep-reviewer `system_prompt`
  (`lib/general_deep_reviewer_agent.ml`, "Method" step 2/3) from "If the provided file contents are
  insufficient … drop the lead. Never guess." to: "If a lead's failure claim depends on a fact you can check
  — a helper signature, a called module, a sibling file, a schema — fetch that file with `get_file_content`
  and resolve it. Confirm only on fetched or diff-visible evidence; never on an unresolved conditional."
- **Recall risk:** could suppress `evidenced`/`plausible` findings if the model over-drops on fetch failure.
  Protection-set slice at risk: `loved_profile.by_reachability` = 11 `evidenced` + 12 `plausible` inline
  `general` comments (exhibits `rvf_27cec580…`, `rvf_42cfc090…` are new-file bugs evidenced by the diff
  alone, so should be untouched). **Before shipping:** replay `eval.jsonl` `must_keep_flagging` (36 rows) and
  confirm 0 regressions among the 23 `evidenced`+`plausible` loved comments (§7d); manual FN sanity-check the
  4 loved `error-handling` items (thinnest slice).
- **Expected impact:** targets 11.0 of 17.0 invalid weight (65%) plus the 8 `intent_mismatch` invalids. Even
  partial recovery (say half of mode-1 + mode-4 context defects) removes ~9–15 adjudicated-invalid findings.
  Adjudicators state these are resolvable "either way" once the file is fetched (INSIGHTS §11), so upside is
  high. Highest-leverage single change in the set.

---

### Rank 2 — SHELVED (precision already achieved vs the era) — was: bind declared `confidence` to verified reachability

> **OUTCOME: SHELVED.** Precision is already where this rank aimed to take it: the
> current pipeline emits only 4–8 of the 52 labeled FPs vs the era engine's 13–15
> (Stage 8), so the invalid-weight this rank targets is largely already gone.
> Against a ~0.3 sampler with the protection set held only intermittently, a
> reachability-tightening prompt change is a direct timidity-ratchet risk
> (`tps_held` is now a primary metric) with no measured FP win left to justify it.
> Not pursued; revisit only paired with a validator change and scored over ≥3
> replays.

- **Pareto cell:** `hypothetical_scenario` — 30 invalid, **11.0 👎-weight**; `prompt_reachability` is its #1
  surface (23 members). ~11 of the downvoted members trace here. Calibration evidence:
  `declared_confidence_vs_reachability` shows **15 `high`-confidence findings with `hypothetical`
  reachability**, and `high`-confidence findings are 40.9% defective vs 41.8% for medium — the label is not
  discriminating (`declared_confidence_vs_adjudication`).
- **Control surface:** `lib/review_prompt.ml` — the `calibration` string (confidence definitions) and the
  `workflow` string (step 2 VERDICT / step 4 SIGNAL CHECK). This prompt feeds both the legacy single-pass
  (`Review_prompt.system_prompt`) and, via `system_prompt_override`, is the same calibration language the deep
  reviewer inherits.
- **Proposed change:** rewrite the `high` confidence definition from "you can show the exact input/state,
  changed line, execution path, and bad outcome" to make verification load-bearing: "`high`: the failure path
  is demonstrated by code you can see in the diff or in fetched file contents — every step of the mechanism is
  grounded in visible code, none inferred. If any step of the failure mechanism rests on an unfetched or
  assumed fact, the finding is at most `medium`, and if the whole mechanism is conditional on an unverified
  premise, DROP it (VERDICT step 2)." Add to the `workflow` banned-patterns list: conditional framing of the
  form "if <fact> is <assumed>, then <failure>" where `<fact>` was checkable.
- **Recall risk:** demoting/dropping conditional findings could catch the 12 `plausible` loved comments
  (`loved_profile.by_reachability`), which are legitimately not fully evidenced. Protection slice: the 9
  `medium`-confidence loved comments (`loved_profile.by_confidence`) — do not let the reachability rule push
  these to drop. **Before shipping:** `eval.jsonl` replay asserting the 12 `plausible` + 9 `medium` loved rows
  survive; §7d.
- **Expected impact:** attacks the reachability root of mode 1 (the 23 `prompt_reachability` members) and
  improves the calibration table so `high` predicts validity. Combined with Rank 1 (which resolves premises
  the model would otherwise guess), expected to move a meaningful share of the 15 hypothetical-high findings
  to either dropped or correctly demoted. Prompt-only, cheap, reversible.

---

### Rank 3 — UNTESTED, optional next cycle (blocked on `suggested_fix` serialization) — was: add a `broken_suggestion` / message-quality gate to the validator

> **OUTCOME: UNTESTED — optional, carried to the next cycle.** The only rank the
> replays never contradicted: it rejects defective *payloads*, not findings, so
> it carries no timidity-ratchet risk. It was not scored because the replay
> harness cannot exercise it — the saved `--output json` findings
> (`lib/local_sink.ml`) serialize only 6 fields and **drop `suggested_fix`**
> (Stage-9 fidelity gap), so a suggestion-payload criterion is inert on the frozen
> data. A genuine test needs `suggested_fix` serialized first. Reasonable
> low-risk candidate for the next cycle.

- **Pareto cell:** `poor_message` — 12 adjudicated-invalid, **4.0 👎-weight** (#2 mode); `prompt_style`
  surface (12 members). ~4 of the invalid `poor_message` members are downvoted. Taxonomy gap #3
  (`broken_suggestion`) rides inside this mode: exhibits `rvf_2b065d4c…`, `rvf_816446bd…`, `rvf_434c3e89…`
  filed as `poor_message` are mechanically defective ` ```suggestion``` ` payloads, plus secondary mentions in
  `rvf_f96ad02d…`. Body-level misreads: exhibits `rvf_c08e8cbe…`, `rvf_516cbf81…` (self-resolved / understated
  body prose).
- **Control surface:** `lib/general_validator_agent.ml` — the `system_prompt` "Validation Criteria" list
  (criteria 1–5). There is currently **no criterion checking the `suggested_fix` payload for mechanical
  validity**, and criterion 3 (Grounded Evidence) only checks the `evidence_snippet` matches the diff, not
  that a suggestion compiles / is not a no-op. Secondary: `lib/review_prompt.ml` `guidelines` ("suggest a fix
  when possible") and `non_findings` (the `summary` self-resolving-observation rule).
- **Proposed change:** add validator criterion 6 "Suggestion Payload Integrity": "If the candidate includes a
  ` ```suggestion``` ` block, REJECT it when the payload is byte-identical to the flagged line (no-op),
  contains literal `\n` escapes, replaces code with prose, duplicates an existing line, or would not
  plausibly typecheck/compile against the visible code. A defective fix payload is worse than no fix." Add to
  criterion 2 a clause rejecting self-resolved observations ("concludes no action needed", "just confirming")
  — mirror the `lib/review_prompt.ml` `non_findings` self-resolving rule into the validator so body-level
  noise (`rvf_c08e8cbe…`) is caught even when it slips the generator.
- **Recall risk:** low — this rejects *payloads*, not *findings*; the underlying defect can still post without
  a suggestion. Protection slice: none of the 36 loved findings are loved *for* a broken suggestion, but 8
  loved `bug` + 11 loved `logic` comments carry fixes — ensure the integrity check does not reject a *correct*
  suggestion. **Before shipping:** `eval.jsonl` replay confirming the 19 loved bug+logic rows keep their
  suggestions; §7d.
- **Expected impact:** targets 4.0 of 17.0 invalid weight (24%) at the payload layer plus the body-prose
  subset of `poor_message`. Recovers most of mode 2 without touching finding recall.

---

### Rank 4 — SHELVED (precision already achieved; downgrade-only) — was: tighten `critical`-severity proportionality in calibration prompt

> **OUTCOME: SHELVED.** Same disposition as Rank 2. This rank targets 1.0 of 17.0
> invalid weight directly (one downvoted member); against a sampler where FP
> suppression is already achieved vs the era, there is no measured invalid-weight
> to recover and a downgrade-only prompt change is not worth the ratchet risk.
> Not pursued.

- **Pareto cell:** `severity_inflation` — 11 adjudicated-invalid, **1.0 👎-weight** (#3 mode);
  `prompt_calibration` surface (11 members). Only 1 downvoted, but calibration data shows the systemic issue:
  **11 of 30 `critical` findings (36.7%) were inflated** (`declared_severity_vs_proportionality`), the worst
  over-declared tier; plus 25 inflated `warning`s. Exhibits `rvf_65a756af…` (removable-dead-code framed
  `warning` with a build-breaking fix), `rvf_a6c1da3e…` (retired-quota `warning`).
- **Control surface:** `lib/review_prompt.ml` — `calibration` string, `severity` definitions
  (`critical`/`warning`/`suggestion`).
- **Proposed change:** sharpen `critical` from "data loss, security exposure, production outage, or a defect
  that blocks the core workflow" to require *demonstrated* reachability: "`critical`: you have shown the exact
  trigger and the outcome IS data loss, security exposure, outage, or a blocked core workflow. If the severe
  outcome is conditional on an unverified premise, it is not `critical` — downgrade to `warning` or drop.
  A compile/exhaustiveness concern that the compiler already enforces is never `critical`." Add a `warning`
  clause: "not `warning` if the 'impact' is cosmetic, a non-functional cleanup, or contradicted by framework
  convention visible in the diff."
- **Recall risk:** could downgrade the 4 loved `critical` findings (`loved_profile.by_severity` = 4 critical)
  to `warning`. A downgrade is not a drop, so recall is preserved, but verify the 4 stay emitted.
  **Before shipping:** `eval.jsonl` replay confirming all 4 loved-critical rows still post (at any severity);
  §7d.
- **Expected impact:** targets 1.0 invalid weight directly but corrects the 11 inflated criticals + 25
  inflated warnings across the whole sample, improving the `critical` label's predictive value (currently
  36.7% inflated). Pairs with Rank 2 (same prompt file). Prompt-only.

---

### Rank 5 — SHELVED (context is not the lost-TP lever; superseded by #23) — was: broaden `fetch_key_files` beyond the 5 changed files

> **OUTCOME: SHELVED.** Explicitly the fallback for Rank 1, which was retired
> because context is not the lost-TP lever (Stage-4b: `deep_dropped` was
> over-refutation of an *embedded, correctly-led* defect). Separately, PR #23
> already made local-mode key-file embedding faithful to production
> (`select_key_files`), closing the fidelity gap this rank noticed. Broadening the
> static fetch beyond the 5 changed files was not pursued — no measured recall
> gain to be had from more context on this set.

- **Pareto cell:** shared root of `hypothetical_scenario` `context_fetch` members (7) and all 8
  `intent_mismatch` invalids (`context_fetch` 8). Escalation top paths cluster on a single private-repo
  backend API file family (×2 requests) behind exhibits `rvf_c51f0aa…` and `rvf_73d915bc…`
  (a helper-signature misread — the signature was one fetch away).
- **Control surface:** `lib/github_source.ml` `fetch_key_files` → `lib/review_job.ml` `select_key_files`
  (`CCList.take max_key_files` = 5; filters to Added/Modified only). This is the static pre-fetch that
  becomes the deep reviewer's `file_contents`
  (`lib/general_review_plugin.ml:230` → `General_deep_reviewer_agent.build_input`).
- **Proposed change:** this is the fallback if Rank 1's on-demand tool is too large a change. Raise the
  `CCList.take 5` cap (e.g. to 10–15) and — higher value — additionally fetch files *referenced by the diff*
  (module names / open'd modules / same-directory siblings of changed files), not only the changed files
  themselves. Keep it behind the existing `max_files` budget (`lib/config_types.ml`, `Config_codec.max_files`)
  so it cannot explode cost.
- **Recall risk:** none directly (more context cannot suppress a finding); the risk is **cost**, not recall.
  Security's $[redacted] tool-loop spend (INSIGHTS §9) is the warning: unbounded fetching is expensive. Cap it.
  No protection-set slice threatened. **Before shipping:** measure token delta on a replay batch; §7d.
- **Expected impact:** partially recovers the 7 mode-1 `context_fetch` + 8 mode-4 invalids that a static
  fetch could reach. Strictly weaker than Rank 1 (static, can't chase an arbitrary premise) — prefer Rank 1;
  ship this only if the tool-wiring change is deferred.

---

### Rank 6 — SHELVED (no measured FP win; part of the stable grounded-but-wrong floor) — was: ground external-tool/platform knowledge

> **OUTCOME: SHELVED.** A `false_mechanism` stale-knowledge fix with no measured
> FP win on the sampler. Its exhibits (`779e28` LD_LIBARY_PATH, `962a2b` unbound
> encoder, `4ea048` float_of_string, `9ecc9c` newest_mtime, and others) turn out
> to be part of the **stable FP floor of grounded-but-wrong findings** that
> Stage 9 showed the validator cannot separate — the evidence is visible in the
> diff, so taxonomy criteria don't fire, and catching them needs re-derivation
> outside the validator's mandate. A prompt knowledge-hygiene clause was not
> shown to move this floor. Not pursued.

- **Pareto cell:** `false_mechanism` sub-species inside `hypothetical_scenario` (30 invalid, 11.0 weight).
  Stale-knowledge exhibits: `rvf_a6c1da3e…` (retired YouTube per-part quota, downvoted), `rvf_19b1676e…`
  (setup-node v6 "does not exist"), `rvf_a7283f28…` (apt_preferences), `rvf_9ecc9ccf…` (GNU `date -d ""`) —
  from `taxonomy_gap_note.md` §2.
- **Control surface:** `lib/review_prompt.ml` `workflow` (VERDICT step 2) and `calibration` (confidence).
  Also `lib/general_scout_agent.ml` `build_system_prompt` (the scout emits these leads with over-flag bias).
- **Proposed change:** add a `workflow` clause: "You may be wrong about external tools, platform versions,
  API quota models, or CLI semantics — your training data may be stale. Do NOT emit a finding whose failure
  mechanism depends on the behavior/version/pricing of an external tool or platform unless the diff itself
  shows the contradicting behavior. When the mechanism is 'this external thing works like X', treat X as
  unverified and drop to at most `medium`, or drop." This is knowledge-hygiene, distinct from Rank 2's
  code-premise rule.
- **Recall risk:** low — the protection set is code-defect findings (`loved_profile.by_category`: bug/logic/
  error-handling, 0 external-tool findings loved). Little overlap. **Before shipping:** `eval.jsonl` replay
  confirming no `must_keep_flagging` row is an external-tool finding that this rule would silence; §7d.
- **Expected impact:** recovers the stale-knowledge subset of mode 1 (≥4 identified exhibits, likely more in
  the 30-member set). Smaller than Rank 1/2 but disjoint from them, so additive. Prompt-only.

---

## Decisions for the team (human decisions, NOT engine changes)

These are policy/config choices the maintainer must make. They are not mechanical tuning actions and must not
be auto-applied.

- **Security plugin cost/value.** `cost_efficiency`: security spent **$[redacted]** for **5** in-sample valid
  comments and **0** loved (vs general's $[redacted] → 79 valid / 23 loved). Decide whether to keep the security
  plugin enabled by default (`lib/config_types.ml` `security_plugin_config.enabled`, default `false` for
  webhooks / `true` for local), narrow `vuln_classes`, or raise `confidence_threshold` (default `Medium`).
  This is a spend/coverage tradeoff with a recall dimension the data can't see — a human call.
- **Split the taxonomy enum.** Adopting `unverified_premise`, `false_mechanism`, `broken_suggestion` as
  first-class failure modes (INSIGHTS §11) is an analysis-schema decision for the next adjudication round, not
  an engine change.
- **Per-repo `ignored_paths` / `ignored_file_regexes`.** 22 escalation path requests were unresolvable
  (guessed paths); the recurring private-repo path clusters (`escalation.top_requested_paths`)
  are candidate high-context areas. Whether to write per-repo config
  (`lib/config_types.ml` `Config_codec.ignored_paths` / `ignored_file_regexes`) is a team judgment about which
  paths are worth the context budget.
- **Upheld-yet-downvoted (18 findings).** These are correct findings authors disliked (INSIGHTS §3). Whether
  to change *tone/UX* (not suppress) is a product decision — do NOT turn it into a suppression knob.
- **Config-generation investigation.** The `38db8250` vs `91a33a6c` deltas are confounded (INSIGHTS §7);
  deciding whether to spend a counterfactual replay to disentangle them is a budget call.

---

## eval.jsonl usage note (mandatory before shipping any action above)

`eval.jsonl` is the frozen evaluation set: **101 rows = 65 `must_not_flag` (confirmed FPs) + 36
`must_keep_flagging` (the protection set — 👍'd + adjudicated-valid)**. The 69 adjudicated-valid-but-
unendorsed items carry no label by design.

Every candidate change (Ranks 1–6) MUST be replay-tested against `eval.jsonl` per the counterfactual-replay
protocol in `tools/replay/` (Stage 4) **before
shipping**: re-run the engine on the eval rows and measure **FPs removed** (of 65 `must_not_flag`) vs
**protected TPs broken** (of 36 `must_keep_flagging`). A change ships only if it removes `must_not_flag`
findings while breaking **zero** `must_keep_flagging` findings. Stage 4 was NOT run in this analysis
(budget-gated, no go-ahead) — so every impact estimate above is a pre-replay projection, and no action is
ship-ready until its replay passes.
