#!/usr/bin/env bash

normalize_bounded_positive_integer() {
  local value="$1"
  local default_value="$2"
  local maximum="$3"
  local label="$4"

  if ! [[ "${value}" =~ ^[1-9][0-9]*$ ]] ||
    (( ${#value} > ${#maximum} )) ||
    (( value > maximum )); then
    echo "[WARN] ${label} must be a positive integer no greater than ${maximum}; using ${default_value}" >&2
    printf '%s\n' "${default_value}"
    return 0
  fi
  printf '%s\n' "${value}"
}

normalize_boolean() {
  local value="$1"
  local default_value="$2"
  local label="$3"

  case "${value}" in
    true|false)
      printf '%s\n' "${value}"
      ;;
    *)
      echo "[WARN] ${label} must be true or false; using ${default_value}" >&2
      printf '%s\n' "${default_value}"
      ;;
  esac
}

normalize_sandbox_mode() {
  local value="$1"

  case "${value}" in
    read-only|workspace-write|danger-full-access)
      printf '%s\n' "${value}"
      ;;
    *)
      echo "[WARN] sandbox_mode is unsupported; using read-only" >&2
      printf '%s\n' "read-only"
      ;;
  esac
}

normalize_review_runtime_inputs() {
  MAX_FILES="$(
    normalize_bounded_positive_integer \
      "${MAX_FILES}" \
      500 \
      5000 \
      max_files
  )"
  MAX_DIFF_CHARS="$(
    normalize_bounded_positive_integer \
      "${MAX_DIFF_CHARS}" \
      1000000 \
      5000000 \
      max_diff_chars
  )"
  ALLOW_UNSAFE_NO_SANDBOX_FALLBACK="$(
    normalize_boolean \
      "${ALLOW_UNSAFE_NO_SANDBOX_FALLBACK}" \
      false \
      allow_unsafe_no_sandbox_fallback
  )"
  SANDBOX_MODE="$(normalize_sandbox_mode "${SANDBOX_MODE}")"
}

is_codex_sandbox_startup_error() {
  local log_file="$1"
  grep -Eiq 'bwrap: loopback: Failed RTM_NEWADDR|could not find bubblewrap' "${log_file}"
}

verify_pr_head_commit() {
  local repo_dir="$1"
  local ref="$2"
  local expected_sha="$3"
  local actual_sha

  actual_sha="$(git -C "${repo_dir}" rev-parse --verify "${ref}^{commit}" 2>/dev/null)" || {
    echo "[ERROR] fetched PR head ref is not a commit" >&2
    return 1
  }
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "[ERROR] fetched PR head does not match the metadata head SHA" >&2
    return 1
  fi
}
