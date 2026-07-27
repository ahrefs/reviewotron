#!/usr/bin/env python3
"""Assemble replay_baseline.json from eval.jsonl + match_auto.json +
match_results.json (agent confirmations) + replay_runs metadata.

Per-row outcome semantics:
- must_not_flag      + matched     -> "regressed"  (FP still emitted)
- must_not_flag      + not matched -> "fp_gone"
- must_keep_flagging + matched     -> "held"
- must_keep_flagging + not matched -> "lost"
- uncovered rows keep their coverage class (body / plugin / missing_sha /
  run_failed).

Reads ANALYSIS_DIR (replay_batches.json, items/) and OUTPUT_DIR
(match_auto.json, match_results.json, replay_runs/). Writes
OUTPUT_DIR/replay_baseline.json and prints the headline.

Pass --label <name> to tag the output (e.g. a PR candidate name); default
"baseline". The generated-date is not stamped by the script (Date is not
available in the workflow sandbox that may host this); pass --date YYYY-MM-DD
to record one.
"""
import json
import os
import re
import sys
import collections

import _config as C


def auto_rows():
    """Load match_auto.json, validating every row's outcome up front."""
    rows = C.unique_by(
        json.load(open(C.in_output("match_auto.json"))), "feedback_id", "match auto rows"
    )
    for fid, row in rows.items():
        if not isinstance(row.get("outcome"), str) or row["outcome"] == "":
            sys.exit("match auto row has non-string outcome: %s" % fid)
    return rows


def match_results_by_feedback(candidates, results):
    candidate_by_id = C.unique_by(candidates, "pair_id", "match candidates")
    result_by_id = C.unique_by(results, "pair_id", "match results")
    missing = sorted(set(candidate_by_id) - set(result_by_id))
    unexpected = sorted(set(result_by_id) - set(candidate_by_id))
    if missing or unexpected:
        sys.exit("match results must cover candidates exactly; missing=%s unexpected=%s" % (missing, unexpected))
    by_feedback = collections.defaultdict(list)
    for pair_id, result in result_by_id.items():
        if not isinstance(result.get("match"), bool):
            sys.exit("match result %s has non-boolean match" % pair_id)
        candidate = candidate_by_id[pair_id]
        by_feedback[candidate["feedback_id"]].append(
            {
                "pair_id": pair_id,
                "match": result["match"],
                "reason": result.get("reason", ""),
            }
        )
    return by_feedback, candidate_by_id


