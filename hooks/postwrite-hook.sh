#!/bin/bash
# PostToolUse hook (Write/Edit/MultiEdit) — cloud mode artifact sync.
#
# When cloud mode is active for the current session, this hook mirrors every
# write under the shadow dir to the server:
#   * state.md            → POST /api/sessions/<sid>/state
#   * <stage>-report.md   → POST /api/sessions/<sid>/artifacts/<stage>
#
# Any other file path is ignored. For local-mode sessions (no cloud registry
# entry) the hook exits immediately so it's free on the hot path.
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

# Fast exit: if the file isn't under the cloud scratch root, it's a local-mode
# or unrelated write — skip immediately without touching the registry.
SCRATCH_ROOT="$(cloud_scratch_dir)"
case "$FILE_PATH" in
  "$SCRATCH_ROOT"/*) ;;
  *) exit 0 ;;
esac

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

case "$REL_FILE" in
  state.md)
    ST=$(_read_fm_field "$FILE_PATH" status)
    EP=$(_read_fm_field "$FILE_PATH" epoch)
    RE=$(_read_fm_field "$FILE_PATH" resume_status)
    cloud_post_state "$PATH_SID" "${ST:-}" "${EP:-1}" "${RE:-}" "true" 2>/dev/null || true
    ;;
  *-report.md)
    STAGE="${REL_FILE%-report.md}"
    cloud_post_artifact "$PATH_SID" "$STAGE" "$FILE_PATH" 2>/dev/null || true
    ;;
esac

exit 0
