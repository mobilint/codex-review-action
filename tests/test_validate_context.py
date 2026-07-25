from __future__ import annotations

from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts" / "validate-context.sh"


class ValidateContextTests(unittest.TestCase):
    def validate(
        self,
        *,
        repo: str = "mobilint/example",
        pr_number: str = "7",
        event_name: str = "issue_comment",
        mode: str = "mention",
        comment_id: str = "101",
        reaction_id: str = "202",
        reaction_target: str = "issue_comment",
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(SCRIPT),
                repo,
                pr_number,
                event_name,
                mode,
                comment_id,
                reaction_id,
                reaction_target,
            ],
            capture_output=True,
            check=False,
            text=True,
        )

    def test_accepts_numeric_github_ids(self) -> None:
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_review_without_acknowledgement_reaction(self) -> None:
        result = self.validate(reaction_id="", reaction_target="")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_auto_review_issue_reaction(self) -> None:
        result = self.validate(
            event_name="pull_request",
            mode="auto",
            comment_id="",
            reaction_target="issue",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_path_traversal_reaction_id(self) -> None:
        result = self.validate(reaction_id="../../comments/555")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ack_reaction_id must be a positive integer", result.stderr)

    def test_rejects_nonnumeric_reaction_id(self) -> None:
        result = self.validate(reaction_id="not-a-number")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ack_reaction_id must be a positive integer", result.stderr)

    def test_rejects_incomplete_reaction_pair(self) -> None:
        result = self.validate(reaction_target="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be provided together", result.stderr)

    def test_rejects_invalid_path_identifiers(self) -> None:
        for field, value in (
            ("repo", "mobilint/example/../../git"),
            ("pr_number", "../7"),
            ("comment_id", "101/reactions"),
        ):
            with self.subTest(field=field):
                result = self.validate(**{field: value})
                self.assertNotEqual(result.returncode, 0)

    def test_comment_reaction_requires_comment_id(self) -> None:
        result = self.validate(mode="auto", comment_id="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "comment_id is required for issue_comment",
            result.stderr,
        )


if __name__ == "__main__":
    unittest.main()
