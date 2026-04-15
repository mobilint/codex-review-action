#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROMPTS_DIR="${ROOT_DIR}/prompts"

REPO="${INPUT_REPO}"
PR_NUMBER="${INPUT_PR_NUMBER}"
EVENT_NAME="${INPUT_EVENT_NAME}"
MODE="${INPUT_MODE:-auto}"
COMMENT_ID="${INPUT_COMMENT_ID:-}"
COMMENTER="${INPUT_COMMENTER:-}"
MAX_FILES="${INPUT_MAX_FILES:-200}"
MAX_DIFF_CHARS="${INPUT_MAX_DIFF_CHARS:-200000}"
SANDBOX_STRATEGY="${INPUT_SANDBOX_STRATEGY:-auto}"
ALLOWED_OWNER="mobilint"

WORKDIR="$(mktemp -d)"
REPO_DIR="${WORKDIR}/repo"
REVIEW_DIR="${REPO_DIR}/.codex-review"
COMMENT_JSON="${WORKDIR}/comment.json"
RAW_OUTPUT_FILE="${WORKDIR}/codex_raw_output.txt"
REPLY_PAYLOAD_FILE="${WORKDIR}/mention-reply-payload.json"
CODEX_LOG_FILE="${WORKDIR}/codex_exec.log"
CODEX_LIMIT_FILE="${WORKDIR}/codex_limit.txt"
FALLBACK_PROMPT_FILE="${WORKDIR}/codex_fallback_prompt.md"
REVIEW_JSON_FILE="${WORKDIR}/review.json"
FILTERED_REVIEW_JSON_FILE="${WORKDIR}/review.filtered.json"
REVIEW_PAYLOAD_FILE="${WORKDIR}/review-payload.json"
SUMMARY_BODY_FILE="${WORKDIR}/summary-body.md"
AUTO_PROMPT_FILE="${WORKDIR}/review_prompt.md"
MENTION_PROMPT_FILE="${WORKDIR}/mention_prompt.md"
export WORKDIR REPO_DIR REVIEW_DIR COMMENT_JSON RAW_OUTPUT_FILE REPLY_PAYLOAD_FILE CODEX_LOG_FILE CODEX_LIMIT_FILE FALLBACK_PROMPT_FILE

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

cd "${WORKDIR}"

require_commands() {
  for cmd in gh git jq python3 codex; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "[ERROR] ${cmd} not found" >&2
      exit 1
    }
  done
}

render_prompt() {
  local template="$1"
  local output="$2"
  shift 2
  python3 "${SCRIPT_DIR}/render-prompt.py" --template "${template}" --output "${output}" "$@"
}

normalize_review_json() {
  python3 "${SCRIPT_DIR}/review-json.py" normalize --input "${RAW_OUTPUT_FILE}" --output "${REVIEW_JSON_FILE}"
}

filter_findings() {
  python3 "${SCRIPT_DIR}/review-json.py" filter \
    --input "${REVIEW_JSON_FILE}" \
    --changed-files "${REVIEW_DIR}/changed-files.txt" \
    --changed-lines "${REVIEW_DIR}/changed-lines.json" \
    --output "${FILTERED_REVIEW_JSON_FILE}"
}

build_review_payload() {
  local trigger="$1"
  local commenter="${2:-}"
  local comment_url="${3:-}"
  python3 "${SCRIPT_DIR}/review-json.py" build-payload \
    --input "${FILTERED_REVIEW_JSON_FILE}" \
    --output "${REVIEW_PAYLOAD_FILE}" \
    --summary-output "${SUMMARY_BODY_FILE}" \
    --trigger "${trigger}" \
    --limit-file "${CODEX_LIMIT_FILE}" \
    --commenter "${commenter}" \
    --comment-url "${comment_url}"
}

run_review_pipeline() {
  local prompt_file="$1"
  local trigger="$2"
  local commenter="${3:-}"
  local comment_url="${4:-}"
  local normalize_label="${5:-normalizing codex JSON}"
  local filter_label="${6:-filtering findings against changed hunks}"
  local payload_label="${7:-building review payload}"

  run_codex "${prompt_file}" "${RAW_OUTPUT_FILE}"
  echo "[INFO] ${normalize_label}"
  normalize_review_json
  echo "[INFO] ${filter_label}"
  filter_findings
  echo "[INFO] ${payload_label}"
  build_review_payload "${trigger}" "${commenter}" "${comment_url}"
}

