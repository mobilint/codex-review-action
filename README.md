# codex-review-action

[![GitHub clones](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fmobilint%2Fcodex-review-action%2Fbadges%2F.github%2Fbadges%2Fclones.json)](https://github.com/mobilint/codex-review-action/graphs/traffic)

Composite GitHub Action for running Mobilint's self-hosted Codex reviewer on a
pull request.

## Modes

- `auto`: collects the PR diff, asks Codex for structured review JSON, and
  posts a PR review with inline comments when possible. A clean review adds a
  👍 reaction to the pull request without posting a comment.
- `mention`: handles a direct `@mobilint-review` request from a PR comment,
  review comment, or review body. It repeats complete review passes until a
  pass yields no new findings, then submits up to the 25 highest-priority
  findings. Additional findings are summarized to keep the payload bounded. A
  clean request adds 👍 to the source item without posting a reply.

## Required runner tools

- `gh`
- `git`
- `jq`
- `python3`
- `codex`
- `bubblewrap` (`bwrap`) for Codex's built-in Linux sandbox

## Inputs

- `repo`: GitHub repository in `owner/repo` format, restricted to `mobilint`.
- `pr_number`: positive numeric pull-request number.
- `event_name`: `pull_request`, `issue_comment`,
  `pull_request_review_comment`, or `pull_request_review`.
- `mode`: `auto` or `mention`. When omitted, `pull_request` events use `auto`
  and comment/review events use `mention`.
- `comment_id`: positive numeric source discussion ID for mention runs.
- `commenter`: source commenter login for mention runs.
- `ack_reaction_id`: positive numeric ID of the temporary 👀 reaction.
- `ack_reaction_target`: `issue`, `issue_comment`, or `review_comment`.
- `max_files`: summary-only threshold (default `500`, maximum `5000`).
- `max_diff_chars`: diff truncation threshold (default `1000000`, maximum
  `5000000`).
- `sandbox_mode`: Codex sandbox mode (default `read-only`).
- `allow_unsafe_no_sandbox_fallback`: legacy escape hatch for a separately
  isolated trusted runner (default `false`).

Invalid numeric limits fall back to their defaults. Invalid sandbox modes fall
back to `read-only`, and invalid fallback values fail safe to `false`.

## Review behavior

1. Fetch PR metadata and check out the matching PR head on the self-hosted
   runner. A missing head ref or commit mismatch fails closed; the synthetic
   merge ref is never substituted because its review coordinates can differ.
2. Build bounded review assets outside the hostile PR checkout from the current
   diff.
3. Render the appropriate prompt and run Codex.
4. Normalize the returned JSON and validate findings against changed lines.
5. Remove 👀, then add 👍 for a clean result or publish a bounded review.

Inline findings use visible priorities:

- `P0`: release-blocking or immediately exploitable.
- `P1`: serious correctness, security, reliability, or data-loss risk.
- `P2`: bounded but actionable defect or important missing test.

Cosmetic suggestions and optional refactors are not findings. During migration,
legacy `high`, `medium`, and `low` values map to `P0`, `P1`, and `P2`.

Mentions inside Markdown quotes or code do not trigger review. Review-thread
requests receive a thread reply when inline review publication is not
appropriate. Sandbox startup failure aborts the action unless the explicitly
unsafe fallback is enabled on a separately isolated trusted runner.

For implementation structure, CI, contract maintenance, validation, and release
procedures, see the [maintainer guide](.github/MAINTAINERS.md).

Codex and Claude share repository guidance through symlinks: edit `AGENTS.md`
and `.agents/skills`; `CLAUDE.md` and `.claude/skills` use those same files.

## Multiple review runners

The central workflow targets runner group `codex` and label `codex-reviewer`.
GitHub assigns eligible queued jobs to any idle matching runner. Two registered,
online runners can execute two reviews at once; additional eligible jobs wait
for capacity. This does not bypass the trust gate or per-PR concurrency policy.
See the maintainer guide for setup and the manual pool check.

This repository uses the central managed review caller, pinned to a reviewed
full commit SHA. The central workflow also pins the deployed action by commit;
neither privileged dependency is resolved from a mutable branch or tag. After
that caller is on `main`, trusted contributors can request a self-hosted review
with `@mobilint-review` on a pull request.

## Official connector quota fallback

The central reusable workflow checks official output immediately, then every
15 seconds during the configured wait (five minutes by default). A recognized
quota or review-credit error from `chatgpt-codex-connector[bot]` starts local
fallback on the next check, including “You have reached your Codex usage limits
for code reviews.” Silence retains the timeout; mention reviews bypass it.
Checks use the triggering PR event timestamp, require the current head for
reviews, and ignore matching text from other authors or older comments. An eyes
reaction does not end polling early because the connector can report quota
failure afterward. Trust gates and runner scheduling still apply.

This behavior is implemented in the central workflow, not the action. Consumers
pinned to older workflow SHAs need a reviewed caller-pin update after this
central change merges; their behavior does not change merely by updating the
action. Keep timeout, author, timestamp, and head guards covered by regression
tests when editing fallback detection.
