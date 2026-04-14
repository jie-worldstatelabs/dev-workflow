#!/bin/bash
# Cancel a dev workflow.
#
# Default:  move the run dir to .dev-workflow/.archive/<ts>-<topic>-cancelled/
#           so the audit trail (reports + baseline) is preserved.
# --hard:   rm -rf the run dir (no archive). Use when you really don't want
#           the artifacts.
#
# Usage: cancel-workflow.sh [--topic <name>] [--hard]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC_ARG=""
HARD=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --topic)
      TOPIC_ARG="$2"
      shift 2
      ;;
    --hard)
      HARD="yes"
      shift
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
  echo "No matching dev workflow to cancel." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  fi
  exit 1
fi

if [[ -n "$HARD" ]]; then
  # Hard delete — no archive, no audit trail.
  if [[ -d "$TOPIC_DIR" ]]; then
    rm -rf "$TOPIC_DIR"
    echo "Dev workflow '$TOPIC' cancelled (hard-deleted $TOPIC_DIR)."
  else
    rm -f "$STATE_FILE"
    echo "Dev workflow '$TOPIC' cancelled."
  fi
  exit 0
fi

# Default: archive to .dev-workflow/.archive/<ts>-<topic>-cancelled/
rc=0
archive_run_dir "$TOPIC_DIR" "$TOPIC" "cancelled" || rc=$?
case $rc in
  0) echo "Dev workflow '$TOPIC' cancelled (archived to $ARCHIVE_RESULT_PATH)." ;;
  1)
    # Nothing to archive — dir already missing or empty.
    rm -f "$STATE_FILE"
    echo "Dev workflow '$TOPIC' cancelled."
    ;;
  2)
    echo "⚠️  Archive failed; run '$TOPIC' removed." >&2
    ;;
esac
