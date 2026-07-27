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
import functools
import json
import os
import sys

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


def finding_bundle_path(feedback_id, adir=None):
    """Path to a feedback item's original-finding bundle."""
    return in_analysis(os.path.join("items", feedback_id, "finding.json"), adir)


def posted_review_path(batch_id, adir=None):
    """Path to a batch's posted review (carries the review body)."""
    return os.path.join(evidence_dir(adir), batch_id, "posted_review.json")


@functools.lru_cache(maxsize=None)
def finding_plugin_name(feedback_id, adir=None):
    """Return a finding's plugin when the private analysis bundle has it.

    Memoized: several scripts resolve the same feedback_id repeatedly, and the
    analysis dir does not change within a run.
    """
    path = finding_bundle_path(feedback_id, adir)
    if not os.path.exists(path):
        return None
    return json.load(open(path)).get("plugin_name")


def plugin_name(row, adir=None):
    """Resolve a row's plugin, preferring the source finding when available."""
    row_plugin = row.get("plugin_name")
    bundle_plugin = finding_plugin_name(row["feedback_id"], adir)
    if row_plugin and bundle_plugin and row_plugin != bundle_plugin:
        raise SystemExit(
            "plugin mismatch for %s: eval row=%s finding bundle=%s"
            % (row["feedback_id"], row_plugin, bundle_plugin)
        )
    plugin = bundle_plugin or row_plugin
    if not plugin:
        raise SystemExit("unknown plugin for %s; add plugin_name to the eval row" % row["feedback_id"])
    return plugin


def is_general_row(row, adir=None):
    """Whether the general-only replay can score this evaluation row."""
    return plugin_name(row, adir) == "general"


BODY_FINDING_REF = "pr_review_body"
INLINE_FINDING_REFS = ("pr_review_comment",)


def is_body_row(row):
    """Whether the row is a review-body finding rather than an inline one.

    Fails closed on an unrecognized finding_ref: body vs inline is a dispatch
    key now that both are replayed, so a new feedback kind must not silently
    take the inline path.
    """
    ref = row["finding_ref"]
    if ref == BODY_FINDING_REF:
        return True
    if ref in INLINE_FINDING_REFS:
        return False
    raise SystemExit(
        "unrecognized finding_ref for %s: %s" % (row["feedback_id"], ref)
    )


def is_replayable_row(row, batches, adir=None):
    """Whether this row is in a replayed batch and scoreable by the replay.

    Shared by the driver, the matcher and the aggregator so their notions of
    "replayable" cannot drift.
    """
    bid = row["review_batch_id"]
    return (
        bid in batches
        and row["feedback_id"] in batches[bid]
        and is_general_row(row, adir)
    )


def replayable_rows(rows, batches, adir=None):
    """The replayable rows keyed by feedback_id."""
    return {
        row["feedback_id"]: row
        for row in rows
        if is_replayable_row(row, batches, adir)
    }


def unique_by(rows, key, label):
    """Index rows by a non-empty string key, rejecting missing/duplicate keys."""
    result = {}
    for row in rows:
        value = row.get(key)
        if not isinstance(value, str) or value == "":
            sys.exit("%s missing %s" % (label, key))
        if value in result:
            sys.exit("duplicate %s in %s: %s" % (key, label, value))
        result[value] = row
    return result


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
