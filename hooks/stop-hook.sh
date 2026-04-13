#!/bin/bash

# Dev Workflow Stop Hook
# Prevents session exit when a workflow is active.
#
# DESIGN: Generic state machine controller driven by workflow.json.
# Reads (status, epoch) from state.md, then for the current stage:
#   1. If the stage's artifact exists with matching epoch + non-empty result
#      → stage is DONE, use the stage's transitions to tell Claude which
#        status to move to next.
#   2. Else → stage is NOT DONE. For uninterruptible stages, block and prompt
#     Claude to execute the stage. For interruptible stages, emit a
#     systemMessage hint but do not block.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

if ! config_check; then
  # Without config we can't do anything; allow exit silently.
  exit 0
fi

if ! resolve_state; then
  exit 0
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
EPOCH=$(echo "$FRONTMATTER" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation (directory × session_id)
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' | tr -d '[:space:]' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]]; then
  if [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
    exit 0
  fi
elif [[ -n "$HOOK_SESSION" ]]; then
  sed -i '' "s/^session_id: *$/session_id: $HOOK_SESSION/" "$STATE_FILE"
fi

# Terminal states
if config_is_terminal "$STATUS"; then
  case "$STATUS" in
    interrupted)
      # This shouldn't happen (interrupted isn't in terminal_stages by default)
      # but handle it gracefully — allow exit, keep state for /dev-workflow:continue
      exit 0
      ;;
    *)
      # complete / escalated → done, clean up and allow exit
      rm -f "$STATE_FILE"
      exit 0
      ;;
  esac
fi

# Paused by user — allow exit but KEEP state file for /dev-workflow:continue
# (interrupted is handled here since it's a state machine feature, not a "terminal" per config)
if [[ "$STATUS" == "interrupted" ]]; then
  exit 0
fi

