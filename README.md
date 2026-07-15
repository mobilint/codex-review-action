# codex-review-action

[![GitHub clones](https://img.shields.io/endpoint?url=https%3A%2F%2Frawcodex-review-actionusercontent.com%2Fmobilint%2Fcodex-review-action%2Fmain%2Fcodex-review-action%2Fbadges%2Fclones.json)](https://github.com/mobilint/codex-review-action/graphs/traffic)

Composite GitHub Action for running Mobilint's self-hosted Codex reviewer on a pull request.

## Modes

- `auto`: collects the PR diff, asks Codex for structured review JSON, and posts a PR review with inline comments when possible. A clean review adds a 👍 reaction to the pull request without posting a comment.
- `mention`: fetches the source PR comment, review comment, or review body, asks Codex to repeat complete review passes until a pass yields no new findings, and submits the resulting structured review with inline comments when possible. A clean review request adds a 👍 reaction to the source comment without posting a reply. If no valid inline comments can be posted for a non-clean review, it falls back to a summary PR comment.

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
- `ack_reaction_id`: ID of the temporary 👀 reaction created by the caller.
- `ack_reaction_target`: location of that reaction (`issue`, `issue_comment`, or `review_comment`).
- `max_files`: soft limit for summary-only review mode.
- `max_diff_chars`: soft limit for diff truncation.

## Flow

1. Fetch PR metadata and check out the PR head on the self-hosted runner.
2. Build `.codex-review` assets from the current diff.
3. Render the appropriate prompt template and run Codex.
4. Normalize and validate the returned review JSON.
5. Remove the temporary 👀 reaction, then add a 👍 reaction without a comment for a clean review; otherwise submit a PR review with inline comments when possible, or fall back to a summary PR comment.

## Finding priorities

Every inline finding is prefixed with a visible priority badge:

- `P0`: release-blocking or immediately exploitable; do not merge as written.
- `P1`: serious correctness, security, reliability, or data-loss risk; fix before merge.
- `P2`: bounded but actionable defect or important missing test; fix soon.

Cosmetic suggestions and optional refactors are not reported as findings. During rollout, the formatter also accepts the former `high`, `medium`, and `low` severity values and maps them to `P0`, `P1`, and `P2` respectively.

## Notes

- Repository checkout uses `GH_TOKEN`, so private repositories can be reviewed on the self-hosted runner.
- Codex always runs in a read-only sandbox. On Linux, that typically requires `bubblewrap` (`bwrap`) to be installed on the runner. If sandbox startup fails, the action aborts instead of falling back to unsandboxed execution.
- Mention-triggered runs now use the same inline-review submission path as automatic reviews when valid diff positions are available.
- Mentions inside Markdown blockquotes, fenced code blocks, indented code blocks, or inline code are treated as examples and do not trigger a review.
- When a mention comes from an existing PR review thread, the action replies in that thread instead of creating a new top-level PR comment.