def main():
    label = "baseline"
    gen_date = None
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--label":
            label = args.pop(0)
        elif a == "--date":
            gen_date = args.pop(0)
        else:
            sys.exit("unknown arg: %s" % a)

    rows = [json.loads(l) for l in open(C.EVAL_JSONL)]
    batches = json.load(open(C.in_analysis("replay_batches.json")))
    auto = auto_rows()
    candidates = json.load(open(C.in_output("match_candidates.json")))
    results = json.load(open(C.in_output("match_results.json")))
    runs = C.runs_dir()
    matched_rows, candidate_by_id = match_results_by_feedback(candidates, results)
    scored_feedback_ids = set(C.replayable_rows(rows, batches))
    prepared_feedback_ids = set(auto) | {candidate["feedback_id"] for candidate in candidate_by_id.values()}
    if scored_feedback_ids != prepared_feedback_ids:
        missing = sorted(scored_feedback_ids - prepared_feedback_ids)
        unexpected = sorted(prepared_feedback_ids - scored_feedback_ids)
        sys.exit("match preparation does not cover replayable rows; missing=%s unexpected=%s" % (missing, unexpected))

    out_rows = []
    tally = collections.Counter()
    for row in rows:
        fid = row["feedback_id"]
        bid = row["review_batch_id"]
        rlabel = row["label"]
        entry = {
            "feedback_id": fid,
            "review_batch_id": bid,
            "label": rlabel,
            "finding_ref": row["finding_ref"],
        }
        plugin = C.plugin_name(row)
        if plugin != "general":
            entry["coverage"] = "uncovered_plugin_%s" % (plugin or "unknown")
            entry["outcome"] = None
        elif bid not in batches or fid not in batches.get(bid, []):
            entry["coverage"] = "uncovered_missing_sha"
            entry["outcome"] = None
        elif fid in auto and (
            auto[fid]["outcome"].startswith("run_")
            or auto[fid]["outcome"] == "missing_original"
        ):
            entry["coverage"] = "uncovered_" + auto[fid]["outcome"]
            entry["outcome"] = None
        else:
            entry["coverage"] = "replayed"
            pairs = matched_rows.get(fid, [])
            matched = any(p["match"] for p in pairs)
            entry["n_candidates"] = len(pairs)
            entry["match_reasons"] = [
                {"pair_id": p["pair_id"], "match": p["match"], "reason": p["reason"]}
                for p in pairs
            ]
            if rlabel == "must_not_flag":
                entry["outcome"] = "regressed" if matched else "fp_gone"
            else:
                entry["outcome"] = "held" if matched else "lost"
        tally[(entry["coverage"], rlabel, str(entry["outcome"]))] += 1
        out_rows.append(entry)

    # spend from cost_tracking stderr lines
    spend = 0.0
    durations = []
    per_batch_cost = {}
    for bid in batches:
        log = os.path.join(runs, bid, "stderr.log")
        if os.path.exists(log):
            m = re.findall(r"cost \[general\] total: .*cost=\$([0-9.]+)",
                           open(log, errors="replace").read())
            if m:
                c = float(m[-1])
                spend += c
                per_batch_cost[bid] = c
        mp = os.path.join(runs, bid, "meta.json")
        if os.path.exists(mp):
            meta = json.load(open(mp))
            if meta.get("duration_s"):
                durations.append(meta["duration_s"])

    headline = {
        "must_not_flag_total": sum(1 for r in rows if r["label"] == "must_not_flag"),
        "must_keep_flagging_total": sum(1 for r in rows if r["label"] == "must_keep_flagging"),
        "fps_still_emitted": sum(1 for e in out_rows if e["outcome"] == "regressed"),
        "fps_gone": sum(1 for e in out_rows if e["outcome"] == "fp_gone"),
        "tps_held": sum(1 for e in out_rows if e["outcome"] == "held"),
        "tps_lost": sum(1 for e in out_rows if e["outcome"] == "lost"),
        "replayed_must_not_flag": sum(
            1 for e in out_rows if e["coverage"] == "replayed" and e["label"] == "must_not_flag"),
        "replayed_must_keep_flagging": sum(
            1 for e in out_rows if e["coverage"] == "replayed" and e["label"] == "must_keep_flagging"),
    }
    coverage = collections.Counter((e["coverage"], e["label"]) for e in out_rows)
    baseline = {
        "label": label,
        "generated": gen_date,
        "engine": {
            "repo": "reviewotron",
            "pipeline": "scout+deep (general), security plugin disabled",
            "config": "pinned inline for all batches (see replay_driver.py)",
            "line_match_window": 10,
        },
        "headline": headline,
        "coverage": {"%s|%s" % k: v for k, v in sorted(coverage.items())},
        "spend": {
            "engine_usd_total": round(spend, 2),
            "batches_run": len(per_batch_cost),
            "mean_batch_usd": round(spend / max(1, len(per_batch_cost)), 3),
            "mean_batch_duration_s": round(sum(durations) / max(1, len(durations)), 1),
        },
        "rows": out_rows,
    }
    out_path = C.in_output("replay_baseline.json")
    json.dump(baseline, open(out_path, "w"), indent=1)
    print(json.dumps({k: v for k, v in baseline.items() if k != "rows"}, indent=1))


if __name__ == "__main__":
    main()
