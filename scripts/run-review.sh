#!/usr/bin/env bash
set -euo pipefail

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
RESPONSE_BODY_FILE="${WORKDIR}/mention-response-body.md"
REPLY_PAYLOAD_FILE="${WORKDIR}/mention-reply-payload.json"
CODEX_LOG_FILE="${WORKDIR}/codex_exec.log"
FALLBACK_PROMPT_FILE="${WORKDIR}/codex_fallback_prompt.md"
export WORKDIR REPO_DIR REVIEW_DIR COMMENT_JSON RAW_OUTPUT_FILE RESPONSE_BODY_FILE REPLY_PAYLOAD_FILE CODEX_LOG_FILE FALLBACK_PROMPT_FILE

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

cd "${WORKDIR}"

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
  auto|unsandboxed)
    ;;
  *)
    echo "[ERROR] unsupported sandbox strategy: ${SANDBOX_STRATEGY}" >&2
    exit 1
    ;;
esac

echo "[INFO] repo=${REPO} pr=${PR_NUMBER} event=${EVENT_NAME} mode=${MODE} sandbox_strategy=${SANDBOX_STRATEGY}"

for cmd in gh git jq python3 codex; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERROR] ${cmd} not found"
    exit 1
  }
done

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
GH_AUTH_HEADER="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 | tr -d '\n')"
git -C "${REPO_DIR}" -c "http.extraheader=${GH_AUTH_HEADER}" fetch --depth=50 "https://github.com/${REPO}.git" "${BASE_REF}"
git -C "${REPO_DIR}" checkout -B base FETCH_HEAD >/dev/null 2>&1 || {
  echo "[ERROR] failed to checkout base branch ${BASE_REF}" >&2
  exit 1
}

echo "[INFO] fetching PR head"
git -C "${REPO_DIR}" -c "http.extraheader=${GH_AUTH_HEADER}" fetch --depth=50 "https://github.com/${REPO}.git" "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
git -C "${REPO_DIR}" checkout "pr-${PR_NUMBER}" >/dev/null 2>&1 || {
  echo "[ERROR] failed to checkout PR head branch pr-${PR_NUMBER}" >&2
  exit 1
}

MERGE_BASE="$(git -C "${REPO_DIR}" merge-base base "pr-${PR_NUMBER}" || true)"
if [[ -z "${MERGE_BASE}" ]]; then
  echo "[WARN] merge-base not found from shallow fetch, retrying with full history"
  git -C "${REPO_DIR}" -c "http.extraheader=${GH_AUTH_HEADER}" fetch --unshallow "https://github.com/${REPO}.git" "${BASE_REF}" || git -C "${REPO_DIR}" -c "http.extraheader=${GH_AUTH_HEADER}" fetch "https://github.com/${REPO}.git" "${BASE_REF}"
  git -C "${REPO_DIR}" -c "http.extraheader=${GH_AUTH_HEADER}" fetch "https://github.com/${REPO}.git" "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
  MERGE_BASE="$(git -C "${REPO_DIR}" merge-base base "pr-${PR_NUMBER}" || true)"
fi

if [[ -z "${MERGE_BASE}" ]]; then
  echo "[ERROR] failed to compute merge-base for base=${BASE_REF} pr=${PR_NUMBER}" >&2
  git -C "${REPO_DIR}" show-ref >&2 || true
  exit 1
fi

echo "[INFO] merge_base=${MERGE_BASE} head_sha=${HEAD_SHA}"

echo "[INFO] collecting diff and changed-line metadata"
git -C "${REPO_DIR}" diff --find-renames --name-only "${MERGE_BASE}" HEAD > "${WORKDIR}/changed-files.txt"
git -C "${REPO_DIR}" diff --find-renames --unified=3 "${MERGE_BASE}" HEAD > "${WORKDIR}/pr.diff"
git -C "${REPO_DIR}" diff --find-renames --unified=0 "${MERGE_BASE}" HEAD > "${WORKDIR}/pr-zero.diff"

CHANGED_FILES="$(python3 - <<'PY'
from pathlib import Path

