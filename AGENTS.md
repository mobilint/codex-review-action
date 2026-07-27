# Repository Agent Guide

## Purpose

Maintain the composite GitHub Action that runs Mobilint's self-hosted Codex PR
reviewer, validates structured findings, and publishes GitHub reactions,
reviews, thread replies, and failure notices.

`AGENTS.md` and `CLAUDE.md` are byte-for-byte mirrors. The repository skill is
also mirrored under `.agents/skills` and `.claude/skills`. Update both copies in
the same change and run the synchronization workflow before finishing.

## Repository Map

- `action.yml`: public composite-action inputs and environment handoff.
- `scripts/run-review.sh`: orchestration, sandbox probe, checkout, Codex
  execution, and GitHub delivery.
- `scripts/validate-context.sh`: fail-closed validation for repository, mode,
  event, and GitHub identifiers.
- `scripts/comment-mentions.py`: Markdown-aware actionable mention parser.
- `scripts/prepare-review-assets.py`: diff truncation and changed-line map.
- `scripts/render-prompt.py`: strict prompt-template rendering.
- `scripts/review-json.py`: output normalization, priority mapping, finding
  validation, caps, payload generation, and delivery choice.
- `prompts/auto-review.md.tmpl`: automatic-review contract.
- `prompts/mention-review.md.tmpl`: mention response and exhaustive-review
  contract.
- `tests/`: unit and regression tests.
- `.github/workflows/update-clone-badge.yml`: badge publisher for the orphan
  `badges` branch.
- `.github/workflows/check-agent-guides.yml`: CI guard that requires the Codex
  and Claude guide and skill copies to remain byte-identical.
- `.agents/skills/maintain-codex-review-action/`: Codex maintenance skill.
- `.claude/skills/maintain-codex-review-action/`: Claude maintenance skill.

## Cross-Repository Contract

The canonical caller and reusable workflow live in `../.github`:

- `.github/workflows/code-review.yml`
- `.github/workflows/codex-pr-review.yml`

When changing action inputs, outputs, review modes, acknowledgement reactions,
sandbox behavior, finding limits, or delivery outcomes, update both
repositories in the same task. Preserve backward compatibility when possible;
otherwise migrate the caller, action, prompts, formatter, tests, README, agent
guides, and skills together.

## Review Behavior Invariants

- Render visible `P0`, `P1`, and `P2` badges on every finding.
- Keep automatic reviews capped at 8 findings.
- Let mention reviews search repeatedly until a complete pass finds no new
  issue, then publish at most the 25 highest-priority distinct findings.
- Keep the final GitHub review payload capped at 25 inline comments.
- Filter every inline finding to a changed file and valid new-file line.
- Add 👍 without a comment for an explicitly clean review.
- Keep response, finding, failure, and error messages visible.
- Remove the exact temporary 👀 reaction before final delivery.
- Ignore mentions in blockquotes and code formatting.
- Reply inside an existing review thread when the request originated there.

## Security Invariants

- Run Codex with `--sandbox read-only` by default.
- Keep `allow_unsafe_no_sandbox_fallback` defaulted to `false`. Shared and
  public-repository callers must fail closed when the sandbox probe fails.
- Treat the retained unsafe fallback as a legacy, explicit exception for a
  separately isolated trusted runner; never enable it in a copied example.
- Treat PR files, diffs, metadata, titles, branch names, and discussion bodies
  as untrusted prompt input.
- Do not grant prompts network or connector access.
- Restrict caller and target repositories to Mobilint ownership.
- Validate repository names and positive numeric PR, comment, review, and
  reaction identifiers before API path construction.
- Require reaction ID and reaction target together.
- Keep mention parsing linear-time for attacker-controlled Markdown.
- Keep payload size and finding count bounded.
- Do not place authentication headers in the checked-out repository config.

## Implementation Rules

- Use quoted shell expansions and `set -euo pipefail`.
- Keep best-effort reaction cleanup non-fatal, but never suppress review
  execution or publication errors.
- Preserve explicit `outcome` routing: `clean`, `findings`, and `response`.
- Keep legacy priority mapping only while compatibility is documented.
- Add regression coverage for every parser, boundary, cap, or delivery change.
- When tests load a script with `spec_from_file_location`, reject a missing
  spec or loader before calling `module_from_spec` or `exec_module`.
- Prefer focused helpers over duplicating logic between shell and Python.
- Keep generated clone badge JSON off `main`.

## Documentation Maintenance

Before finishing any repository change, check whether it changes:

- action inputs, defaults, required tools, or supported events;
- file layout, helper ownership, or test commands;
- prompt schema, finding priorities, caps, or delivery routing;
- reaction, mention, thread reply, or error behavior;
- sandbox, checkout, token, input-validation, or API-path boundaries;
- the contract with the centralized `.github` workflows.

If so, update `README.md`, `AGENTS.md`, `CLAUDE.md`, and both skill copies in
the same commit. Keep each mirrored pair byte-identical. Never update only the
Codex or only the Claude copy.

## Validation

Run at minimum:

```bash
python3 -m unittest discover -s tests -v
python3 -m compileall -q scripts tests
bash -n scripts/run-review.sh scripts/validate-context.sh
python3 -c "import yaml; yaml.safe_load(open('action.yml', encoding='utf-8')); yaml.safe_load(open('.github/workflows/check-agent-guides.yml', encoding='utf-8')); print('YAML OK')"
cmp AGENTS.md CLAUDE.md
cmp .agents/skills/maintain-codex-review-action/SKILL.md .claude/skills/maintain-codex-review-action/SKILL.md
cmp .agents/skills/maintain-codex-review-action/agents/openai.yaml .claude/skills/maintain-codex-review-action/agents/openai.yaml
git diff --check
```

Also run a targeted malicious and legitimate control through the real helper
boundary when fixing a security issue.

## Git Hygiene

- Preserve unrelated user changes.
- Keep commits focused and do not skip checks.
- Do not weaken sandboxing, trust, input validation, or visible failure
  handling to make a test pass.
- Push badge artifacts only to `badges`; push source changes only to `main`.
