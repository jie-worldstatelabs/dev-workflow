#!/bin/bash

# Dev Workflow Continue Script
# Resumes an interrupted workflow by restoring the saved resume_status.
# Only works when status is "interrupted" — use /dev-workflow:dev for a fresh start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

if ! resolve_state; then
  echo "No interrupted dev workflow found." >&2
  echo "Start a new workflow with: /dev-workflow:dev <task>" >&2
  exit 1
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')
RESUME_STATUS=$(echo "$FRONTMATTER" | grep '^resume_status:' | sed 's/resume_status: *//')

if [[ "$STATUS" != "interrupted" ]]; then
  echo "⚠️  Workflow is not interrupted (status: $STATUS)." >&2
  echo "   Only interrupted workflows can be continued." >&2
  exit 1
fi

# Fall back to executing if resume_status was not saved (e.g. older state files)
if [[ -z "$RESUME_STATUS" ]]; then
  RESUME_STATUS="executing"
fi

# Restore active status and clear resume_status
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^status: .*/status: $RESUME_STATUS/" "$STATE_FILE" | \
  sed "s/^resume_status: .*/resume_status:/" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

echo "▶️  Dev workflow resumed."
echo ""
echo "   Topic:  $TOPIC"
echo "   Phase:  $RESUME_STATUS"
echo "   Plan:   $PLAN_FILE"
echo ""
echo "   The stop hook is now active again."
echo "   To interrupt again: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
