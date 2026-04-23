#!/bin/bash

# stage-context.sh — Print binding I/O context for the current inline stage.
#
# Called by the main agent at the start of every inline stage
# (execution.type = "inline"). Reads workflow.json to surface required/optional
# inputs, output artifact path, epoch, and valid result keys.
#
# Usage:
#   "$P/scripts/stage-context.sh" [--topic <topic>]
#
# Output: structured I/O context block to stdout.
# Exit 0 on success, 1 on error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TOPIC_ARG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --topic=*) TOPIC_ARG="${1#--topic=}"; shift ;;
    --topic)   TOPIC_ARG="$2";            shift 2 ;;
    *) echo "Warning: unknown argument: $1" >&2; shift ;;
  esac
done

[[ -n "$TOPIC_ARG" ]] && DESIRED_TOPIC="$TOPIC_ARG"

if ! resolve_state; then
  echo "❌ Could not resolve an active dev workflow." >&2
  exit 1
fi
resolve_workflow_dir_from_state

if ! config_check; then
  exit 1
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
EPOCH=$(_read_fm_field "$STATE_FILE" epoch)

if is_terminal_status "$STATUS" || [[ "$STATUS" == "interrupted" ]]; then
  echo "❌ Workflow is in terminal/interrupted status ($STATUS) — no stage to run." >&2
  exit 1
fi

if ! config_is_stage "$STATUS"; then
  echo "❌ '$STATUS' is not a known stage in workflow.json." >&2
  exit 1
fi

EXEC_TYPE="$(config_execution_type "$STATUS")"
if [[ "$EXEC_TYPE" != "inline" ]]; then
  echo "⚠️  Stage '$STATUS' has execution type '$EXEC_TYPE', not inline." >&2
  echo "   stage-context.sh is for inline stages only." >&2
  echo "   For subagent stages, agent-guard.sh provides the prompt template via PreToolUse hook." >&2
  exit 1
fi

ARTIFACT="$(config_artifact_path "$STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
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
      path="$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
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

cat <<EOF
[stagent] Inline stage context: $STATUS (epoch $EPOCH)

Stage instructions: $INSTRUCTIONS_PATH
  → Read this file first — it is the full protocol for this stage.

Project directory: $PROJECT_ROOT
Epoch: $EPOCH
Output artifact: $ARTIFACT

Required inputs (read before starting work):
${REQUIRED_SECTION:-  (none)}
Optional inputs (read if present, skip if absent):
${OPTIONAL_SECTION:-  (none)}
You MUST write the output artifact at the path above with this frontmatter:
---
epoch: $EPOCH
result: <one of: $TRANSITION_KEYS>
---

Then write the body according to the stage instructions file.
EOF
