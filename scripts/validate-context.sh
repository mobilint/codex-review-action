#!/usr/bin/env bash

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_review_context() {
  local repo="$1"
  local pr_number="$2"
  local event_name="$3"
  local mode="$4"
  local comment_id="$5"
  local ack_reaction_id="$6"
  local ack_reaction_target="$7"
  local invalid=false

  if ! [[ "${repo}" =~ ^mobilint/[A-Za-z0-9._-]+$ ]]; then
    echo "[ERROR] repo must identify one mobilint repository in owner/name format" >&2
    invalid=true
  fi

  if ! is_positive_integer "${pr_number}"; then
    echo "[ERROR] pr_number must be a positive integer" >&2
    invalid=true
  fi

  case "${event_name}" in
    pull_request|issue_comment|pull_request_review_comment|pull_request_review)
      ;;
    *)
      echo "[ERROR] unsupported event_name: ${event_name:-missing}" >&2
      invalid=true
      ;;
  esac

  case "${mode}" in
    auto|mention)
      ;;
    *)
      echo "[ERROR] mode must be auto or mention" >&2
      invalid=true
      ;;
  esac

  if [[ -n "${comment_id}" ]] && ! is_positive_integer "${comment_id}"; then
    echo "[ERROR] comment_id must be a positive integer when provided" >&2
    invalid=true
  elif [[ "${mode}" == "mention" && -z "${comment_id}" ]]; then
    echo "[ERROR] comment_id is required for mention mode" >&2
    invalid=true
  fi

  if [[ -z "${ack_reaction_id}" && -z "${ack_reaction_target}" ]]; then
    :
  elif [[ -z "${ack_reaction_id}" || -z "${ack_reaction_target}" ]]; then
    echo "[ERROR] ack_reaction_id and ack_reaction_target must be provided together" >&2
    invalid=true
  else
    if ! is_positive_integer "${ack_reaction_id}"; then
      echo "[ERROR] ack_reaction_id must be a positive integer" >&2
      invalid=true
    fi

    case "${ack_reaction_target}" in
      issue)
        ;;
      issue_comment|review_comment)
        if [[ -z "${comment_id}" ]]; then
          echo "[ERROR] comment_id is required for ${ack_reaction_target}" >&2
          invalid=true
        fi
        ;;
      *)
        echo "[ERROR] unsupported ack_reaction_target: ${ack_reaction_target}" >&2
        invalid=true
        ;;
    esac
  fi

  if [[ "${invalid}" == "true" ]]; then
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "$#" -ne 7 ]]; then
    echo "usage: $0 REPO PR_NUMBER EVENT_NAME MODE COMMENT_ID ACK_REACTION_ID ACK_REACTION_TARGET" >&2
    exit 2
  fi
  validate_review_context "$@"
fi
