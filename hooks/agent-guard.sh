#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When a meta-workflow is active and Claude launches an Agent, this hook
# injects guidance about what subagent_type / mode / prompt contents to use,
# driven by workflow.json.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

# Fallback-derive CLAUDE_PLUGIN_ROOT if Claude Code didn't set it for this
# hook invocation. Real hook subprocesses always get it set; this is a
# safety net so manual invocations don't trip `set -u`.
: "${CLAUDE_PLUGIN_ROOT:=$(dirname "$HOOK_DIR")}"

# Session-keyed: resolve THIS session's workflow dir (from HOOK_INPUT).
# If there's no workflow for this session, nothing to advise.
DESIRED_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if ! resolve_state; then
  exit 0
fi
resolve_workflow_dir_from_state

if ! config_check; then
  exit 0
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
EPOCH=$(_read_fm_field "$STATE_FILE" epoch)

# Terminal / paused: nothing to advise
if is_terminal_status "$STATUS" || [[ "$STATUS" == "interrupted" ]]; then
  exit 0
fi

# Must be a known active stage
if ! config_is_stage "$STATUS"; then
  exit 0
fi

ARTIFACT="$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
EXEC_TYPE="$(config_execution_type "$STATUS")"
TRANSITION_KEYS="$(config_transition_keys "$STATUS")"
INSTRUCTIONS_PATH="$(config_stage_instructions_path "$STATUS")"

if [[ "$EXEC_TYPE" == "inline" ]]; then
  cat <<EOF
[meta-workflow] Active workflow (phase: $STATUS, epoch: $EPOCH).
This stage is INLINE — the main agent runs it directly.
Do NOT launch a subagent for this phase.
If you're about to launch workflow-subagent, you probably need to transition out of $STATUS first via ${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh.

Stage instructions: $INSTRUCTIONS_PATH
Expected output: $ARTIFACT
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---
EOF
  exit 0
fi

# Subagent stage: the subagent self-resolves its stage context via
# subagent-bootstrap.sh as its mandatory first action (see the
# workflow-subagent.md system prompt). The main agent doesn't need
# to copy any paths or context into the Agent-tool prompt — the prompt
# is just a trigger string.
SUBAGENT_TYPE="meta-workflow:workflow-subagent"
MODEL="$(config_model "$STATUS")"

cat <<EOF
[meta-workflow] agent-guard (PreToolUse, Agent matcher)
Active workflow phase: $STATUS (epoch $EPOCH).

Agent tool parameters to use:
  - subagent_type: "$SUBAGENT_TYPE"$( [[ -n "$MODEL" ]] && printf '\n  - model: %s' "$MODEL" )
  - mode: bypassPermissions
  - prompt: any short trigger string (e.g. "Execute the current workflow stage.")

You do NOT need to hand-copy paths, epoch, or inputs into the prompt.
The subagent's system prompt mandates running subagent-bootstrap.sh
as its first action; that script self-resolves the active stage's
context from state.md + workflow.json and feeds it to the subagent
via tool_result. Trying to pre-populate the prompt with paths is
harmless but redundant.
EOF
exit 0
