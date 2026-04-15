# codex-review-action

Composite GitHub Action for running Mobilint's self-hosted Codex reviewer on a pull request.

## Modes

- `auto`: collects the PR diff, asks Codex for structured review JSON, and posts a PR review with inline comments when possible.
- `mention`: fetches the source PR comment, review comment, or review body, asks Codex for the same structured review format, and submits a PR review with inline comments when possible. If no valid inline comments can be posted, it falls back to a summary PR comment.

## Structure

- `scripts/run-review.sh`: top-level orchestrator for context resolution, repository checkout, asset preparation, Codex execution, and GitHub submission.
- `prompts/auto-review.md.tmpl`: prompt template for automatic PR reviews.
- `prompts/mention-review.md.tmpl`: prompt template for mention-triggered review requests.
- `scripts/render-prompt.py`: renders prompt templates with runtime values.
- `scripts/prepare-review-assets.py`: prepares `.codex-review` assets, including changed-line metadata.
- `scripts/review-json.py`: normalizes Codex JSON, filters findings to valid changed lines, and builds GitHub review payloads.

## Required runner tools

- `gh`
- `git`
- `jq`
- `python3`
- `codex`
- `bubblewrap` (`bwrap`) when you want Codex's built-in sandbox modes to work on Linux runners

## Inputs

- `repo`: GitHub repository in `owner/repo` format.
- `pr_number`: Pull request number.
- `event_name`: `pull_request`, `issue_comment`, `pull_request_review_comment`, or `pull_request_review`.
- `mode`: `auto` or `mention`.
- `comment_id`: source discussion item ID for mention-triggered runs.
- `commenter`: source commenter login for mention-triggered runs.
- `max_files`: soft limit for summary-only review mode.
- `max_diff_chars`: soft limit for diff truncation.
- `sandbox_strategy`: `auto` or `unsandboxed`.

## Flow

1. Fetch PR metadata and check out the PR head on the self-hosted runner.
2. Build `.codex-review` assets from the current diff.
3. Render the appropriate prompt template and run Codex.
4. Normalize and validate the returned review JSON.
5. Submit a PR review with inline comments when possible, or fall back to a summary PR comment.

## Notes

- Repository checkout uses `GH_TOKEN`, so private repositories can be reviewed on the self-hosted runner.
- `unsandboxed` is useful on runners where Codex's built-in read-only sandbox cannot start successfully.
- The default `sandbox_strategy: auto` first tries Codex's read-only sandbox. On Linux, that typically requires `bubblewrap` (`bwrap`) to be installed on the runner. If sandbox startup fails, the action falls back to unsandboxed execution.
- Mention-triggered runs now use the same inline-review submission path as automatic reviews when valid diff positions are available.
- When a mention comes from an existing PR review thread, the action replies in that thread instead of creating a new top-level PR comment.
