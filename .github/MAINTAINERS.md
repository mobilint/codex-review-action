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
- `model`
- `reasoning_effort`
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
`codex-reviewer`. Use separate installation and `_work` directories beneath
`~/codex-runners/`. The current installation has five services; add or remove
registrations to change capacity without editing review scheduling policy.
Each service user needs the tools listed in the action README, Codex credentials,
and a working read-only sandbox. Shared-host runners share machine capacity;
adding services does not add CPU, memory, or Codex account quota. The reviewed
action uses a unique directory under `RUNNER_TEMP`, falling back to `TMPDIR` or
`/tmp` outside Actions, and cleans up only its own directory. No custom
dispatcher, runner-name binding, or fixed pool-size policy is needed.

An organization administrator should verify each registration is online with
the matching label, and that group `codex` permits each consuming repository
(and its reusable workflow if workflow restrictions are enabled). Listing these
settings through the REST API requires organization runner administration access;
ordinary repository access is insufficient.

Manually dispatch `Check reviewer runner pool` from the central repository's
default branch with a job count matching the capacity you want to inspect. The
pool size is independent of this diagnostic's count. Choose a requested count
accepted by the current central workflow's validation; diagnostic input bounds
are separate from review scheduling policy. Its optional authenticated smoke
check makes a small Luna/max request and uses account quota; ordinary readiness checks only validate
tools and sandbox startup. Neither mode publishes a PR review. Keep probe
batches serialized, with no checkout or write token. Compare distinct runner
names and overlapping execution intervals when the intended runners are idle;
completed jobs alone cannot prove simultaneous capacity. Serial execution can
mean a runner was busy or offline, rather than a scheduling defect.

GitHub's matrix-job bounds are documented in
[Actions limits](https://docs.github.com/en/actions/reference/limits). Actual
runner registrations, host resources, trust gates, and per-PR concurrency determine
review capacity. For current diagnostic input validation and the deployed probe
revision, consult the central operations guide; probe maintenance is independent
of this immutable reusable workflow pin.

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
for code reviews.” Completed reviews or 👍 end the wait immediately. Silence retains the timeout;
mention reviews bypass it.
Checks use the triggering PR event timestamp, require the current head for
reviews, and ignore matching text from other authors or older comments. An eyes
reaction does not end polling early because the connector can report quota
failure afterward. Trust gates and runner scheduling still apply.

This behavior is implemented in the central workflow, not the action. Consumers
pinned to older workflow SHAs need a reviewed caller-pin update after this
central change merges; their behavior does not change merely by updating the
action. Keep timeout, author, timestamp, and head guards covered by regression
tests when editing fallback detection. Polling uses one bounded GraphQL query
per check for the newest 100 reviews, comments, and reactions. Partial API errors
fail visibly. Configured waits accept 0–20 minutes; invalid or larger values use
the five-minute default, leaving headroom within the 30-minute gate timeout.

Finding headings receive one priority badge from the normalized `priority` field.
Prompts keep titles free of leading priority badges; the formatter also removes
repeated leading `[P0]`, `[P1]`, or `[P2]` labels from older model output. The
priority field determines the displayed label even when a title prefix disagrees.
Labels within title text are preserved. Keep regression coverage at the filtering
boundary when changing heading formatting.

## Model configuration and rollout status

The action accepts `model` and `reasoning_effort`, defaulting to `gpt-6-luna`
and `max`. Both sandbox execution paths use validated CLI arguments and
`--ignore-user-config`; no connectors or interactive profiles are inherited from
the user config. Project configuration remains subject to Codex's normal trust
and configuration handling. Model names are limited to 128 ASCII letters,
digits, dots, underscores, and hyphens, starting with a letter or digit. Effort
is low/medium/high/xhigh/max. Invalid inputs fall back to the defaults.

This caller rollout proposes central revision
`17c7413b49c0aa056965bd03850685bb1e59a1b8`, merged through central PR #15
and verified through the GitHub Contents API. It selects reviewed action
`c156f3b883e3317f0c5a5a5fa9137f7bc2c07ad1`, merged through action PR #17.
The exact action passed both modes in
[canary run 43829681155](https://github.com/mobilint/codex-review-action/actions/runs/43829681155).
Central routing at that exact SHA also passed the
[automatic official-first/fallback run](https://github.com/mobilint/codex-review-action/actions/runs/43832639608)
and [mention run](https://github.com/mobilint/codex-review-action/actions/runs/43833750345).
Both runs reference central `17c7413`, reached `codex-reviewer-4`, and completed
with Luna/max in the read-only sandbox and clean reactions. These routing checks
are separate from the direct-action canary and establish the caller rollout
provenance.
After this caller update merges, the repository adopts those revisions; other
consumers remain on their existing pins until their own reviewed caller PRs
merge. Updating a central default branch alone never advances an immutable caller.

Historical audit: the former action pin
`2454440c864b485d23ae3c3a4078f0adb445c497` and pre-rollout action main
`64ec9f23019340099d0f045e6fc02963fae07ea8` had divergent history. The three
commits exclusive to that old pin were mode inference and merge commits. The
reviewed release retains mode inference with regression coverage, adds explicit
model selection, and passed exact-SHA canaries. Review complete comparisons for
future releases rather than assuming a fast-forward promotion. New action or
central changes still require the release/canary/routing/caller sequence above.

Runner installation, capacity checks, and safe add/remove procedures are owned
by the central [runner operations guide](https://github.com/mobilint/.github/blob/main/.github/MAINTAINERS.md#runner-installation-and-removal).
Use its versioned `scripts/runner-codex` wrapper when running older actions:
it supplies configuration defaults rather than duplicate `--model` flags, so
explicit settings in newer actions take precedence.

## Run exact-SHA canaries

After merging this action, use a controlled open PR in this repository authored
by the workflow operator, from the same-repository branch
`test/reviewer-release-canary` into the default branch. The fixed branch is a
canary allowlist; do not use it for production development. Dispatch the
default-branch-only manual workflow:

```bash
gh workflow run canary-review-action.yml -R mobilint/codex-review-action \
  -f action_sha=FULL_REVIEWED_ACTION_SHA -f pr_number=CONTROLLED_PR_NUMBER
```

Its hosted preflight requires a 40-hex commit reachable from the default branch
and the operator-authored, same-repository allowlisted target, using only read
permissions. Only then does it allocate runners. Write scopes are restricted
to the canary job. Each matrix job
uses the immutable checkout v6 revision
`d23441a48e516b6c34aea4fa41551a30e30af803` (verified against the upstream v6
ref and signed commit) to check out the verified action revision with credential
persistence disabled, then invokes the local composite action directly with
explicit auto/pull_request or
mention/issue_comment inputs. The mention job creates an actionable
`@mobilint-review` source comment on the controlled PR. It uses the repository
workflow token, Luna/max, and read-only
sandboxing; it never enables the unsafe fallback. This tests action behavior,
not central event/trust routing. Verify posted reviews or clean reactions,
runner summaries, and both job conclusions; record the run URL before promoting
the central action pin. Close a temporary canary PR after testing rather than
merging its fixture change.
