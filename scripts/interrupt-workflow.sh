#!/bin/bash

# Dev Workflow Interrupt Script
# Pauses the loop at the current phase WITHOUT clearing state.
# Resume with: /dev-workflow:continue
# Cancel entirely with: /dev-workflow:cancel
#
# Usage: interrupt-workflow.sh [--topic <name>]
# Routing:
#   --topic <name>           explicit
#   else                     uses the single active workflow if there's exactly one

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --topic)
      TOPIC_ARG="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
fi

if ! resolve_state; then
  echo "No matching active dev workflow." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  fi
  exit 1
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)

if [[ "$STATUS" == "interrupted" ]]; then
  echo "⚠️  Workflow is already interrupted (topic: $TOPIC)." >&2
  echo "   Resume with: /dev-workflow:continue" >&2
  echo "   Cancel with: /dev-workflow:cancel" >&2
  exit 0
fi

if [[ "$STATUS" == "complete" ]] || [[ "$STATUS" == "escalated" ]]; then
  echo "⚠️  Workflow already finished (status: $STATUS)." >&2
  exit 1
fi

# Save current status as resume_status, then set interrupted.
set_fm_field "$STATE_FILE" resume_status "$STATUS"
set_fm_field "$STATE_FILE" status interrupted

echo "⏸️  Dev workflow interrupted."
echo ""
echo "   Topic: $TOPIC"
echo "   Phase: $STATUS (saved as resume_status)"
echo "   State preserved at: $STATE_FILE"
echo ""
echo "   Resume with: /dev-workflow:continue --topic $TOPIC"
echo "   Cancel entirely with: /dev-workflow:cancel --topic $TOPIC"
