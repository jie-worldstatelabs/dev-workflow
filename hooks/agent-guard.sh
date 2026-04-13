#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When a dev-workflow is active and Claude launches an Agent, this hook
# injects guidance about what subagent_type / mode / prompt contents to use,
# driven by workflow.json.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

if ! config_check; then
  exit 0
fi

if ! resolve_state; then
  exit 0
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
EPOCH=$(echo "$FRONTMATTER" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' | tr -d '[:space:]' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if [[ -n "$STATE_SESSION" ]] && [[ -n "$HOOK_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Terminal / paused: nothing to advise
if config_is_terminal "$STATUS" || [[ "$STATUS" == "interrupted" ]]; then
  exit 0
fi

# Must be a known active stage
if ! config_is_stage "$STATUS"; then
  exit 0
fi

BASELINE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
ARTIFACT="$(config_artifact_path "$STATUS" "$TOPIC" "$PROJECT_ROOT")"

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
    path="$(config_artifact_path "$from_stage" "$TOPIC" "$PROJECT_ROOT")"
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
[dev-workflow] Active workflow (phase: $STATUS, epoch: $EPOCH).
Stage instructions: $INSTRUCTIONS_PATH

This Agent call should use:
  - subagent_type: "$SUBAGENT_TYPE"$( [[ -n "$MODEL" ]] && printf '\n  - model: %s' "$MODEL" )
  - mode: bypassPermissions

Prompt must include:
  - Project directory: $PROJECT_ROOT
  - Epoch: $EPOCH
  - Output: $ARTIFACT
  - Required inputs (MUST exist):
$REQUIRED_SECTION  - Optional inputs:
$OPTIONAL_SECTION
The agent MUST write $ARTIFACT with frontmatter:
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---
EOF
