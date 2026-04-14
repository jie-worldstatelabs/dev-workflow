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
# Archive helper — move a run dir to .dev-workflow/.archive/
# ──────────────────────────────────────────────────────────────
#
# Shared by setup-workflow.sh (archive-on-replace) and cancel-workflow.sh
# (archive-on-cancel) so the "keep audit trail instead of rm -rf" policy
# lives in one place.
#
# Archive path: <.dev-workflow>/.archive/<YYYYMMDD-HHMMSS>-<topic>[-<suffix>]/
# Hidden dot-dir so resolve_state's "$dw"/*/state.md glob skips it.
#
# Args:
#   $1 = run dir (absolute), typically .dev-workflow/<session_id>
#   $2 = topic fallback (optional, used when state.md is missing/empty)
#   $3 = suffix (optional, e.g. "cancelled" to distinguish intent)
#
# Side effects:
#   On success: sets ARCHIVE_RESULT_PATH to the archive dir, returns 0.
#   On skip   : run dir missing or empty, ARCHIVE_RESULT_PATH="", returns 1.
#   On error  : mv failed, falls back to rm -rf the run dir so callers can
#               proceed, ARCHIVE_RESULT_PATH="", returns 2.
archive_run_dir() {
  local run_dir="$1"
  local topic_fallback="${2:-}"
  local suffix="${3:-}"
  ARCHIVE_RESULT_PATH=""

  if [[ ! -d "$run_dir" ]] || [[ -z "$(ls -A "$run_dir" 2>/dev/null)" ]]; then
    return 1
  fi

  local dw_root; dw_root="$(dirname "$run_dir")"
  local archive_root="${dw_root}/.archive"

  # Derive a human-readable topic label for the archive dir name.
  local topic=""
  if [[ -f "$run_dir/state.md" ]]; then
    topic=$(_read_fm_field "$run_dir/state.md" topic)
  fi
  if [[ -z "$topic" ]] && [[ -f "$run_dir/planning-report.md" ]]; then
    topic=$(grep -m1 '^# Planning Report' "$run_dir/planning-report.md" \
            | sed 's/^# Planning Report:* *//')
  fi
  [[ -z "$topic" ]] && topic="${topic_fallback:-orphan}"

  local topic_safe
  topic_safe=$(printf '%s' "$topic" | tr -c '[:alnum:]_-' '-' \
               | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-40)
  [[ -z "$topic_safe" ]] && topic_safe="orphan"

  local name="$(date -u +%Y%m%d-%H%M%S)-${topic_safe}"
  [[ -n "$suffix" ]] && name="${name}-${suffix}"

  mkdir -p "$archive_root"
  local base="${archive_root}/${name}"
  local target="$base"
  local n=1
  while [[ -e "$target" ]]; do
    target="${base}-${n}"
    n=$((n + 1))
  done

  if mv "$run_dir" "$target" 2>/dev/null; then
    ARCHIVE_RESULT_PATH="$target"
    return 0
  fi

  # mv failed — fall back to rm so caller can proceed with setup
  rm -rf "$run_dir"
  return 2
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
# matches, the session_id is unknown and setup-workflow.sh fails fast
# (it can't create a session-keyed run dir without one).

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
# Layout: <project>/.dev-workflow/<session_id>/state.md plus per-stage
# reports in the same <session_id>/ subdir. Each Claude session gets its
# own isolated run, so multiple sessions in the same worktree coexist
# without stepping on each other.
#
# resolve_state() is the main entry point. It keys by session_id: either
# DESIRED_SESSION (set by callers, e.g. hooks parsing HOOK_INPUT.session_id)
# or the cached session_id for the current Claude session
# (read_cached_session_id, populated by hooks/session-start.sh).
#
# Optional inputs (callers may set as shell vars before calling):
#   DESIRED_SESSION=<id>   — use this session's subdir (primary resolution)
#   DESIRED_TOPIC=<name>   — fallback: scan all session subdirs for one
#                            whose `topic:` frontmatter matches. Useful
#                            for CLI commands that want to target a
#                            specific run without knowing its session_id.
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
  # Cloud mode short-circuit: if the current session is registered as
  # cloud, read its shadow state.md from the scratch dir directly. The
  # project's worktree has no .dev-workflow/ in cloud mode, so walking up
  # from CWD would fail — the scratch dir is the only truth locally.
  local _sess="${DESIRED_SESSION:-}"
  if [[ -z "$_sess" ]]; then _sess="$(read_cached_session_id)"; fi
  if [[ -n "$_sess" ]] && is_cloud_session "$_sess"; then
    # Read scratch dir from the registry — allows cross-machine takeover
    # to alias one physical shadow under the local session_id without
    # renaming the on-disk directory.
    local _scratch_dir; _scratch_dir="$(cloud_registry_get "$_sess" scratch_dir)"
    [[ -z "$_scratch_dir" ]] && _scratch_dir="$(cloud_scratch_dir)/${_sess}"
    local _state="${_scratch_dir}/state.md"
    if [[ -f "$_state" ]]; then
      _populate_state_vars "$_state" ""
      local _pr; _pr="$(_read_fm_field "$_state" project_root)"
      [[ -z "$_pr" ]] && _pr="$(pwd)"
      PROJECT_ROOT="$_pr"
      return 0
    fi
  fi

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
# Resolution precedence:
#   1. DW_RUN_BASE env var — setup-workflow.sh exports this in cloud mode
#      before state.md exists, so config_show_stage_context prints the
#      right shadow path.
#   2. $TOPIC_DIR — set by resolve_state after state.md is located; points
#      to the correct run dir in both local and cloud modes.
#   3. Fallback: <project>/.dev-workflow/<run_dir_name>/<stage>-report.md —
#      the legacy local-mode path when neither of the above is populated.
config_artifact_path() {
  local stage="$1"
  local run_dir_name="$2"
  local project_root="$3"
  if [[ -n "${DW_RUN_BASE:-}" ]]; then
    echo "${DW_RUN_BASE}/${run_dir_name}/${stage}-report.md"
    return
  fi
  if [[ -n "${TOPIC_DIR:-}" ]]; then
    echo "${TOPIC_DIR}/${stage}-report.md"
    return
  fi
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

# ──────────────────────────────────────────────────────────────
# Cloud mode
# ──────────────────────────────────────────────────────────────
#
# Cloud mode puts the authoritative copy of state + artifacts on a
# remote server (the workflowUI webapp). A transient shadow lives under
# ~/.cache/dev-workflow/sessions/<session_id>/ so Claude's Read/Write
# tools still have real file paths to operate on. Every write is mirrored
# to the server via curl. The project worktree gets no .dev-workflow/ dir.
#
# Registry: ~/.dev-workflow/cloud-registry/<session_id>.json records
# {mode, session_id, scratch_dir, server, workflow_url}. Its presence is
# how every script/hook decides "cloud or local" — no env var needed.

CLOUD_REGISTRY_DIR="${HOME}/.dev-workflow/cloud-registry"
CLOUD_SCRATCH_BASE="${HOME}/.cache/dev-workflow/sessions"

# Default cloud server for this plugin build. Hard-coded so users only need
# to export DEV_WORKFLOW_API_TOKEN; the server URL is baked in. Override by
# exporting DEV_WORKFLOW_SERVER=... (useful for pointing at a local dev
# webapp, a staging deployment, or a fork).
: "${DEV_WORKFLOW_SERVER:=https://workflowui.vercel.app}"
export DEV_WORKFLOW_SERVER

cloud_scratch_dir() {
  echo "$CLOUD_SCRATCH_BASE"
}

cloud_registry_file() {
  echo "${CLOUD_REGISTRY_DIR}/${1}.json"
}

is_cloud_session() {
  local sid="$1"
  [[ -n "$sid" ]] && [[ -f "${CLOUD_REGISTRY_DIR}/${sid}.json" ]]
}

# Echo a field from the registry JSON. Returns empty if missing.
cloud_registry_get() {
  local sid="$1" field="$2"
  local f; f="$(cloud_registry_file "$sid")"
  [[ -f "$f" ]] || { echo ""; return; }
  jq -r --arg k "$field" '.[$k] // ""' "$f" 2>/dev/null
}

# Register a session as cloud-managed.
# Args:
#   $1 = session_id used as the registry file key (may be the local
#        Claude session_id in a takeover scenario)
#   $2 = server URL
#   $3 = workflow URL (may be empty)
#   $4 = scratch dir override (optional). Defaults to
#        ${CLOUD_SCRATCH_BASE}/${sid}. Used by cross-machine takeover
#        where one physical scratch dir is aliased under two keys.
cloud_register_session() {
  local sid="$1" server="$2" url="$3" scratch="${4:-}"
  [[ -z "$scratch" ]] && scratch="${CLOUD_SCRATCH_BASE}/${sid}"
  mkdir -p "$CLOUD_REGISTRY_DIR"
  jq -n \
    --arg sid "$sid" \
    --arg scratch "$scratch" \
    --arg server "$server" \
    --arg url "$url" \
    '{mode:"cloud", session_id:$sid, scratch_dir:$scratch, server:$server, workflow_url:$url}' \
    > "$(cloud_registry_file "$sid")"
}

# Drop the registry entry for a session — and any alias entries that
# point at the same scratch_dir (cross-machine takeover creates two
# registry files for one physical shadow; we must clean both).
cloud_unregister_session() {
  local sid="$1"
  local primary; primary="$(cloud_registry_file "$sid")"
  local scratch=""
  if [[ -f "$primary" ]]; then
    scratch="$(jq -r '.scratch_dir // ""' "$primary" 2>/dev/null)"
  fi
  rm -f "$primary"
  if [[ -n "$scratch" ]] && [[ -d "$CLOUD_REGISTRY_DIR" ]]; then
    local other other_scratch
    for other in "$CLOUD_REGISTRY_DIR"/*.json; do
      [[ -f "$other" ]] || continue
      other_scratch="$(jq -r '.scratch_dir // ""' "$other" 2>/dev/null)"
      [[ "$other_scratch" == "$scratch" ]] && rm -f "$other"
    done
  fi
}

# Wipe the local shadow for a session.
cloud_wipe_scratch() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  rm -rf "${CLOUD_SCRATCH_BASE}/${sid}"
}

# ──────────────────────────────────────────────────────────────
# Cloud env + HTTP helpers
# ──────────────────────────────────────────────────────────────

cloud_require_env() {
  # Auth is currently disabled — session_id in the URL is the capability.
  # Only the server URL must be set, and it always is (baked-in default
  # at the top of this file; users can override by exporting
  # DEV_WORKFLOW_SERVER). This function stays in place so a future
  # multi-user auth layer can plug back in without touching callers.
  if [[ -z "${DEV_WORKFLOW_SERVER:-}" ]]; then
    echo "❌ DEV_WORKFLOW_SERVER unexpectedly empty" >&2
    return 1
  fi
  return 0
}

_cloud_server() {
  local sid="${1:-}"
  if [[ -n "$sid" ]]; then
    local s; s="$(cloud_registry_get "$sid" server)"
    [[ -n "$s" ]] && { echo "$s"; return; }
  fi
  echo "${DEV_WORKFLOW_SERVER:-}"
}

# No-op header placeholder so every curl call site can keep passing
# `-H "$(_cloud_auth_header)"` unchanged. When auth comes back this is
# where the Authorization / API-key construction lands again.
_cloud_auth_header() {
  echo "X-Dev-Workflow: plugin"
}

# POST JSON to an endpoint; echoes the response body. Non-zero on HTTP error.
_cloud_post_json() {
  local url="$1" body="$2"
  curl -sS -fL -X POST "$url" \
    -H "$(_cloud_auth_header)" \
    -H "Content-Type: application/json" \
    --data "$body"
}

# ──────────────────────────────────────────────────────────────
# Remote workflow config fetch
# ──────────────────────────────────────────────────────────────
#
# Supported forms (matches setup-workflow.sh --workflow argument):
#   server://<name>   named template on $DEV_WORKFLOW_SERVER
#   http(s)://...     direct URL to a workflow directory (must serve
#                     workflow.json and one <stage>.md per stage key)
#   /abs/path         local absolute path (copied verbatim)
#   bare name         resolved against PLUGIN_ROOT/skills/dev-workflow/
#
# Destination is a local directory that setup-workflow.sh prepares — the
# scratch dir's .workflow-cache/ in cloud mode, or a fresh temp dir for
# local mode.

cloud_fetch_workflow_from_url() {
  local url="$1" dest="$2"
  mkdir -p "$dest"
  if ! curl -sS -fL -H "$(_cloud_auth_header)" -o "${dest}/workflow.json" "${url%/}/workflow.json"; then
    echo "❌ failed to fetch ${url%/}/workflow.json" >&2
    return 1
  fi
  if ! jq empty "${dest}/workflow.json" 2>/dev/null; then
    echo "❌ remote workflow.json is not valid JSON" >&2
    return 1
  fi
  local stages
  stages="$(jq -r '.stages | keys[]' "${dest}/workflow.json")"
  local stage
  while read -r stage; do
    [[ -z "$stage" ]] && continue
    if ! curl -sS -fL -H "$(_cloud_auth_header)" \
         -o "${dest}/${stage}.md" "${url%/}/${stage}.md"; then
      echo "⚠️  could not fetch ${stage}.md from ${url}" >&2
    fi
  done <<< "$stages"
  return 0
}

cloud_fetch_workflow_from_name() {
  local name="$1" dest="$2"
  cloud_require_env || return 1
  mkdir -p "$dest"
  local base="${DEV_WORKFLOW_SERVER}/api/workflows/${name}"
  local bundle
  bundle="$(curl -sS -fL -H "$(_cloud_auth_header)" "$base")" || {
    echo "❌ failed to fetch workflow '${name}' from server" >&2
    return 1
  }
  printf '%s' "$bundle" | jq '.workflow' > "${dest}/workflow.json"
  local files
  files="$(printf '%s' "$bundle" | jq -r '.files | keys[]?')"
  local fname
  while read -r fname; do
    [[ -z "$fname" ]] && continue
    curl -sS -fL -H "$(_cloud_auth_header)" \
      -o "${dest}/${fname}" "${base}/files/${fname}" || {
      echo "⚠️  could not fetch ${fname} from template ${name}" >&2
    }
  done <<< "$files"
  return 0
}

# ──────────────────────────────────────────────────────────────
# Cloud state / artifact sync
# ──────────────────────────────────────────────────────────────

# POST /api/sessions/<sid>/setup — initial workflow registration.
# Arguments:
#   $1 = session_id
#   $2 = topic
#   $3 = resolved workflow dir (must contain workflow.json + *.md)
#   $4 = workflow_url (may be empty)
#   $5 = project_root
#   $6 = worktree
#   $7 = force (true|false)
cloud_post_setup() {
  local sid="$1" topic="$2" wfdir="$3" wfurl="$4" proot="$5" wtree="$6" force="$7"
  cloud_require_env || return 1

  local wfjson="${wfdir}/workflow.json"
  [[ -f "$wfjson" ]] || { echo "❌ missing ${wfjson}" >&2; return 1; }

  # Build { "<stage>.md": "<contents>" } map for all .md files next to workflow.json.
  local files_json="{}"
  local f
  for f in "$wfdir"/*.md; do
    [[ -f "$f" ]] || continue
    local name content
    name="$(basename "$f")"
    content="$(cat "$f")"
    files_json="$(jq -n --argjson base "$files_json" --arg k "$name" --arg v "$content" \
                  '$base + {($k): $v}')"
  done

  local wfval; wfval="$(cat "$wfjson")"
  local payload
  payload="$(jq -n \
      --arg topic "$topic" \
      --argjson workflow "$wfval" \
      --argjson files "$files_json" \
      --arg url "$wfurl" \
      --arg proot "$proot" \
      --arg wtree "$wtree" \
      --argjson force "$force" \
      '{
        topic: $topic,
        workflow: $workflow,
        workflow_files: $files,
        workflow_url: (if $url == "" then null else $url end),
        project_root: (if $proot == "" then null else $proot end),
        worktree: (if $wtree == "" then null else $wtree end),
        force: $force
      }')"

  _cloud_post_json "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/setup" "$payload"
}

cloud_post_state() {
  local sid="$1" status="$2" epoch="$3" resume="${4:-}" active="${5:-true}" project_root="${6:-}"
  cloud_require_env || return 1
  local payload
  payload="$(jq -n \
      --arg status "$status" \
      --argjson epoch "${epoch:-1}" \
      --arg resume "$resume" \
      --argjson active "$active" \
      --arg pr "$project_root" \
      '{
        status: $status,
        epoch: $epoch,
        resume_status: (if $resume == "" then null else $resume end),
        active: $active
      } + (if $pr == "" then {} else {project_root: $pr} end)')"
  _cloud_post_json "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/state" "$payload" > /dev/null
}

# ──────────────────────────────────────────────────────────────
# Project identity (git root-commit fingerprint)
# ──────────────────────────────────────────────────────────────
#
# We use the set of root commits (`git rev-list --max-parents=0 HEAD`)
# as a stable, language-agnostic identifier for "this is the same
# project". Two clones of the same repo share a root commit; two
# unrelated repos cannot. The check is meant to catch the case where
# a user resumes a workflow from the wrong directory — not to verify
# that HEAD matches, so different revisions are allowed.

git_project_fingerprint() {
  local dir="${1:-.}"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo ""; return; }
  git -C "$dir" rev-list --max-parents=0 HEAD 2>/dev/null \
    | sort | tr '\n' ',' | sed 's/,$//'
}

# Compare the current CWD's fingerprint with the one recorded in the
# given state.md. Return codes:
#   0 → match, or either side has no fingerprint (skip — nothing to verify)
#   1 → mismatch: both sides have git but root commits differ
#   2 → mismatch: state.md has a fingerprint but the current dir is not git
verify_project_match() {
  local state_file="$1"
  local cwd="${2:-$(pwd)}"
  local expected; expected="$(_read_fm_field "$state_file" project_fingerprint)"
  [[ -z "$expected" ]] && return 0
  [[ "$expected" == "EMPTY" ]] && return 0
  local actual; actual="$(git_project_fingerprint "$cwd")"
  if [[ -z "$actual" ]]; then
    return 2
  fi
  if [[ "$actual" != "$expected" ]]; then
    return 1
  fi
  return 0
}

cloud_post_artifact() {
  local sid="$1" stage="$2" file="$3"
  cloud_require_env || return 1
  [[ -f "$file" ]] || return 1
  curl -sS -fL -X POST \
    -H "$(_cloud_auth_header)" \
    -H "Content-Type: text/plain" \
    --data-binary "@${file}" \
    "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/artifacts/${stage}" > /dev/null
}

cloud_delete_artifact() {
  local sid="$1" stage="$2"
  cloud_require_env || return 1
  curl -sS -fL -X DELETE \
    -H "$(_cloud_auth_header)" \
    "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/artifacts/${stage}" > /dev/null
}

cloud_post_archive() {
  local sid="$1"
  cloud_require_env || return 1
  curl -sS -fL -X POST \
    -H "$(_cloud_auth_header)" \
    "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/archive" > /dev/null
}

cloud_post_cancel() {
  local sid="$1"
  cloud_require_env || return 1
  curl -sS -fL -X POST \
    -H "$(_cloud_auth_header)" \
    "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/cancel" > /dev/null
}

cloud_delete_session() {
  local sid="$1"
  cloud_require_env || return 1
  curl -sS -fL -X DELETE \
    -H "$(_cloud_auth_header)" \
    "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}" > /dev/null
}

# ──────────────────────────────────────────────────────────────
# Cross-machine takeover
# ──────────────────────────────────────────────────────────────
#
# Rebuild a full local shadow for a cloud session by pulling every
# artifact, workflow file, state field, and baseline from the server.
# Used by continue-workflow.sh when the user runs `/dev-workflow:continue
# --session <id>` on a machine that has never seen this session before.
#
# Side effects:
#   Wipes and recreates ${CLOUD_SCRATCH_BASE}/<sid>/ with state.md,
#   baseline, every <stage>-report.md present on the server, and a
#   .workflow-cache/ populated from the server's workflow_files.
# Does NOT register the session — callers decide which key(s) to write.
# On success: echoes the absolute scratch dir path and returns 0.
# On failure: prints error to stderr and returns non-zero.
cloud_pull_shadow() {
  local sid="$1"
  cloud_require_env || return 1
  if [[ -z "$sid" ]]; then
    echo "❌ cloud_pull_shadow: session_id required" >&2
    return 1
  fi

  local snapshot
  snapshot="$(curl -sS -fL \
      -H "$(_cloud_auth_header)" \
      "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}" 2>/dev/null)" || {
    echo "❌ could not fetch session ${sid} from server" >&2
    return 1
  }
  if ! printf '%s' "$snapshot" | jq empty 2>/dev/null; then
    echo "❌ server returned non-JSON for session ${sid}" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$snapshot" | jq 'has("session")')" != "true" ]]; then
    echo "❌ session ${sid} not found on server" >&2
    return 1
  fi

  local shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  rm -rf "$shadow"
  mkdir -p "${shadow}/.workflow-cache"

  # workflow.json
  printf '%s' "$snapshot" | jq '.workflow' > "${shadow}/.workflow-cache/workflow.json"

  # Per-stage workflow files — fetched individually since the snapshot
  # only lists filenames (content lives behind GET /api/.../files/<name>).
  local fname
  while read -r fname; do
    [[ -z "$fname" ]] && continue
    curl -sS -fL -H "$(_cloud_auth_header)" \
      -o "${shadow}/.workflow-cache/${fname}" \
      "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/files/${fname}" 2>/dev/null || {
      echo "⚠️  could not fetch workflow file ${fname}" >&2
    }
  done < <(printf '%s' "$snapshot" | jq -r '.workflow_files[]?.filename')

  # Artifacts — written to <stage>-report.md with frontmatter intact.
  local count i=0
  count="$(printf '%s' "$snapshot" | jq '.artifacts | length')"
  while [[ $i -lt $count ]]; do
    local stage content
    stage="$(printf '%s' "$snapshot" | jq -r ".artifacts[$i].stage")"
    content="$(printf '%s' "$snapshot" | jq -r ".artifacts[$i].content")"
    if [[ -n "$stage" ]] && [[ "$content" != "null" ]]; then
      printf '%s' "$content" > "${shadow}/${stage}-report.md"
    fi
    i=$((i + 1))
  done

  # state.md — rebuilt from the snapshot's session row. Keeps the
  # server-side session_id so cloud_post_* helpers target the same row.
  local topic status epoch resume project_root fingerprint worktree workflow_url
  topic="$(printf '%s' "$snapshot" | jq -r '.session.topic // ""')"
  status="$(printf '%s' "$snapshot" | jq -r '.session.status // ""')"
  epoch="$(printf '%s' "$snapshot" | jq -r '.session.epoch // 1')"
  resume="$(printf '%s' "$snapshot" | jq -r '.session.resume_status // ""')"
  project_root="$(printf '%s' "$snapshot" | jq -r '.session.project_root // ""')"
  fingerprint="$(printf '%s' "$snapshot" | jq -r '.session.project_fingerprint // ""')"
  worktree="$(printf '%s' "$snapshot" | jq -r '.session.worktree // ""')"
  workflow_url="$(printf '%s' "$snapshot" | jq -r '.session.workflow_url // ""')"

  cat > "${shadow}/state.md" <<EOF
---
active: true
status: $status
epoch: $epoch
resume_status: $resume
topic: "$topic"
session_id: $sid
worktree: "$worktree"
workflow_dir: "${shadow}/.workflow-cache"
project_root: "$project_root"
project_fingerprint: $fingerprint
mode: cloud
pulled_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

  # Baseline — pulled from /diff endpoint so cloud_post_diff on this
  # machine produces diffs against the same reference the original
  # machine used.
  local diff_resp baseline
  diff_resp="$(curl -sS -fL -H "$(_cloud_auth_header)" \
               "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/diff" 2>/dev/null || echo "{}")"
  baseline="$(printf '%s' "$diff_resp" | jq -r '.baseline // ""')"
  if [[ -n "$baseline" ]] && [[ "$baseline" != "null" ]]; then
    echo "$baseline" > "${shadow}/baseline"
  else
    echo "EMPTY" > "${shadow}/baseline"
  fi

  echo "$shadow"
  return 0
}

# Capture the working-tree diff against the session's baseline SHA and
# upload it to the server. Called from setup (initial empty diff) and
# update-status (after every transition). All branches are best-effort:
# if there's no git repo, no baseline, or curl fails, the function
# exits 0 and the workflow keeps running.
cloud_post_diff() {
  local sid="$1"
  cloud_require_env || return 1

  local shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -d "$shadow" ]] || return 0

  local baseline_file="${shadow}/baseline"
  [[ -f "$baseline_file" ]] || return 0
  local baseline; baseline="$(cat "$baseline_file" 2>/dev/null)"
  [[ -z "$baseline" ]] && return 0
  [[ "$baseline" == "EMPTY" ]] && return 0

  # project_root comes from the shadow state.md — that's the one place
  # it's recorded in cloud mode.
  local proot=""
  if [[ -f "${shadow}/state.md" ]]; then
    proot="$(_read_fm_field "${shadow}/state.md" project_root)"
  fi
  [[ -z "$proot" ]] && return 0

  git -C "$proot" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local head diff
  head="$(git -C "$proot" rev-parse HEAD 2>/dev/null || echo "")"
  # Diff baseline → working tree (captures committed + staged + unstaged
  # edits). Excludes .dev-workflow/ defensively in case the user later
  # switches to local mode in the same repo.
  diff="$(git -C "$proot" diff --no-color "$baseline" -- \
          ':(exclude).dev-workflow' 2>/dev/null || echo "")"

  local payload
  payload="$(jq -n \
      --arg baseline "$baseline" \
      --arg head "$head" \
      --arg content "$diff" \
      '{baseline: $baseline, head: $head, content: $content}')"

  curl -sS -fL -X POST \
    -H "$(_cloud_auth_header)" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/diff" > /dev/null 2>&1 || true
}
