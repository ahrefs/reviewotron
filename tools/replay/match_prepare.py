#!/usr/bin/env python3
"""Build match candidates: eval row (original finding) x replay finding pairs.

Deterministic filter: same file (a/ b/ prefixes stripped), |line delta| <= 10.
Outputs (into OUTPUT_DIR):
- match_candidates.json  pairs needing agent confirmation
- match_auto.json        rows resolved without agents (no replay candidate, or
                         the batch replay failed or source body is unavailable)

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


def original_body(bid):
    path = C.in_analysis(os.path.join("snapshot", "reviewotron-feedback-evidence", bid, "posted_review.json"))
    try:
        body = json.load(open(path)).get("body")
    except (OSError, json.JSONDecodeError):
        return None
    return body.strip() if isinstance(body, str) and body.strip() else None


def original_finding(fid):
    path = C.in_analysis(os.path.join("items", fid, "finding.json"))
    try:
        return json.load(open(path))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit("cannot load original finding for %s: %s" % (fid, error))


def body_pair(fid, row, bid, original, replay):
    return {
        "pair_id": "%s#body" % fid,
        "feedback_id": fid,
        "label": row["label"],
        "review_batch_id": bid,
        "kind": "review_body",
        "original": {"body": original},
        "replay": {"body": replay},
    }


def inline_pairs(fid, row, bid, original, replay):
    original_finding = original["finding"]
    opath = norm_path(original_finding["path"])
    oline = original_finding["line"]
    candidates = [
        (i, replay_finding)
        for i, replay_finding in enumerate(replay.get("findings", []))
        if norm_path(replay_finding["file"]) == opath and abs(replay_finding["line"] - oline) <= LINE_WINDOW
    ]
    pairs = []
    for i, replay_finding in candidates:
        pairs.append(
            {
                "pair_id": "%s#%d" % (fid, i),
                "feedback_id": fid,
                "label": row["label"],
                "review_batch_id": bid,
                "kind": "inline_finding",
                "original": {
                    "path": original_finding["path"],
                    "line": oline,
                    "end_line": original_finding.get("end_line"),
                    "severity": original_finding.get("severity"),
                    "category": original_finding.get("category"),
                    "confidence": original_finding.get("confidence"),
                    "message": original_finding["message"],
                    "failure_scenario": original_finding.get("failure_scenario", ""),
                    "evidence_snippet": original_finding.get("evidence_snippet", ""),
                    "why_now": original_finding.get("why_now", ""),
                    "suggested_fix": original_finding.get("suggested_fix"),
                },
                "replay": {
                    "file": replay_finding["file"],
                    "line": replay_finding["line"],
                    "end_line": replay_finding.get("end_line"),
                    "level": replay_finding.get("level"),
                    "category": replay_finding.get("category"),
                    "confidence": replay_finding.get("confidence"),
                    "summary": replay_finding["summary"],
                    "failure_scenario": replay_finding.get("failure_scenario", ""),
                    "evidence_snippet": replay_finding.get("evidence_snippet", ""),
                    "why_now": replay_finding.get("why_now", ""),
                    "suggested_fix": replay_finding.get("suggested_fix"),
                },
            }
        )
    return pairs


def main():
    rows = [json.loads(l) for l in open(C.EVAL_JSONL)]
    batches = json.load(open(C.in_analysis("replay_batches.json")))
    replayable = {
        r["feedback_id"]: r
        for r in rows
        if r["review_batch_id"] in batches
        and r["feedback_id"] in batches[r["review_batch_id"]]
        and C.is_general_row(r)
    }
    runs = C.runs_dir()
    replay = {}
    run_status = {}
    for bid in batches:
        try:
            meta = json.load(open(os.path.join(runs, bid, "meta.json")))
            out = json.load(open(os.path.join(runs, bid, "output.json")))
        except OSError:
            run_status[bid] = "missing"
            replay[bid] = {"findings": [], "summary": ""}
            continue
        except json.JSONDecodeError as error:
            raise SystemExit("invalid replay output for %s: %s" % (bid, error))
        if (
            not isinstance(out, dict)
            or not isinstance(out.get("findings"), list)
            or not isinstance(out.get("summary"), str)
        ):
            raise SystemExit("invalid replay output for %s: expected object with findings list and summary" % bid)
        run_status[bid] = "ok" if meta.get("exit") == 0 else "failed"
        replay[bid] = out

    pairs = []
    auto = []
    for fid, row in sorted(replayable.items()):
        bid = row["review_batch_id"]
        if run_status[bid] != "ok":
            auto.append({
                "feedback_id": fid, "label": row["label"],
                "outcome": "run_" + run_status[bid], "matched": None,
            })
            continue
        if row["finding_ref"] == "pr_review_body":
            original = original_body(bid)
            replay_body = str(replay[bid].get("summary", "")).strip()
            if original is None:
                auto.append({
                    "feedback_id": fid, "label": row["label"], "outcome": "missing_original", "matched": None,
                })
            elif replay_body == "":
                auto.append({
                    "feedback_id": fid, "label": row["label"], "outcome": "no_candidates", "matched": False,
                })
            else:
                pairs.append(body_pair(fid, row, bid, original, replay_body))
            continue
        original = original_finding(fid)
        inline = inline_pairs(fid, row, bid, original, replay[bid])
        if inline == []:
            auto.append({
                "feedback_id": fid, "label": row["label"],
                "outcome": "no_candidates", "matched": False,
                "n_replay_findings_in_batch": len(replay[bid].get("findings", [])),
            })
            continue
        pairs.extend(inline)

    json.dump(pairs, open(C.in_output("match_candidates.json"), "w"), indent=1)
    json.dump(auto, open(C.in_output("match_auto.json"), "w"), indent=1)
    by = collections.Counter(a["outcome"] for a in auto)
    print("replayable rows:", len(replayable))
    print("auto-resolved:", dict(by))
    print("pairs needing agent confirm:", len(pairs),
          "covering", len(set(p["feedback_id"] for p in pairs)), "rows")


if __name__ == "__main__":
    main()
