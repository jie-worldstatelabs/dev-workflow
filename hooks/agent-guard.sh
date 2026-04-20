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

build_inputs_section() {
  local kind="$1"
  local source_fn="config_${kind}_inputs"
  local section=""
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local path
    if [[ "$type" == "run_file" ]]; then
      path="$(config_run_file_path "$key")"
    else
      path="$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    fi
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

# Subagent stage: inject prompt template. Every subagent-typed stage uses
# the single generic workflow-subagent; per-stage behavior comes from the
# stage instructions file, not from per-stage agent definitions. Model
# can still be overridden per stage via workflow.json.stages.<s>.execution.model.
SUBAGENT_TYPE="meta-workflow:workflow-subagent"
MODEL="$(config_model "$STATUS")"

cat <<EOF
[meta-workflow] agent-guard (PreToolUse hook for Agent tool)
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

Execute the $STATUS stage of the meta-workflow.

Stage name: $STATUS
Stage instructions file: $INSTRUCTIONS_PATH
  → READ THIS FILE FIRST. It is the full protocol for this stage — what
    to do, what constraints apply, and what the report body must contain.
    Do not guess from the stage name alone.

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

Then write the body according to the stage instructions file.

━━━━━━━━━━ END PROMPT TEMPLATE ━━━━━━━━━━
EOF

# Capture the prompt the main agent is *about to* send to the
# subagent. Use PreToolUse (this hook) rather than PostToolUse so
# the webapp sees the prompt immediately when the Agent call starts
# — PostToolUse for Agent only fires after the subagent returns,
# which can be many minutes later for long stage runs. Only record
# workflow-subagent invocations; unrelated Agent calls the user
# might make mid-workflow are ignored.
if is_cloud_session "$RUN_DIR_NAME"; then
  _TOOL_SUBAGENT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || true)
  if [[ "$_TOOL_SUBAGENT" == "meta-workflow:workflow-subagent" ]]; then
    _PROMPT_TMP=$(mktemp -t dw-stage-prompt-XXXXXX)
    if echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null > "$_PROMPT_TMP" \
       && [[ -s "$_PROMPT_TMP" ]]; then
      cloud_post_stage_prompt "$RUN_DIR_NAME" "$STATUS" "${EPOCH:-0}" "$_PROMPT_TMP"
    fi
    # cloud_post_stage_prompt backgrounds its curl; give it a moment
    # to open the tmp file before we let the OS reclaim it.
    (sleep 5 && rm -f "$_PROMPT_TMP") &
    disown 2>/dev/null || true
  fi
fi
exit 0
