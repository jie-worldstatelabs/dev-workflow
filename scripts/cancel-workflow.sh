#!/bin/bash
# Cancel a dev workflow — removes its entire topic subdir (state.md + all artifacts).
#
# Usage: cancel-workflow.sh [--topic <name>]

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
  echo "No matching dev workflow to cancel." >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  fi
  exit 1
fi

# Remove the whole topic subdir (state.md + baseline + all stage artifacts).
# Leaves the parent .dev-workflow/ alone so other workflows aren't affected.
if [[ -d "$TOPIC_DIR" ]]; then
  rm -rf "$TOPIC_DIR"
  echo "Dev workflow '$TOPIC' cancelled (removed $TOPIC_DIR)."
else
  rm -f "$STATE_FILE"
  echo "Dev workflow '$TOPIC' cancelled."
fi
