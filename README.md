# codex-review-action

Composite GitHub Action for running Mobilint's self-hosted Codex reviewer on a pull request.

## Modes

- `auto`: collects the PR diff, asks Codex for structured review JSON, and posts a PR review with inline comments when possible.
- `mention`: fetches the source PR comment, review comment, or review body, passes that request to Codex, and posts the reply back to GitHub.

## Required runner tools

- `gh`
- `git`
- `jq`
- `python3`
- `codex`

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

## Notes

- Repository checkout uses `GH_TOKEN`, so private repositories can be reviewed on the self-hosted runner.
- `unsandboxed` is useful on runners where Codex's built-in read-only sandbox cannot start successfully.
- Review-thread replies are posted directly when the source comment is a top-level PR review comment.
- Mentions on PR review bodies are answered as regular PR comments that link back to the source review.
- Nested review-comment replies are not supported by the GitHub API, so those fall back to a regular PR comment that links back to the source.
