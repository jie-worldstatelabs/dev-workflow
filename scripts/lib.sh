#!/bin/bash
# Shared utilities for dev-workflow scripts.
#
# Groups:
#   1. .dev-workflow/ discovery (find_dw_root)
#   2. State resolution (resolve_state) — locates the right state.md among
#      possibly many per-topic subdirs
#   3. Workflow config access (reads workflow.json)

# ──────────────────────────────────────────────────────────────
# Plugin & default workflow paths
# ──────────────────────────────────────────────────────────────

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$_LIB_DIR")"

# A workflow is a directory containing workflow.json + one {stage}.md per stage.
# Default ships at skills/dev-workflow/workflow/.
DEFAULT_WORKFLOW_DIR="${PLUGIN_ROOT}/skills/dev-workflow/workflow"

# Resolved workflow dir + config file (may be overridden by resolve_workflow_dir_from_state)
WORKFLOW_DIR="$DEFAULT_WORKFLOW_DIR"
CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"

# ──────────────────────────────────────────────────────────────
# .dev-workflow/ discovery
# ──────────────────────────────────────────────────────────────

# Echo the absolute path to the nearest .dev-workflow/ dir (upward walk from CWD).
# Returns 1 if none found.
find_dw_root() {
  if [[ -d ".dev-workflow" ]]; then
    echo "$(pwd)/.dev-workflow"
    return 0
  fi
  local dir
  dir="$(pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.dev-workflow" ]]; then
      echo "$dir/.dev-workflow"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Returns 0 if the given status is terminal/paused (i.e. inactive).
_is_inactive_status() {
  case "$1" in
    complete|escalated|interrupted) return 0 ;;
    *) return 1 ;;
  esac
}

# Read a YAML frontmatter scalar from a file; echoes the value.
_read_fm_field() {
  local file="$1" field="$2"
  grep "^${field}:" "$file" 2>/dev/null \
    | head -1 \
    | sed "s/^${field}: *//" \
    | sed 's/^"\(.*\)"$/\1/' \
    | tr -d '[:space:]'
}

# ──────────────────────────────────────────────────────────────
# State resolution
# ──────────────────────────────────────────────────────────────
#
# Layout (v1.11+): <project>/.dev-workflow/<topic>/state.md plus per-stage
# reports in the same <topic>/ subdir. Multiple topics may coexist so long
# as at most ONE is active at any moment (sessions switch focus serially).
#
# resolve_state() is the main entry point. Callers populate environment
# variables to guide the search:
#
#   DESIRED_TOPIC=<name>   — direct: .dev-workflow/<name>/state.md
#   DESIRED_SESSION=<id>   — find state.md owned by this session (or claimable)
#                            Prefers ACTIVE state.md; falls back to unclaimed.
#   (neither set)          — if exactly one ACTIVE state.md exists, use it
#
# On success, sets: STATE_FILE, TOPIC, TOPIC_DIR, PROJECT_ROOT
# Returns 0 on success, 1 if nothing resolvable.

