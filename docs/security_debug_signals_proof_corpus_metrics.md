# Security Debug, Signals, and Proof Corpus Metrics

Date: 2026-06-24

This report records the first tranche implementation status for the
provider-backed security corpus. The corpus runner requires
`ANTHROPIC_API_KEY` for triage and full-pipeline quality metrics.

## Baseline Capture

- Baseline tree: `HEAD` at `cd46f0f1fb2c19855f613ef0a2522ab614e4f84c`,
  extracted to `/tmp/reviewotron-baseline.Bhwxet` so the dirty worktree was not
  reverted.
- Command run from the baseline `test/` directory: `dune exec
  ./test_security_corpus.exe`.
- Result: 28/28 passed.

| Metric | Baseline |
|--------|----------|
| Structural corpus checks | 10/10 |
| Triage recall | 7/7 = 100.0% |
| Triage precision, vulnerable cases | 7/9 = 77.8% |
| Pipeline true-positive rate | 7/7 = 100.0% |
| Clean-case post-validation false-positive rate | 0/3 = 0.0% |
| Average / p95 agent count | 2.60 / 3 |
| Average / p95 agent turns | 4.70 / 9 |
| Average / p95 `get_file_content` calls / fetched files | 2.10 / 6 |
| Average / p95 estimated cost | $0.0317 / $0.0676 |
| Total estimated corpus cost | $0.3167 |
| Fetched bytes | Not instrumented |

## After Tranche Capture

- Command run from the working-tree `test/` directory after the proof prompt
  and validator proof-repair fixes: `dune exec ./test_security_corpus.exe`.
- Result: 28/28 passed.

| Metric | After tranche |
|--------|---------------|
| Structural corpus checks | 10/10 |
| Triage recall | 7/7 = 100.0% |
| Triage precision, vulnerable cases | 7/8 = 87.5% |
| Pipeline true-positive rate | 7/7 = 100.0% |
| Clean-case post-validation false-positive rate | 0/3 = 0.0% |
| Average / p95 agent count | 2.70 / 4 |
| Average / p95 agent turns | 5.50 / 13 |
| Average / p95 `get_file_content` calls / fetched files | 2.80 / 9 |
| Average / p95 estimated cost from stage metrics | $0.0419 / $0.0802 |
| Total estimated corpus cost from stage metrics | $0.4192 |
| Fetched bytes | Not instrumented |

For apples-to-apples comparison with the baseline logs, the after-tranche
agent-runner token estimate was average / p95 $0.0388 / $0.0764, total $0.3881.
The stage metrics are preferred for new runs because they come from
`Cost_tracking` records.

## Outcome Delta

- Final pass/fail outcomes: no corpus case changed outcome. Baseline and after
  both passed every vulnerable and clean full-pipeline case.
- Triage precision improved on vulnerable cases from 77.8% to 87.5%.
- Clean-case false positives did not increase: 0/3 before and 0/3 after.
- Cost and tool/fetch usage increased modestly: average agent count +0.10,
  p95 agent count +1, average fetched files/tool calls +0.70, p95 fetched
  files/tool calls +3, and average stage-metric cost $0.0419 after vs an
  estimated $0.0317 baseline.
- Parse failures: none observed in either final provider-backed run.
- Proof downgrades: none observed in the final after-tranche run.

## Regression Found During Capture

The first after-tranche provider run exposed a false-negative regression:
validator responses often had strong `verdict = "confirmed"` rationale but
omitted `proof_by_construction`, causing post-parse proof enforcement to
downgrade 6 of 7 vulnerable pipeline cases. The fix was to make the validator
agent schema require the proof key, strengthen the prompt to emit an object for
confirmed results and `null` for rejected results, and add per-candidate proof
trace requirements naming the exact source and sink sites.

A later full `make clean build test fmt` pass exposed the same provider omission
on `authn/jwt_no_expiry_check`: the validator notes concretely confirmed the
finding but still omitted the proof object, so the post-parse guard downgraded
it. The final fix keeps the strict invariant but adds a narrow parser-side
repair: a missing proof may be synthesized only from the typed candidate
source/sink/flow evidence when validator notes are decisive, mention concrete
source and sink sites, and do not contain unresolved assumptions. Hedged or
vague missing-proof results still downgrade.

Post-repair validation on 2026-06-24:

- `dune exec ./test_security_corpus.exe -- test corpus_pipeline 7`: passed.
- `make clean build test fmt`: passed, including `security_corpus` 28/28 in
  579.672s.

## Tranche Notes

- Metrics/artifacts: covered by local artifact tests; full artifacts remain
  opt-in.
- Deterministic signals: covered by scanner tests and an end-to-end regression
  proving signals do not route analysis without actionable triage output.
- Proof enforcement: covered by validator parsing/enforcement tests; confirmed
  results without concrete proof are downgraded.
- Proof summaries: covered by review finding field tests for
  `failure_scenario`, `evidence_snippet`, and `why_now`.
- Fetched-byte metrics are still unavailable; current instrumentation records
  fetched-file/tool-call counts but not content byte totals.