lines = [
    line for line in Path("changed-files.txt").read_text(encoding="utf-8", errors="ignore").splitlines()
    if line.strip()
]
print(len(lines))
PY
)"

DIFF_SIZE="$(wc -c < "${WORKDIR}/pr.diff" | tr -d ' ')"
SUMMARY_ONLY="false"

if [[ "${CHANGED_FILES}" -gt "${MAX_FILES}" ]]; then
  SUMMARY_ONLY="true"
fi

if [[ "${DIFF_SIZE}" -gt "${MAX_DIFF_CHARS}" ]]; then
  SUMMARY_ONLY="true"
  python3 - <<'PY'
from pathlib import Path
import os

p = Path("pr.diff")
text = p.read_text(encoding="utf-8", errors="ignore")
limit = int(os.environ.get("INPUT_MAX_DIFF_CHARS", "200000"))
p.write_text(text[:limit] + "\n\n[TRUNCATED_DIFF]\n", encoding="utf-8")
PY
fi

mkdir -p "${REVIEW_DIR}"
cp "${WORKDIR}/pr.json" "${REVIEW_DIR}/pr.json"
cp "${WORKDIR}/pr.diff" "${REVIEW_DIR}/pr.diff"
cp "${WORKDIR}/changed-files.txt" "${REVIEW_DIR}/changed-files.txt"

python3 - <<'PY'
from pathlib import Path
import json
import os
import re

patch_path = Path(os.environ["WORKDIR"]) / "pr-zero.diff"
output_path = Path(os.environ["REVIEW_DIR"]) / "changed-lines.json"

hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
current_path = None
changed_lines = {}

for raw_line in patch_path.read_text(encoding="utf-8", errors="ignore").splitlines():
    if raw_line.startswith("+++ /dev/null"):
        current_path = None
        continue
    if raw_line.startswith("+++ b/"):
        current_path = raw_line[6:]
        changed_lines.setdefault(current_path, set())
        continue
    match = hunk_re.match(raw_line)
    if match and current_path:
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        if count > 0:
            changed_lines.setdefault(current_path, set()).update(range(start, start + count))

