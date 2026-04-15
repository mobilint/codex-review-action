#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    text = Path(args.log).read_text(encoding="utf-8", errors="ignore")
    text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
    text = text.replace("\r", "\n")

    patterns = [
        re.compile(r".*(?:remaining|left).*(?:limit|quota).*", re.I),
        re.compile(r".*(?:limit|quota).*(?:remaining|left).*", re.I),
        re.compile(r".*rate limit.*", re.I),
        re.compile(r".*usage.*(?:limit|quota).*", re.I),
    ]

    matches = []
    for raw_line in text.splitlines():
        line = " ".join(raw_line.split()).strip()
        if not line:
            continue
        if any(pattern.search(line) for pattern in patterns):
            matches.append(line)

    Path(args.output).write_text(matches[-1] if matches else "", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
