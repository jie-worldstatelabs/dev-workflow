#!/bin/bash

# Dev Workflow Status Update Script
# Atomic phase transition: validates required inputs, increments epoch,
# updates status, and deletes the new stage's output artifact.
#
# Resolves which workflow to operate on (multiple topics may coexist):
#   --topic <name>           explicit
#   else                     if exactly one active workflow exists, use it
#
# Usage: update-status.sh --status <status> [--topic <topic>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NEW_STATUS=""
TOPIC_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --status=*) NEW_STATUS="${1#--status=}"; shift ;;
    --status)   NEW_STATUS="$2";             shift 2 ;;
    --topic=*)  TOPIC_ARG="${1#--topic=}";   shift ;;
    --topic)    TOPIC_ARG="$2";              shift 2 ;;
    *)
      echo "Warning: unknown argument: $1" >&2
      shift
      ;;
  esac
done

if [[ -z "$NEW_STATUS" ]]; then
  echo "⚠️  --status is required" >&2
  exit 1
fi

# Route to the right state.md
if [[ -n "$TOPIC_ARG" ]]; then
  DESIRED_TOPIC="$TOPIC_ARG"
fi

if ! resolve_state; then
  echo "⚠️  Could not resolve an active dev workflow" >&2
  if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
    echo "   Available workflows:" >&2
    echo "$workflows" >&2
    echo "   Pass --topic <name> to select one." >&2
  else
    echo "   No workflows found. Run /meta-workflow:start to start one." >&2
  fi
  exit 1
fi

resolve_workflow_dir_from_state

if ! config_check; then
  exit 1
fi

# If the project was pre-git at setup time but has a git repo now (very
# common: greenfield scaffold that the executor initialises a few minutes
# later), backfill baseline + project_fingerprint before proceeding.
# ensure_baseline_and_fingerprint is idempotent and cheap.
ensure_baseline_and_fingerprint "$STATE_FILE" || true

# Validate: the new status must be either an active stage or a terminal stage.
if ! config_is_stage "$NEW_STATUS" && ! is_terminal_status "$NEW_STATUS"; then
  echo "❌ Unknown status: '$NEW_STATUS'" >&2
  echo "   Valid stages: $(config_all_stages | tr '\n' ' ')" >&2
  echo "   Terminal stages: $(config_terminal_stages | tr '\n' ' ')" >&2
  exit 1
fi

# Read current state
CURRENT_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
if [[ -z "$CURRENT_EPOCH" ]] || ! [[ "$CURRENT_EPOCH" =~ ^[0-9]+$ ]]; then
  CURRENT_EPOCH=0
fi
NEW_EPOCH=$((CURRENT_EPOCH + 1))

# ──────────────────────────────────────────────────────────────
# Validate required inputs for the new stage
# ──────────────────────────────────────────────────────────────
if config_is_stage "$NEW_STATUS"; then
  MISSING_INPUTS=()
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    input_path=
    if [[ "$type" == "run_file" ]]; then
      input_path="$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    else
      input_path="$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    fi
    if [[ ! -f "$input_path" ]]; then
      MISSING_INPUTS+=("$input_path ($description)")
    fi
  done < <(config_required_inputs "$NEW_STATUS")

  if [[ ${#MISSING_INPUTS[@]} -gt 0 ]]; then
    echo "❌ Cannot transition to '$NEW_STATUS' for topic '$TOPIC': required inputs missing:" >&2
    for m in "${MISSING_INPUTS[@]}"; do
      echo "   - $m" >&2
    done
    echo "" >&2
    echo "   (required inputs are declared in workflow.json → stages.$NEW_STATUS.inputs.required)" >&2
    exit 1
  fi
fi

# Update status + epoch (two calls; set_fm_field already does atomic temp+mv)
set_fm_field "$STATE_FILE" status "$NEW_STATUS"
set_fm_field "$STATE_FILE" epoch "$NEW_EPOCH"

# Invalidate the artifact the new stage will produce
NEW_ARTIFACT=""
if config_is_stage "$NEW_STATUS"; then
  NEW_ARTIFACT="$(config_artifact_path "$NEW_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
  rm -f "$NEW_ARTIFACT"
fi

# ──────────────────────────────────────────────────────────────
# Cloud mirror — mirror state + artifact wipe to the server.
# ──────────────────────────────────────────────────────────────
if is_cloud_session "$RUN_DIR_NAME"; then
  _active="true"
  if is_terminal_status "$NEW_STATUS"; then
    _active="false"
  fi
  cloud_post_state "$RUN_DIR_NAME" "$NEW_STATUS" "$NEW_EPOCH" "" "$_active" || {
    echo "⚠️  cloud state sync failed; local shadow is ahead of server" >&2
  }
  if config_is_stage "$NEW_STATUS"; then
    cloud_delete_artifact "$RUN_DIR_NAME" "$NEW_STATUS" || true
  fi
  # Refresh the working-tree diff on every transition so the UI stays in
  # step with whatever the executor committed. Cheap (git diff + curl) and
  # best-effort — failures never block the transition.
  cloud_post_diff "$RUN_DIR_NAME" || true
  if is_terminal_status "$NEW_STATUS"; then
    cloud_post_archive "$RUN_DIR_NAME" || true
    # Terminal status = we're done. Wipe the shadow so nothing stays on
    # this machine; server keeps the audit trail. Same cleanup as cancel.
    # `|| true` both: the terminal transition has already succeeded on
    # the server; a cleanup glitch must not surface as a script exit 1
    # and make the main agent think the transition failed.
    cloud_wipe_scratch "$RUN_DIR_NAME" || true
    cloud_unregister_session "$RUN_DIR_NAME" || true
  fi
fi

echo "[meta-workflow] Topic: $TOPIC | Status: $NEW_STATUS | epoch: $NEW_EPOCH"

if config_is_stage "$NEW_STATUS"; then
  config_show_stage_context "$NEW_STATUS" "$RUN_DIR_NAME" "$PROJECT_ROOT"
fi
