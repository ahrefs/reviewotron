#!/usr/bin/env python3
"""Aggregate repeated replay_baseline.json files into stable-core metrics."""
import json
import sys


def rows_by_id(path):
    rows = json.load(open(path))["rows"]
    result = {}
    for row in rows:
        fid = row["feedback_id"]
        if fid in result:
            sys.exit("duplicate feedback_id in %s: %s" % (path, fid))
        result[fid] = row
    return result


def parse_args():
    paths = []
    output = None
    args = iter(sys.argv[1:])
    for arg in args:
        if arg == "--output":
            output = next(args, None)
            if output is None:
                sys.exit("--output requires a path")
        else:
            paths.append(arg)
    if len(paths) < 2:
        sys.exit("usage: replay_stable.py baseline.json baseline.json [baseline.json ...] [--output path]")
    return paths, output


def main():
    paths, output = parse_args()
    runs = [rows_by_id(path) for path in paths]
    feedback_ids = set(runs[0])
    if any(set(rows) != feedback_ids for rows in runs[1:]):
        sys.exit("baseline files do not cover the same feedback IDs")

    rows = []
    for fid in sorted(feedback_ids):
        samples = [run[fid] for run in runs]
        labels = {sample["label"] for sample in samples}
        if len(labels) != 1:
            sys.exit("feedback_id has inconsistent labels: %s" % fid)
        label = labels.pop()
        outcomes = [sample["outcome"] for sample in samples]
        replayed = [outcome is not None for outcome in outcomes]
        held = sum(outcome == "held" for outcome in outcomes)
        emitted = sum(outcome == "regressed" for outcome in outcomes)
        rows.append(
            {
                "feedback_id": fid,
                "label": label,
                "replayed_runs": sum(replayed),
                "outcomes": outcomes,
                "held_runs": held,
                "emitted_runs": emitted,
                "stable_held": label == "must_keep_flagging" and held == len(runs),
                "stable_emitted": label == "must_not_flag" and emitted == len(runs),
            }
        )

    count = len(runs)
    stable = {
        "run_count": count,
        "must_keep_held_mean": round(sum(row["held_runs"] for row in rows) / count, 3),
        "must_keep_held_stable": sum(row["stable_held"] for row in rows),
        "must_not_flag_emitted_mean": round(sum(row["emitted_runs"] for row in rows) / count, 3),
        "must_not_flag_emitted_stable": sum(row["stable_emitted"] for row in rows),
        "uncovered_rows": sum(row["replayed_runs"] != count for row in rows),
    }
    result = {"headline": stable, "rows": rows}
    encoded = json.dumps(result, indent=1)
    if output is None:
        print(encoded)
    else:
        open(output, "w").write(encoded + "\n")
        print(json.dumps(stable, indent=1))


if __name__ == "__main__":
    main()
