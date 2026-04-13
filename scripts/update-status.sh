#!/bin/bash

# Dev Workflow Status Update Script
# Atomic phase transition: validates required inputs, increments epoch,
# updates status, and deletes the new stage's output artifact.
#
# The state machine shape is declared in workflow.json (stages, transitions,
# required inputs). This script is the only legitimate way to change status.
#
# Usage: update-status.sh --status <status>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

if ! config_check; then
  exit 1
fi

if ! resolve_state; then
  echo "⚠️  No active dev workflow" >&2
  exit 1
fi

NEW_STATUS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --status)
      NEW_STATUS="$2"
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

# Validate: the new status must be either an active stage or a terminal stage.
if ! config_is_stage "$NEW_STATUS" && ! config_is_terminal "$NEW_STATUS"; then
  echo "❌ Unknown status: '$NEW_STATUS'" >&2
  echo "   Valid stages: $(config_all_stages | tr '\n' ' ')" >&2
  echo "   Terminal stages: $(config_terminal_stages | tr '\n' ' ')" >&2
  exit 1
fi

# Read current state
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
CURRENT_EPOCH=$(echo "$FRONTMATTER" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]')
if [[ -z "$CURRENT_EPOCH" ]] || ! [[ "$CURRENT_EPOCH" =~ ^[0-9]+$ ]]; then
  CURRENT_EPOCH=0
fi
NEW_EPOCH=$((CURRENT_EPOCH + 1))

# ──────────────────────────────────────────────────────────────
# Validate required inputs for the new stage (state-machine constraint)
# A required input from stage X means: {topic}-X-report.md MUST exist
# before the target stage is allowed to start.
# Terminal stages have no inputs to validate.
# ──────────────────────────────────────────────────────────────
if config_is_stage "$NEW_STATUS"; then
  MISSING_INPUTS=()
  while IFS=$'\t' read -r from_stage description; do
    [[ -z "$from_stage" ]] && continue
    input_path="$(config_artifact_path "$from_stage" "$TOPIC" "$PROJECT_ROOT")"
    if [[ ! -f "$input_path" ]]; then
      MISSING_INPUTS+=("$input_path ($description)")
    fi
  done < <(config_required_inputs "$NEW_STATUS")

  if [[ ${#MISSING_INPUTS[@]} -gt 0 ]]; then
    echo "❌ Cannot transition to '$NEW_STATUS': required inputs missing:" >&2
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

# Invalidate the artifact the new stage will produce (only active stages have artifacts).
if config_is_stage "$NEW_STATUS"; then
  NEW_ARTIFACT="$(config_artifact_path "$NEW_STATUS" "$TOPIC" "$PROJECT_ROOT")"
  rm -f "$NEW_ARTIFACT"
fi

echo "[dev-workflow] Status: $NEW_STATUS | epoch: $NEW_EPOCH"
