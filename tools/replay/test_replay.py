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
        env = os.environ.copy()
        env.update(
            {
                "ANALYSIS_DIR": str(self.analysis),
                "OUTPUT_DIR": str(self.output),
                "EVAL_JSONL": str(self.root / "eval.jsonl"),
            }
        )
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

        write_json(self.output / "match_candidates.json", [])
        write_json(self.output / "match_results.json", [])
        write_json(self.output / "match_auto.json", [{"feedback_id": candidate["feedback_id"], "outcome": None}])
        invalid_auto = self.run_script("replay_aggregate.py")
        self.assertNotEqual(invalid_auto.returncode, 0)
        self.assertIn("non-string outcome", invalid_auto.stderr)

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

        (self.analysis / "items" / feedback_id / "finding.json").unlink()
        unknown = self.run_script("replay_scope.py")
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("unknown plugin", unknown.stderr)

        self.write_eval(
            [
                {
                    "feedback_id": feedback_id,
                    "review_batch_id": batch_id,
                    "head_sha": "head",
                    "label": "must_not_flag",
                    "finding_ref": "pr_review_comment",
                    "plugin_name": "general",
                }
            ]
        )
        write_json(self.analysis / "items" / feedback_id / "finding.json", {"plugin_name": "security"})
        mismatch = self.run_script("replay_scope.py")
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("plugin mismatch", mismatch.stderr)

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
                    "plugin_name": "general",
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

        write_json(
            self.analysis / "snapshot" / "reviewotron-feedback-evidence" / batch_id / "posted_review.json",
            {"body": ""},
        )
        empty_body = self.run_script("match_prepare.py")
        self.assertEqual(empty_body.returncode, 0, empty_body.stderr)
        auto = json.loads((self.output / "match_auto.json").read_text())
        self.assertEqual(auto[0]["outcome"], "missing_original")

        (self.output / "replay_runs" / batch_id / "output.json").write_text("{")
        corrupt_output = self.run_script("match_prepare.py")
        self.assertNotEqual(corrupt_output.returncode, 0)
        self.assertIn("invalid replay output", corrupt_output.stderr)

    def test_prepare_reports_missing_inline_original(self):
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
                    "plugin_name": "general",
                }
            ]
        )
        write_json(self.analysis / "replay_batches.json", {batch_id: [feedback_id]})
        write_json(self.output / "replay_runs" / batch_id / "meta.json", {"exit": 0})
        write_json(self.output / "replay_runs" / batch_id / "output.json", {"summary": "", "findings": []})

        result = self.run_script("match_prepare.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot load original finding", result.stderr)

    def test_stable_aggregation_reports_repeatability(self):
        first = self.root / "first.json"
        second = self.root / "second.json"
        third = self.root / "third.json"
        rows = [
            {"feedback_id": "keep", "label": "must_keep_flagging", "outcome": "held"},
            {"feedback_id": "drop", "label": "must_not_flag", "outcome": "regressed"},
        ]
        write_json(first, {"label": "baseline", "run": 1, "rows": rows})
        write_json(
            second,
            {
                "label": "baseline",
                "run": 2,
                "rows": [
                    {"feedback_id": "keep", "label": "must_keep_flagging", "outcome": "lost"},
                    {"feedback_id": "drop", "label": "must_not_flag", "outcome": "regressed"},
                ]
            },
        )
        write_json(third, {"label": "baseline", "run": 3, "rows": rows})
        output = self.root / "stable.json"
        result = self.run_script("replay_stable.py", str(first), str(second), str(third), "--output", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        stable = json.loads(output.read_text())
        self.assertEqual(stable["headline"]["must_keep_held_stable"], 0)
        self.assertEqual(stable["headline"]["must_not_flag_emitted_stable"], 1)

        too_few = self.run_script("replay_stable.py", str(first), str(second))
        self.assertNotEqual(too_few.returncode, 0)

        duplicate_path = self.run_script("replay_stable.py", str(first), str(second), str(first))
        self.assertNotEqual(duplicate_path.returncode, 0)
        self.assertIn("duplicate baseline input", duplicate_path.stderr)

        copy = self.root / "copy.json"
        copy.write_text(first.read_text())
        duplicate_content = self.run_script("replay_stable.py", str(first), str(second), str(copy))
        self.assertNotEqual(duplicate_content.returncode, 0)
        self.assertIn("duplicate baseline content", duplicate_content.stderr)

        mismatched = self.root / "mismatched.json"
        write_json(mismatched, {"label": "candidate", "run": 4, "rows": rows})
        mismatched_label = self.run_script("replay_stable.py", str(first), str(second), str(mismatched))
        self.assertNotEqual(mismatched_label.returncode, 0)
        self.assertIn("inconsistent labels", mismatched_label.stderr)


if __name__ == "__main__":
    unittest.main()
