#!/bin/bash

# Dev Workflow Status Update Script
# Updates the status and/or round in the state file.
# Usage: update-status.sh --status <status> [--round <n>]

set -euo pipefail

STATE_FILE=".claude/dev-workflow.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
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

echo "[dev-workflow] Status updated: ${NEW_STATUS:-unchanged} | Round: ${NEW_ROUND:-unchanged}"
