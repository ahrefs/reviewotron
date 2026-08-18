# Security validator count gate: all findings discarded

Investigation 2026-08-18. Read-only; no code changed.

## Summary

On a deliberately vulnerable todo app, reviewotron v0.7.0 detected 9 candidate
findings (covering 7 distinct real vulnerabilities) and reported **none** of
them, emitting `LGTM :+1:`.

Nothing failed to detect the vulnerabilities. They were destroyed at the last
stage by a strict count check.

## Mechanism

1. Detection worked: `analysis complete: 9 total candidate findings`.
2. `validator_results_for_candidates` (`lib/security_review_plugin.ml:329`)
   gates on `Int.equal candidate_count result_count`. The validator returned
   **1** result for **9** candidates, so **all 9 were discarded wholesale** —
   not one was individually judged. Hence the contradictory log line
   `validation complete: 0 confirmed, 0 rejected`.
3. `run_validator` maps every failure (agent error, JSON parse error, count
   mismatch) to an empty finding list (`main:679`, `Lwt.return ([], [cost], true)`).
4. The renderer derives LGTM from `findings = []` (`review_engine.ml:401`),
   so "validation destroyed everything" is indistinguishable from
   "validated clean".

`validated_finding` (`lib/security_types.ml:273`) has no `candidate_id`;
results are paired to candidates **positionally, by count alone**.

## Since when

- Introduced **2026-07-01** by `60e5572` "Reduce security review validation
  pressure". Before that commit there was no gate — validator output fed
  straight through, so a 9→1 undercount would have surfaced **1** finding
  instead of 0. The commit converted partial loss into total loss.
- Ships in every released version **0.1.0 → 0.7.0** (current).
- `33577f2` "Report local review engine failures (#32)" (2026-08-17) added a
  `failed` boolean, so the run is now marked failed — but
  `validator_results_for_candidates` is **byte-identical on main**. #32 fixed
  the *signal*, not the *discard*.
- `test/test.ml:2136` `test_security_validator_result_count_mismatch_is_error`,
  added in `60e5572`, asserts the total-discard Error is correct behaviour. Any
  fix must change this test.

## Local vs server: the bug differs in visibility, not in loss

Finding loss is identical (same plugin code). Surfacing differs:

| | Local (`--json`) | Server (GitHub PR) |
|---|---|---|
| Findings lost | all 9 | all 9 |
| Failure surfaced | `"outcome": "failure"` + warning note | `report_has_surface` includes `security_error` (`reviewer.ml:213`), so the real body + warning note is posted instead of bare LGTM |
| Worst case | headline still reads `LGTM :+1:` | no bare-LGTM comment |

`"outcome"` is written **only** on the failure path (`local_sink.ml:50`); runs
4 and 5 omit the key entirely. So you cannot detect this by checking for
`outcome: success`.

## Evidence (v0.7.0, VPS runs 2026-08-18)

| candidates (deduped) | validator returned | reported |
|---|---|---|
| 1 | 1 | 1 |
| 3 (from 4 raw) | 3 | 3 |
| 4 ×4 sweeps | 4 | 4 (one legit rejection → 3) |
| **9** | **1** | **0** |

Correct counts at n=1,3,4 rule out a code-side dedup miscount: this is
model-side. Corroborating: the validator burned only 744 output tokens and
stopped after 1 step despite `max_steps=12`.

Across usable sweeps: 16 candidates → 15 reported, the one loss a legitimate
rejection. The gate fired **once** in the whole corpus — rare but catastrophic.

## Fix design: a content join is already possible

No `candidate_id` and no schema change needed:

- `dedup_candidates` (`:719`) keys on exactly `(sink.path, sink.line)` and runs
  at `:844`, immediately before the validator call at `:868`. That key is
  therefore **unique by construction** among candidates sent to the validator.
- `validated_finding` echoes the whole `candidate_finding` back, so the join
  fields are already on the wire.
- The objection "content matching was tried and abandoned" does **not** apply.
  The scheme removed in `ead7189` keyed on
  `path && line && String.equal c.message f.message` and was dropped because
  the model paraphrases **`message`**. `path`/`line` were never implicated.
  (That was general-plugin code, which has no dedupe pass, so path+line
  uniqueness was never guaranteed there as it now is for security.)
- `enforce_validator_proofs` is a pure `List.map` with no positional
  dependency, so it survives a join-based rewrite unchanged.

Blast radius for a full error channel: 6 files, ~13 sites. `fp_run` has exactly
one findings plugin, so widening it forces no other plugin changes.

`build_input` embeds the full `diff_text` in **every** batch
(`validator_agent.ml:199-209`) — so per-candidate validation costs N copies of
the diff, not just N calls. Cost aggregation handles N calls correctly (pure
folds); only the user-visible "N agents" footer changes.

## Recommended, in order

1. **Join results to candidates on `(sink.path, sink.line)`; treat unmatched
   candidates as unvalidated-withheld, not discarded.** Smallest change, rests
   on an invariant that already holds, strictly dominates today's behaviour
   (this run would have surfaced 1 finding instead of 0).
2. **Derive LGTM from successful completion, not from `findings = []`.** This
   is what turns a rare fault into a silent one, and it is worth fixing
   regardless of validation strategy.
