#!/bin/bash
# Cancel a dev workflow.
#
# Default:  move the run dir to .dev-workflow/.archive/<ts>-<topic>-cancelled/
#           so the audit trail (reports + baseline) is preserved.
# --hard:   rm -rf the run dir (no archive). Use when you really don't want
#           the artifacts.
#
# Usage: cancel-workflow.sh [--hard]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

HARD=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --hard) HARD="yes"; shift ;;
    *)      shift ;;
  esac
done

if ! resolve_state; then
  echo "No matching dev workflow to cancel." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
  fi
  exit 1
fi

# Cloud mode: server is authoritative. Hit the cancel endpoint, wipe the
# shadow dir, drop the registry entry. No local archive — server holds the
# audit trail.
if is_cloud_session "$RUN_DIR_NAME"; then
  if [[ -n "$HARD" ]]; then
    cloud_delete_session "$RUN_DIR_NAME" || true
  else
    cloud_post_cancel "$RUN_DIR_NAME" || {
      echo "⚠️  cloud cancel POST failed — the server may still show this run as active" >&2
    }
  fi
  cloud_wipe_scratch "$RUN_DIR_NAME"
  cloud_unregister_session "$RUN_DIR_NAME"
  if [[ -n "$HARD" ]]; then
    echo "Dev workflow '$TOPIC' cancelled (hard-deleted from cloud)."
  else
    echo "Dev workflow '$TOPIC' cancelled (archived on server)."
  fi
  exit 0
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
