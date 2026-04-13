#!/bin/bash
# Shared utilities for dev-workflow scripts.
#
# Two groups of helpers:
#   1. State file resolution (resolve_state, sets STATE_FILE, PROJECT_ROOT)
#   2. Workflow config access (reads workflow.json — the single source of
#      truth for stages, transitions, interruptible flags, and inputs)

# ──────────────────────────────────────────────────────────────
# State file resolution
# ──────────────────────────────────────────────────────────────

resolve_state() {
  local state_file=""

  # 1. Check CWD
  if [[ -f ".dev-workflow/state.md" ]]; then
    state_file="$(pwd)/.dev-workflow/state.md"
  fi

  # 2. Search upward from CWD
  if [[ -z "$state_file" ]]; then
    local dir
    dir="$(pwd)"
    while [[ "$dir" != "/" ]]; do
      if [[ -f "$dir/.dev-workflow/state.md" ]]; then
        state_file="$dir/.dev-workflow/state.md"
        break
      fi
      dir="$(dirname "$dir")"
    done
  fi

  if [[ -z "$state_file" ]]; then
    return 1
  fi

  STATE_FILE="$state_file"

  PROJECT_ROOT=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" \
    | grep '^project_root:' \
    | sed 's/project_root: *//' \
    | sed 's/^"\(.*\)"$/\1/') || true
  if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(dirname "$(dirname "$STATE_FILE")")"
  fi

  return 0
}

# ──────────────────────────────────────────────────────────────
# Config helpers
# ──────────────────────────────────────────────────────────────
# Callers source this file and then call these functions.
# CONFIG_FILE is resolved relative to this script's location (plugin root).
# ──────────────────────────────────────────────────────────────

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$(dirname "$_LIB_DIR")/workflow.json"

config_check() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ workflow.json not found at $CONFIG_FILE" >&2
    return 1
  fi
  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "❌ workflow.json is not valid JSON" >&2
    return 1
  fi
  return 0
}

config_initial_stage() {
  jq -r '.initial_stage' "$CONFIG_FILE"
}

config_terminal_stages() {
  jq -r '.terminal_stages[]' "$CONFIG_FILE"
}

config_all_stages() {
  jq -r '.stages | keys[]' "$CONFIG_FILE"
}

# Returns 0 if the given status is a defined active stage.
config_is_stage() {
  jq -e --arg s "$1" '.stages[$s]' "$CONFIG_FILE" > /dev/null 2>&1
}

config_is_terminal() {
  jq -e --arg s "$1" '.terminal_stages | index($s)' "$CONFIG_FILE" > /dev/null 2>&1
}

config_is_interruptible() {
  local s="$1"
  local v
  v=$(jq -r --arg s "$s" '.stages[$s].interruptible // false' "$CONFIG_FILE")
  [[ "$v" == "true" ]]
}

config_execution_type() {
  jq -r --arg s "$1" '.stages[$s].execution.type // ""' "$CONFIG_FILE"
}

config_subagent_type() {
  jq -r --arg s "$1" '.stages[$s].execution.subagent_type // ""' "$CONFIG_FILE"
}

config_model() {
  jq -r --arg s "$1" '.stages[$s].execution.model // ""' "$CONFIG_FILE"
}

# Returns next_status for a given (stage, result). Empty string if not in transition table.
config_next_status() {
  jq -r --arg s "$1" --arg r "$2" '.stages[$s].transitions[$r] // ""' "$CONFIG_FILE"
}

# All transition keys (valid results) for a stage, space-separated.
config_transition_keys() {
  jq -r --arg s "$1" '.stages[$s].transitions // {} | keys | join(" ")' "$CONFIG_FILE"
}

# Required/optional inputs — output format: one line per input, tab-separated:
#   <from_stage>\t<description>
config_required_inputs() {
  jq -r --arg s "$1" '.stages[$s].inputs.required[]? | "\(.from_stage)\t\(.description)"' "$CONFIG_FILE"
}

config_optional_inputs() {
  jq -r --arg s "$1" '.stages[$s].inputs.optional[]? | "\(.from_stage)\t\(.description)"' "$CONFIG_FILE"
}

# Artifact filename (topic-prefixed) for a stage. Convention: {topic}-{stage}-report.md
config_artifact_path() {
  local stage="$1"
  local topic="$2"
  local project_root="$3"
  echo "${project_root}/.dev-workflow/${topic}-${stage}-report.md"
}

# Stage-instructions markdown path. Convention: skills/dev-workflow/stages/<stage>.md
# relative to the plugin root.
config_stage_instructions_path() {
  local stage="$1"
  echo "$(dirname "$_LIB_DIR")/skills/dev-workflow/stages/${stage}.md"
}

# Print a summary of a stage's I/O context (required/optional input paths,
# output path). Called by setup-workflow.sh and update-status.sh so that
# Claude sees the new stage's artifact paths right when it enters the stage,
# without relying on hook injections (which only fire on session-stop or
# Agent-tool launch). This is the primary delivery mechanism for inline
# stages — for subagent stages, agent-guard.sh re-injects the same info
# at Agent-tool launch time (belt-and-suspenders).
config_show_stage_context() {
  local stage="$1"
  local topic="$2"
  local project_root="$3"

  local required=""
  while IFS=$'\t' read -r from_stage description; do
    [[ -z "$from_stage" ]] && continue
    local path
    path="$(config_artifact_path "$from_stage" "$topic" "$project_root")"
    required+="     - ${path} — ${description}"$'\n'
  done < <(config_required_inputs "$stage")

  local optional=""
  while IFS=$'\t' read -r from_stage description; do
    [[ -z "$from_stage" ]] && continue
    local path
    path="$(config_artifact_path "$from_stage" "$topic" "$project_root")"
    optional+="     - ${path} — ${description} (if exists)"$'\n'
  done < <(config_optional_inputs "$stage")

  if [[ -n "$required" ]]; then
    echo "   Required inputs:"
    printf '%s' "$required"
  fi
  if [[ -n "$optional" ]]; then
    echo "   Optional inputs:"
    printf '%s' "$optional"
  fi
  echo "   Output: $(config_artifact_path "$stage" "$topic" "$project_root")"
}
