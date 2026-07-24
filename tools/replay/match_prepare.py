#!/usr/bin/env python3
"""Build match candidates: eval row (original finding) x replay finding pairs.

Deterministic filter: same file (a/ b/ prefixes stripped), |line delta| <= 10.
Outputs (into OUTPUT_DIR):
- match_candidates.json  pairs needing agent confirmation
- match_auto.json        rows resolved without agents (no replay candidate, or
                         the batch replay failed)

Reads replay_batches.json + items/<fid>/finding.json from ANALYSIS_DIR, and the
per-batch engine output from OUTPUT_DIR/replay_runs/.
"""
import json
import os
import collections

import _config as C

LINE_WINDOW = 10


def norm_path(p):
    for pre in ("a/", "b/"):
        if p.startswith(pre):
            return p[len(pre):]
    return p


def main():
    rows = [json.loads(l) for l in open(C.EVAL_JSONL)]
    batches = json.load(open(C.in_analysis("replay_batches.json")))
    replayable = {
        r["feedback_id"]: r
        for r in rows
        if r["review_batch_id"] in batches
        and r["feedback_id"] in batches[r["review_batch_id"]]
    }
    runs = C.runs_dir()
    replay = {}
    run_status = {}
    for bid in batches:
        try:
            meta = json.load(open(os.path.join(runs, bid, "meta.json")))
            out = json.load(open(os.path.join(runs, bid, "output.json")))
            run_status[bid] = "ok" if meta.get("exit") == 0 else "failed"
            replay[bid] = out.get("findings", [])
        except Exception:
            run_status[bid] = "missing"
            replay[bid] = []

    pairs = []
    auto = []
    for fid, row in sorted(replayable.items()):
        bid = row["review_batch_id"]
        orig = json.load(open(C.in_analysis(os.path.join("items", fid, "finding.json"))))
        opath = norm_path(orig["finding"]["path"])
        oline = orig["finding"]["line"]
        if run_status[bid] != "ok":
            auto.append({
                "feedback_id": fid, "label": row["label"],
                "outcome": "run_" + run_status[bid], "matched": None,
            })
            continue
        cands = [
            (i, f) for i, f in enumerate(replay[bid])
            if norm_path(f["file"]) == opath and abs(f["line"] - oline) <= LINE_WINDOW
        ]
        if not cands:
            auto.append({
                "feedback_id": fid, "label": row["label"],
                "outcome": "no_candidates", "matched": False,
                "n_replay_findings_in_batch": len(replay[bid]),
            })
            continue
        for i, f in cands:
            pairs.append({
                "pair_id": "%s#%d" % (fid, i),
                "feedback_id": fid,
                "label": row["label"],
                "review_batch_id": bid,
                "original": {
                    "path": orig["finding"]["path"],
                    "line": oline,
                    "severity": orig["finding"].get("severity"),
                    "category": orig["finding"].get("category"),
                    "message": orig["finding"]["message"],
                },
                "replay": {
                    "file": f["file"], "line": f["line"],
                    "level": f.get("level"), "category": f.get("category"),
                    "summary": f["summary"],
                    "failure_scenario": f.get("failure_scenario", ""),
                },
            })

    json.dump(pairs, open(C.in_output("match_candidates.json"), "w"), indent=1)
    json.dump(auto, open(C.in_output("match_auto.json"), "w"), indent=1)
    by = collections.Counter(a["outcome"] for a in auto)
    print("replayable rows:", len(replayable))
    print("auto-resolved:", dict(by))
    print("pairs needing agent confirm:", len(pairs),
          "covering", len(set(p["feedback_id"] for p in pairs)), "rows")


if __name__ == "__main__":
    main()
