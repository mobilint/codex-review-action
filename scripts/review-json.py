#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


def extract_json(raw_text: str) -> str:
    raw_text = raw_text.strip()
    if raw_text.startswith("{") and raw_text.endswith("}"):
        return raw_text
    match = re.search(r"\{.*\}", raw_text, re.S)
    if match:
        return match.group(0)
    raise ValueError("No JSON object found")


def normalize_command(args: argparse.Namespace) -> int:
    text = Path(args.input).read_text(encoding="utf-8", errors="ignore").strip()
    obj = json.loads(extract_json(text))
    obj.setdefault("verdict", "No verdict provided.")
    obj.setdefault("findings", [])
    obj.setdefault("suggested_next_steps", [])
    if not isinstance(obj["findings"], list):
        obj["findings"] = []
    if not isinstance(obj["suggested_next_steps"], list):
        obj["suggested_next_steps"] = []
    Path(args.output).write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


def filter_command(args: argparse.Namespace) -> int:
    review = json.loads(Path(args.input).read_text(encoding="utf-8"))
    changed_files = {
        line.strip()
        for line in Path(args.changed_files).read_text(encoding="utf-8", errors="ignore").splitlines()
        if line.strip()
    }
    changed_lines = {
        path: set(lines)
        for path, lines in json.loads(Path(args.changed_lines).read_text(encoding="utf-8")).items()
    }

    filtered = []
    for item in review.get("findings", []):
        path = item.get("path")
        line = item.get("line")
        title = item.get("title", "").strip()
        body = item.get("body", "").strip()

        if path not in changed_files:
            continue
        if not isinstance(line, int) or line <= 0:
            continue
        if line not in changed_lines.get(path, set()):
            continue
        if not body:
            continue

        if title:
            body = f"**{title}**\n\n{body}"

        filtered.append({
            "path": path,
            "line": line,
            "side": "RIGHT",
            "body": body,
        })

    review["findings"] = filtered[:8]
    Path(args.output).write_text(json.dumps(review, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


def build_body(review: dict, trigger: str, limit_text: str, commenter: str = "", comment_url: str = "") -> str:
    verdict = review.get("verdict", "").strip()
    steps = review.get("suggested_next_steps", [])
    body_lines = ["## Codex review", ""]

    if commenter:
        body_lines.append(f"Requested by @{commenter}.")
        body_lines.append("")

    body_lines.extend([
        "## Verdict",
        verdict if verdict else "No meaningful findings.",
        "",
        "## Suggested next steps",
    ])

    if steps:
        for step in steps:
            body_lines.append(f"- {step}")
    else:
        body_lines.append("- No additional next steps.")

    body_lines.extend(["", "---", f"_Trigger: {trigger}_"])
    if comment_url:
        body_lines.append(f"_Source: {comment_url}_")
    if limit_text:
        body_lines.append(f"_CLI limit: {limit_text}_")
    return "\n".join(body_lines)


def build_payload_command(args: argparse.Namespace) -> int:
    review = json.loads(Path(args.input).read_text(encoding="utf-8"))
    limit_text = Path(args.limit_file).read_text(encoding="utf-8", errors="ignore").strip() if args.limit_file else ""
    body = build_body(
        review,
        trigger=args.trigger,
        limit_text=limit_text,
        commenter=args.commenter,
        comment_url=args.comment_url,
    )
    payload = {
        "body": body,
        "event": "COMMENT",
        "comments": review.get("findings", []),
    }
    Path(args.output).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    Path(args.summary_output).write_text(body, encoding="utf-8")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    normalize = subparsers.add_parser("normalize")
    normalize.add_argument("--input", required=True)
    normalize.add_argument("--output", required=True)
    normalize.set_defaults(func=normalize_command)

    filter_parser = subparsers.add_parser("filter")
    filter_parser.add_argument("--input", required=True)
    filter_parser.add_argument("--changed-files", required=True)
    filter_parser.add_argument("--changed-lines", required=True)
    filter_parser.add_argument("--output", required=True)
    filter_parser.set_defaults(func=filter_command)

    build = subparsers.add_parser("build-payload")
    build.add_argument("--input", required=True)
    build.add_argument("--output", required=True)
    build.add_argument("--summary-output", required=True)
    build.add_argument("--trigger", required=True)
    build.add_argument("--limit-file")
    build.add_argument("--commenter", default="")
    build.add_argument("--comment-url", default="")
    build.set_defaults(func=build_payload_command)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