submit_review_with_fallback() {
  local context_label="$1"
  local success_label="$2"
  local fallback_label="$3"
  local review_response
  local review_exit

  echo "[INFO] attempting ${context_label} submission"
  set +e
  review_response="$(
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
      --input "${REVIEW_PAYLOAD_FILE}" 2>&1
  )"
  review_exit=$?
  set -e

  if [[ ${review_exit} -eq 0 ]]; then
    echo "[INFO] ${success_label}"
    return 0
  fi

  echo "[WARN] ${fallback_label}"
  echo "${review_response}" >&2
  gh pr comment "${PR_NUMBER}" --repo "${REPO}" --body-file "${SUMMARY_BODY_FILE}"
  echo "[INFO] fallback summary comment posted"
}

run_codex() {
  local prompt_file="$1"
  local output_file="$2"
  local codex_exit=0
  local sandbox_failure_detected="false"
  local retried_without_sandbox="false"
  local started_unsandboxed="false"

  echo "[INFO] running codex"

  {
    cat <<'EOF'
Runner note:
- This self-hosted review runner may execute Codex without its built-in sandbox.
- Do not modify files, install dependencies, or access the network.
- Do not use MCP connectors or web tools.
- Restrict yourself to reading the checked-out repository and .codex-review assets only.

EOF
    cat "${prompt_file}"
  } > "${FALLBACK_PROMPT_FILE}"

  if [[ "${SANDBOX_STRATEGY}" == "auto" ]]; then
    rm -f "${output_file}"
    : > "${CODEX_LOG_FILE}"
    set +e
    (
      cd "${REPO_DIR}"
      codex exec \
        --json \
        --sandbox read-only \
        --output-last-message "${output_file}" \
        "$(cat "${prompt_file}")"
    ) > "${CODEX_LOG_FILE}" 2>&1
    codex_exit=$?
    set -e

    if grep -Eiq 'bwrap: loopback: Failed RTM_NEWADDR|Sandbox\(Denied|ERROR codex_core::tools::router: error=exec_command failed|could not find bubblewrap' "${CODEX_LOG_FILE}"; then
      sandbox_failure_detected="true"
    fi

    if [[ "${sandbox_failure_detected}" == "true" ]]; then
      retried_without_sandbox="true"
      echo "[WARN] Codex read-only sandbox is unavailable on this runner. Retrying without sandbox."
      : > "${CODEX_LOG_FILE}"
      rm -f "${output_file}"
      set +e
      (
        cd "${REPO_DIR}"
        codex exec \
          --json \
          --dangerously-bypass-approvals-and-sandbox \
          --output-last-message "${output_file}" \
          "$(cat "${FALLBACK_PROMPT_FILE}")"
      ) > "${CODEX_LOG_FILE}" 2>&1
      codex_exit=$?
      set -e
    fi
  else
    retried_without_sandbox="true"
    started_unsandboxed="true"
    echo "[INFO] sandbox_strategy=unsandboxed; skipping read-only sandbox probe."
    : > "${CODEX_LOG_FILE}"
    rm -f "${output_file}"
    set +e
    (
      cd "${REPO_DIR}"
      codex exec \
        --json \
        --dangerously-bypass-approvals-and-sandbox \
        --output-last-message "${output_file}" \
        "$(cat "${FALLBACK_PROMPT_FILE}")"
    ) > "${CODEX_LOG_FILE}" 2>&1
    codex_exit=$?
    set -e
  fi

  if [[ ${codex_exit} -ne 0 ]]; then
    echo "[ERROR] Codex execution failed" >&2
    tail -n 120 "${CODEX_LOG_FILE}" >&2 || true
    exit "${codex_exit}"
  fi

  if [[ ! -s "${output_file}" ]]; then
    echo "[ERROR] Codex did not produce output" >&2
    tail -n 120 "${CODEX_LOG_FILE}" >&2 || true
    exit 1
  fi

  if [[ "${started_unsandboxed}" == "true" ]]; then
    echo "[INFO] Codex completed in configured unsandboxed mode."
  elif [[ "${retried_without_sandbox}" == "true" ]]; then
    echo "[INFO] Codex completed after fallback to unsandboxed mode."
  else
    echo "[INFO] Codex completed in read-only sandbox."
  fi

  python3 "${SCRIPT_DIR}/extract-codex-limit.py" --log "${CODEX_LOG_FILE}" --output "${CODEX_LIMIT_FILE}"
}

