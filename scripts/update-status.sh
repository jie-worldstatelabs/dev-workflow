#!/bin/bash

# Dev Workflow Status Update Script
# Updates the status in the state file and invalidates the current stage's output artifact.
# Usage: update-status.sh --status <status>

set -euo pipefail

# Resolve state file (handles CWD drift)
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

# Read topic from state file
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')

# Update status in state file
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^status: .*/status: $NEW_STATUS/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Invalidate the artifact this stage will produce (lazy deletion).
# This is the source of truth for phase detection in the stop hook:
#   entering executing → delete report.md  (stop hook sees: no report = executing)
#   entering verifying → delete verify.md  (stop hook sees: report but no verify = verifying)
#   entering reviewing → delete review.md  (stop hook sees: verify but no review = reviewing)
#   entering qa-ing    → delete qa-report  (stop hook sees: review PASS, no qa-report = qa-ing)
# Other stages (gating, complete, etc.) produce no artifact, so no deletion needed.
case "$NEW_STATUS" in
  executing)
    rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-report.md"
    ;;
  verifying)
    rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verify.md"
    ;;
  reviewing)
    rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-review.md"
    ;;
  qa-ing)
    rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-report.md"
    ;;
esac

echo "[dev-workflow] Status updated: $NEW_STATUS"
