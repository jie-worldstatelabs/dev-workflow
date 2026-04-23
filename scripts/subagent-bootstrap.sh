#!/bin/bash
#
# subagent-bootstrap.sh — self-resolving context bootstrap for
# workflow-subagent. Runs inside the subagent's own Bash tool call;
# its stdout is returned to the subagent as tool_result and becomes
# the authoritative stage contract in its context window.
#
# Replaces the earlier "main agent must hand-copy a prompt template
# verbatim" contract, which repeatedly failed (placeholders, truncated
# copies, missing paths). Here, the subagent asks the filesystem
# directly, using the same resolve_state / config_* helpers the main
# agent uses — no transcription loss possible.
#
# Also POSTs the emitted context to /api/sessions/<sid>/stage-prompts
# so the webapp's "Runtime prompt" panel shows the subagent's actual
# contract (not the main agent's possibly-trivial trigger string).
# Fire-and-forget; local-mode sessions skip the POST.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

die() {
  echo "❌ [subagent-bootstrap] $*" >&2
  exit 1
}

if ! resolve_state; then
  die "no active workflow resolvable — surface to main agent and stop"
fi
resolve_workflow_dir_from_state
if ! config_check; then
  die "workflow config invalid"
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
EPOCH="${EPOCH:-0}"

[[ -z "$STATUS" ]] && die "state.md has no 'status:' field"
is_terminal_status "$STATUS" && die "current status '$STATUS' is terminal — nothing to execute"
config_is_stage "$STATUS" || die "'$STATUS' is not a declared stage in workflow.json"

EXEC_TYPE=$(config_execution_type "$STATUS")
if [[ "$EXEC_TYPE" != "subagent" ]]; then
  die "stage '$STATUS' has execution type '$EXEC_TYPE' — inline stages are not subagent-executed; tell the main agent to transition out first"
fi

INSTR_PATH=$(config_stage_instructions_path "$STATUS")
ARTIFACT_PATH=$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")
TKEYS=$(config_transition_keys "$STATUS" | tr '\n' ' ' | sed -E 's/ +$//')

# Compose the context block once. Emit to stdout (for the subagent's
# tool_result context injection) AND — for cloud sessions — POST to
# the server so the webapp's Runtime prompt panel shows this exact
# contract.
CONTEXT_FILE="$(mktemp -t dw-subagent-ctx-XXXXXX)"
trap 'rm -f "$CONTEXT_FILE"' EXIT

{
  echo "━━━━━━━━━━ stagent subagent context ━━━━━━━━━━"
  echo ""
  echo "Stage: $STATUS"
  echo "Epoch: $EPOCH"
  echo "Project directory: $PROJECT_ROOT"
  echo "Stage instructions file: $INSTR_PATH"
  echo "  ⚠ READ THIS FILE FIRST — it is the canonical protocol for this stage."
  echo "Output artifact path: $ARTIFACT_PATH"
  echo ""
  echo "Required inputs (every file below MUST exist — read each):"
  _REQ=0
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    _REQ=1
    if [[ "$type" == "run_file" ]]; then
      p=$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT" 2>/dev/null || echo "")
    else
      p=$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")
    fi
    echo "  - $p"
    echo "      $description"
  done < <(config_required_inputs "$STATUS")
  [[ $_REQ -eq 0 ]] && echo "  (none)"
  echo ""
  echo "Optional inputs (read each if the file exists; otherwise treat as absent):"
  _OPT=0
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    _OPT=1
    if [[ "$type" == "run_file" ]]; then
      p=$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT" 2>/dev/null || echo "")
    else
      p=$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")
    fi
    echo "  - $p"
    echo "      $description"
  done < <(config_optional_inputs "$STATUS")
  [[ $_OPT -eq 0 ]] && echo "  (none)"
  echo ""
  echo "Valid result: values you may write to the artifact frontmatter:"
  echo "  $TKEYS"
  echo ""
  echo "Write the output artifact at the path above with frontmatter:"
  echo "  ---"
  echo "  epoch: $EPOCH"
  echo "  result: <one of: $TKEYS>"
  echo "  ---"
  echo "  <body per the stage instructions file>"
  echo ""
  echo "━━━━━━━━━━ end of subagent context ━━━━━━━━━━"
} > "$CONTEXT_FILE"

# Best-effort upload so webapp "Runtime prompt" panel surfaces the
# exact contract the subagent just received. Non-blocking.
if is_cloud_session "$RUN_DIR_NAME"; then
  cloud_post_stage_prompt "$RUN_DIR_NAME" "$STATUS" "$EPOCH" "$CONTEXT_FILE" || true
fi

cat "$CONTEXT_FILE"