resolve_context() {
  CALLER_OWNER="${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}"
  TARGET_OWNER="${REPO%%/*}"

  if [[ "${CALLER_OWNER}" != "${ALLOWED_OWNER}" ]]; then
    echo "[ERROR] this action can only run from ${ALLOWED_OWNER}-owned repositories (caller_owner=${CALLER_OWNER:-unknown})" >&2
    exit 1
  fi

  if [[ "${TARGET_OWNER}" != "${ALLOWED_OWNER}" ]]; then
    echo "[ERROR] this action can only review ${ALLOWED_OWNER}-owned repositories (target_owner=${TARGET_OWNER:-unknown})" >&2
    exit 1
  fi

  if [[ -z "${MODE}" ]]; then
    if [[ "${EVENT_NAME}" == "pull_request" ]]; then
      MODE="auto"
    else
      MODE="mention"
    fi
  fi

  if [[ -z "${COMMENT_ID}" && "${MODE}" == "mention" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    case "${EVENT_NAME}" in
      issue_comment|pull_request_review_comment)
        COMMENT_ID="$(jq -r '.comment.id // ""' "${GITHUB_EVENT_PATH}")"
        ;;
      pull_request_review)
        COMMENT_ID="$(jq -r '.review.id // ""' "${GITHUB_EVENT_PATH}")"
        ;;
    esac
  fi

  if [[ -z "${COMMENTER}" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    case "${EVENT_NAME}" in
      issue_comment|pull_request_review_comment)
        COMMENTER="$(jq -r '.comment.user.login // ""' "${GITHUB_EVENT_PATH}")"
        ;;
      pull_request_review)
        COMMENTER="$(jq -r '.review.user.login // .sender.login // ""' "${GITHUB_EVENT_PATH}")"
        ;;
    esac
  fi

  case "${SANDBOX_STRATEGY}" in
    auto|unsandboxed) ;;
    *)
      echo "[ERROR] unsupported sandbox strategy: ${SANDBOX_STRATEGY}" >&2
      exit 1
      ;;
  esac
}

fetch_pr_and_checkout() {
  echo "[INFO] fetching PR metadata"
  gh pr view "${PR_NUMBER}" \
    --repo "${REPO}" \
    --json number,title,body,author,baseRefName,headRefName,url,headRefOid \
    > "${WORKDIR}/pr.json"

  PR_URL="$(jq -r '.url' "${WORKDIR}/pr.json")"
  PR_TITLE="$(jq -r '.title' "${WORKDIR}/pr.json")"
  PR_AUTHOR="$(jq -r '.author.login' "${WORKDIR}/pr.json")"
  BASE_REF="$(jq -r '.baseRefName' "${WORKDIR}/pr.json")"
  HEAD_REF="$(jq -r '.headRefName' "${WORKDIR}/pr.json")"
  HEAD_SHA="$(jq -r '.headRefOid' "${WORKDIR}/pr.json")"

  echo "[INFO] checking out repository"
  git init "${REPO_DIR}" >/dev/null 2>&1
  git -C "${REPO_DIR}" remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
  git -C "${REPO_DIR}" fetch --depth=50 origin "${BASE_REF}"
  git -C "${REPO_DIR}" checkout -B base FETCH_HEAD >/dev/null 2>&1 || {
    echo "[ERROR] failed to checkout base branch ${BASE_REF}" >&2
    exit 1
  }

  echo "[INFO] fetching PR head"
  git -C "${REPO_DIR}" fetch --depth=50 origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
  git -C "${REPO_DIR}" checkout "pr-${PR_NUMBER}" >/dev/null 2>&1 || {
    echo "[ERROR] failed to checkout PR head branch pr-${PR_NUMBER}" >&2
    exit 1
  }

  MERGE_BASE="$(git -C "${REPO_DIR}" merge-base base "pr-${PR_NUMBER}" || true)"
  if [[ -z "${MERGE_BASE}" ]]; then
    echo "[WARN] merge-base not found from shallow fetch, retrying with full history"
    git -C "${REPO_DIR}" fetch --unshallow origin "${BASE_REF}" || git -C "${REPO_DIR}" fetch origin "${BASE_REF}"
    git -C "${REPO_DIR}" fetch origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
    MERGE_BASE="$(git -C "${REPO_DIR}" merge-base base "pr-${PR_NUMBER}" || true)"
  fi

  if [[ -z "${MERGE_BASE}" ]]; then
    echo "[ERROR] failed to compute merge-base for base=${BASE_REF} pr=${PR_NUMBER}" >&2
    git -C "${REPO_DIR}" show-ref >&2 || true
    exit 1
  fi

  echo "[INFO] merge_base=${MERGE_BASE} head_sha=${HEAD_SHA}"
}