3. **Batch only if step exhaustion persists** after 1–2. Smaller batches each
   get their own 12-step budget.

Withhold unvalidated findings rather than publishing them low-confidence: the
validator is the precision boundary, and publishing raw analysis output
recreates the false-positive pressure it exists to control.

## Not recommended

- **Deleting the gate.** Equal counts never proved correspondence (the model
  can reorder, duplicate, or mutate echoed findings and still pass). Keep it as
  an integrity *assertion*; just stop using it as a mapping mechanism or as
  grounds for returning `[]`.
- **`candidate_id` alone.** General already has one *and* the identical count
  gate, so IDs do not rescue an undercount without a recovery policy.
- **Per-candidate validation as step 1.** Right in principle, but N× diff cost
  against an exhausted key; revisit if 1–2 prove insufficient.
- **Re-running to reproduce.** Costs money and proves nothing already known.

## Fix plan: the silence (scoped, agreed)

Scope: reviewotron must never render `LGTM :+1:` when the security stage
failed. Does **not** touch the discard, the count gate, batching, or validator
capacity.

**Deployed build is materially worse than main.** On `fb364dc` the mismatch
returns `([], [cost])`; `security_error` is `errored || (enabled && costs = [])`
— nothing raised and costs are non-empty, so `security_error = false`. Result:
bare LGTM, no warning, `outcome` absent, and `report_has_surface = false` so the
PR gets the hardcoded quiet-success `"LGTM :+1:"` (`github_sink.ml:216-219`).
Total silence on both paths.

On main, 33577f2 already sets the flag — but `review_engine.ml:403` still
renders LGTM and `:412` merely *appends* a note after it.

**The change (one file):** guard the zero-findings arm at `review_engine.ml:403`
on `security_error`, which `review_body` already receives (`:327`). Replace LGTM
with a neutral "review did not complete" message rather than appending a warning
after it.

**Trap:** do NOT gate on `security_completed` (`:343-344`) — it is
`enabled && not security_error && cost_plugin_ran`, so it is false when security
is *disabled*, which would delete LGTM for disabled-security configs. Gate on
`security_error`.

**The withheld count is not available at the render site.** It is computed at
`:330`, formatted into the log string at `:678`, then dropped — only the bool
survives. The same bool is also set by triage/analysis failures that have no
candidate count. Carrying N means a bool→variant change through ~8 sites, which
is outside this scope. Omit the number, as `security_error_notice` already does.

**Remaining bare-LGTM path (latent):** `github_sink.ml:214-219` hardcodes
`"LGTM :+1:"` independently of `review_body`. Unreachable for the security case
on main (`security_error` is a disjunct of `report_has_surface`), but it is the
reason the deployed build is silent.

**Loudness risk is nil on main:** since 33577f2 `security_error` already forces a
PR review post, so the fix only rewords what is already posted. Transient 403/401
outages already post today and get retry guidance (`:321-324`).

**Backport:** the guard **cannot** be cherry-picked to `fb364dc` — there is no
flag to read there. Backporting means backporting 33577f2 first. Recommended:
fix on main, then deploy main.

**Tests:** `test_security_validator_result_count_mismatch_is_error` (`:2136`)
does NOT break (the gate is untouched). Must keep passing:
`test_local_review_all_refuted_shows_lgtm_not_summary` (main `:4237`). Add:
(a) validation failure produces no LGTM and `report_failed` — a count mismatch is
reproducible through the public surface with a fixture returning fewer `results`
than candidates, so nothing needs exposing; (b) a genuinely clean review still
emits LGTM; (c) local-JSON (`"outcome":"failure"`) and PR-comment variants.

## Ordering after the silence fix

1. **Validator capacity / bounded work per call** — the likely real cause.
2. **Pairing join** — safety net only. If added, use an explicit `candidate_id`,
   **not** `(path, line)`: that key is unique today only because
   `dedup_candidates` happens to run immediately before the validator, which is
   an incidental ordering invariant rather than a guaranteed one.

## Open questions

- **Trigger not isolated.** Batch size is confounded with pipeline breadth:
  run3 is also the only full-pipeline run (6 analysis agents), and nothing was
  tested between 4 and 9 candidates. Truncation-under-load is the best
  explanation but is not established as count-specific. A single 6–7 candidate
  run would separate the two.
- **No raw validator payload.** `validator_input.md` / `validator_output.json`
  do not exist for run3, so we cannot confirm the validator *received* all 9.
  The path+line join is robust either way.
- **10 of 15 sweep logs are truncated to 2 lines**, outcomes unknown. Absence
  of the signature there is not evidence of absence.
- **Deployment scan not done.** The deployed build is `fb364dc`, which predates
  every change here, so use the *old* fingerprint when grepping its logs:
  `security validator returned N results for M candidates`, or in metrics
  `raw_candidates_produced > 0 && confirmed == 0 && rejected == 0` (a legitimate
  rejection satisfies `confirmed + rejected == kept`).

  That string no longer exists after the id-join change. On current builds the
  equivalent signal is
  `validator: N candidate(s) withheld with no verdict after retry`, and the
  metrics invariant `confirmed + rejected == kept` still identifies loss — but
  loss is now partial (the withheld candidates only) rather than total.
