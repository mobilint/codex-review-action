from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RunReviewSecurityTests(unittest.TestCase):
    def test_review_assets_are_outside_hostile_checkout(self) -> None:
        script = (ROOT / "scripts" / "run-review.sh").read_text(encoding="utf-8")

        self.assertIn('REPO_DIR="${WORKDIR}/repo"', script)
        self.assertIn('REVIEW_DIR="${WORKDIR}/review-assets"', script)
        self.assertNotIn('REVIEW_DIR="${REPO_DIR}/', script)

    def test_prompts_receive_external_review_asset_path(self) -> None:
        script = (ROOT / "scripts" / "run-review.sh").read_text(encoding="utf-8")

        self.assertEqual(script.count('--var "REVIEW_DIR=${REVIEW_DIR}"'), 2)
        for template_name in ("auto-review.md.tmpl", "mention-review.md.tmpl"):
            template = (ROOT / "prompts" / template_name).read_text(encoding="utf-8")
            self.assertIn("{{REVIEW_DIR}}/changed-files.txt", template)
            self.assertNotIn(".codex-review/", template)


if __name__ == "__main__":
    unittest.main()
