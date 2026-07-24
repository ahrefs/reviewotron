#!/usr/bin/env python3
"""Offline fidelity check for the local-mode file-context shim, per batch:

1. Parse filtered_diff.patch; select the first 5 added/modified file paths
   (mirrors Github_source.fetch_key_files / the local shim).
2. Compare that path list against the bundle's fetched_files.json (what
   production actually embedded).
3. For each fetched file, sha256(git show head_sha:path) must equal the
   bundle's recorded sha256 (content at head_sha == what production embedded).

Mismatches in (2) can be legitimate (production dropped binary/oversized or
fetch-failed files), so they are reported rather than fail hard. Use this to
confirm that a local replay (shimmed, or post-PR-#23) sees the same key files
production did before trusting the scores.

Reads snapshot bundles from ANALYSIS_DIR, resolves blobs in TARGET_REPO_ROOT,
writes OUTPUT_DIR/shim_fidelity_report.json.
"""
import hashlib
import json
import os
import subprocess

import _config as C


def diff_key_paths(patch_path):
    """First 5 added/modified paths in diff order (b-side path)."""
    paths = []
    cur = None
    status = None
    for line in open(patch_path, errors="replace"):
        if line.startswith("diff --git "):
            if cur and status in ("A", "M"):
                paths.append(cur)
            parts = line.rstrip("\n").split(" b/")
            cur = parts[-1] if len(parts) > 1 else None
            status = "M"  # default until proven otherwise
        elif line.startswith("new file mode"):
            status = "A"
        elif line.startswith("deleted file mode"):
            status = "D"
        elif line.startswith("rename from"):
            status = "R"
    if cur and status in ("A", "M"):
        paths.append(cur)
    return paths[:5]


def git_blob_sha256(target_repo, sha, path):
    r = subprocess.run(
        ["git", "-C", target_repo, "show", "%s:%s" % (sha, path)],
        capture_output=True,
    )
    if r.returncode != 0:
        return None
    return hashlib.sha256(r.stdout).hexdigest()


def main():
    target_repo = C.target_repo_root()
    evidence = C.evidence_dir()
    rows = [json.loads(l) for l in open(C.EVAL_JSONL)]
    batches = json.load(open(C.in_analysis("replay_batches.json")))
    sha_by_batch = {r["review_batch_id"]: r["head_sha"] for r in rows}
    ok = paths_diverge = content_mismatch = 0
    reports = []
    for bid in sorted(batches):
        sha = sha_by_batch[bid]
        patch = os.path.join(evidence, bid, "filtered_diff.patch")
        ff = json.load(open(os.path.join(evidence, bid, "fetched_files.json")))
        recorded = [(f["path"], f["sha256"]) for f in ff["files"]]
        expected = diff_key_paths(patch)
        rec_paths = [p for p, _ in recorded]
        prob = []
        if expected != rec_paths:
            # allow production drops: recorded must be a subsequence of expected
            it = iter(expected)
            subseq = all(any(p == e for e in it) for p in rec_paths)
            prob.append("paths diverge (subseq=%s): expected=%s recorded=%s"
                        % (subseq, expected, rec_paths))
        for p, want in recorded:
            got = git_blob_sha256(target_repo, sha, p)
            if got != want:
                prob.append("content mismatch %s (blob %s)"
                            % (p, "missing" if got is None else "differs"))
        if not prob:
            ok += 1
        else:
            if any("paths diverge" in x for x in prob):
                paths_diverge += 1
            if any("content mismatch" in x for x in prob):
                content_mismatch += 1
            reports.append({"batch": bid, "problems": prob})
    print("batches ok=%d paths_diverge=%d content_mismatch=%d of %d"
          % (ok, paths_diverge, content_mismatch, len(batches)))
    json.dump(reports, open(C.in_output("shim_fidelity_report.json"), "w"), indent=1)
    for r in reports[:8]:
        print(r["batch"][:24], r["problems"][:2])


if __name__ == "__main__":
    main()
