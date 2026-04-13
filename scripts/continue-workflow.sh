#!/bin/bash

# Dev Workflow Continue Script
# Resumes an interrupted workflow by restoring the saved resume_status.
# Only works when status is "interrupted" — use /dev-workflow:dev for a fresh start.
#
# Session-keyed model: each run lives under .dev-workflow/<session_id>/.
# If the user resumes from a NEW Claude session (e.g. reopened terminal),
# the interrupted run's dir is renamed to this session's id so the stop hook
# and other session-scoped machinery resolve correctly.
#
# Usage: continue-workflow.sh [--topic <name>] [--session <id>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC_ARG=""
SESSION_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --topic)
      TOPIC_ARG="$2"
      shift 2
      ;;
    --session)
      SESSION_ARG="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$TOPIC_ARG" ]] && DESIRED_TOPIC="$TOPIC_ARG"
[[ -n "$SESSION_ARG" ]] && DESIRED_SESSION="$SESSION_ARG"

# Resolve the interrupted workflow to resume. Strategy:
#   1. If DESIRED_TOPIC or DESIRED_SESSION was set, use resolve_state (scoped).
#   2. Otherwise, scan all .dev-workflow/*/ for a single interrupted run
#      (cross-session takeover — the common case when the user reopened
#      Claude Code in a fresh session).
if [[ -n "${DESIRED_TOPIC:-}" ]] || [[ -n "${DESIRED_SESSION:-}" ]]; then
  if ! resolve_state; then
    echo "No dev workflow matching the given --topic/--session." >&2
    exit 1
  fi
else
  rc=0
  resolve_interrupted_state || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 2 ]]; then
      # Multiple matches already printed by resolve_interrupted_state
      exit 1
    fi
    echo "No interrupted dev workflow found." >&2
    if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
      echo "   Available workflows:" >&2
      echo "$workflows" >&2
    else
      echo "   Start a new workflow with: /dev-workflow:dev <task>" >&2
    fi
    exit 1
  fi
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
RESUME_STATUS=$(echo "$FRONTMATTER" | grep '^resume_status:' | sed 's/resume_status: *//')

if [[ "$STATUS" != "interrupted" ]]; then
  echo "⚠️  Workflow '$TOPIC' is not interrupted (status: $STATUS)." >&2
  echo "   Only interrupted workflows can be continued." >&2
  exit 1
fi

[[ -z "$RESUME_STATUS" ]] && RESUME_STATUS="executing"

# ──────────────────────────────────────────────────────────────
# Cross-session takeover: rename the run dir to this session's id so
# hooks resolve to it from this session onward.
# ──────────────────────────────────────────────────────────────
NEW_SESSION="$(read_cached_session_id)"
OLD_SESSION="$RUN_DIR_NAME"
if [[ -n "$NEW_SESSION" ]] && [[ "$NEW_SESSION" != "$OLD_SESSION" ]]; then
  NEW_DIR="${PROJECT_ROOT}/.dev-workflow/${NEW_SESSION}"
  if [[ -e "$NEW_DIR" ]]; then
    echo "⚠️  This session already has a workflow dir at $NEW_DIR — refusing to overwrite." >&2
    echo "   Cancel or resolve that run first, then retry continue." >&2
    exit 1
  fi
  mv "$TOPIC_DIR" "$NEW_DIR"
  TOPIC_DIR="$NEW_DIR"
  STATE_FILE="$NEW_DIR/state.md"
  RUN_DIR_NAME="$NEW_SESSION"
  # Record the new session id in state.md for traceability
  set_fm_field "$STATE_FILE" session_id "$NEW_SESSION"
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
echo "   Session: $RUN_DIR_NAME"
echo "   State dir: $TOPIC_DIR"
echo ""
echo "   The stop hook is now active again."
echo "   To interrupt again: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
