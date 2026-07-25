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

    def test_filter_bounds_and_prioritizes_large_finding_sets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_path = root / "review.json"
            changed_files_path = root / "changed-files.txt"
            changed_lines_path = root / "changed-lines.json"
            output_path = root / "filtered.json"
            findings = [
                {
                    "path": "src/example.py",
                    "line": line,
                    "priority": "P2",
                    "title": f"Finding {line}",
                    "body": f"Distinct supported issue {line}.",
                }
                for line in range(1, 1001)
            ]
            findings[-1]["priority"] = "P0"
            findings[-2]["priority"] = "P1"

            input_path.write_text(
                json.dumps({"findings": findings}),
                encoding="utf-8",
            )
            changed_files_path.write_text("src/example.py\n", encoding="utf-8")
            changed_lines_path.write_text(
                json.dumps({"src/example.py": list(range(1, 1001))}),
                encoding="utf-8",
            )

            review_json.filter_command(argparse.Namespace(
                input=str(input_path),
                changed_files=str(changed_files_path),
                changed_lines=str(changed_lines_path),
                output=str(output_path),
            ))

            filtered = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(len(filtered["findings"]), 8)
            self.assertEqual(filtered["omitted_findings"], 992)
            self.assertTrue(filtered["findings"][0]["body"].startswith("**[P0]"))
            self.assertTrue(filtered["findings"][1]["body"].startswith("**[P1]"))

            review_json.filter_command(argparse.Namespace(
                input=str(input_path),
                changed_files=str(changed_files_path),
                changed_lines=str(changed_lines_path),
                output=str(output_path),
                max_findings=0,
            ))
            filtered = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(len(filtered["findings"]), 8)

            review_json.filter_command(argparse.Namespace(
                input=str(input_path),
                changed_files=str(changed_files_path),
                changed_lines=str(changed_lines_path),
                output=str(output_path),
                max_findings=1000,
            ))
            filtered = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(len(filtered["findings"]), 25)
            self.assertEqual(filtered["omitted_findings"], 975)

    def test_payload_enforces_final_comment_cap_and_reports_overflow(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_path = root / "review.json"
            output_path = root / "payload.json"
            summary_path = root / "summary.md"
            input_path.write_text(json.dumps({
                "verdict": "Review complete.",
                "findings": [
                    {
                        "path": "src/example.py",
                        "line": line,
                        "side": "RIGHT",
                        "body": f"Finding {line}",
                    }
                    for line in range(1, 1001)
                ],
            }), encoding="utf-8")

            review_json.build_payload_command(argparse.Namespace(
                input=str(input_path),
                output=str(output_path),
                summary_output=str(summary_path),
                trigger="issue_comment",
                commenter="reviewer",
                comment_url="",
            ))

            payload = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(len(payload["comments"]), 25)
            self.assertIn(
                "975 additional valid finding(s) were omitted",
                payload["body"],
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
