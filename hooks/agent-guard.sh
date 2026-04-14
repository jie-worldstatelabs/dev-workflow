#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When a dev-workflow is active and Claude launches an Agent, this hook
# injects guidance about what subagent_type / mode / prompt contents to use,
# driven by workflow.json.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

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

BASELINE="${TOPIC_DIR}/baseline"
ARTIFACT="$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"

# Auto-record baseline at the start of an executing phase (belt-and-suspenders)
if [[ "$STATUS" == "executing" ]] && [[ ! -f "$BASELINE" ]]; then
  git -C "${PROJECT_ROOT}" rev-parse HEAD > "$BASELINE" 2>/dev/null || echo "EMPTY" > "$BASELINE"
fi

EXEC_TYPE="$(config_execution_type "$STATUS")"
TRANSITION_KEYS="$(config_transition_keys "$STATUS")"
INSTRUCTIONS_PATH="$(config_stage_instructions_path "$STATUS")"

build_inputs_section() {
  local kind="$1"
  local source_fn="config_${kind}_inputs"
  local section=""
  while IFS=$'\t' read -r from_stage description; do
    [[ -z "$from_stage" ]] && continue
    local path
    path="$(config_artifact_path "$from_stage" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    if [[ "$kind" == "optional" ]]; then
      section+="  - $path (if exists, else \"none\") — $description"$'\n'
    else
      section+="  - $path — $description"$'\n'
    fi
  done < <($source_fn "$STATUS")
  printf '%s' "$section"
}

REQUIRED_SECTION="$(build_inputs_section required)"
OPTIONAL_SECTION="$(build_inputs_section optional)"

if [[ "$EXEC_TYPE" == "inline" ]]; then
  cat <<EOF
[dev-workflow] Active workflow (phase: $STATUS, epoch: $EPOCH).
This stage is INLINE — the main agent runs it directly.
Do NOT launch a subagent for this phase.
If you're about to launch workflow-executor/reviewer/qa, you probably need to transition out of $STATUS first via \${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh.

Stage instructions: $INSTRUCTIONS_PATH
Expected output: $ARTIFACT
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---
EOF
  exit 0
fi

# Subagent stage: inject prompt template
SUBAGENT_TYPE="$(config_subagent_type "$STATUS")"
MODEL="$(config_model "$STATUS")"

cat <<EOF
[dev-workflow] agent-guard (PreToolUse hook for Agent tool)
Active workflow phase: $STATUS (epoch $EPOCH) — stage instructions: $INSTRUCTIONS_PATH

⚠️  IMPORTANT — how this hook works:
  This output is visible ONLY to you, the main agent. PreToolUse hooks cannot
  modify Agent-tool parameters. The subagent will see ONLY the prompt string
  you pass to the Agent tool — NOT this hook's output.
  → You MUST copy the prompt template below into the \`prompt\` argument of
    your Agent tool call. Do NOT write "see injected paths" — the subagent
    has no access to "injected" context.

Agent tool parameters to use:
  - subagent_type: "$SUBAGENT_TYPE"$( [[ -n "$MODEL" ]] && printf '\n  - model: %s' "$MODEL" )
  - mode: bypassPermissions

━━━━━━━━━━ PROMPT TEMPLATE — copy verbatim into the Agent tool's \`prompt\` ━━━━━━━━━━

Execute the $STATUS stage of the dev-workflow.

Project directory: $PROJECT_ROOT
Epoch: $EPOCH
Output artifact path: $ARTIFACT

Required inputs (these files MUST exist — read and use them as needed):
$REQUIRED_SECTION
Optional inputs (read each if the file exists; otherwise treat as absent):
$OPTIONAL_SECTION
You MUST write the output artifact at the path above with this frontmatter:
---
epoch: $EPOCH
result: <one of: $TRANSITION_KEYS>
---

Then write the body according to your agent definition.

━━━━━━━━━━ END PROMPT TEMPLATE ━━━━━━━━━━
EOF
