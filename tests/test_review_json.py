from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts" / "review-json.py"
SPEC = importlib.util.spec_from_file_location("review_json", SCRIPT)
review_json = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(review_json)


class ReviewJsonTests(unittest.TestCase):
    def test_priority_accepts_new_schema_and_legacy_severity(self) -> None:
        self.assertEqual(review_json.finding_priority({"priority": "P0"}), "P0")
        self.assertEqual(review_json.finding_priority({"priority": "p1"}), "P1")
        self.assertEqual(review_json.finding_priority({"severity": "low"}), "P2")
        self.assertEqual(review_json.finding_priority({"priority": "invalid"}), "P2")

    def test_filter_adds_visible_priority_badge(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_path = root / "review.json"
            changed_files_path = root / "changed-files.txt"
            changed_lines_path = root / "changed-lines.json"
            output_path = root / "filtered.json"

            input_path.write_text(json.dumps({
                "findings": [{
                    "path": "src/example.py",
                    "line": 7,
                    "priority": "P1",
                    "title": "Handle the failure",
                    "body": "This error path returns a successful result.",
                }],
            }), encoding="utf-8")
            changed_files_path.write_text("src/example.py\n", encoding="utf-8")
            changed_lines_path.write_text(
                json.dumps({"src/example.py": [7]}),
                encoding="utf-8",
            )

            result = review_json.filter_command(argparse.Namespace(
                input=str(input_path),
                changed_files=str(changed_files_path),
                changed_lines=str(changed_lines_path),
                output=str(output_path),
            ))

            self.assertEqual(result, 0)
            filtered = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(
                filtered["findings"][0]["body"],
                "**[P1] Handle the failure**\n\n"
                "This error path returns a successful result.",
            )

    def test_clean_review_uses_reaction_only(self) -> None:
        review = {"outcome": "clean", "findings": []}
        self.assertEqual(review_json.delivery_action(review, "auto"), "reaction")
        self.assertEqual(review_json.delivery_action(review, "mention"), "reaction")

    def test_findings_and_written_responses_still_use_comments(self) -> None:
        finding = {"outcome": "clean", "findings": [{"body": "problem"}]}
        summary_finding = {"outcome": "findings", "findings": []}
        answer = {"outcome": "response", "findings": []}

        self.assertEqual(review_json.delivery_action(finding, "auto"), "comment")
        self.assertEqual(review_json.delivery_action(summary_finding, "auto"), "comment")
        self.assertEqual(review_json.delivery_action(answer, "mention"), "comment")

    def test_legacy_mention_without_findings_keeps_its_written_response(self) -> None:
        self.assertEqual(
            review_json.delivery_action({"findings": []}, "mention"),
            "comment",
        )


if __name__ == "__main__":
    unittest.main()
