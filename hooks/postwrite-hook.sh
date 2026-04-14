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

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[[ -z "$SID" ]] && exit 0

# Fast exit if this session isn't cloud-managed.
is_cloud_session "$SID" || exit 0

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

SCRATCH_ROOT="$(cloud_scratch_dir)"
PREFIX="${SCRATCH_ROOT}/${SID}/"
case "$FILE_PATH" in
  "$PREFIX"*) ;;
  *) exit 0 ;;
esac

REL="${FILE_PATH#$PREFIX}"

case "$REL" in
  state.md)
    ST=$(_read_fm_field "$FILE_PATH" status)
    EP=$(_read_fm_field "$FILE_PATH" epoch)
    RE=$(_read_fm_field "$FILE_PATH" resume_status)
    cloud_post_state "$SID" "${ST:-}" "${EP:-1}" "${RE:-}" "true" 2>/dev/null || true
    ;;
  *-report.md)
    STAGE="${REL%-report.md}"
    cloud_post_artifact "$SID" "$STAGE" "$FILE_PATH" 2>/dev/null || true
    ;;
esac

exit 0
