#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


def flatten_text(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if value is None:
        return ""
    if isinstance(value, list):
        return " ".join(part for item in value if (part := flatten_text(item)))
    if isinstance(value, dict):
        return " ".join(part for item in value.values() if (part := flatten_text(item)))
    return ""


def collect_candidates(obj: object, path: str = "") -> list[str]:
    candidates: list[str] = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            next_path = f"{path}.{key}" if path else key
            lowered_key = key.lower()
            text = flatten_text(value).strip()
            if text and any(token in lowered_key for token in ("limit", "quota", "usage", "remaining", "reset")):
                candidates.append(f"{key}: {text}")
            candidates.extend(collect_candidates(value, next_path))
    elif isinstance(obj, list):
        for idx, value in enumerate(obj):
            candidates.extend(collect_candidates(value, f"{path}[{idx}]"))
    return candidates


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

        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            obj = None
        if obj is not None:
            json_matches = collect_candidates(obj)
            if json_matches:
                matches.extend(json_matches)

        if any(pattern.search(line) for pattern in patterns):
            matches.append(line)

    Path(args.output).write_text(matches[-1] if matches else "", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
