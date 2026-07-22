# Replay harness — scoring an engine against the frozen feedback eval set

This directory holds the offline harness used to score a reviewotron engine
build against a **frozen evaluation set** derived from real deployment feedback.
It answers one question about a candidate change (a tuning PR, a prompt tweak, a
model swap): *does it suppress the false positives humans downvoted without
dropping the findings humans endorsed?*

It is a **development / evaluation tool**, not part of the shipped binary.

## What `eval.jsonl` is

`eval.jsonl` (vendored here, 101 rows) is the labeled evaluation set. Each row
is one finding a deployed reviewotron posted on a real PR, tagged with a label
derived from a **blind adjudication** (an agent judged validity without seeing
the human reaction) cross-checked against the PR author's 👍/👎:

| label | count | meaning |
|---|---:|---|
| `must_not_flag` | 65 | adjudicated **invalid** (a false positive the engine should not re-emit) |
| `must_keep_flagging` | 36 | adjudicated **valid and endorsed** (the protection set — must not be lost) |

Row fields: `feedback_id`, `review_batch_id`, `head_sha`, `label`,
`source_reaction`, `failure_mode`, `finding_ref`, and `diff_ref` (a
provenance breadcrumb — an analysis-dir-relative path; the driver does **not**
read it, it derives the diff path from `--analysis-dir`).

**Provenance.** The labels come from the 2026-07-17 dev-sg deployment snapshot
(334 targets / 188 reviews / 83 PR-author reactions), adjudicated over a
173-item blind worklist with an adversarial verify pass. Full method and the
per-row exhibits live in the analysis archive (see "The analysis dir" below),
not in this repo.

### The single-draw caveat (read before trusting any single score)

The engine is a **high-variance sampler**: replaying the *label-era* engine
against its own labels reproduces only **~29–31% of them per run** (≈0.3
re-emission probability per row). A finding posted once in production is a
single draw, not a reliable behavior. Practical consequences:

- **`eval.jsonl` labels are one-shot samples.** "36 protected TPs" overstates
  what any engine — including the one that produced them — reliably emits.
- **Single-run `tps_held` / `fps_still_emitted` deltas of ±2–3 are noise.**
- **Decisions require ≥3 runs per variant**, scored in expectation, and gated
  on the *stable cores* (the rows that reproduce across all runs — ~6 TPs and
  ~9–10 FPs), not on any single roll.

## How to score a candidate engine

Prerequisites:

1. **Build the candidate engine** (`dune build`, ideally `--profile=release`).
   If the tree predates PR #23 (local-mode key-file embedding), you must apply a
   local-context shim first or the deep reviewer runs blind — the driver prints
   whether the fix is present at startup. See "Fidelity" below.
2. **A monorepo checkout** the diffs came from, and a **worktree pool**:
   ```sh
   export MONOREPO_ROOT=~/code/monorepo
   export OUTPUT_DIR=~/replay-out
   for i in $(seq 0 5); do
     git -C "$MONOREPO_ROOT" worktree add --detach "$OUTPUT_DIR/replay_worktrees/wt$i"
   done
   ```
3. **The analysis dir** (`ANALYSIS_DIR`) — the un-vendored run inputs (snapshot
   bundles, `replay_batches.json`, `worklist.json`, `items/`,
   `missing_shas.txt`). See "The analysis dir".
4. **A provider key** — `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY` in the env.

Then:

```sh
export ANALYSIS_DIR=~/feedback-analysis/2026-07-17
export OUTPUT_DIR=~/replay-out
export REVIEWOTRON_EXE=$PWD/_build/default/src/reviewotron.exe

# 0. (optional) scope & fidelity sanity checks — no engine runs
python3 tools/replay/replay_scope.py
python3 tools/replay/verify_shim_fidelity.py

# 1. run the engine once per replayable diff (resumable)
python3 tools/replay/replay_driver.py --concurrency 6

# 2. build same-file/±10-line candidate pairs
python3 tools/replay/match_prepare.py

# 3. generate the same-issue confirmation workflow, run it, harvest results
python3 tools/replay/gen_match_workflow.py
#    -> run $OUTPUT_DIR/match_workflow.js with the Workflow tool
#    -> save its returned `results` array to $OUTPUT_DIR/match_results.json

# 4. score
python3 tools/replay/replay_aggregate.py --label my-candidate --date 2026-07-30
```

The aggregator writes `$OUTPUT_DIR/replay_baseline.json` and prints the
headline (`tps_held`, `fps_still_emitted`, `fps_gone`, `tps_lost`, plus
coverage and spend). **Diff a candidate's headline against the baseline's, and
require ≥3 runs before calling a delta real** (see the single-draw caveat).

### The two-runs-minimum + stable-core protocol

For a go/no-go decision (not a quick smoke check):

