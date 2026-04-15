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
  # Primary source is state.md; if that's missing/corrupt we fall back
  # to whatever the caller supplied, or the run dir basename, or the
  # literal "orphan". No stage-name-specific parsing.
  local topic=""
  if [[ -f "$run_dir/state.md" ]]; then
    topic=$(_read_fm_field "$run_dir/state.md" topic)
  fi
  [[ -z "$topic" ]] && topic="${topic_fallback:-}"
  [[ -z "$topic" ]] && topic="$(basename "$run_dir")"
  [[ -z "$topic" ]] && topic="orphan"

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

  # Unambiguous single-workflow fallback. When neither DESIRED_SESSION
  # nor DESIRED_TOPIC was provided and the project has exactly one
  # session subdir under .dev-workflow/, just use it. This removes the
  # friction of having to pass --topic when calling plugin scripts from
  # an agent Bash invocation that didn't inherit the session-start hook
  # context (so read_cached_session_id returned empty). With two or
  # more candidates we still error out — the error message below will
  # list them so the caller knows what to pass.
  local _candidates=()
  local _c
  for _c in "$dw"/*/state.md; do
    [[ -f "$_c" ]] && _candidates+=("$_c")
  done
  if [[ ${#_candidates[@]} -eq 1 ]]; then
    _populate_state_vars "${_candidates[0]}" "$project_root"
    return 0
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

    # subagent stages must NOT declare subagent_type. There is one generic
    # dev-workflow:workflow-subagent hardcoded in agent-guard.sh and
    # stop-hook.sh — per-stage behavior comes entirely from the stage
    # instructions file. Accepting a per-stage subagent_type here would
    # create a silent mismatch between workflow.json and what actually
    # gets launched.
    if [[ "$etype" == "subagent" ]]; then
      local sub; sub="$(jq -r --arg s "$stage" '.stages[$s].execution.subagent_type // ""' "$CONFIG_FILE")"
      if [[ -n "$sub" ]]; then
        echo "❌ $prefix execution.subagent_type is not supported — the plugin uses a single generic workflow-subagent for all subagent stages. Remove this field; per-stage behavior comes from the stage instructions file." >&2
        errors=$((errors + 1))
      fi

      # subagent stages cannot be interruptible — the main agent blocks on
      # the Agent tool call for the duration, so the stop hook has no turn
      # boundary to fire at. Accepting the flag would silently lie.
      local intr
      intr="$(jq -r --arg s "$stage" '.stages[$s].interruptible // false' "$CONFIG_FILE")"
      if [[ "$intr" == "true" ]]; then
        echo "❌ $prefix execution.type=subagent cannot be interruptible — main agent blocks on the Agent tool call, stop hook has no chance to fire" >&2
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

# Treats both the workflow's declared terminal_stages and the plugin-
# reserved status "cancelled" as terminal. Server-side /cancel sets
# status=cancelled, which may not be in an older session's stored
# workflow_json.terminal_stages — this wrapper closes that gap so any
# script reasoning about "is this done?" gets the right answer even
# for older sessions that were created before we added cancelled.
is_terminal_status() {
  local s="$1"
  [[ -z "$s" ]] && return 1
  [[ "$s" == "cancelled" ]] && return 0
  config_is_terminal "$s"
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
: "${DEV_WORKFLOW_SERVER:=https://workflows.worldstatelabs.com}"
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
      # Must use `if`, not `[[ ]] && rm` — the && short-circuit returns
      # non-zero when the test is false, and under `set -e` in callers
      # that becomes the function's exit code and kills the script.
      if [[ "$other_scratch" == "$scratch" ]]; then
        rm -f "$other"
      fi
    done
  fi
  return 0
}

# Wipe the local shadow for a session. Returns 0 unconditionally —
# cleanup operations must not trip `set -e` in callers.
cloud_wipe_scratch() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  rm -rf "${CLOUD_SCRATCH_BASE}/${sid}"
  return 0
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

# Auth header for cloud requests. Two modes:
#
#   - Authenticated: ~/.dev-workflow/auth.json exists with a `token`
#     field. We emit "Authorization: Bearer <token>" so the server can
#     attribute the request to the logged-in user and stamp user_id on
#     any rows it creates.
#
#   - Anonymous: no auth file. We emit a benign X-Dev-Workflow marker
#     so the curl -H argument is always well-formed (curl rejects empty
#     -H values). Server routes that don't require auth continue to
#     accept the request; routes that check user_id see NULL.
#
# To log in:  /dev-workflow:login
# To log out: /dev-workflow:logout
# Returns 0 if the user has a non-empty bearer token at
# ~/.dev-workflow/auth.json (written by login-workflow.sh), else 1.
# Used by setup-workflow.sh to surface a "consider logging in" tip on
# anonymous cloud runs. Never errors; non-zero just means "not logged in".
cloud_is_logged_in() {
  local auth_file="${HOME}/.dev-workflow/auth.json"
  [[ -f "$auth_file" ]] || return 1
  local token
  token="$(jq -r '.token // empty' "$auth_file" 2>/dev/null || true)"
  [[ -n "$token" ]]
}

_cloud_auth_header() {
  local auth_file="${HOME}/.dev-workflow/auth.json"
  if [[ -f "$auth_file" ]]; then
    local token
    token="$(jq -r '.token // empty' "$auth_file" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      echo "Authorization: Bearer ${token}"
      return 0
    fi
  fi
  echo "X-Dev-Workflow: plugin"
}

# ──────────────────────────────────────────────────────────────
# Reliability primitives
# ──────────────────────────────────────────────────────────────
#
# Every mutating cloud call goes through one of these helpers so we get
# bounded retries + visible failure logging for free. Silent failures
# used to cause state drift (observed in prod: a cloud_post_state call
# at transition time failed once, got swallowed by `|| echo warning`,
# and the server sat on the old status for minutes until a separate
# call happened to converge it). These helpers fix that class of bug:
#
#   _cloud_curl_retry  — 2 attempts, 1s gap, 5s timeout each → ~11s worst
#                        case. Use for transitions where correctness is
#                        paramount (update-status.sh).
#   _cloud_curl_once   — 1 attempt, 3s timeout → ~3s worst case. Use for
#                        convergence loops that run frequently and can
#                        afford to miss a cycle (stop-hook reconcile).
#   _cloud_warn        — append timestamped message to the shadow's
#                        .sync-warnings.log + stderr. stop-hook tails
#                        the file and surfaces it via systemMessage so
#                        the user actually sees sync issues.

# Returns 0 on any 2xx, 1 otherwise. Discards response body.
# Usage: _cloud_curl_retry <method> <url> [additional curl args...]
_cloud_curl_retry() {
  local method="$1" url="$2"
  shift 2
  local attempt=1 max=2 delay=1
  local http_code
  while [[ $attempt -le $max ]]; do
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
                --max-time 5 \
                -X "$method" "$url" \
                -H "$(_cloud_auth_header)" \
                "$@" 2>/dev/null || echo "000")
    case "$http_code" in
      2*) return 0 ;;
    esac
    if [[ $attempt -lt $max ]]; then
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# Single attempt, short timeout. Same interface as _cloud_curl_retry.
_cloud_curl_once() {
  local method="$1" url="$2"
  shift 2
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
              --max-time 3 \
              -X "$method" "$url" \
              -H "$(_cloud_auth_header)" \
              "$@" 2>/dev/null || echo "000")
  case "$http_code" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

# Append a timestamped warning to the shadow's .sync-warnings.log and
# echo to stderr. Bounded to 100 lines so it can't grow unbounded.
# Callers: every cloud_post_* helper on final failure, and
# ensure_baseline_and_fingerprint / cloud_reconcile_state on notable events.
_cloud_warn() {
  local sid="$1" msg="$2"
  [[ -n "$msg" ]] || return 0
  echo "⚠️  [dev-workflow cloud] $msg" >&2
  [[ -n "$sid" ]] || return 0
  local shadow; shadow="$(cloud_registry_get "$sid" scratch_dir)"
  [[ -z "$shadow" ]] && shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -d "$shadow" ]] || return 0
  local log="${shadow}/.sync-warnings.log"
  printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$log"
  if [[ $(wc -l < "$log" 2>/dev/null || echo 0) -gt 100 ]]; then
    tail -100 "$log" > "${log}.tmp.$$" && mv "${log}.tmp.$$" "$log"
  fi
}

# POST JSON to an endpoint via the retry wrapper. Returns 0 on 2xx, 1 otherwise.
# No response body — routes are fire-and-forget by convention.
_cloud_post_json() {
  local url="$1" body="$2"
  _cloud_curl_retry POST "$url" \
    -H "Content-Type: application/json" \
    --data "$body"
}

# ──────────────────────────────────────────────────────────────
# Remote workflow config fetch
# ──────────────────────────────────────────────────────────────
#
# Supported forms (matches setup-workflow.sh --workflow argument):
#   cloud://author/name  named template on $DEV_WORKFLOW_SERVER
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
  local sid="$1" status="$2" epoch="$3" resume="${4:-}" active="${5:-true}" project_root="${6:-}" fingerprint="${7:-}"
  cloud_require_env || return 1
  local payload
  payload="$(jq -n \
      --arg status "$status" \
      --argjson epoch "${epoch:-1}" \
      --arg resume "$resume" \
      --argjson active "$active" \
      --arg pr "$project_root" \
      --arg fpr "$fingerprint" \
      '{
        status: $status,
        epoch: $epoch,
        resume_status: (if $resume == "" then null else $resume end),
        active: $active
      }
      + (if $pr  == "" then {} else {project_root: $pr} end)
      + (if $fpr == "" then {} else {project_fingerprint: $fpr} end)')"
  if ! _cloud_post_json "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/state" "$payload"; then
    _cloud_warn "$sid" "cloud_post_state failed after retries: status=${status} epoch=${epoch}"
    return 1
  fi
  return 0
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
  # Not a git repo at all → empty fingerprint, success exit.
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo ""; return 0; }
  # Git repo with no commits yet (fresh `git init` before first commit):
  # rev-list on HEAD would fail with exit 128, which combined with
  # `set -o pipefail` propagates a non-zero status to the caller and
  # — under `set -e` in setup-workflow.sh — would silently kill the
  # whole script. Detect the no-HEAD case explicitly and return an
  # empty fingerprint (success exit) so callers skip the verification.
  git -C "$dir" rev-parse HEAD >/dev/null 2>&1 || { echo ""; return 0; }
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
  if [[ ! -f "$file" ]]; then
    _cloud_warn "$sid" "cloud_post_artifact: file not found: $file"
    return 1
  fi
  if ! _cloud_curl_retry POST \
        "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/artifacts/${stage}" \
        -H "Content-Type: text/plain" \
        --data-binary "@${file}"; then
    local bytes; bytes=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
    _cloud_warn "$sid" "cloud_post_artifact failed after retries: stage=${stage} bytes=${bytes}"
    return 1
  fi
  return 0
}

cloud_delete_artifact() {
  local sid="$1" stage="$2"
  cloud_require_env || return 1
  if ! _cloud_curl_retry DELETE \
        "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/artifacts/${stage}"; then
    _cloud_warn "$sid" "cloud_delete_artifact failed after retries: stage=${stage}"
    return 1
  fi
  return 0
}

cloud_post_archive() {
  local sid="$1"
  cloud_require_env || return 1
  if ! _cloud_curl_retry POST "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/archive"; then
    _cloud_warn "$sid" "cloud_post_archive failed after retries"
    return 1
  fi
  return 0
}

cloud_post_cancel() {
  local sid="$1"
  cloud_require_env || return 1
  if ! _cloud_curl_retry POST "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/cancel"; then
    _cloud_warn "$sid" "cloud_post_cancel failed after retries"
    return 1
  fi
  return 0
}

cloud_delete_session() {
  local sid="$1"
  cloud_require_env || return 1
  if ! _cloud_curl_retry DELETE "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}"; then
    _cloud_warn "$sid" "cloud_delete_session failed after retries"
    return 1
  fi
  return 0
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
# upload it to the server. Called from setup (initial empty diff),
# update-status (every transition), and stop-hook reconcile.
#
# If the project was pre-git at setup time (baseline=EMPTY, fingerprint
# empty) but now has git, backfill them first via
# ensure_baseline_and_fingerprint — that's how a workflow that starts in
# a fresh dir and later gets `git init`'d picks up diffs automatically.
#
# All branches are best-effort: missing git, missing baseline, or a
# failed POST just logs a warning and returns — never blocks the workflow.
cloud_post_diff() {
  local sid="$1"
  cloud_require_env || return 1

  local shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -d "$shadow" ]] || return 0

  # Try to backfill baseline/fingerprint if the project became git since setup.
  if [[ -f "${shadow}/state.md" ]]; then
    ensure_baseline_and_fingerprint "${shadow}/state.md" || true
  fi

  local baseline_file="${shadow}/baseline"
  [[ -f "$baseline_file" ]] || return 0
  local baseline; baseline="$(cat "$baseline_file" 2>/dev/null)"
  [[ -z "$baseline" ]] && return 0
  [[ "$baseline" == "EMPTY" ]] && return 0

  local proot=""
  if [[ -f "${shadow}/state.md" ]]; then
    proot="$(_read_fm_field "${shadow}/state.md" project_root)"
  fi
  [[ -z "$proot" ]] && return 0

  git -C "$proot" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local head diff
  head="$(git -C "$proot" rev-parse HEAD 2>/dev/null || echo "")"
  diff="$(git -C "$proot" diff --no-color "$baseline" -- \
          ':(exclude).dev-workflow' 2>/dev/null || echo "")"

  local payload
  payload="$(jq -n \
      --arg baseline "$baseline" \
      --arg head "$head" \
      --arg content "$diff" \
      '{baseline: $baseline, head: $head, content: $content}')"

  if ! _cloud_post_json "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}/diff" "$payload"; then
    _cloud_warn "$sid" "cloud_post_diff failed after retries: baseline=${baseline:0:10} head=${head:0:10}"
    return 1
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────
# Deferred baseline / fingerprint backfill
# ──────────────────────────────────────────────────────────────
#
# setup-workflow.sh records baseline + project_fingerprint from the git
# state at setup time. If the project is pre-git then (e.g. a greenfield
# scaffold that will `git init` a few minutes later), both get recorded
# as EMPTY / empty. Without backfill, cloud_post_diff would short-circuit
# forever — the UI would show an empty diff panel for the entire run and
# cross-machine continue would skip the verify check.
#
# This helper re-reads the project each time it's called; once git shows
# up, it writes the real values into state.md + the baseline file and
# (in cloud mode) pushes the updated fingerprint to the server so
# verify_project_match works on future resume.
#
# Idempotent: a no-op if baseline/fingerprint are already populated, or
# if the project still has no git. Safe to call from any convergence
# point (update-status, stop-hook, cloud_post_diff).
ensure_baseline_and_fingerprint() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0

  local shadow; shadow="$(dirname "$state_file")"
  local sid; sid="$(basename "$shadow")"
  local proot; proot="$(_read_fm_field "$state_file" project_root)"
  [[ -z "$proot" ]] && return 0
  git -C "$proot" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local changed_baseline="false"
  local changed_fpr="false"

  # Baseline backfill. We treat "EMPTY", empty string, or a non-SHA-looking
  # value as unset. Git root HEAD becomes the new baseline — it's the best
  # approximation of "when this workflow started" given the data we have.
  local baseline_file="${shadow}/baseline"
  local cur_baseline=""
  [[ -f "$baseline_file" ]] && cur_baseline="$(cat "$baseline_file" 2>/dev/null)"
  if [[ -z "$cur_baseline" ]] || [[ "$cur_baseline" == "EMPTY" ]]; then
    local head_sha
    head_sha="$(git -C "$proot" rev-parse HEAD 2>/dev/null || echo "")"
    if [[ -n "$head_sha" ]]; then
      echo "$head_sha" > "$baseline_file"
      _cloud_warn "$sid" "baseline backfilled from local git: ${head_sha:0:10}"
      changed_baseline="true"
    fi
  fi

  # Fingerprint backfill. Written into state.md via the atomic
  # set_fm_field helper; no impact on the skill that may be reading
  # state.md concurrently because the rename is atomic.
  local cur_fpr
  cur_fpr="$(_read_fm_field "$state_file" project_fingerprint)"
  if [[ -z "$cur_fpr" ]] || [[ "$cur_fpr" == "EMPTY" ]]; then
    local new_fpr
    new_fpr="$(git_project_fingerprint "$proot")"
    if [[ -n "$new_fpr" ]]; then
      set_fm_field "$state_file" project_fingerprint "$new_fpr"
      _cloud_warn "$sid" "project_fingerprint backfilled: ${new_fpr:0:10}"
      changed_fpr="true"

      # Sync the new fingerprint to the server via the state endpoint
      # (which now accepts project_fingerprint as an optional field).
      if is_cloud_session "$sid"; then
        local cs ce
        cs="$(_read_fm_field "$state_file" status)"
        ce="$(_read_fm_field "$state_file" epoch)"
        cloud_post_state "$sid" "$cs" "${ce:-1}" "" "true" "" "$new_fpr" || true
      fi
    fi
  fi

  # Return value isn't currently used by callers, but document intent:
  # 0 = nothing backfilled OR backfill succeeded; non-zero reserved for
  # future use if callers want to know that state.md was mutated.
  [[ "$changed_baseline" == "true" ]] || [[ "$changed_fpr" == "true" ]]
}

# ──────────────────────────────────────────────────────────────
# Cloud state reconciliation
# ──────────────────────────────────────────────────────────────
#
# Safety net for drift between local shadow and the server. Pulls the
# current server snapshot, compares against the local state.md and the
# latest local artifact for the current stage; re-pushes anything that
# diverged. Called from stop-hook.sh on every fire (cloud mode, non-
# terminal only) so every turn-end is an implicit convergence point.
#
# Design notes:
# - Uses _cloud_curl_once for the snapshot GET (short timeout, no retry)
#   so a flaky network doesn't block the stop hook for 10+ seconds.
#   Missing a reconcile cycle is fine; the next turn-end tries again.
# - The re-push goes through cloud_post_state / cloud_post_artifact,
#   which themselves retry — so a recovered server gets the update on
#   the first reconcile cycle it's reachable.
# - Never blocks, never errors: returns 0 unconditionally.
cloud_reconcile_state() {
  local sid="$1"
  [[ -z "$sid" ]] && return 0
  cloud_require_env 2>/dev/null || return 0

  local shadow; shadow="$(cloud_registry_get "$sid" scratch_dir)"
  [[ -z "$shadow" ]] && shadow="${CLOUD_SCRATCH_BASE}/${sid}"
  [[ -f "$shadow/state.md" ]] || return 0

  local local_status local_epoch
  local_status="$(_read_fm_field "$shadow/state.md" status)"
  local_epoch="$(_read_fm_field "$shadow/state.md" epoch)"
  [[ -z "$local_status" ]] && return 0

  # Pull server snapshot (short timeout, single shot).
  local snapshot
  snapshot="$(curl -sS -fL --max-time 3 \
              -H "$(_cloud_auth_header)" \
              "${DEV_WORKFLOW_SERVER}/api/sessions/${sid}" 2>/dev/null)" || return 0
  printf '%s' "$snapshot" | jq empty 2>/dev/null || return 0

  local server_status server_epoch
  server_status="$(printf '%s' "$snapshot" | jq -r '.session.status // ""')"
  server_epoch="$(printf '%s' "$snapshot" | jq -r '.session.epoch // ""')"

  # State reconcile — server is authoritative. In cloud mode the server
  # is the source of truth (SKILL.md's Cloud mode section says so, and
  # multiple Claude sessions on different machines may be advancing the
  # same session via update-status.sh). On mismatch we pull server state
  # DOWN into the local shadow state.md. The local write that just
  # happened (update-status.sh → set_fm_field + cloud_post_state) is
  # already visible on the server by this point because stop-hook fires
  # AFTER the turn's tool calls finished — so a server value newer than
  # local means another writer advanced the session.
  #
  # Trade-off vs the old "local wins" policy: if cloud_post_state silently
  # fails during a transition (network blip between set_fm_field and this
  # reconcile), the local advance will be silently reverted on the next
  # reconcile. That's safer than the previous behavior where reconcile
  # would keep overwriting a healthy server with stale local state — the
  # diary 4/14 incident showed that "local wins" corrupted the server side.
  # If you hit this in practice, inspect the sync-warnings.log and retry
  # the update-status.sh call.
  if [[ "$server_status" != "$local_status" ]] || [[ "$server_epoch" != "$local_epoch" ]]; then
    set_fm_field "$shadow/state.md" status "$server_status"
    set_fm_field "$shadow/state.md" epoch "$server_epoch"
    _cloud_warn "$sid" "reconcile: pulled server → local (was local=${local_status}/${local_epoch}, now ${server_status}/${server_epoch})"
  fi

  # Artifact reconcile — if the current stage has a local artifact
  # whose byte length differs from the server's, re-upload.
  local local_artifact="${shadow}/${local_status}-report.md"
  if [[ -f "$local_artifact" ]]; then
    local local_bytes server_bytes
    local_bytes="$(wc -c < "$local_artifact" 2>/dev/null | tr -d ' ')"
    server_bytes="$(printf '%s' "$snapshot" \
                    | jq -r --arg s "$local_status" \
                         '((.artifacts[] | select(.stage == $s) | .content) // "") | length')"
    if [[ -n "$local_bytes" ]] && [[ "$local_bytes" != "$server_bytes" ]]; then
      if cloud_post_artifact "$sid" "$local_status" "$local_artifact"; then
        _cloud_warn "$sid" "reconcile: ${local_status}-report.md caught up (local=${local_bytes} server=${server_bytes})"
      fi
    fi
  fi

  return 0
}
