#!/bin/bash
# PostToolUse hook (all tools) — cloud mode activity log.
#
# When a meta-workflow cloud session is active and a stage is running,
# posts a lightweight tool-use event to the server so the webapp can
# display a live activity feed. Always fire-and-forget (cloud_post_activity
# backgrounds the curl) — zero latency impact on the agent.
#
# Skipped: non-cloud sessions, no active stage, terminal stages,
#          and noisy internal tools (TodoWrite, TodoRead, LS).

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[[ -z "$SID" ]] && exit 0

is_cloud_session "$SID" || exit 0

TOOL=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
[[ -z "$TOOL" ]] && exit 0

# Skip internal / noisy tools
case "$TOOL" in
  TodoWrite|TodoRead|LS) exit 0 ;;
esac

# Read current stage from shadow state.md
SHADOW_DIR="$(cloud_registry_get "$SID" scratch_dir)"
[[ -z "$SHADOW_DIR" ]] && SHADOW_DIR="${CLOUD_SCRATCH_BASE}/${SID}"
STATE_FILE="${SHADOW_DIR}/state.md"
[[ -f "$STATE_FILE" ]] || exit 0

STAGE=$(_read_fm_field "$STATE_FILE" status)
[[ -z "$STAGE" ]] && exit 0

EPOCH=$(_read_fm_field "$STATE_FILE" epoch)

# Skip known terminal statuses
case "$STAGE" in
  complete|cancelled|archived|interrupted) exit 0 ;;
esac

# Extract a one-line summary from tool_input
INPUT=$(echo "$HOOK_INPUT" | jq -r '.tool_input // {}' 2>/dev/null || echo "{}")

case "$TOOL" in
  Read)
    SUMMARY=$(echo "$INPUT" | jq -r '.file_path // ""' 2>/dev/null || true)
    ;;
  Write|Edit|MultiEdit)
    SUMMARY=$(echo "$INPUT" | jq -r '.file_path // ""' 2>/dev/null || true)
    ;;
  Bash)
    SUMMARY=$(echo "$INPUT" | jq -r '.command // ""' 2>/dev/null | cut -c1-120 || true)
    ;;
  Grep)
    PAT=$(echo "$INPUT" | jq -r '.pattern // ""' 2>/dev/null || true)
    PPATH=$(echo "$INPUT" | jq -r '.path // ""' 2>/dev/null || true)
    SUMMARY="${PAT}${PPATH:+ in ${PPATH}}"
    ;;
  Glob)
    SUMMARY=$(echo "$INPUT" | jq -r '.pattern // ""' 2>/dev/null || true)
    ;;
  Agent)
    SUMMARY=$(echo "$INPUT" | jq -r '.subagent_type // .description // ""' 2>/dev/null \
              | cut -c1-80 || true)
    # Capture the actual prompt string this Agent tool call passed to
    # the subagent — only for workflow-subagent runs (don't hoover up
    # unrelated Agent invocations the user might make mid-workflow).
    # Fire-and-forget; the webapp surfaces this as the "Prompt" view
    # for subagent stages.
    _SUBTYPE=$(echo "$INPUT" | jq -r '.subagent_type // ""' 2>/dev/null || true)
    if [[ "$_SUBTYPE" == "meta-workflow:workflow-subagent" ]]; then
      _PROMPT_TMP=$(mktemp -t dw-stage-prompt-XXXXXX)
      if echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null > "$_PROMPT_TMP" \
         && [[ -s "$_PROMPT_TMP" ]]; then
        cloud_post_stage_prompt "$SID" "$STAGE" "${EPOCH:-0}" "$_PROMPT_TMP"
      fi
      # cloud_post_stage_prompt backgrounds its curl; give it a moment
      # to read the tmp file before we unlink, then let it vanish. Worst
      # case the curl loses the file mid-read — the next Agent call
      # will re-record, so best-effort.
      (sleep 5 && rm -f "$_PROMPT_TMP") &
      disown 2>/dev/null || true
    fi
    ;;
  WebSearch)
    SUMMARY=$(echo "$INPUT" | jq -r '.query // ""' 2>/dev/null || true)
    ;;
  WebFetch)
    SUMMARY=$(echo "$INPUT" | jq -r '.url // ""' 2>/dev/null || true)
    ;;
  *)
    SUMMARY=""
    ;;
esac

cloud_post_activity "$SID" "$STAGE" "${EPOCH:-0}" "$TOOL" "${SUMMARY:-}"

exit 0
