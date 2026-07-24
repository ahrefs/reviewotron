#!/usr/bin/env python3
"""Replay driver: run the current engine (`review-diff`, general pipeline only)
once per eval batch against a target-repo worktree pinned to the batch's head_sha.

Design:
- worktree pool (wt0..wtN under OUTPUT_DIR/replay_worktrees/), one worker each
- inline --config pinned so every batch replays under identical config
- security plugin disabled via --no-security
- outputs per batch under OUTPUT_DIR/replay_runs/<bid>/:
  output.json, stderr.log, meta.json
- resumable: batches with a good meta.json are skipped

Paths and credentials come from _config.py (env-driven). Run:

  ANALYSIS_DIR=~/feedback-analysis OUTPUT_DIR=~/feedback-analysis \
  TARGET_REPO_ROOT=/path/to/target-repo OPENROUTER_API_KEY=... \
  python3 tools/replay/replay_driver.py --concurrency 6

Create the worktree pool first (one detached checkout per worker):
  for i in $(seq 0 5); do
    git -C "$TARGET_REPO_ROOT" worktree add --detach "$OUTPUT_DIR/replay_worktrees/wt$i"
  done
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

import _config as C

RUN_TIMEOUT = int(os.environ.get("REPLAY_RUN_TIMEOUT", "2400"))  # sec/run

# Config pinned inline so every batch replays identically regardless of the
# per-SHA checked-in .reviewotron.json. The security section is irrelevant here
# (--no-security wins) but kept so the config parses. Override the whole object
# by pointing REPLAY_INLINE_CONFIG at a JSON file.
DEFAULT_INLINE_CONFIG = {
    "show_review_cost": True,
    "auto_review_on_comment": True,
    "review_draft_prs": False,
    "auto_review_pr_open": True,
    "max_diff_lines": 5000,
    "max_files": 100,
    "ignored_file_regexes": ["\\.ratchet$"],
    "review_plugins": {"security": {"enabled": True}},
}


def inline_config():
    p = os.environ.get("REPLAY_INLINE_CONFIG")
    if p:
        return open(p).read()
    return json.dumps(DEFAULT_INLINE_CONFIG)


def batch_meta():
    """One entry per replayable diff: {bid, head_sha, diff, pr}.

    Reads eval.jsonl (operator-supplied) for labels/SHAs, replay_batches.json (which
    feedback_ids are covered per batch) and worklist.json (pr_number) from the
    ANALYSIS_DIR. The diff path is derived from ANALYSIS_DIR, never from the
    row's diff_ref (which is only a provenance breadcrumb).
    """
    rows = [json.loads(l) for l in open(C.EVAL_JSONL)]
    batches = json.load(open(C.in_analysis("replay_batches.json")))
    wl = json.load(open(C.in_analysis("worklist.json")))
    items = wl if isinstance(wl, list) else wl.get("items") or list(wl.values())
    if isinstance(items, dict):
        items = list(items.values())
    pr_by_batch = {}
    for i in items:
        if isinstance(i, dict) and i.get("review_batch_id"):
            pr_by_batch[i["review_batch_id"]] = i.get("pr_number")
    evidence = C.evidence_dir()
    out = []
    seen = set()
    for r in rows:
        bid = r["review_batch_id"]
        if bid in batches and bid not in seen:
            seen.add(bid)
            out.append({
                "bid": bid,
                "head_sha": r["head_sha"],
                "diff": os.path.join(evidence, bid, "filtered_diff.patch"),
                "pr": pr_by_batch.get(bid),
            })
    return out


def already_done(bid):
    meta_path = os.path.join(C.runs_dir(), bid, "meta.json")
    out_path = os.path.join(C.runs_dir(), bid, "output.json")
    if not (os.path.exists(meta_path) and os.path.exists(out_path)):
        return False
    try:
        meta = json.load(open(meta_path))
        json.load(open(out_path))
        return meta.get("exit") == 0
    except Exception:
        return False


def run_one(wt, b, base_env):
    bid = b["bid"]
    d = os.path.join(C.runs_dir(), bid)
    os.makedirs(d, exist_ok=True)
    t0 = time.time()
    co = subprocess.run(
        ["git", "-C", wt, "checkout", "-q", "--detach", b["head_sha"]],
        capture_output=True, text=True, timeout=1800,
    )
    if co.returncode != 0:
        meta = {"exit": -100, "error": "checkout failed: " + co.stderr[-500:],
                "duration_s": round(time.time() - t0, 1)}
        json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=1)
        return meta
    title = "PR #%s" % b["pr"] if b["pr"] else "replay " + bid[:16]
    cmd = [
        C.reviewotron_exe(), "review-diff",
        "--diff", b["diff"],
        "--root", wt,
        "--no-security",
        "--config", inline_config(),
        "--title", title,
        "--output", "json",
        "--loglevel", "info",
    ]
    with open(os.path.join(d, "output.json"), "w") as so, \
         open(os.path.join(d, "stderr.log"), "w") as se:
        try:
            p = subprocess.run(cmd, stdout=so, stderr=se, env=base_env,
                               timeout=RUN_TIMEOUT, cwd=d)
            exit_code = p.returncode
            err = None
        except subprocess.TimeoutExpired:
            exit_code = -101
            err = "timeout after %ds" % RUN_TIMEOUT
    n_findings = None
    try:
        out = json.load(open(os.path.join(d, "output.json")))
        n_findings = len(out.get("findings", []))
    except Exception as e:
        err = (err or "") + " stdout not json: %s" % e
    meta = {
        "exit": exit_code,
        "error": err,
        "duration_s": round(time.time() - t0, 1),
        "n_findings": n_findings,
        "head_sha": b["head_sha"],
        "worktree": os.path.basename(wt),
    }
    json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=1)
    return meta


def main():
    only = None
    conc = 6
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--only":
            only = args.pop(0)
        elif a == "--concurrency":
            conc = int(args.pop(0))
        else:
            sys.exit("unknown arg: %s" % a)

    if C.provider_key() is None:
        sys.exit("no provider key: set OPENROUTER_API_KEY or ANTHROPIC_API_KEY")
    base_env = dict(os.environ)  # engine resolves provider from the env

    os.makedirs(C.runs_dir(), exist_ok=True)
    if C.local_context_fix_present():
        print("SHIM: local-context fix detected in engine tree — "
              "replay_fidelity_shim.patch NOT needed (skip it).", flush=True)
    else:
        print("SHIM: local-context fix NOT present — apply "
              "replay_fidelity_shim.patch before this run or the deep reviewer "
              "runs blind.", flush=True)

    wt_dir = C.worktree_dir()
    if not os.path.isdir(wt_dir):
        sys.exit("worktree pool not found at %s — create it first (see the "
                 "module docstring)." % wt_dir)

    batches = batch_meta()
    if only:
        batches = [b for b in batches if b["bid"] == only]
    todo = [b for b in batches if not already_done(b["bid"])]
    print("total=%d todo=%d conc=%d" % (len(batches), len(todo), conc), flush=True)

    q = queue.Queue()
    for b in todo:
        q.put(b)
    done_lock = threading.Lock()
    done = [0]

    def worker(wt):
        while True:
            try:
                b = q.get_nowait()
            except queue.Empty:
                return
            try:
                meta = run_one(wt, b, base_env)
            except Exception as e:
                meta = {"exit": -102, "error": str(e)[:300]}
                d = os.path.join(C.runs_dir(), b["bid"])
                os.makedirs(d, exist_ok=True)
                json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=1)
            with done_lock:
                done[0] += 1
                n = done[0]
            print("PROGRESS %d/%d %s exit=%s findings=%s dur=%ss" % (
                n, len(todo), b["bid"][:20], meta.get("exit"),
                meta.get("n_findings"), meta.get("duration_s")), flush=True)

    wts = sorted(
        os.path.join(wt_dir, x) for x in os.listdir(wt_dir) if x.startswith("wt")
    )[:conc]
    if not wts:
        sys.exit("no wt* worktrees under %s" % wt_dir)
    threads = [threading.Thread(target=worker, args=(wt,)) for wt in wts]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    bad = []
    for b in batches:
        mp = os.path.join(C.runs_dir(), b["bid"], "meta.json")
        try:
            m = json.load(open(mp))
            if m.get("exit") != 0:
                bad.append((b["bid"], m.get("exit"), (m.get("error") or "")[:120]))
        except Exception:
            bad.append((b["bid"], None, "no meta"))
    print("DONE ok=%d bad=%d" % (len(batches) - len(bad), len(bad)), flush=True)
    for x in bad:
        print("BAD %s exit=%s %s" % x, flush=True)


if __name__ == "__main__":
    main()
