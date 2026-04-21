#!/bin/bash
#
# SessionEnd hook — auto-interrupt the workflow on graceful exit.
#
# When a Claude Code session ends cleanly (/exit, UI close, orderly
# shutdown), Claude Code fires SessionEnd. If this session owns an
# active meta-workflow, flip it to `status: interrupted` so another
# Claude session can safely pick it up via /meta-workflow:continue.
#
# The goal is to make hand-off painless: the user doesn't need to
# remember to run /meta-workflow:interrupt before leaving. ESC alone
# still only cancels the current turn (that's the right semantics
# for mid-course redirection); but an actual session exit should
# release ownership.
#
# Bystander-safe: if this session doesn't own a workflow (or the
# workflow has already reached a terminal / interrupted status),
# the hook is a no-op. Kill -9 / crashes never trigger this hook —
# server-side stale detection is the backstop for those cases.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)

# Resolve this session's workflow. If there's nothing to interrupt,
# exit silently — SessionEnd fires for every Claude Code session,
# not just meta-workflow-aware ones.
if ! resolve_state; then
  exit 0
fi
resolve_workflow_dir_from_state
if ! config_check; then
  exit 0
fi

STATUS=$(_read_fm_field "$STATE_FILE" status 2>/dev/null || echo "")

# Nothing to do if already interrupted, terminal, or missing.
[[ -z "$STATUS" ]] && exit 0
[[ "$STATUS" == "interrupted" ]] && exit 0
is_terminal_status "$STATUS" && exit 0

# Defer to the canonical path — interrupt-workflow.sh handles the
# state.md edits, resume_status saving, and cloud state POST. Pass
# --session explicitly: our DESIRED_SESSION is a local shell var,
# not exported, so the child process wouldn't inherit it otherwise
# and would fall back to cwd/ppid resolution (wrong session under
# multi-session machines).
PLUGIN_DIR="$(dirname "$HOOK_DIR")"
TARGET_SID="${DESIRED_SESSION:-$RUN_DIR_NAME}"
if [[ -n "$TARGET_SID" ]]; then
  "$PLUGIN_DIR/scripts/interrupt-workflow.sh" --session="$TARGET_SID" \
    >/dev/null 2>&1 || true
fi

exit 0
