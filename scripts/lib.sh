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

# Set (or insert if missing) a frontmatter scalar in state.md. Operates only
# on the first YAML frontmatter block (between the first two --- lines).
set_fm_field() {
  local file="$1" field="$2" value="$3"
  awk -v field="$field" -v value="$value" '
    BEGIN { fm=0; done=0 }
    /^---$/ {
      fm++
      if (fm == 2 && !done) { print field ": " value; done=1 }
      print; next
    }
    fm == 1 && $0 ~ "^" field ":" { if (!done) { print field ": " value; done=1 } ; next }
    { print }
  ' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
}

# ──────────────────────────────────────────────────────────────
# Session-id cache (written by hooks/session-start.sh, read by
# setup-workflow.sh and continue-workflow.sh)
# ──────────────────────────────────────────────────────────────
#
# Claude Code exposes session_id to hooks via stdin JSON, but NOT to the
# Bash tool's subprocess env. The cache bridges that gap.
#
# SessionStart hook writes two keys:
#   cwd-<sha1(cwd)>   matches when reader's cwd == hook's cwd
#   ppid-<PPID>       matches when reader's $PPID (walked up if needed) is
#                     the Claude Code harness PID (same as hook's $PPID)
#
# Readers try both, walking the process tree on the ppid path. If neither
# matches, the session_id is unknown and owner_session_id stays empty —
# callers fall back to worktree-level blocking semantics.

_DW_SESSION_CACHE_DIR="${HOME}/.dev-workflow/session-cache"

_session_cache_cwd_key() {
  printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16
}

# Echo the cached session_id for the current session, or empty if unknown.
read_cached_session_id() {
  local cache="$_DW_SESSION_CACHE_DIR"
  local key
  # Try cwd key first (most reliable when there's no cd-drift)
  key="$(_session_cache_cwd_key)"
  if [[ -f "${cache}/cwd-${key}" ]]; then
    cat "${cache}/cwd-${key}"
    return 0
  fi
  # Walk up the process tree looking for a matching ppid cache file
  local pid=$PPID
  local hops=0
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $hops -lt 8 ]]; do
    if [[ -f "${cache}/ppid-${pid}" ]]; then
      cat "${cache}/ppid-${pid}"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    hops=$((hops + 1))
  done
  echo ""
}

# ──────────────────────────────────────────────────────────────
# State resolution
# ──────────────────────────────────────────────────────────────
#
# Layout (v1.11+): <project>/.dev-workflow/<topic>/state.md plus per-stage
# reports in the same <topic>/ subdir. Multiple topics may coexist so long
# as at most ONE is active at any moment (sessions switch focus serially).
#
# resolve_state() is the main entry point. Worktree-based model: at most
# one workflow per worktree, so resolution is simple — find the single
# state.md in .dev-workflow/*/state.md.
#
# Optional:
#   DESIRED_TOPIC=<name>   — if set, filter to the state.md whose topic
#                            frontmatter matches (for cross-worktree CLI
#                            commands, or to pick among multiple dirs if
#                            ever more than one coexists)
#
# On success, sets: STATE_FILE, TOPIC, RUN_DIR_NAME, TOPIC_DIR, PROJECT_ROOT
# Returns 0 on success, 1 if nothing resolvable.

_populate_state_vars() {
  local sd="$1"
  local project_root="$2"
  STATE_FILE="$sd"
  TOPIC_DIR="$(dirname "$sd")"
  RUN_DIR_NAME="$(basename "$TOPIC_DIR")"
  TOPIC="$(_read_fm_field "$sd" topic)"
  [[ -z "$TOPIC" ]] && TOPIC="$RUN_DIR_NAME"
  PROJECT_ROOT="$project_root"
}