prepare_review_assets() {
  local prep_json
  echo "[INFO] collecting diff and changed-line metadata"
  git -C "${REPO_DIR}" diff --find-renames --name-only "${MERGE_BASE}" HEAD > "${WORKDIR}/changed-files.txt"
  git -C "${REPO_DIR}" diff --find-renames --unified=3 "${MERGE_BASE}" HEAD > "${WORKDIR}/pr.diff"
  git -C "${REPO_DIR}" diff --find-renames --unified=0 "${MERGE_BASE}" HEAD > "${WORKDIR}/pr-zero.diff"

  mkdir -p "${REVIEW_DIR}"
  cp "${WORKDIR}/pr.json" "${REVIEW_DIR}/pr.json"
  cp "${WORKDIR}/changed-files.txt" "${REVIEW_DIR}/changed-files.txt"

  prep_json="$(
    python3 "${SCRIPT_DIR}/prepare-review-assets.py" \
      --changed-files "${WORKDIR}/changed-files.txt" \
      --diff "${WORKDIR}/pr.diff" \
      --zero-diff "${WORKDIR}/pr-zero.diff" \
      --review-dir "${REVIEW_DIR}" \
      --max-diff-chars "${MAX_DIFF_CHARS}"
  )"

  CHANGED_FILES="$(jq -r '.changed_files' <<< "${prep_json}")"
  DIFF_SIZE="$(jq -r '.diff_size' <<< "${prep_json}")"
  SUMMARY_ONLY="false"
  if [[ "${CHANGED_FILES}" -gt "${MAX_FILES}" || "${DIFF_SIZE}" -gt "${MAX_DIFF_CHARS}" ]]; then
    SUMMARY_ONLY="true"
  fi

  cp "${WORKDIR}/pr.diff" "${REVIEW_DIR}/pr.diff"
  echo "[INFO] changed_files=${CHANGED_FILES} summary_only=${SUMMARY_ONLY} diff_size=${DIFF_SIZE}"
}

run_auto_review() {
  render_prompt "${PROMPTS_DIR}/auto-review.md.tmpl" "${AUTO_PROMPT_FILE}" \
    --var "REPO=${REPO}" \
    --var "PR_NUMBER=${PR_NUMBER}" \
    --var "PR_URL=${PR_URL}" \
    --var "PR_TITLE=${PR_TITLE}" \
    --var "PR_AUTHOR=${PR_AUTHOR}" \
    --var "BASE_REF=${BASE_REF}" \
    --var "HEAD_REF=${HEAD_REF}" \
    --var "HEAD_SHA=${HEAD_SHA}" \
    --var "EVENT_NAME=${EVENT_NAME}" \
    --var "COMMENTER=${COMMENTER}" \
    --var "CHANGED_FILES=${CHANGED_FILES}" \
    --var "SUMMARY_ONLY=${SUMMARY_ONLY}"

  run_review_pipeline "${AUTO_PROMPT_FILE}" "${EVENT_NAME}"
  submit_review_with_fallback "pull request review" "review submitted successfully" "review submission failed, falling back to summary comment"
}

