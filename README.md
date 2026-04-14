# codex-review-action

Composite GitHub Action for running Mobilint's self-hosted Codex reviewer on a pull request.

## Modes

- `auto`: collects the PR diff, asks Codex for structured review JSON, and posts a PR review with inline comments when possible.
- `mention`: fetches the source PR comment or review-thread comment, passes that request to Codex, and posts the reply back to GitHub.

## Required runner tools

- `gh`
- `git`
- `jq`
- `python3`
- `codex`

## Inputs

- `repo`: GitHub repository in `owner/repo` format.
- `pr_number`: Pull request number.
- `event_name`: `pull_request`, `issue_comment`, or `pull_request_review_comment`.
- `mode`: `auto` or `mention`.
- `comment_id`: source comment ID for mention-triggered runs.
- `commenter`: source commenter login for mention-triggered runs.
- `max_files`: soft limit for summary-only review mode.
- `max_diff_chars`: soft limit for diff truncation.

## Notes

- Repository checkout uses `GH_TOKEN`, so private repositories can be reviewed on the self-hosted runner.
- Review-thread replies are posted directly when the source comment is a top-level PR review comment.
- Nested review-comment replies are not supported by the GitHub API, so those fall back to a regular PR comment that links back to the source.
