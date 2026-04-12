#!/bin/bash

# Dev Workflow Status Update Script
# Atomic phase transition: increments epoch, updates status, deletes the new
# stage's output artifact.
#
# The epoch is a monotonically increasing counter that lets the stop hook tell
# fresh artifacts apart from stale ones (agents write the current epoch into
# their artifact's frontmatter).
#
# Usage: update-status.sh --status <status>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

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

# Read current state
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
CURRENT_EPOCH=$(echo "$FRONTMATTER" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]')
if [[ -z "$CURRENT_EPOCH" ]] || ! [[ "$CURRENT_EPOCH" =~ ^[0-9]+$ ]]; then
  CURRENT_EPOCH=0
fi
NEW_EPOCH=$((CURRENT_EPOCH + 1))

# Atomically update status AND epoch
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed -e "s/^status: .*/status: $NEW_STATUS/" \
    -e "s/^epoch: .*/epoch: $NEW_EPOCH/" \
    "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Invalidate the artifact this stage will produce (clean slate for new work).
# With the epoch mechanism this is defense-in-depth — even without deletion,
# stale artifacts would be caught by epoch mismatch. But deletion keeps the
# file system state simple and avoids partial-write edge cases.
# Unified naming: {topic}-{stage}-report.md
case "$NEW_STATUS" in
  executing|verifying|reviewing|qa-ing)
    rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-${NEW_STATUS}-report.md"
    ;;
esac

echo "[dev-workflow] Status: $NEW_STATUS | epoch: $NEW_EPOCH"
