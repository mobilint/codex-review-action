#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


MENTION_RE = re.compile(
    r"(^|[^\S\r\n])@mobilint-review(?=[\s\W]|$)",
    re.I | re.M,
)
FENCE_RE = re.compile(r"^[ \t]{0,3}(`{3,}|~{3,})")
BLOCKQUOTE_RE = re.compile(r"^[ \t]{0,3}>")
INDENTED_CODE_RE = re.compile(r"^(?: {4}|\t)")


def strip_inline_code(line: str) -> str:
    """Remove closed backtick spans in one pass without regex backtracking."""
    visible: list[str] = []
    copy_from = 0
    opener_start = -1
    opener_length = 0
    index = 0

    while index < len(line):
        if line[index] != "`":
            index += 1
            continue

        run_start = index
        while index < len(line) and line[index] == "`":
            index += 1
        run_length = index - run_start

        if opener_start < 0:
            visible.append(line[copy_from:run_start])
            opener_start = run_start
            opener_length = run_length
        elif run_length == opener_length:
            opener_start = -1
            opener_length = 0
            copy_from = index

    if opener_start >= 0:
        # An unmatched delimiter is ordinary visible Markdown.
        visible.append(line[opener_start:])
    else:
        visible.append(line[copy_from:])

    return "".join(visible)


def actionable_markdown(text: str) -> str:
    """Return Markdown that can intentionally invoke the reviewer."""
    visible_lines: list[str] = []
    fence_char = ""
    fence_length = 0

    for line in text.splitlines():
        fence = FENCE_RE.match(line)
        if fence:
            marker = fence.group(1)
            if not fence_char:
                fence_char = marker[0]
                fence_length = len(marker)
            elif marker[0] == fence_char and len(marker) >= fence_length:
                fence_char = ""
                fence_length = 0
            continue

        if fence_char or BLOCKQUOTE_RE.match(line) or INDENTED_CODE_RE.match(line):
            continue

        visible_lines.append(strip_inline_code(line))

    return "\n".join(visible_lines)


def has_actionable_mention(text: str) -> bool:
    return MENTION_RE.search(actionable_markdown(text)) is not None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="GitHub comment or review JSON")
    args = parser.parse_args()

    payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
    return 0 if has_actionable_mention(str(payload.get("body", ""))) else 1


if __name__ == "__main__":
    raise SystemExit(main())