run_mention_reply() {
  local comment_body comment_url comment_path comment_line comment_diff_hunk comment_in_reply_to_id thread_reply_target_id request_text

  if [[ -z "${COMMENT_ID}" ]]; then
    echo "[ERROR] comment_id is required for mention-triggered runs" >&2
    exit 1
  fi

  echo "[INFO] fetching mention context"
  case "${EVENT_NAME}" in
    issue_comment)
      gh api "/repos/${REPO}/issues/comments/${COMMENT_ID}" > "${COMMENT_JSON}"
      ;;
    pull_request_review_comment)
      gh api "/repos/${REPO}/pulls/comments/${COMMENT_ID}" > "${COMMENT_JSON}"
      ;;
    pull_request_review)
      gh api "/repos/${REPO}/pulls/${PR_NUMBER}/reviews/${COMMENT_ID}" > "${COMMENT_JSON}"
      ;;
    *)
      echo "[ERROR] unsupported mention event: ${EVENT_NAME}" >&2
      exit 1
      ;;
  esac

  cp "${COMMENT_JSON}" "${REVIEW_DIR}/comment.json"

  comment_body="$(jq -r '.body // ""' "${COMMENT_JSON}")"
  comment_url="$(jq -r '.html_url // ""' "${COMMENT_JSON}")"
  comment_path="$(jq -r '.path // ""' "${COMMENT_JSON}")"
  comment_line="$(jq -r '(.line // .original_line // "") | tostring' "${COMMENT_JSON}")"
  comment_diff_hunk="$(jq -r '.diff_hunk // ""' "${COMMENT_JSON}")"
  comment_in_reply_to_id="$(jq -r '.in_reply_to_id // ""' "${COMMENT_JSON}")"

  thread_reply_target_id=""
  if [[ "${EVENT_NAME}" == "pull_request_review_comment" ]]; then
    if [[ -n "${comment_in_reply_to_id}" ]]; then
      thread_reply_target_id="${comment_in_reply_to_id}"
    else
      thread_reply_target_id="${COMMENT_ID}"
    fi
  fi

  request_text="$(
    COMMENT_BODY="${comment_body}" python3 - <<'PY'
import os
import re

text = os.environ.get("COMMENT_BODY", "")
text = re.sub(r'(^|[^\S\r\n])@mobilint-review(?=[\s\W]|$)', ' ', text, flags=re.I)
text = re.sub(r'\s+', ' ', text).strip()
print(text)
PY
  )"

  if [[ -z "${request_text}" ]]; then
    request_text="Please review this pull request and respond with the most helpful answer for the requester."
  fi

  render_prompt "${PROMPTS_DIR}/mention-review.md.tmpl" "${MENTION_PROMPT_FILE}" \
    --var "REPO=${REPO}" \
    --var "PR_NUMBER=${PR_NUMBER}" \
    --var "PR_URL=${PR_URL}" \
    --var "PR_TITLE=${PR_TITLE}" \
    --var "PR_AUTHOR=${PR_AUTHOR}" \
    --var "BASE_REF=${BASE_REF}" \
    --var "HEAD_REF=${HEAD_REF}" \
    --var "HEAD_SHA=${HEAD_SHA}" \
    --var "EVENT_NAME=${EVENT_NAME}" \
    --var "COMMENTER=${COMMENTER}" \
    --var "COMMENT_URL=${comment_url}" \
    --var "REQUEST_TEXT=${request_text}" \
    --var "CHANGED_FILES=${CHANGED_FILES}" \
    --var "SUMMARY_ONLY=${SUMMARY_ONLY}" \
    --var "COMMENT_BODY=${comment_body}" \
    --var "COMMENT_PATH=${comment_path}" \
    --var "COMMENT_LINE=${comment_line}" \
    --var "COMMENT_DIFF_HUNK=${comment_diff_hunk}"

  run_review_pipeline \
    "${MENTION_PROMPT_FILE}" \
    "${EVENT_NAME}" \
    "${COMMENTER}" \
    "${comment_url}" \
    "normalizing mention JSON" \
    "filtering mention findings against changed hunks" \
    "building mention review payload"

  if [[ -n "${thread_reply_target_id}" ]]; then
    echo "[INFO] posting mention response as review-thread reply"
    jq -n --arg body "$(cat "${SUMMARY_BODY_FILE}")" '{body: $body}' > "${REPLY_PAYLOAD_FILE}"
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO}/pulls/${PR_NUMBER}/comments/${thread_reply_target_id}/replies" \
      --input "${REPLY_PAYLOAD_FILE}"
    echo "[INFO] mention thread reply posted"
    return 0
  fi

  submit_review_with_fallback "mention review" "mention review submitted successfully" "mention review submission failed, falling back to summary comment"
}

resolve_context
echo "[INFO] repo=${REPO} pr=${PR_NUMBER} event=${EVENT_NAME} mode=${MODE} sandbox_strategy=${SANDBOX_STRATEGY}"
require_commands
fetch_pr_and_checkout
prepare_review_assets

if [[ "${MODE}" == "mention" ]]; then
  run_mention_reply
else
  run_auto_review
fi
