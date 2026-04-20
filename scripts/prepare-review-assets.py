#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def build_changed_lines(zero_diff_path: Path) -> dict[str, list[int]]:
    current_path: str | None = None
    changed_lines: dict[str, set[int]] = {}

    for raw_line in zero_diff_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if raw_line.startswith("+++ /dev/null"):
            current_path = None
            continue
        if raw_line.startswith("+++ b/"):
            current_path = raw_line[6:]
            changed_lines.setdefault(current_path, set())
            continue

        match = HUNK_RE.match(raw_line)
        if match and current_path:
            start = int(match.group(1))
            count = int(match.group(2) or "1")
            if count > 0:
                changed_lines.setdefault(current_path, set()).update(range(start, start + count))

    return {path: sorted(lines) for path, lines in changed_lines.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--changed-files", required=True)
    parser.add_argument("--diff", required=True)
    parser.add_argument("--zero-diff", required=True)
    parser.add_argument("--review-dir", required=True)
    parser.add_argument("--max-diff-chars", required=True, type=int)
    args = parser.parse_args()

    changed_files_path = Path(args.changed_files)
    diff_path = Path(args.diff)
    zero_diff_path = Path(args.zero_diff)
    review_dir = Path(args.review_dir)
    review_dir.mkdir(parents=True, exist_ok=True)

    changed_files = [
        line for line in changed_files_path.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()
    ]

    diff_text = diff_path.read_text(encoding="utf-8", errors="ignore")
    diff_size = len(diff_text.encode("utf-8"))

    if diff_size > args.max_diff_chars:
        diff_path.write_text(diff_text[: args.max_diff_chars] + "\n\n[TRUNCATED_DIFF]\n", encoding="utf-8")

    changed_lines = build_changed_lines(zero_diff_path)
    (review_dir / "changed-lines.json").write_text(
        json.dumps(changed_lines, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(json.dumps({"changed_files": len(changed_files), "diff_size": diff_size}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
