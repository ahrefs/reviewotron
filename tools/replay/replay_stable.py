#!/usr/bin/env python3
"""Aggregate repeated replay_baseline.json files into stable-core metrics."""
import json
import hashlib
import os
import sys

import _config as C


def load_baseline(path):
    """Read one baseline once, returning (content digest, label, rows by id)."""
    raw = open(path, "rb").read()
    try:
        baseline = json.loads(raw)
    except json.JSONDecodeError as error:
        sys.exit("invalid baseline %s: %s" % (path, error))
    label = baseline.get("label")
    if not isinstance(label, str) or label == "":
        sys.exit("baseline has no label: %s" % path)
    rows = C.unique_by(baseline["rows"], "feedback_id", path)
    return hashlib.sha256(raw).digest(), label, rows


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
    if len(paths) < 3:
        sys.exit("usage: replay_stable.py baseline.json baseline.json baseline.json [baseline.json ...] [--output path]")
    return paths, output


def main():
    paths, output = parse_args()
    resolved_paths = [os.path.realpath(path) for path in paths]
    if len(set(resolved_paths)) != len(resolved_paths):
        sys.exit("duplicate baseline input")
    loaded = [load_baseline(path) for path in paths]
    digests = [digest for digest, _, _ in loaded]
    if len(set(digests)) != len(digests):
        sys.exit("duplicate baseline content")
    if len({label for _, label, _ in loaded}) != 1:
        sys.exit("baseline files have inconsistent labels")
    runs = [rows for _, _, rows in loaded]
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
            }
        )

    count = len(runs)
    # Each metric is scoped to the label it is named for.
    keep = [row for row in rows if row["label"] == "must_keep_flagging"]
    drop = [row for row in rows if row["label"] == "must_not_flag"]
    stable = {
        "run_count": count,
        "must_keep_held_mean": round(sum(row["held_runs"] for row in keep) / count, 3),
        "must_keep_held_stable": sum(row["held_runs"] == count for row in keep),
        "must_not_flag_emitted_mean": round(sum(row["emitted_runs"] for row in drop) / count, 3),
        "must_not_flag_emitted_stable": sum(row["emitted_runs"] == count for row in drop),
        "not_replayed_every_run": sum(row["replayed_runs"] != count for row in rows),
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
