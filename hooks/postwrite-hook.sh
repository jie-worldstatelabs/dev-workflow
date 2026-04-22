#!/bin/bash
# PostToolUse hook (Write/Edit/MultiEdit) — cloud mode state.md mirror.
#
# When cloud mode is active for the current session, this hook mirrors
# writes to state.md under the shadow dir to the server:
#   * state.md  → POST /api/sessions/<sid>/state
#
# Artifact sync (<stage>-report.md) is intentionally NOT handled here.
# update-status.sh is the authoritative sync point for stage artifacts:
# it reads the outgoing stage's canonical artifact path and uploads it
# as part of the transition, failing loudly if the file is missing or
# the upload fails. Relying on this hook for artifact sync silently
# missed writes that landed on non-canonical paths (e.g. a subagent
# writing `<stage>.md` instead of `<stage>-report.md`); routing through
# the transition guarantees every state change carries its artifact.
#
# Any other file path is ignored. For local-mode sessions (no cloud
# registry entry) the hook exits immediately so it's free on the hot path.
#
# Session ID is derived from the file path (the first directory component
# under SCRATCH_ROOT), NOT from the hook input's session_id. This correctly
# handles cross-machine takeover and same-machine --session continues where
# the current Claude session UUID differs from the server session UUID that
# keys the scratch directory.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

SCRATCH_ROOT="$(cloud_scratch_dir)"

case "$FILE_PATH" in
  "$SCRATCH_ROOT"/*)
    # Shadow write — existing state.md mirror path.
    #
    # Extract the session UUID from the file path (first dir under SCRATCH_ROOT).
    # For a normal start:       ~/.cache/meta-workflow/sessions/<uuid>/<file>
    # For a cross-machine/--session continue the scratch dir is keyed by the
    # SERVER uuid (not the current local Claude session uuid), so using the path
    # is the only reliable way to get the right SID.
    REL="${FILE_PATH#$SCRATCH_ROOT/}"   # "<uuid>/<rest>"
    PATH_SID="${REL%%/*}"               # "<uuid>"

    # Guard: verify this SID is actually cloud-registered (avoids acting on
    # stray files that happen to land under the scratch root).
    is_cloud_session "$PATH_SID" || exit 0

    REL_FILE="${REL#*/}"   # strip the <uuid>/ prefix

    # Only state.md triggers cloud sync from this hook. Stage artifacts
    # (<stage>-report.md) are handled by update-status.sh at transition
    # time — see the header comment for rationale.
    case "$REL_FILE" in
      state.md)
        ST=$(_read_fm_field "$FILE_PATH" status)
        EP=$(_read_fm_field "$FILE_PATH" epoch)
        RE=$(_read_fm_field "$FILE_PATH" resume_status)
        cloud_post_state "$PATH_SID" "${ST:-}" "${EP:-1}" "${RE:-}" "true" 2>/dev/null || true
        ;;
    esac
    ;;
  *)
    # Project-worktree write (or anywhere outside the shadow). Trigger a
    # diff refresh so the UI reflects mid-stage subagent writes — not just
    # the stage-transition snapshot. cloud_post_diff dedups internally
    # against .last-posted-tree, so no-ops don't hit the network.
    PLUGIN_SID=$(read_cached_session_id 2>/dev/null || true)
    if [[ -n "$PLUGIN_SID" ]] && is_cloud_session "$PLUGIN_SID"; then
      cloud_post_diff "$PLUGIN_SID" >/dev/null 2>&1 || true
    fi
    ;;
esac

exit 0
