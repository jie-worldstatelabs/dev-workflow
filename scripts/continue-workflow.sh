#!/bin/bash

# Dev Workflow Continue Script
# Resumes an interrupted workflow by restoring the saved resume_status.
# Only works when status is "interrupted" — use /dev-workflow:dev for a fresh start.
#
# Usage: continue-workflow.sh [--topic <name>]

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

# For continue, we want to find an INTERRUPTED workflow. If --topic given,
# use it. Otherwise, look for one owned by this session (interrupted ones
# included via second-pass in resolve_state), or the single one in the dir.
if [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
  DESIRED_SESSION="$CLAUDE_CODE_SESSION_ID"
fi

if ! resolve_state; then
  echo "No interrupted dev workflow found." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  else
    echo "   Start a new workflow with: /dev-workflow:dev <task>" >&2
  fi
  exit 1
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
RESUME_STATUS=$(echo "$FRONTMATTER" | grep '^resume_status:' | sed 's/resume_status: *//')

if [[ "$STATUS" != "interrupted" ]]; then
  echo "⚠️  Workflow '$TOPIC' is not interrupted (status: $STATUS)." >&2
  echo "   Only interrupted workflows can be continued." >&2
  exit 1
fi

# Fall back to executing if resume_status was not saved
if [[ -z "$RESUME_STATUS" ]]; then
  RESUME_STATUS="executing"
fi

# Restore active status and clear resume_status
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^status: .*/status: $RESUME_STATUS/" "$STATE_FILE" | \
  sed "s/^resume_status:.*$/resume_status:/" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

echo "▶️  Dev workflow resumed."
echo ""
echo "   Topic:  $TOPIC"
echo "   Phase:  $RESUME_STATUS"
echo "   State dir: $TOPIC_DIR"
echo ""
echo "   The stop hook is now active again."
echo "   To interrupt again: /dev-workflow:interrupt --topic $TOPIC"
echo "   To cancel: /dev-workflow:cancel --topic $TOPIC"
