---
name: maintain-codex-review-action
description: Maintain Mobilint's composite Codex PR review action. Use when changing action inputs, sandboxing, checkout, prompts, mention parsing, P0/P1/P2 findings, caps, reactions, GitHub review delivery, validation helpers, tests, badge automation, or the contract with the centralized mobilint/.github workflows.
---

# Maintain Codex Review Action

## Establish Scope

1. Read the root agent guide (`AGENTS.md` or `CLAUDE.md`) completely.
2. Trace the requested behavior through `action.yml`, `scripts/run-review.sh`,
   the relevant helper, prompt template, formatter, and tests.
3. Inspect `../.github/.github/workflows/codex-pr-review.yml` and
   `code-review.yml` when the public action contract changes.
4. Preserve unrelated worktree changes.

## Select the Change Surface

- Change action inputs and environment mapping in `action.yml`.
- Change orchestration, checkout, sandboxing, and delivery in
  `scripts/run-review.sh`.
- Change prompt contracts in both templates when behavior applies to both
  modes.
- Change normalization, priority badges, caps, and payloads in
  `scripts/review-json.py`.
- Change actionable mention semantics in `scripts/comment-mentions.py`.
- Change API path validation in `scripts/validate-context.sh`.
- Change bounded numeric, boolean, sandbox, and fallback normalization in
  `scripts/review-runtime.sh`.
- Keep `config/codex-review-action-contract.json` synchronized with the central
  fixture and reusable workflow.
- Add focused regression tests for every behavior or security boundary.
- Guard both the module spec and loader before dynamically importing hyphenated
  scripts in tests.

## Preserve Invariants

- Use visible `P0`, `P1`, and `P2` finding badges.
- Keep automatic findings at 8 and final payloads at 25.
- Keep the action's default review capacity aligned with the centralized
  workflow at 500 files and 1,000,000 diff characters.
- Fall back to bounded safe defaults for invalid numeric limits, booleans, or
  sandbox modes.
- Let mention mode search exhaustively, then retain at most 25 distinct
  highest-priority findings.
- Filter inline findings to changed files and valid changed lines.
- Use reaction-only 👍 for clean reviews and keep errors visible.
- Remove the exact temporary 👀 reaction before final output.
- Ignore quoted and code-formatted mentions in linear time.
- Run in the read-only sandbox by default and keep the unsafe fallback
  disabled in shared or public-repository callers.
- Validate every identifier before constructing a GitHub API path.
- For pull-request checks, reject non-`100644` index entries and compare Git
  blob IDs without dereferencing or printing PR-controlled working-tree paths.
- Set `persist-credentials: false` on read-only checkouts that do not need to
  perform authenticated Git operations.

## Update Documentation

After changing behavior, structure, interfaces, security boundaries, or
validation:

1. Update `README.md`.
2. Update `AGENTS.md` and `CLAUDE.md`.
3. Update this skill and
   `.claude/skills/maintain-codex-review-action/SKILL.md`.
4. Keep each mirrored pair byte-identical.
5. Update both `agents/openai.yaml` copies if the skill purpose changes.
6. Update the centralized workflow guides and skill if their contract changed.

Never update only the Codex or only the Claude documentation.

## Validate

Run:

```bash
python3 -m unittest discover -s tests -v
python3 -m compileall -q scripts tests
bash -n scripts/run-review.sh scripts/review-runtime.sh scripts/validate-context.sh
python3 -c "import yaml; yaml.safe_load(open('action.yml', encoding='utf-8')); yaml.safe_load(open('.github/workflows/check-agent-guides.yml', encoding='utf-8')); print('YAML OK')"
cmp AGENTS.md CLAUDE.md
cmp .agents/skills/maintain-codex-review-action/SKILL.md .claude/skills/maintain-codex-review-action/SKILL.md
cmp .agents/skills/maintain-codex-review-action/agents/openai.yaml .claude/skills/maintain-codex-review-action/agents/openai.yaml
git diff --check
```

For a security fix, also run the original malicious input and a legitimate
control through the real boundary. Review the final diff for alternate sinks,
fallback branches, unbounded output, and cross-repository contract drift.
