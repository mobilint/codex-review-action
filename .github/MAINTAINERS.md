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

The optional `mode` input has no manifest default: the runtime infers `auto`
for `pull_request` and `mention` for comment/review events.

## Security and compatibility rules

- Preserve Mobilint owner restrictions and validate all identifiers used in
  GitHub API paths.
- Treat checked-out PR content and rendered prompt data as hostile.
- Keep generated review assets in the action-owned temporary workspace, outside
  the checked-out PR tree, so PR-controlled symlinks cannot redirect writes.
- Keep read-only sandboxing and unsafe fallback disabled in central policy.
- Never turn an arbitrary Codex failure into an unsandboxed retry.
- Require the fetched PR head commit to equal `headRefOid`; never substitute a
  synthetic merge ref when producing inline-review coordinates.
- Keep output bounded and restrict inline comments to verified changed lines.
- Preserve 👀 acknowledgement removal, 👍 clean delivery, visible errors, and
  P0/P1/P2 badges.
- Ordinary tests must not require Codex authentication or mutate a live PR.

## CI and validation

`.github/workflows/check-action.yml` runs the offline unit suite, Python
compilation, shell syntax checks, canonical-source and symlink checks, and whitespace validation.
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

The central reusable workflow currently consumes the action from its reviewed
commit SHA. The managed callers likewise pin the central workflow to a reviewed
full commit SHA; never distribute a caller that uses a branch or tag. No
validated `stable` branch exists yet. Use `main` only for implementation and
canary validation, then:

1. Record the exact reviewed action candidate SHA while leaving production pinned.
2. Canary that exact action directly in a controlled repository with auto and
   mention event contexts; verify checkout, sandbox, and delivery.
3. Promote the tested action SHA through a reviewed central workflow PR, keeping
   its contract fixture synchronized. Validate routing at the resulting central SHA.
4. Update the central canonical caller and generated example to that validated
   workflow SHA, then distribute through reviewed consumer synchronization PRs.

Verify workflow SHA provenance in `mobilint/.github`, including existence of
`.github/workflows/codex-pr-review.yml` at that ref. A 40-hex syntax check cannot
validate provenance. Existing consumers migrate only when their caller PRs merge.
Protected release branches may track releases but never replace the immutable
references. Rollback requires reviewed caller updates to a validated rollback
SHA; changing `main` or `stable` alone does not update pinned consumers. See the
central maintainer guide for the full release and rollback procedure.

## Shared Codex and Claude guidance

Edit `AGENTS.md` and `.agents/skills` as the canonical sources. `CLAUDE.md`
links to `AGENTS.md`; `.claude/skills` links to `../.agents/skills`. Changes through
either path affect the same files. Check out with Git symlink support enabled
(`core.symlinks=true`) so these entries materialize as links rather than text.
The guide CI checks canonical files as tracked `100644` blobs and accepts only
those two exact `120000` link targets by Git blob identity. It never dereferences
PR-controlled links. Other source-file and managed-caller checks still reject
symlinks. The regression tests cover valid links and hostile alternatives.

## Multiple review runners

Register each runner under a distinct name in group `codex`, with custom label
`codex-reviewer`. Use separate installation and `_work` directories (on this
server: `~/actions-runner` and `~/actions-runner-2`) and keep both services online.
Each service user needs the tools listed in the action README, Codex credentials,
and a working read-only sandbox. Shared-host runners share machine capacity;
adding services does not add CPU or memory. The action uses a unique directory
under `RUNNER_TEMP`, falling back to `TMPDIR` or `/tmp` outside Actions, and cleans
up only its own directory. This describes the candidate action in this PR; the
central deployed pin remains `2454440`, which uses `mktemp -d` under `TMPDIR`
or `/tmp`. Deploying the candidate requires approval, a direct-action canary,
and a separate reviewed central pin update. No custom dispatcher or runner-name
binding is needed.

An organization administrator should verify both registrations are online with
the matching label, and that group `codex` permits each consuming repository
(and its reusable workflow if workflow restrictions are enabled). Listing these
settings through the REST API requires organization runner administration access;
ordinary repository access is insufficient.

After the central workflow is merged to the default branch, manually dispatch
`Check reviewer runner pool` in `mobilint/.github`. It runs two independent jobs
with `max-parallel: 2`, no checkout and no write permissions. Each checks tools and
sandbox startup and stays occupied for 20 seconds. When both runners are idle,
verify distinct runner names and overlapping execution intervals in the two job
logs. A serial run alone does not prove failure: a runner may have been busy or
offline. This smoke check does not authenticate a model request or publish a review.

GitHub schedules eligible jobs, not jobs still waiting at the hosted gate or
blocked by concurrency. Automatic reviews remain latest-update-wins per PR;
mention reviews retain their bounded per-PR slots with `cancel-in-progress: false`,
so a newer mention never interrupts the running review. A colliding mention waits
for that slot even if another runner is idle. GitHub permits only one pending job
per group by default: a third colliding request replaces the older pending job,
not the running job, even with `cancel-in-progress: false`. See the official
[concurrency documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
These are intentional review policies, not runner affinity. An already-running review is not migrated. A queued
eligible job with an idle matching runner warrants checking its labels, group
access, online status and runner service logs before changing concurrency policy.

## Reviewing this repository

`.github/workflows/code-review.yml` is an exact copy of the central managed
caller. It delegates automatic and `@mobilint-review` reviews to a reviewed,
SHA-pinned reusable workflow and its SHA-pinned deployed action, not the action
code under review. When central workflow behavior changes, review that change,
then synchronize every managed caller to the resulting full commit SHA.
Comment events use the default-branch caller, so after the initial enrollment
PR merges, post a fresh mention on existing PRs. The initial caller PR can be
reviewed via its `pull_request.opened` event, including self-hosted fallback
when the official reviewer has reached its usage limit.

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
