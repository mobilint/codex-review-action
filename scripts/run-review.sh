#!/usr/bin/env bash
set -euo pipefail

REPO="${INPUT_REPO}"
PR_NUMBER="${INPUT_PR_NUMBER}"
EVENT_NAME="${INPUT_EVENT_NAME}"
COMMENTER="${INPUT_COMMENTER:-}"
MAX_FILES="${INPUT_MAX_FILES:-200}"
MAX_DIFF_CHARS="${INPUT_MAX_DIFF_CHARS:-200000}"

WORKDIR="$(mktemp -d)"
REPO_DIR="${WORKDIR}/repo"
REVIEW_DIR="${REPO_DIR}/.codex-review"
export WORKDIR REPO_DIR REVIEW_DIR

cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

cd "${WORKDIR}"

echo "[INFO] repo=${REPO} pr=${PR_NUMBER} event=${EVENT_NAME}"

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
git -C "${REPO_DIR}" remote add origin "https://github.com/${REPO}.git"
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

echo "[INFO] running codex"
(
  cd "${REPO_DIR}"
  codex exec \
    -a never \
    --sandbox read-only \
    --output-last-message "${WORKDIR}/codex_raw_output.txt" \
    "$(cat "${WORKDIR}/review_prompt.md")"
)

if [[ ! -s "${WORKDIR}/codex_raw_output.txt" ]]; then
  echo "[ERROR] Codex did not produce output"
  exit 1
fi

echo "[INFO] normalizing codex JSON"
python3 - <<'PY'
from pathlib import Path
import json
import os
import re

src = Path(os.environ["WORKDIR"]) / "codex_raw_output.txt"
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
    side = item.get("side", "RIGHT")
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
    "## 🤖 Codex review",
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
  exit 0
fi

echo "[WARN] review submission failed, falling back to summary comment"
echo "${REVIEW_RESPONSE}" >&2

gh pr comment "${PR_NUMBER}" \
  --repo "${REPO}" \
  --body-file "${WORKDIR}/summary-body.md"

echo "[INFO] fallback summary comment posted"
