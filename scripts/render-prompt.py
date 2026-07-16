#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--var", action="append", default=[])
    args = parser.parse_args()

    values: dict[str, str] = {}
    for item in args.var:
        key, sep, value = item.partition("=")
        if not sep:
            raise SystemExit(f"Invalid --var value: {item}")
        values[key] = value

    template = Path(args.template).read_text(encoding="utf-8")

    def replace(match: re.Match[str]) -> str:
        return values.get(match.group(1), "")

    rendered = re.sub(r"\{\{([A-Z0-9_]+)\}\}", replace, template)
    Path(args.output).write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
