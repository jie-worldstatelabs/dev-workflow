#!/bin/bash

# Dev Workflow Interrupt Script
# Pauses the loop at the current round WITHOUT clearing state.
# Resume with: /dev-workflow:continue
# Cancel entirely with: /dev-workflow:cancel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

if ! resolve_state; then
  echo "No active dev workflow." >&2
  exit 1
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
ROUND=$(echo "$FRONTMATTER" | grep '^round:' | sed 's/round: *//')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')

if [[ "$STATUS" == "interrupted" ]]; then
  echo "⚠️  Workflow is already interrupted (round $ROUND, topic: $TOPIC)." >&2
  echo "   Resume with: /dev-workflow:continue" >&2
  echo "   Cancel with: /dev-workflow:cancel" >&2
  exit 0
fi

if [[ "$STATUS" == "complete" ]] || [[ "$STATUS" == "escalated" ]]; then
  echo "⚠️  Workflow already finished (status: $STATUS)." >&2
  exit 1
fi

TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^status: .*/status: interrupted/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

echo "⏸️  Dev workflow interrupted."
echo ""
echo "   Topic: $TOPIC"
echo "   Round: $ROUND"
echo "   State preserved at: $STATE_FILE"
echo ""
echo "   Resume with: /dev-workflow:continue"
echo "   Cancel entirely with: /dev-workflow:cancel"
