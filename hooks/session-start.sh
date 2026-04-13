#!/bin/bash

# Dev Workflow SessionStart Hook
# Caches the real Claude session_id to a file keyed by the Claude process
# PID ($PPID of this hook). setup-workflow.sh reads the same file by its
# own $PPID — since both are direct children of the Claude Code main
# process, $PPID matches.
#
# Cache location: <project>/.dev-workflow/.session-cache/<PPID>
# This is intentionally project-scoped. If no .dev-workflow/ exists in the
# CWD upward, the hook is a no-op — avoids polluting unrelated projects
# (first /dev-workflow:dev call will still fall back to nosession-* and
# get claimed by the first hook fire; subsequent runs in the same project
# will have the cache ready).

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[[ -z "$SESSION_ID" ]] && exit 0

# Only write cache for fresh session starts. Avoids subagent-spawn events
# (if Claude Code fires SessionStart for those) from clobbering the main
# session's cache.
SOURCE=$(echo "$HOOK_INPUT" | jq -r '.source // ""' 2>/dev/null || true)
case "$SOURCE" in
  startup|resume|clear|compact|"")  ;;  # main session events → cache it
  *) exit 0 ;;                         # anything else → skip defensively
esac

# Only cache if this project already uses dev-workflow
# (or will use it — find_dw_root tolerates missing dir by returning 1,
# so we create when known to be wanted).
if dw=$(find_dw_root 2>/dev/null); then
  CACHE_DIR="$dw/.session-cache"
  mkdir -p "$CACHE_DIR"
  echo "$SESSION_ID" > "$CACHE_DIR/$PPID"
fi

exit 0
