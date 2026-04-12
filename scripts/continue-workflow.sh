#!/bin/bash

# Dev Workflow Continue Script
# Resumes an interrupted workflow by restoring active status based on artifacts.
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
ROUND=$(echo "$FRONTMATTER" | grep '^round:' | sed 's/round: *//')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')

if [[ "$STATUS" != "interrupted" ]]; then
  echo "⚠️  Workflow is not interrupted (status: $STATUS)." >&2
  echo "   Only interrupted workflows can be continued." >&2
  exit 1
fi

# Derive actual phase from artifacts (same logic as stop-hook.sh)
REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-report.md"
VERIFY_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-verify.md"
REVIEW_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-review.md"
QA_REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md"

if [[ -f "$QA_REPORT_FILE" ]]; then
  RESUME_STATUS="gating"
elif [[ -f "$REVIEW_FILE" ]]; then
  # Check reviewer verdict: PASS → qa-ing (QA not yet run), FAIL/ambiguous → gating
  if grep -q 'VERDICT: PASS' "$REVIEW_FILE" 2>/dev/null; then
    RESUME_STATUS="qa-ing"
  else
    RESUME_STATUS="gating"
  fi
elif [[ -f "$VERIFY_FILE" ]]; then
  RESUME_STATUS="reviewing"
elif [[ -f "$REPORT_FILE" ]]; then
  RESUME_STATUS="verifying"
else
  RESUME_STATUS="executing"
fi

# Restore active status
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^status: .*/status: $RESUME_STATUS/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

echo "▶️  Dev workflow resumed."
echo ""
echo "   Topic:  $TOPIC"
echo "   Round:  $ROUND"
echo "   Phase:  $RESUME_STATUS"
echo "   Plan:   $PLAN_FILE"
echo ""
echo "   The stop hook is now active again."
echo "   To interrupt again: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