resolve_state() {
  local dw
  dw="$(find_dw_root)" || return 1
  local project_root
  project_root="$(dirname "$dw")"

  # Strategy 1: explicit topic wins
  if [[ -n "${DESIRED_TOPIC:-}" ]]; then
    local sd="$dw/${DESIRED_TOPIC}/state.md"
    if [[ -f "$sd" ]]; then
      STATE_FILE="$sd"
      TOPIC="$DESIRED_TOPIC"
      TOPIC_DIR="$dw/$TOPIC"
      PROJECT_ROOT="$project_root"
      return 0
    fi
    return 1
  fi

  # Collect all state.md files
  local -a all_states=()
  for sd in "$dw"/*/state.md; do
    [[ -f "$sd" ]] || continue
    all_states+=("$sd")
  done

  # Legacy: flat .dev-workflow/state.md (pre-v1.11) — support as single workflow
  if [[ -f "$dw/state.md" ]] && [[ ${#all_states[@]} -eq 0 ]]; then
    STATE_FILE="$dw/state.md"
    TOPIC="$(_read_fm_field "$STATE_FILE" topic)"
    TOPIC_DIR="$dw"  # legacy: no subdir
    PROJECT_ROOT="$project_root"
    return 0
  fi

  [[ ${#all_states[@]} -eq 0 ]] && return 1

  # Strategy 2: session-based match (prefer active, fall back to unclaimed)
  if [[ -n "${DESIRED_SESSION:-}" ]]; then
    # First pass: exact session match + active status
    local sd ss status
    for sd in "${all_states[@]}"; do
      ss="$(_read_fm_field "$sd" session_id)"
      status="$(_read_fm_field "$sd" status)"
      if [[ "$ss" == "$DESIRED_SESSION" ]] && ! _is_inactive_status "$status"; then
        STATE_FILE="$sd"
        TOPIC_DIR="$(dirname "$sd")"
        TOPIC="$(basename "$TOPIC_DIR")"
        PROJECT_ROOT="$project_root"
        return 0
      fi
    done
    # Second pass: exact session match + any status (paused workflow in same session)
    for sd in "${all_states[@]}"; do
      ss="$(_read_fm_field "$sd" session_id)"
      if [[ "$ss" == "$DESIRED_SESSION" ]]; then
        STATE_FILE="$sd"
        TOPIC_DIR="$(dirname "$sd")"
        TOPIC="$(basename "$TOPIC_DIR")"
        PROJECT_ROOT="$project_root"
        return 0
      fi
    done
    # Third pass: unclaimed (session_id empty) — auto-claim candidate. Pick newest.
    local newest="" newest_mtime=0
    for sd in "${all_states[@]}"; do
      ss="$(_read_fm_field "$sd" session_id)"
      if [[ -z "$ss" ]]; then
        local mt
        mt=$(stat -f %m "$sd" 2>/dev/null || stat -c %Y "$sd" 2>/dev/null || echo 0)
        if [[ "$mt" -gt "$newest_mtime" ]]; then
          newest_mtime=$mt
          newest="$sd"
        fi
      fi
    done
    if [[ -n "$newest" ]]; then
      STATE_FILE="$newest"
      TOPIC_DIR="$(dirname "$newest")"
      TOPIC="$(basename "$TOPIC_DIR")"
      PROJECT_ROOT="$project_root"
      return 0
    fi
    return 1
  fi

  # Strategy 3: no hint — if exactly one ACTIVE state.md, use it
  local -a active=()
  local sd status
  for sd in "${all_states[@]}"; do
    status="$(_read_fm_field "$sd" status)"
    _is_inactive_status "$status" && continue
    active+=("$sd")
  done
  if [[ ${#active[@]} -eq 1 ]]; then
    STATE_FILE="${active[0]}"
    TOPIC_DIR="$(dirname "$STATE_FILE")"
    TOPIC="$(basename "$TOPIC_DIR")"
    PROJECT_ROOT="$project_root"
    return 0
  fi
  # Zero or multiple active — ambiguous
  return 1
}

# List all workflows (state.md files) under .dev-workflow/, with their status.
# Useful for error messages when resolve_state is ambiguous.
list_all_workflows() {
  local dw
  dw="$(find_dw_root)" || return 1
  for sd in "$dw"/*/state.md; do
    [[ -f "$sd" ]] || continue
    local topic status session
    topic="$(basename "$(dirname "$sd")")"
    status="$(_read_fm_field "$sd" status)"
    session="$(_read_fm_field "$sd" session_id)"
    echo "  - $topic (status: $status, session: ${session:-unclaimed})"
  done
}

# ──────────────────────────────────────────────────────────────
# Workflow config access
# ──────────────────────────────────────────────────────────────

# Called AFTER resolve_state so state.md can override the default workflow dir.
resolve_workflow_dir_from_state() {
  if [[ -z "${STATE_FILE:-}" ]] || [[ ! -f "${STATE_FILE}" ]]; then
    return 0
  fi
  local dir
  dir="$(_read_fm_field "$STATE_FILE" workflow_dir)"
  if [[ -n "$dir" ]]; then
    WORKFLOW_DIR="$dir"
    CONFIG_FILE="${dir}/workflow.json"
  fi
}

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

config_next_status() {
  jq -r --arg s "$1" --arg r "$2" '.stages[$s].transitions[$r] // ""' "$CONFIG_FILE"
}

config_transition_keys() {
  jq -r --arg s "$1" '.stages[$s].transitions // {} | keys | join(" ")' "$CONFIG_FILE"
}

config_required_inputs() {
  jq -r --arg s "$1" '.stages[$s].inputs.required[]? | "\(.from_stage)\t\(.description)"' "$CONFIG_FILE"
}

config_optional_inputs() {
  jq -r --arg s "$1" '.stages[$s].inputs.optional[]? | "\(.from_stage)\t\(.description)"' "$CONFIG_FILE"
}

# Artifact path for a stage's output (convention: <topic>/<stage>-report.md
# inside .dev-workflow/).
config_artifact_path() {
  local stage="$1"
  local topic="$2"
  local project_root="$3"
  echo "${project_root}/.dev-workflow/${topic}/${stage}-report.md"
}

# Stage-instructions markdown path.
config_stage_instructions_path() {
  local stage="$1"
  echo "${WORKFLOW_DIR}/${stage}.md"
}

# Print summary of a stage's I/O context (for Claude's context after transitions).
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
