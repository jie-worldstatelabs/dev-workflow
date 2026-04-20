#!/bin/bash
#
# next-status.sh — resolve the next stage given the current stage's
# artifact `result:` value. Replaces the `jq ... "<workflow_dir>/
# workflow.json"` one-liner that SKILL.md used to ask the main agent
# to write by hand (that pattern broke on frontmatter quote handling).
#
# Usage:
#   next-status.sh --result <R> [--topic <name>]
#
# Output (JSON):
#   {
#     "next_status": "<stage or terminal name>",
#     "is_terminal": <bool>,
#     "next_artifact_path": "<abs path>"
#   }
#
# `next_artifact_path` is the canonical output location for whichever
# agent/subagent will run the next stage — OR, if `is_terminal: true`,
# the location where the main agent should write a run-summary report
# before calling update-status.sh --status <terminal>. update-status.sh
# synthesises a mechanical fallback if the file is missing, but a
# human-written summary is strongly preferred.
#
# Non-zero exit with a diagnostic on stderr when:
#   - --result is missing
#   - no active workflow is resolvable
#   - the workflow config is invalid
#   - the result key is not in the current stage's transition table

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

RESULT=""
TOPIC_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --result=*) RESULT="${1#--result=}";  shift ;;
    --result)   RESULT="$2";              shift 2 ;;
    --topic=*)  TOPIC_ARG="${1#--topic=}"; shift ;;
    --topic)    TOPIC_ARG="$2";           shift 2 ;;
    *)
      echo "Warning: unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -z "$RESULT" ]]; then
  echo "❌ next-status: --result is required" >&2
  exit 1
fi

if [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
fi

if ! resolve_state; then
  echo "❌ next-status: no active workflow" >&2
  exit 1
fi
resolve_workflow_dir_from_state
if ! config_check; then
  echo "❌ next-status: workflow config invalid" >&2
  exit 1
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
if [[ -z "$STATUS" ]]; then
  echo "❌ next-status: state.md has no status" >&2
  exit 1
fi
if ! config_is_stage "$STATUS"; then
  echo "❌ next-status: current status '$STATUS' is not an active stage" >&2
  exit 1
fi

NEXT=$(config_next_status "$STATUS" "$RESULT")
if [[ -z "$NEXT" ]]; then
  echo "❌ next-status: result '$RESULT' not in transition table for stage '$STATUS'" >&2
  echo "   valid result keys: $(config_transition_keys "$STATUS" | tr '\n' ' ')" >&2
  exit 1
fi

IS_TERM=false
is_terminal_status "$NEXT" && IS_TERM=true

NEXT_PATH=$(config_artifact_path "$NEXT" "$RUN_DIR_NAME" "$PROJECT_ROOT")

jq -n \
  --arg ns "$NEXT" \
  --argjson it "$IS_TERM" \
  --arg np "$NEXT_PATH" \
  '{
    next_status: $ns,
    is_terminal: $it,
    next_artifact_path: $np
  }'
