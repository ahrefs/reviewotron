#!/usr/bin/env python3
"""Focused checks for replay-harness coverage and scoring invariants."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).parent


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class ReplayHarnessTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.analysis = self.root / "analysis"
        self.output = self.root / "output"
        self.analysis.mkdir()
        self.output.mkdir()

    def tearDown(self):
        self.tempdir.cleanup()

    def run_script(self, script, *args):
        env = os.environ | {
            "ANALYSIS_DIR": str(self.analysis),
            "OUTPUT_DIR": str(self.output),
            "EVAL_JSONL": str(self.root / "eval.jsonl"),
        }
        return subprocess.run(
            [sys.executable, str(HERE / script), *args],
            capture_output=True,
            text=True,
            env=env,
        )

    def write_eval(self, rows):
        (self.root / "eval.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))

    def write_inline_case(self):
        feedback_id = "feedback-inline"
        batch_id = "batch-inline"
        self.write_eval(
            [
                {
                    "feedback_id": feedback_id,
                    "review_batch_id": batch_id,
                    "head_sha": "head",
                    "label": "must_keep_flagging",
                    "finding_ref": "pr_review_comment",
                }
            ]
        )
        write_json(self.analysis / "replay_batches.json", {batch_id: [feedback_id]})
        write_json(
            self.analysis / "items" / feedback_id / "finding.json",
            {"plugin_name": "general", "finding": {"path": "src/main.ml", "line": 12, "message": "issue"}},
        )
        candidate = {"pair_id": feedback_id + "#0", "feedback_id": feedback_id}
        write_json(self.output / "match_auto.json", [])
        write_json(self.output / "match_candidates.json", [candidate])
        return candidate

    def test_aggregate_requires_exact_match_results_and_maps_pair_ids(self):
        candidate = self.write_inline_case()
        write_json(self.output / "match_results.json", [])
        incomplete = self.run_script("replay_aggregate.py")
        self.assertNotEqual(incomplete.returncode, 0)
        self.assertIn("missing", incomplete.stderr)

        write_json(
            self.output / "match_results.json",
            [{"pair_id": candidate["pair_id"], "match": True, "reason": "same issue"}],
        )
        complete = self.run_script("replay_aggregate.py")
        self.assertEqual(complete.returncode, 0, complete.stderr)
        baseline = json.loads((self.output / "replay_baseline.json").read_text())
        self.assertEqual(baseline["rows"][0]["outcome"], "held")

    def test_scope_excludes_security_rows_from_general_replay(self):
        feedback_id = "feedback-security"
        batch_id = "batch-security"
        self.write_eval(
            [
                {
                    "feedback_id": feedback_id,
                    "review_batch_id": batch_id,
                    "head_sha": "head",
                    "label": "must_not_flag",
                    "finding_ref": "pr_review_comment",
                }
            ]
        )
        write_json(self.analysis / "items" / feedback_id / "finding.json", {"plugin_name": "security"})
        diff = self.analysis / "snapshot" / "reviewotron-feedback-evidence" / batch_id / "filtered_diff.patch"
        diff.parent.mkdir(parents=True)
        diff.write_text("diff --git a/a b/a\n")

        result = self.run_script("replay_scope.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        scope = json.loads((self.output / "replay_scope.json").read_text())
        self.assertEqual(scope["summary"]["security_rows"], 1)
        self.assertEqual(scope["summary"]["replayable_rows"], 0)

    def test_prepare_matches_review_bodies_against_replay_summary(self):
        feedback_id = "feedback-body"
        batch_id = "batch-body"
        self.write_eval(
            [
                {
                    "feedback_id": feedback_id,
                    "review_batch_id": batch_id,
                    "head_sha": "head",
                    "label": "must_keep_flagging",
                    "finding_ref": "pr_review_body",
                }
            ]
        )
        write_json(self.analysis / "replay_batches.json", {batch_id: [feedback_id]})
        write_json(
            self.analysis / "snapshot" / "reviewotron-feedback-evidence" / batch_id / "posted_review.json",
            {"body": "The error path drops the response."},
        )
        write_json(self.output / "replay_runs" / batch_id / "meta.json", {"exit": 0})
        write_json(
            self.output / "replay_runs" / batch_id / "output.json",
            {"summary": "The error path drops the response.", "findings": []},
        )

        result = self.run_script("match_prepare.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        candidates = json.loads((self.output / "match_candidates.json").read_text())
        self.assertEqual(candidates[0]["kind"], "review_body")
        self.assertEqual(candidates[0]["replay"]["body"], "The error path drops the response.")

    def test_stable_aggregation_reports_repeatability(self):
        first = self.root / "first.json"
        second = self.root / "second.json"
        rows = [
            {"feedback_id": "keep", "label": "must_keep_flagging", "outcome": "held"},
            {"feedback_id": "drop", "label": "must_not_flag", "outcome": "regressed"},
        ]
        write_json(first, {"rows": rows})
        write_json(
            second,
            {
                "rows": [
                    {"feedback_id": "keep", "label": "must_keep_flagging", "outcome": "lost"},
                    {"feedback_id": "drop", "label": "must_not_flag", "outcome": "regressed"},
                ]
            },
        )
        output = self.root / "stable.json"
        result = self.run_script("replay_stable.py", str(first), str(second), "--output", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        stable = json.loads(output.read_text())
        self.assertEqual(stable["headline"]["must_keep_held_stable"], 0)
        self.assertEqual(stable["headline"]["must_not_flag_emitted_stable"], 1)


if __name__ == "__main__":
    unittest.main()