# Corrupted state
if [[ -z "$STATUS" ]] || [[ -z "$EPOCH" ]] || ! [[ "$EPOCH" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Dev workflow: State file corrupted (status='$STATUS' epoch='$EPOCH')" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Active stage: must be declared in config
if ! config_is_stage "$STATUS"; then
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Current stage's artifact
# ──────────────────────────────────────────────────────────────
ARTIFACT="$(config_artifact_path "$STATUS" "$TOPIC" "$PROJECT_ROOT")"

ARTIFACT_EPOCH=""
ARTIFACT_RESULT=""
if [[ -f "$ARTIFACT" ]]; then
  ART_FM=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$ARTIFACT" 2>/dev/null || true)
  ARTIFACT_EPOCH=$(echo "$ART_FM" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]' || true)
  ARTIFACT_RESULT=$(echo "$ART_FM" | grep '^result:' | sed 's/result: *//' | tr -d '[:space:]' || true)
fi

# ──────────────────────────────────────────────────────────────
# Interruptible stages: output info, do NOT block exit
# For interruptible stages, a "transition key" result (e.g. planning:approved)
# triggers a ⚠️ hint. Other values (pending, empty, etc.) are neutral.
# ──────────────────────────────────────────────────────────────
if config_is_interruptible "$STATUS"; then
  INSTR="$(config_stage_instructions_path "$STATUS")"
  NEXT_STATUS=""
  if [[ -n "$ARTIFACT_RESULT" ]] && [[ -f "$ARTIFACT" ]] && [[ "$ARTIFACT_EPOCH" == "$EPOCH" ]]; then
    NEXT_STATUS=$(config_next_status "$STATUS" "$ARTIFACT_RESULT")
  fi
  if [[ -n "$NEXT_STATUS" ]]; then
    SYSTEM_MSG="📋 Dev workflow: $STATUS stage (epoch $EPOCH) — interruptible. ⚠️  $ARTIFACT has result: $ARTIFACT_RESULT; run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status $NEXT_STATUS to proceed. Stage instructions: $INSTR"
  else
    SYSTEM_MSG="📋 Dev workflow: $STATUS stage (epoch $EPOCH) — interruptible. Stage instructions: $INSTR. Continue the conversation to proceed, or use /dev-workflow:cancel to abort."
  fi
  jq -n --arg msg "$SYSTEM_MSG" '{"systemMessage": $msg}'
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Uninterruptible: either transition (stage done) or re-execute (stage not done)
# ──────────────────────────────────────────────────────────────

# Build input descriptors for prompt templating.
# Each input becomes a line: "  - {artifact_path}  (<description>)"
build_inputs_section() {
  local kind="$1"   # required | optional
  local stage="$2"
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
  done < <($source_fn "$stage")
  printf '%s' "$section"
}

REQUIRED_SECTION="$(build_inputs_section required "$STATUS")"
OPTIONAL_SECTION="$(build_inputs_section optional "$STATUS")"
TRANSITION_KEYS="$(config_transition_keys "$STATUS")"
EXEC_TYPE="$(config_execution_type "$STATUS")"
INSTRUCTIONS_PATH="$(config_stage_instructions_path "$STATUS")"

# Render the "execute this stage" instruction based on execution type.
# Always point to the stage instructions file — it owns the full per-stage protocol.
if [[ "$EXEC_TYPE" == "subagent" ]]; then
  SUBAGENT_TYPE="$(config_subagent_type "$STATUS")"
  MODEL="$(config_model "$STATUS")"
  MODEL_LINE=""
  if [[ -n "$MODEL" ]]; then
    MODEL_LINE="  - model: $MODEL"$'\n'
  fi
  STAGE_WORK="Read stage instructions: $INSTRUCTIONS_PATH

Call the Agent tool. When you do, the agent-guard PreToolUse hook will print
a prompt template you MUST copy verbatim into the Agent-tool \`prompt\` argument
(the subagent cannot see hook output — only the prompt string you pass it).

Agent-tool parameters:
  - subagent_type: $SUBAGENT_TYPE
$MODEL_LINE  - mode: bypassPermissions

The prompt you pass to the Agent tool must include (transcribe every path
literally — do NOT write \"see injected paths\"):
  - Project directory: $PROJECT_ROOT
  - Epoch: $EPOCH
  - Output: $ARTIFACT
  - Required inputs (MUST exist):
$REQUIRED_SECTION  - Optional inputs:
$OPTIONAL_SECTION
Agent MUST write $ARTIFACT with frontmatter:
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---"
else
  # inline — the main agent does the work directly, per the stage file
  STAGE_WORK="Read stage instructions: $INSTRUCTIONS_PATH

This is an inline stage (no subagent). Follow the stage file for the exact steps (e.g. verifying runs quick tests; planning runs Q&A with user).

Output: $ARTIFACT
Required inputs (MUST exist):
$REQUIRED_SECTION
Optional inputs:
$OPTIONAL_SECTION
Write $ARTIFACT with frontmatter:
  ---
  epoch: $EPOCH
  result: <one of: $TRANSITION_KEYS>
  ---"
fi

# ──────────────────────────────────────────────────────────────
# Decide: stage done → transition prompt | not done → execute prompt
# ──────────────────────────────────────────────────────────────
if [[ -f "$ARTIFACT" ]] && [[ "$ARTIFACT_EPOCH" == "$EPOCH" ]] && [[ -n "$ARTIFACT_RESULT" ]]; then
  NEXT=$(config_next_status "$STATUS" "$ARTIFACT_RESULT")
  if [[ -z "$NEXT" ]]; then
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — unknown result in artifact.

Status: $STATUS (epoch $EPOCH)
Artifact: $ARTIFACT
Result value: '$ARTIFACT_RESULT' — not in the transition table (valid keys: $TRANSITION_KEYS).

Inspect $ARTIFACT, then call:
  \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status <correct-next>

DO NOT STOP."
  else
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — stage '$STATUS' DONE (result: $ARTIFACT_RESULT), transition not yet called.

$ARTIFACT is valid for epoch $EPOCH.
You MUST now run:
  \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status $NEXT

Then continue the workflow (either do the next stage's work or, if the new status is terminal, announce completion).

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
  fi
else
  if [[ ! -f "$ARTIFACT" ]]; then
    REASON="$ARTIFACT does not exist"
  elif [[ "$ARTIFACT_EPOCH" != "$EPOCH" ]]; then
    REASON="$ARTIFACT has epoch='$ARTIFACT_EPOCH' (stale; expected $EPOCH)"
  else
    REASON="$ARTIFACT has no result field (incomplete)"
  fi

  CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: $STATUS, epoch: $EPOCH).

Reason: $REASON.

Execute the stage:
$STAGE_WORK

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
fi

SYSTEM_MSG="🔄 Dev workflow | Phase: $STATUS (epoch $EPOCH) | EXIT BLOCKED — /dev-workflow:interrupt to pause, /dev-workflow:cancel to stop"

jq -n \
  --arg prompt "$CONTINUE_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
