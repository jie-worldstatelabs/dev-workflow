#!/bin/bash

# Dev Workflow Status Update Script
# Updates the status and/or round in the state file.
# Usage: update-status.sh --status <status> [--round <n>]

set -euo pipefail

# Resolve state file (handles CWD drift)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

if ! resolve_state; then
  echo "⚠️  No active dev workflow" >&2
  exit 1
fi

NEW_STATUS=""
NEW_ROUND=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --status)
      NEW_STATUS="$2"
      shift 2
      ;;
    --round)
      NEW_ROUND="$2"
      shift 2
      ;;
    *)
      echo "Warning: unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -n "$NEW_STATUS" ]]; then
  TEMP_FILE="${STATE_FILE}.tmp.$$"
  sed "s/^status: .*/status: $NEW_STATUS/" "$STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"
fi

if [[ -n "$NEW_ROUND" ]]; then
  TEMP_FILE="${STATE_FILE}.tmp.$$"
  sed "s/^round: .*/round: $NEW_ROUND/" "$STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"
fi

# When entering 'executing' status, record baseline commit for the reviewer
if [[ "$NEW_STATUS" == "executing" ]]; then
  TOPIC=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
  ROUND="${NEW_ROUND}"
  if [[ -z "$ROUND" ]]; then
    ROUND=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" | grep '^round:' | sed 's/round: *//')
  fi
  BASELINE_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-baseline"
  git -C "${PROJECT_ROOT}" rev-parse HEAD > "$BASELINE_FILE" 2>/dev/null || echo "EMPTY" > "$BASELINE_FILE"
fi

echo "[dev-workflow] Status updated: ${NEW_STATUS:-unchanged} | Round: ${NEW_ROUND:-unchanged}"