resolve_state() {
  local dw
  dw="$(find_dw_root)" || return 1
  local project_root
  project_root="$(dirname "$dw")"

  # Session-keyed layout: .dev-workflow/<session_id>/state.md
  # Primary resolution: DESIRED_SESSION (caller-supplied, typically from
  # HOOK_INPUT in hooks) or the cached session_id for this Claude session.
  local session="${DESIRED_SESSION:-}"
  if [[ -z "$session" ]]; then
    session="$(read_cached_session_id)"
  fi

  if [[ -n "$session" ]] && [[ -f "$dw/$session/state.md" ]]; then
    _populate_state_vars "$dw/$session/state.md" "$project_root"
    return 0
  fi

  # Fallback for cross-session CLI queries: DESIRED_TOPIC filters by the
  # `topic:` field in state.md across all session dirs.
  if [[ -n "${DESIRED_TOPIC:-}" ]]; then
    local sd
    for sd in "$dw"/*/state.md; do
      [[ -f "$sd" ]] || continue
      local tp
      tp="$(_read_fm_field "$sd" topic)"
      if [[ "$tp" == "$DESIRED_TOPIC" ]]; then
        _populate_state_vars "$sd" "$project_root"
        return 0
      fi
    done
  fi

  # Legacy: flat .dev-workflow/state.md (pre-v1.11) — single-workflow fallback
  if [[ -f "$dw/state.md" ]]; then
    _populate_state_vars "$dw/state.md" "$project_root"
    TOPIC_DIR="$dw"
    RUN_DIR_NAME=""
    return 0
  fi

  return 1
}

# Find a state.md with status=interrupted across all session dirs under
# .dev-workflow/. Used by continue-workflow.sh for cross-session takeover.
# On success: sets STATE_FILE/TOPIC_DIR/RUN_DIR_NAME/TOPIC/PROJECT_ROOT to
# the found dir (still keyed by the ORIGINAL session id — caller must
# rename to new session id).
resolve_interrupted_state() {
  local dw
  dw="$(find_dw_root)" || return 1
  local project_root
  project_root="$(dirname "$dw")"

  local match_count=0
  local match=""
  local sd
  for sd in "$dw"/*/state.md; do
    [[ -f "$sd" ]] || continue
    local st
    st="$(_read_fm_field "$sd" status)"
    if [[ "$st" == "interrupted" ]]; then
      match_count=$((match_count + 1))
      match="$sd"
    fi
  done

  if [[ $match_count -eq 0 ]]; then
    return 1
  fi
  if [[ $match_count -gt 1 ]]; then
    echo "⚠️  Multiple interrupted workflows found; disambiguate with --session <id>:" >&2
    for sd in "$dw"/*/state.md; do
      [[ -f "$sd" ]] || continue
      local st
      st="$(_read_fm_field "$sd" status)"
      [[ "$st" == "interrupted" ]] || continue
      local tp
      tp="$(_read_fm_field "$sd" topic)"
      echo "   - session: $(basename "$(dirname "$sd")")   topic: ${tp:-?}" >&2
    done
    return 2
  fi

  _populate_state_vars "$match" "$project_root"
  return 0
}

# List all workflows (state.md files) under .dev-workflow/, with their status.
# Useful for error messages when resolve_state is ambiguous.
list_all_workflows() {
  local dw
  dw="$(find_dw_root)" || return 1
  for sd in "$dw"/*/state.md; do
    [[ -f "$sd" ]] || continue
    local topic status
    topic="$(_read_fm_field "$sd" topic)"
    status="$(_read_fm_field "$sd" status)"
    echo "  - topic=${topic:-?} status=$status"
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

# Structural validation of the resolved workflow config + directory. Checks:
#   - initial_stage is set and references a declared stage
#   - terminal_stages is a non-empty array
#   - each stage has a matching <stage>.md next to workflow.json
#   - each stage's execution.type is inline | subagent
#   - subagent stages must declare subagent_type
#   - each transition target is either another stage or a terminal stage
#   - each required/optional input's from_stage references a declared stage
# Emits one "❌ ..." line per issue on stderr; returns 0 only on clean.
# Assumes config_check has already passed (file exists, valid JSON).
config_validate() {
  local errors=0

  # initial_stage
  local init; init="$(jq -r '.initial_stage // ""' "$CONFIG_FILE")"
  if [[ -z "$init" ]]; then
    echo "❌ .initial_stage is missing" >&2; errors=$((errors + 1))
  elif ! config_is_stage "$init"; then
    echo "❌ .initial_stage='$init' is not declared under .stages" >&2; errors=$((errors + 1))
  fi

  # terminal_stages
  local term_count
  term_count=$(jq '.terminal_stages | if type=="array" then length else -1 end' "$CONFIG_FILE")
  if [[ "$term_count" -lt 0 ]]; then
    echo "❌ .terminal_stages must be an array" >&2; errors=$((errors + 1))
  elif [[ "$term_count" -eq 0 ]]; then
    echo "❌ .terminal_stages is empty (need at least one, e.g. \"complete\")" >&2
    errors=$((errors + 1))
  fi

  # stages must be an object
  local stage_type
  stage_type=$(jq -r '.stages | type' "$CONFIG_FILE")
  if [[ "$stage_type" != "object" ]]; then
    echo "❌ .stages must be an object (got $stage_type)" >&2
    return $((errors + 1))
  fi

  # Per-stage checks
  local stage
  while read -r stage; do
    [[ -z "$stage" ]] && continue
    local prefix="stage '$stage':"

    # .md file exists next to workflow.json
    local md; md="$(config_stage_instructions_path "$stage")"
    if [[ ! -f "$md" ]]; then
      echo "❌ $prefix instructions file missing: $md" >&2; errors=$((errors + 1))
    fi

    # execution.type sanity
    local etype; etype="$(jq -r --arg s "$stage" '.stages[$s].execution.type // ""' "$CONFIG_FILE")"
    case "$etype" in
      inline|subagent) ;;
      "") echo "❌ $prefix execution.type is missing" >&2; errors=$((errors + 1)) ;;
      *)  echo "❌ $prefix execution.type='$etype' must be 'inline' or 'subagent'" >&2
          errors=$((errors + 1)) ;;
    esac

    # subagent must declare subagent_type
    if [[ "$etype" == "subagent" ]]; then
      local sub; sub="$(jq -r --arg s "$stage" '.stages[$s].execution.subagent_type // ""' "$CONFIG_FILE")"
      if [[ -z "$sub" ]]; then
        echo "❌ $prefix execution.type=subagent but execution.subagent_type is empty" >&2
        errors=$((errors + 1))
      fi
    fi

    # transitions point to a declared stage OR a terminal
    local result next
    while IFS=$'\t' read -r result next; do
      [[ -z "$result" ]] && continue
      if [[ -z "$next" ]]; then
        echo "❌ $prefix transitions['$result'] has no target" >&2
        errors=$((errors + 1)); continue
      fi
      if ! config_is_stage "$next" && ! config_is_terminal "$next"; then
        echo "❌ $prefix transitions['$result'] → '$next' is neither a declared stage nor a terminal" >&2
        errors=$((errors + 1))
      fi
    done < <(jq -r --arg s "$stage" '.stages[$s].transitions // {} | to_entries[]? | "\(.key)\t\(.value)"' "$CONFIG_FILE")

    # inputs.required[*] / inputs.optional[*] from_stage refs exist
    local kind from
    for kind in required optional; do
      while read -r from; do
        [[ -z "$from" ]] && continue
        if ! config_is_stage "$from"; then
          echo "❌ $prefix inputs.$kind references unknown from_stage '$from'" >&2
          errors=$((errors + 1))
        fi
      done < <(jq -r --arg s "$stage" --arg k "$kind" '.stages[$s].inputs[$k][]? | .from_stage // empty' "$CONFIG_FILE")
    done
  done < <(config_all_stages)

  return $errors
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

# Artifact path for a stage's output.
# Convention: <project>/.dev-workflow/<run_dir_name>/<stage>-report.md
# where <run_dir_name> = "<topic>-<run_id>" (the run's own subdir).
config_artifact_path() {
  local stage="$1"
  local run_dir_name="$2"
  local project_root="$3"
  echo "${project_root}/.dev-workflow/${run_dir_name}/${stage}-report.md"
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
