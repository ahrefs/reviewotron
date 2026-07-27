#!/usr/bin/env python3
"""Replay scoping: group eval rows by diff and classify coverage.

Reports how many eval rows are replayable (general-plugin, resolvable head_sha)
and flags any batch config that carries a
system_prompt_override (which would make prompt-hash reproduction impossible).

Reads eval.jsonl (operator-supplied) plus per-batch review_config.json from the
snapshot bundles in ANALYSIS_DIR, and missing_shas.txt from ANALYSIS_DIR (a
list of head SHAs known to be unresolvable; may be empty — direct-SHA HTTPS
fetch usually recovers force-pushed-away heads). Writes
OUTPUT_DIR/replay_scope.json.
"""
import json
import os
import collections

import _config as C


def main():
    rows = [json.loads(l) for l in open(C.EVAL_JSONL)]
    missing_path = C.in_analysis("missing_shas.txt")
    missing_shas = set()
    if os.path.exists(missing_path):
        missing_shas = {l.strip() for l in open(missing_path) if l.strip()}
    evidence = C.evidence_dir()

    by_batch = collections.defaultdict(list)
    for r in rows:
        by_batch[r["review_batch_id"]].append(r)

    summary = {
        "total_rows": len(rows),
        "must_not_flag": sum(1 for r in rows if r["label"] == "must_not_flag"),
        "must_keep_flagging": sum(1 for r in rows if r["label"] == "must_keep_flagging"),
        "distinct_batches": len(by_batch),
        "body_rows": sum(1 for r in rows if r["finding_ref"] == "pr_review_body"),
        "security_rows": sum(1 for r in rows if not C.is_general_row(r)),
    }

    def find_override(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if "override" in k and v:
                    return {k: v}
                f = find_override(v)
                if f:
                    return f
        elif isinstance(o, list):
            for v in o:
                f = find_override(v)
                if f:
                    return f
        return None

    batches = []
    for bid, brows in sorted(by_batch.items()):
        head_sha = brows[0]["head_sha"]
        diff_path = os.path.join(evidence, bid, "filtered_diff.patch")
        cfg_path = os.path.join(evidence, bid, "review_config.json")
        override = None
        if os.path.exists(cfg_path):
            override = find_override(json.load(open(cfg_path)))
        sha_missing = head_sha in missing_shas
        general_rows = [r for r in brows if C.is_general_row(r)]
        batches.append({
            "review_batch_id": bid,
            "head_sha": head_sha,
            "diff_exists": os.path.exists(diff_path),
            "diff_lines": sum(1 for _ in open(diff_path, errors="replace"))
            if os.path.exists(diff_path) else None,
            "config_exists": os.path.exists(cfg_path),
            "prompt_override": override,
            "sha_in_missing_list": sha_missing,
            "n_rows": len(brows),
            "n_body_rows": sum(1 for r in brows if r["finding_ref"] == "pr_review_body"),
            "n_security_rows": len(brows) - len(general_rows),
            "n_replayable_rows": len(general_rows) if not sha_missing else 0,
            "runnable": (not sha_missing) and os.path.exists(diff_path)
            and len(general_rows) > 0,
        })

    summary["runnable_batches"] = sum(1 for b in batches if b["runnable"])
    summary["rows_on_missing_sha"] = sum(
        b["n_rows"] for b in batches if b["sha_in_missing_list"])
    summary["replayable_rows"] = sum(
        b["n_replayable_rows"] for b in batches if b["runnable"])
    summary["batches_with_override"] = sum(1 for b in batches if b["prompt_override"])

    out = {"summary": summary, "batches": batches}
    json.dump(out, open(C.in_output("replay_scope.json"), "w"), indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
