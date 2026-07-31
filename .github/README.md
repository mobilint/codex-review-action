# Codex review action maintenance

This guide is for maintainers of `mobilint/codex-review-action`. The repository
root README documents the public action behavior and inputs.

## Implementation map

- `action.yml`: public composite-action input contract and environment
  forwarding.
- `scripts/run-review.sh`: orchestration, checkout, Codex execution, and GitHub
  delivery.
- `scripts/review-runtime.sh`: bounded numeric, boolean, and sandbox-mode
  normalization.
- `scripts/validate-context.sh`: repository, event, mode, and GitHub identifier
  validation.
- `scripts/comment-mentions.py`: Markdown-aware actionable mention parsing.
- `scripts/prepare-review-assets.py`: bounded diff and changed-line assets.
- `scripts/render-prompt.py`: strict prompt-template rendering.
- `scripts/review-json.py`: review normalization, changed-line filtering,
  priority ordering, and bounded payload construction.
- `prompts/*.tmpl`: automatic and mention review instructions.
- `tests/`: offline unit and contract tests.

## Central contract

`config/codex-review-action-contract.json` is the explicit cross-repository
fixture shared with `mobilint/.github`. Tests require `action.yml` to expose the
same input names, required flags, and defaults. The central repository
separately verifies that `codex-pr-review.yml` passes the full input set.

Update both fixtures and both test suites whenever the public contract changes.
The maintained inputs are:

- `repo`
- `pr_number`
- `event_name`
- `mode`
- `comment_id`
- `commenter`
- `ack_reaction_id`
- `ack_reaction_target`
- `max_files`
- `max_diff_chars`
- `sandbox_mode`
- `allow_unsafe_no_sandbox_fallback`

## Security and compatibility rules

- Preserve Mobilint owner restrictions and validate all identifiers used in
  GitHub API paths.
- Treat checked-out PR content and rendered prompt data as hostile.
- Keep read-only sandboxing and unsafe fallback disabled in central policy.
- Never turn an arbitrary Codex failure into an unsandboxed retry.
- Keep output bounded and restrict inline comments to verified changed lines.
- Preserve 👀 acknowledgement removal, 👍 clean delivery, visible errors, and
  P0/P1/P2 badges.
- Ordinary tests must not require Codex authentication or mutate a live PR.

## CI and validation

`.github/workflows/check-action.yml` runs the offline unit suite, Python
compilation, shell syntax checks, mirror checks, and whitespace validation.
`.github/workflows/check-agent-guides.yml` keeps Codex and Claude guides
byte-identical without dereferencing PR-controlled paths.

Run locally:

```bash
python3 -m unittest discover -s tests -v
python3 -m compileall -q scripts tests
bash -n scripts/run-review.sh scripts/review-runtime.sh scripts/validate-context.sh
git diff --check
```

The prompt-rendering fixtures cover both automatic and mention modes. Runtime
tests validate bounded fallbacks without actually executing an unsafe command.

## Release channel

The action is currently consumed through `mobilint/codex-review-action@main`.
No validated `stable` branch exists yet. Keep `@main` for implementation and
canary validation, then:

1. Validate automatic and mention reviews with the matching reusable workflow.
2. Create and protect `stable` branches in both central repositories.
3. Advance this action's `stable` ref first.
4. Change `codex-pr-review.yml` to use the action's stable ref.
5. Advance the `.github` stable ref and update the canonical caller.
6. Distribute that caller change through managed synchronization PRs.

Organization administrators must require CI and review on `stable`, restrict
direct pushes, and define who may advance it. Repository code cannot create
those settings.
