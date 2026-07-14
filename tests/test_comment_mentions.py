from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts" / "comment-mentions.py"
SPEC = importlib.util.spec_from_file_location("comment_mentions", SCRIPT)
comment_mentions = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(comment_mentions)


class CommentMentionsTests(unittest.TestCase):
    def test_direct_mention_triggers_review(self) -> None:
        self.assertTrue(comment_mentions.has_actionable_mention(
            "@mobilint-review Review current PR",
        ))

    def test_quoted_mention_does_not_trigger_review(self) -> None:
        body = (
            "> @mobilint-review Review current PR\n\n"
            "@teammate You can request a review like this."
        )
        self.assertFalse(comment_mentions.has_actionable_mention(body))

    def test_nested_quote_does_not_trigger_review(self) -> None:
        self.assertFalse(comment_mentions.has_actionable_mention(
            "  >> @mobilint-review Review this",
        ))

    def test_code_examples_do_not_trigger_review(self) -> None:
        self.assertFalse(comment_mentions.has_actionable_mention(
            "```markdown\n@mobilint-review Review this\n```\n"
            "`@mobilint-review Review this`",
        ))

    def test_direct_mention_still_triggers_when_quote_is_present(self) -> None:
        body = (
            "> @mobilint-review previous request\n\n"
            "@mobilint-review Please check the latest change."
        )
        self.assertTrue(comment_mentions.has_actionable_mention(body))


if __name__ == "__main__":
    unittest.main()
