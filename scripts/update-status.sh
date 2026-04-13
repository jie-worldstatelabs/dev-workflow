#!/bin/bash

# Dev Workflow Status Update Script
# Atomic phase transition: validates required inputs, increments epoch,
# updates status, and deletes the new stage's output artifact.
#
# Resolves which workflow to operate on (multiple topics may coexist):
#   --topic <name>           explicit
#   $CLAUDE_CODE_SESSION_ID  falls back to session routing
#   else                     if exactly one active workflow exists, use it
#
# Usage: update-status.sh --status <status> [--topic <topic>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NEW_STATUS=""
TOPIC_ARG=""
RUN_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --status)
      NEW_STATUS="$2"
      shift 2
      ;;
    --topic)
      TOPIC_ARG="$2"
      shift 2
      ;;
    --run)
      RUN_ARG="$2"
      shift 2
      ;;
    *)
      echo "Warning: unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -z "$NEW_STATUS" ]]; then
  echo "⚠️  --status is required" >&2
  exit 1
fi

# Route to the right state.md
if [[ -n "$RUN_ARG" ]]; then
  DESIRED_RUN_ID="$RUN_ARG"
elif [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  DESIRED_SESSION="$CLAUDE_CODE_SESSION_ID"
fi

if ! resolve_state; then
  echo "⚠️  Could not resolve an active dev workflow" >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  else
    echo "   No workflows found. Run /dev-workflow:dev to start one." >&2
  fi
  exit 1
fi

resolve_workflow_dir_from_state

if ! config_check; then
  exit 1
fi

# Validate: the new status must be either an active stage or a terminal stage.
if ! config_is_stage "$NEW_STATUS" && ! config_is_terminal "$NEW_STATUS"; then
  echo "❌ Unknown status: '$NEW_STATUS'" >&2
  echo "   Valid stages: $(config_all_stages | tr '\n' ' ')" >&2
  echo "   Terminal stages: $(config_terminal_stages | tr '\n' ' ')" >&2
  exit 1
fi

# Read current state
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
CURRENT_EPOCH=$(echo "$FRONTMATTER" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]')
if [[ -z "$CURRENT_EPOCH" ]] || ! [[ "$CURRENT_EPOCH" =~ ^[0-9]+$ ]]; then
  CURRENT_EPOCH=0
fi
NEW_EPOCH=$((CURRENT_EPOCH + 1))

# ──────────────────────────────────────────────────────────────
# Validate required inputs for the new stage
# ──────────────────────────────────────────────────────────────
if config_is_stage "$NEW_STATUS"; then
  MISSING_INPUTS=()
  while IFS=$'\t' read -r from_stage description; do
    [[ -z "$from_stage" ]] && continue
    input_path="$(config_artifact_path "$from_stage" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    if [[ ! -f "$input_path" ]]; then
      MISSING_INPUTS+=("$input_path ($description)")
    fi
  done < <(config_required_inputs "$NEW_STATUS")

  if [[ ${#MISSING_INPUTS[@]} -gt 0 ]]; then
    echo "❌ Cannot transition to '$NEW_STATUS' for topic '$TOPIC': required inputs missing:" >&2
    for m in "${MISSING_INPUTS[@]}"; do
      echo "   - $m" >&2
    done
    echo "" >&2
    echo "   (required inputs are declared in workflow.json → stages.$NEW_STATUS.inputs.required)" >&2
    exit 1
  fi
fi

# Atomically update status AND epoch
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed -e "s/^status: .*/status: $NEW_STATUS/" \
    -e "s/^epoch: .*/epoch: $NEW_EPOCH/" \
    "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Invalidate the artifact the new stage will produce
if config_is_stage "$NEW_STATUS"; then
  NEW_ARTIFACT="$(config_artifact_path "$NEW_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
  rm -f "$NEW_ARTIFACT"
fi

echo "[dev-workflow] Topic: $TOPIC | Status: $NEW_STATUS | epoch: $NEW_EPOCH"

if config_is_stage "$NEW_STATUS"; then
  config_show_stage_context "$NEW_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT"
fi
