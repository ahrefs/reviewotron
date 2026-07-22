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


def plugin_name(fid):
    p = C.in_analysis(os.path.join("items", fid, "finding.json"))
    if os.path.exists(p):
        return json.load(open(p)).get("plugin_name")
    return None


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
    auto = {a["feedback_id"]: a
            for a in json.load(open(C.in_output("match_auto.json")))}
    results = json.load(open(C.in_output("match_results.json")))
    runs = C.runs_dir()

    matched_rows = {}
    for r in results:
        matched_rows.setdefault(r["feedback_id"], []).append(r)

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
        pl = plugin_name(fid)
        if row["finding_ref"] == "pr_review_body":
            entry["coverage"] = "uncovered_body"
            entry["outcome"] = None
        elif pl is not None and pl != "general":
            entry["coverage"] = "uncovered_plugin_%s" % pl
            entry["outcome"] = None
        elif bid not in batches or fid not in batches.get(bid, []):
            entry["coverage"] = "uncovered_missing_sha"
            entry["outcome"] = None
        elif fid in auto and auto[fid]["outcome"].startswith("run_"):
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
