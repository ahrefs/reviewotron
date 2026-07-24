#!/usr/bin/env python3
"""Shared configuration for the replay harness.

Every path the harness touches is resolved here from environment variables or
CLI flags, so nothing is hard-coded to a particular machine. Import this from
the driver / matcher / aggregator scripts.

Environment variables (all optional; CLI flags on each script override):

  REVIEWOTRON_EXE   Path to the built reviewotron binary.
                    Default: <repo>/_build/default/src/reviewotron.exe
  TARGET_REPO_ROOT  Path to a checkout of the repository the reviewed diffs
                    came from. Used to create the worktree pool and to resolve
                    blob SHAs. Default: ~/target-repo  (override for your setup)
  ANALYSIS_DIR      Directory holding the run inputs that are NOT vendored:
                    the snapshot/ evidence bundles, replay_batches.json,
                    worklist.json, items/, missing_shas.txt. This is the
                    feedback-analysis working directory; see README.
                    Default: $PWD
  OUTPUT_DIR        Directory the harness writes into (replay_runs/, match_*,
                    replay_baseline.json, worktree pool). Kept separate from
                    ANALYSIS_DIR so a read-only archive can drive fresh runs.
                    Default: ANALYSIS_DIR
  OPENROUTER_API_KEY / ANTHROPIC_API_KEY
                    Provider credential passed to the engine. The engine picks
                    the provider from whichever is set (see project memory:
                    ANTHROPIC_API_KEY + no OPENROUTER_API_KEY -> Anthropic).

The label set eval.jsonl is NOT shipped in this repo — it is private to the
operator (see README). Drop your own at tools/replay/eval.jsonl (gitignored) or
point EVAL_JSONL at it.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
# tools/replay/ -> repo root is two levels up
REPO_ROOT = os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))

# Operator-supplied labels (not shipped): default next to this file, or override.
EVAL_JSONL = os.environ.get("EVAL_JSONL", os.path.join(HERE, "eval.jsonl"))


def reviewotron_exe():
    return os.environ.get(
        "REVIEWOTRON_EXE",
        os.path.join(REPO_ROOT, "_build", "default", "src", "reviewotron.exe"),
    )


def target_repo_root():
    return os.environ.get("TARGET_REPO_ROOT", os.path.expanduser("~/target-repo"))


def analysis_dir():
    return os.path.abspath(os.environ.get("ANALYSIS_DIR", os.getcwd()))


def output_dir():
    return os.path.abspath(os.environ.get("OUTPUT_DIR", analysis_dir()))


def evidence_dir(adir=None):
    """Where the per-batch snapshot bundles live (filtered_diff.patch etc.)."""
    return os.path.join(adir or analysis_dir(), "snapshot",
                        "reviewotron-feedback-evidence")


def runs_dir(odir=None):
    return os.path.join(odir or output_dir(), "replay_runs")


def worktree_dir(odir=None):
    return os.path.join(odir or output_dir(), "replay_worktrees")


def in_analysis(name, adir=None):
    return os.path.join(adir or analysis_dir(), name)


def in_output(name, odir=None):
    return os.path.join(odir or output_dir(), name)


def local_context_fix_present(repo=REPO_ROOT):
    """True when the engine tree already embeds local-mode key-file contents
    (branch fix/local-source-key-files / PR #23 and later), so
    replay_fidelity_shim.patch is NOT needed.

    Detection is by the fix's observable shape:
      - fixed tree: local_source.ml populates file_contents via
        Review_job.select_key_files and no longer hard-codes `file_contents = []`;
      - unfixed tree: local_source.ml still has `file_contents = []` and the
        shared selector does not exist.
    Falls back to "not present" (shim needed) if the source can't be read —
    the safe default: a spurious shim on a fixed tree only double-selects the
    same files, whereas skipping it on an unfixed tree makes the deep reviewer
    run blind.
    """
    ls = os.path.join(repo, "lib", "local_source.ml")
    rj = os.path.join(repo, "lib", "review_job.ml")
    try:
        ls_src = open(ls).read()
        rj_src = open(rj).read()
    except OSError:
        return False
    shared_selector = "select_key_files" in rj_src
    local_uses_it = "Review_job.select_key_files" in ls_src
    still_blind = "file_contents = []" in ls_src
    return shared_selector and local_uses_it and not still_blind


def provider_key():
    """Return (env_var_name, value) for whichever provider key is set, or None.

    Prefers ANTHROPIC_API_KEY when both are set is NOT done here — the caller
    passes the whole environment to the engine, which resolves the provider.
    This helper only checks that at least one credential is present.
    """
    for name in ("OPENROUTER_API_KEY", "ANTHROPIC_API_KEY"):
        v = os.environ.get(name)
        if v:
            return (name, v)
    return None