1. Run steps 1–4 **at least 3 times** (delete/rename `replay_runs/` between
   runs, or use separate `OUTPUT_DIR`s).
2. Compute per-row hold/emit frequency across runs. The **stable core** = rows
   held/emitted in *every* run.
3. A candidate passes only if it (a) does not lose stable-core TPs and (b)
   reduces expected FP emission across runs. A single run's `4/23` vs `7/23` is
   within noise — do not ship or reject on it.

## Coverage

Of the 101 rows, **75 are replayable** by this harness (52 `must_not_flag` +
23 `must_keep_flagging`). Uncovered by design:

- **19 `pr_review_body` rows** — body-level findings can't be matched to
  inline replay output.
- **7 security-plugin rows** — the replay runs the general pipeline only
  (`--no-security`).

The "unrecoverable head SHA" class is empty in practice: force-pushed-away
heads are recoverable with a direct-SHA HTTPS fetch
(`git -c credential.helper='!gh auth git-credential' fetch <remote> <sha>`),
so `missing_shas.txt` is usually empty. Keep it (even empty) so `replay_scope`
can flag any SHA you genuinely can't fetch.

## Cost expectations

One full run of the scout+deep general pipeline over the ~73 replayable diffs
costs roughly **$0.55–1.10 per diff** (large diffs cost more — scout output
scales with diff size), so **≈ $40–80 per full run** at list prices. The
same-issue match workflow is negligible (~0.1–0.2M subagent tokens). Budget for
the ≥3 runs a real decision needs.

Note: a full-run's per-diff cost the driver reports is engine-computed; on the
direct-Anthropic path it is a **list-price basis** and the actual bill can be
lower. Also — historical *production* `review_costs.json` figures from the
label era double-count the prompt (OpenRouter reports the full prompt in both
`input_tokens` and `cache_creation`); don't compare replay $/diff against those
era numbers without halving the era input side.

## Fidelity — what a faithful replay requires

- **Local-mode key files.** Production embeds the first 5 added/modified files
  at `head_sha` into the deep reviewer's context
  (`Github_source.fetch_key_files`). Local `review-diff` did *not*, until PR #23
  wired `Review_job.select_key_files` into `local_source.ml`. On a **post-#23**
  engine the driver auto-detects the fix and needs no shim; on an **older** tree
  you must apply a shim mirroring the production selection or the deep reviewer
  runs blind (and under-flags massively). `verify_shim_fidelity.py` confirms the
  selected paths + content sha256 match each bundle's `fetched_files.json`.
- **PR title/body unavailable.** Bundles don't carry the real PR title/body, so
  replays use a synthetic `--title "PR #<n>"` and empty description. Scout lead
  selection can be mildly sensitive to this. Uniform across all rows.
- **Model era.** The label-era production reviews ran `claude-sonnet-4-6`
  single-pass; the current default tiers are different (sonnet-5 scout/validator
  + opus deep). That delta is part of "the current engine", not noise — but it
  means FP disappearance can't be attributed to any single change.
- **Config is pinned inline** for every batch (see `replay_driver.py`), so
  per-SHA config drift is removed. Override with `REPLAY_INLINE_CONFIG=<file>`.

## The analysis dir (not vendored)

Only `eval.jsonl` is checked into the repo. The harness also needs, from
`ANALYSIS_DIR`, artifacts that are **snapshot / run outputs and are
deliberately not vendored** (they are large and contain the deployment
snapshot):

- `snapshot/reviewotron-feedback-evidence/<batch>/` — `filtered_diff.patch`,
  `fetched_files.json`, `review_config.json` per batch.
- `replay_batches.json` — which `feedback_id`s each batch covers.
- `worklist.json` — per-item metadata (PR numbers).
- `items/<feedback_id>/finding.json` — the original finding (path/line/message)
  each label points at.
- `missing_shas.txt` — head SHAs known unresolvable (usually empty).

These live in the feedback-analysis working directory that produced
`eval.jsonl`; point `ANALYSIS_DIR` at it. `OUTPUT_DIR` (default = `ANALYSIS_DIR`)
is where the harness writes `replay_runs/`, the match files, the worktree pool,
and `replay_baseline.json`; keep it separate to drive fresh runs off a
read-only archive.

## Files

| file | role |
|---|---|
| `eval.jsonl` | the frozen labeled eval set (vendored) |
| `_config.py` | env-driven path/credential resolution shared by all scripts |
| `replay_scope.py` | coverage classification + prompt-override check (no engine runs) |
| `verify_shim_fidelity.py` | offline key-file-selection fidelity check (no engine runs) |
| `replay_driver.py` | run the engine once per replayable diff |
| `match_prepare.py` | build same-file/±10-line candidate pairs |
| `gen_match_workflow.py` | emit the same-issue confirmation Workflow script |
| `replay_aggregate.py` | score → `replay_baseline.json` + headline |