output_path.write_text(
    json.dumps({path: sorted(lines) for path, lines in changed_lines.items()}, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

echo "[INFO] changed_files=${CHANGED_FILES} summary_only=${SUMMARY_ONLY} diff_size=${DIFF_SIZE}"

run_codex() {
  local prompt_file="$1"
  local output_file="$2"
  local codex_exit=0
  local sandbox_failure_detected="false"
  local retried_without_sandbox="false"
  local started_unsandboxed="false"

  echo "[INFO] running codex"

  cat > "${FALLBACK_PROMPT_FILE}" <<EOF
Runner note:
- This self-hosted review runner may execute Codex without its built-in sandbox.
- Do not modify files, install dependencies, or access the network.
- Do not use MCP connectors or web tools.
- Restrict yourself to reading the checked-out repository and .codex-review assets only.

$(cat "${prompt_file}")
EOF

  if [[ "${SANDBOX_STRATEGY}" == "auto" ]]; then
    rm -f "${output_file}"
    : > "${CODEX_LOG_FILE}"
    set +e
    (
      cd "${REPO_DIR}"
      codex exec \
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
}

run_auto_review() {
  cat > "${WORKDIR}/review_prompt.md" <<EOF
You are reviewing a GitHub pull request.

Context:
- Repository: ${REPO}
- Pull Request: #${PR_NUMBER}
- URL: ${PR_URL}
- Title: ${PR_TITLE}
- Author: ${PR_AUTHOR}
- Base branch: ${BASE_REF}
- Head branch: ${HEAD_REF}
- Head SHA: ${HEAD_SHA}
- Trigger: ${EVENT_NAME}
- Requested by commenter: ${COMMENTER}
- Changed files: ${CHANGED_FILES}
- Summary only mode: ${SUMMARY_ONLY}

You are running in the checked-out PR working tree.

Review assets are available in .codex-review/:
- .codex-review/pr.json: GitHub PR metadata
- .codex-review/pr.diff: unified diff for this PR update
- .codex-review/changed-files.txt: changed file paths
- .codex-review/changed-lines.json: valid new-file line numbers for inline comments

Your task:
1. Review the checked-out code and the review assets in .codex-review/.
2. Focus on correctness, reliability, security, performance, maintainability, and missing tests.
3. Prefer high-signal findings with direct evidence.
4. Do not invent issues.
5. If there are no meaningful findings, say so clearly.
6. Use a few tasteful emoji in the summary.
7. Do not use MCP connectors, web tools, or network access. Use only the checked-out repository and .codex-review assets.

IMPORTANT OUTPUT REQUIREMENTS:
- Output MUST be valid JSON only.
- Do not wrap output in markdown fences.
- Follow this schema exactly:

{
  "verdict": "<short markdown paragraph>",
  "findings": [
    {
      "path": "relative/file/path.ext",
      "line": 123,
      "side": "RIGHT",
      "severity": "high|medium|low",
      "title": "Short title",
      "body": "Concrete review comment in markdown"
    }
  ],
  "suggested_next_steps": [
    "step 1",
    "step 2"
  ]
}

Rules for findings:
- Only include a finding when you have strong evidence from the diff or checked-out code.
- Prefer at most 8 findings.
- Use side "RIGHT".
- The "line" must be the line number in the new file version.
- Only use file paths listed in .codex-review/changed-files.txt.
- Only use line numbers present for that file in .codex-review/changed-lines.json.
- If summary_only mode is true, you may return an empty findings list and focus on verdict plus suggested_next_steps.
EOF

  run_codex "${WORKDIR}/review_prompt.md" "${RAW_OUTPUT_FILE}"

  echo "[INFO] normalizing codex JSON"
  python3 - <<'PY'
from pathlib import Path
import json
import os
import re

src = Path(os.environ["RAW_OUTPUT_FILE"])
text = src.read_text(encoding="utf-8", errors="ignore").strip()

def extract_json(raw_text: str) -> str:
    raw_text = raw_text.strip()
    if raw_text.startswith("{") and raw_text.endswith("}"):
        return raw_text
    match = re.search(r"\{.*\}", raw_text, re.S)
    if match:
        return match.group(0)
    raise ValueError("No JSON object found")

obj = json.loads(extract_json(text))
obj.setdefault("verdict", "No verdict provided.")
obj.setdefault("findings", [])
obj.setdefault("suggested_next_steps", [])

if not isinstance(obj["findings"], list):
    obj["findings"] = []
if not isinstance(obj["suggested_next_steps"], list):
    obj["suggested_next_steps"] = []

(Path(os.environ["WORKDIR"]) / "review.json").write_text(
    json.dumps(obj, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

  echo "[INFO] filtering findings against changed hunks"
  python3 - <<'PY'
from pathlib import Path
import json
import os

workdir = Path(os.environ["WORKDIR"])
review_dir = Path(os.environ["REVIEW_DIR"])

review = json.loads((workdir / "review.json").read_text(encoding="utf-8"))
changed_files = {
    line.strip()
    for line in (review_dir / "changed-files.txt").read_text(encoding="utf-8", errors="ignore").splitlines()
    if line.strip()
}
changed_lines = {
    path: set(lines)
    for path, lines in json.loads((review_dir / "changed-lines.json").read_text(encoding="utf-8")).items()
}

def valid_line(value):
    return isinstance(value, int) and value > 0

filtered = []
for item in review.get("findings", []):
    path = item.get("path")
    line = item.get("line")
    title = item.get("title", "").strip()
    body = item.get("body", "").strip()

    if path not in changed_files:
      continue
    if not valid_line(line):
      continue
    if line not in changed_lines.get(path, set()):
      continue
    if not body:
      continue

    if title:
        body = f"**{title}**\n\n{body}"

    filtered.append({
        "path": path,
        "line": line,
        "side": "RIGHT",
        "body": body,
    })

review["findings"] = filtered[:8]
(workdir / "review.filtered.json").write_text(
    json.dumps(review, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
PY

  echo "[INFO] building review payload"
  python3 - <<'PY'
from pathlib import Path
import json
import os

workdir = Path(os.environ["WORKDIR"])
review = json.loads((workdir / "review.filtered.json").read_text(encoding="utf-8"))

verdict = review.get("verdict", "").strip()
steps = review.get("suggested_next_steps", [])
findings = review.get("findings", [])

body_lines = [
    "## Codex review",
    "",
    "## Verdict",
    verdict if verdict else "No meaningful findings.",
    "",
    "## Suggested next steps",
]

if steps:
    for step in steps:
        body_lines.append(f"- {step}")
else:
    body_lines.append("- No additional next steps.")

body_lines.extend([
    "",
    "---",
    f"_Trigger: {os.environ.get('INPUT_EVENT_NAME', '')}_",
])

payload = {
    "body": "\n".join(body_lines),
    "event": "COMMENT",
    "comments": findings,
}

(workdir / "review-payload.json").write_text(
    json.dumps(payload, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
(workdir / "summary-body.md").write_text(payload["body"], encoding="utf-8")
PY

  echo "[INFO] attempting pull request review submission"
  set +e
  REVIEW_RESPONSE=$(
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
      --input "${WORKDIR}/review-payload.json" 2>&1
  )
  REVIEW_EXIT=$?
  set -e

  if [[ ${REVIEW_EXIT} -eq 0 ]]; then
    echo "[INFO] review submitted successfully"
    return 0
  fi

  echo "[WARN] review submission failed, falling back to summary comment"
  echo "${REVIEW_RESPONSE}" >&2

  gh pr comment "${PR_NUMBER}" \
    --repo "${REPO}" \
    --body-file "${WORKDIR}/summary-body.md"

  echo "[INFO] fallback summary comment posted"
}

run_mention_reply() {
  local comment_body comment_url comment_path comment_line comment_diff_hunk comment_in_reply_to_id request_text

  if [[ -z "${COMMENT_ID}" ]]; then
    echo "[ERROR] comment_id is required for mention-triggered runs" >&2
    exit 1
  fi

  echo "[INFO] fetching mention context"
  if [[ "${EVENT_NAME}" == "issue_comment" ]]; then
    gh api "/repos/${REPO}/issues/comments/${COMMENT_ID}" > "${COMMENT_JSON}"
  elif [[ "${EVENT_NAME}" == "pull_request_review_comment" ]]; then
    gh api "/repos/${REPO}/pulls/comments/${COMMENT_ID}" > "${COMMENT_JSON}"
  elif [[ "${EVENT_NAME}" == "pull_request_review" ]]; then
    gh api "/repos/${REPO}/pulls/${PR_NUMBER}/reviews/${COMMENT_ID}" > "${COMMENT_JSON}"
  else
    echo "[ERROR] unsupported mention event: ${EVENT_NAME}" >&2
    exit 1
  fi

  cp "${COMMENT_JSON}" "${REVIEW_DIR}/comment.json"

  comment_body="$(jq -r '.body // ""' "${COMMENT_JSON}")"
  comment_url="$(jq -r '.html_url // ""' "${COMMENT_JSON}")"
  comment_path="$(jq -r '.path // ""' "${COMMENT_JSON}")"
  comment_line="$(jq -r '(.line // .original_line // "") | tostring' "${COMMENT_JSON}")"
  comment_diff_hunk="$(jq -r '.diff_hunk // ""' "${COMMENT_JSON}")"
  comment_in_reply_to_id="$(jq -r '.in_reply_to_id // ""' "${COMMENT_JSON}")"

  export MENTION_COMMENT_URL="${comment_url}"
  if [[ "${EVENT_NAME}" == "pull_request_review_comment" && -z "${comment_in_reply_to_id}" ]]; then
    export MENTION_CAN_THREAD_REPLY="true"
  else
    export MENTION_CAN_THREAD_REPLY="false"
  fi

  request_text="$(COMMENT_BODY="${comment_body}" python3 - <<'PY'
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

  cat > "${WORKDIR}/mention_prompt.md" <<EOF
You are responding to a GitHub pull request discussion item that mentioned @mobilint-review.

Context:
- Repository: ${REPO}
- Pull Request: #${PR_NUMBER}
- URL: ${PR_URL}
- Title: ${PR_TITLE}
- Author: ${PR_AUTHOR}
- Base branch: ${BASE_REF}
- Head branch: ${HEAD_REF}
- Head SHA: ${HEAD_SHA}
- Trigger: ${EVENT_NAME}
- Source author: ${COMMENTER}
- Source URL: ${comment_url}
- Parsed request: ${request_text}
- Changed files: ${CHANGED_FILES}
- Summary only mode: ${SUMMARY_ONLY}

Original source body:
${comment_body}

Review-thread metadata:
- Path: ${comment_path}
- Line: ${comment_line}
- Diff hunk:
${comment_diff_hunk}

You are running in the checked-out PR working tree.

Relevant assets are available in .codex-review/:
- .codex-review/pr.json: GitHub PR metadata
- .codex-review/pr.diff: unified diff for this PR update
- .codex-review/changed-files.txt: changed file paths
- .codex-review/changed-lines.json: valid new-file line numbers for inline comments
- .codex-review/comment.json: raw source discussion metadata

Your task:
1. Understand what the requester is asking for from the original source body and parsed request.
2. Use the checked-out code and review assets to answer the request helpfully.
3. If the request is to review the PR or a specific change, include only findings you can support from the code or diff.
4. If the request is about a review thread, focus on that file and hunk first.
5. If you need to make an inference, say that it is an inference.
6. Do not claim to have changed code or run commands.
7. Do not use MCP connectors, web tools, or network access. Use only the checked-out repository and .codex-review assets.

Output requirements:
- Output markdown only.
- Do not use JSON.
- Keep the reply concise but useful.
- If there are no meaningful findings, say so clearly.
EOF

  run_codex "${WORKDIR}/mention_prompt.md" "${RAW_OUTPUT_FILE}"

  python3 - <<'PY'
from pathlib import Path
import os

raw_text = Path(os.environ["RAW_OUTPUT_FILE"]).read_text(encoding="utf-8", errors="ignore").strip()
commenter = os.environ.get("INPUT_COMMENTER", "").strip()
comment_url = os.environ.get("MENTION_COMMENT_URL", "").strip()
event_name = os.environ.get("INPUT_EVENT_NAME", "").strip()

body_lines = []
if event_name == "issue_comment":
    if commenter:
        body_lines.append(f"@{commenter}")
        body_lines.append("")
    if comment_url:
        body_lines.append(f"Replying to [the request]({comment_url}).")
        body_lines.append("")
elif event_name == "pull_request_review":
    if commenter:
        body_lines.append(f"@{commenter}")
        body_lines.append("")
    if comment_url:
        body_lines.append(f"Replying to [the review]({comment_url}).")
        body_lines.append("")
elif event_name == "pull_request_review_comment" and os.environ.get("MENTION_CAN_THREAD_REPLY", "false") != "true":
    if commenter:
        body_lines.append(f"@{commenter}")
        body_lines.append("")
    if comment_url:
        body_lines.append(f"Replying here because GitHub review-comment replies cannot nest beyond the top-level thread: [source comment]({comment_url}).")
        body_lines.append("")

body_lines.append(raw_text if raw_text else "I could not produce a meaningful response.")
body_lines.extend([
    "",
    "---",
    f"_Trigger: {event_name}_",
])

Path(os.environ["RESPONSE_BODY_FILE"]).write_text("\n".join(body_lines), encoding="utf-8")
PY

  if [[ "${EVENT_NAME}" == "pull_request_review_comment" && -z "${comment_in_reply_to_id}" ]]; then
    echo "[INFO] replying directly to review thread"
    jq -n --arg body "$(cat "${RESPONSE_BODY_FILE}")" '{body: $body}' > "${REPLY_PAYLOAD_FILE}"
    gh api \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
      --input "${REPLY_PAYLOAD_FILE}"
  else
    echo "[INFO] posting mention response as PR comment"
    gh pr comment "${PR_NUMBER}" \
      --repo "${REPO}" \
      --body-file "${RESPONSE_BODY_FILE}"
  fi
}

if [[ "${MODE}" == "mention" ]]; then
  run_mention_reply
else
  run_auto_review
fi
