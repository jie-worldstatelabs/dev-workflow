#!/bin/bash

# Dev Workflow Setup Script
#
# Two modes:
#   local (default)  workflow lives on disk under <project>/.dev-workflow/
#                    — one run per session per worktree.
#   cloud            state and artifacts are mirrored to a remote server
#                    (the workflowUI webapp); the project worktree gets
#                    nothing under .dev-workflow/. A transient shadow at
#                    ~/.cache/dev-workflow/sessions/<session_id>/ holds
#                    the minimum files the skill needs to Read/Write
#                    against. Every write is POSTed to the server.
#
# Usage:
#   setup-workflow.sh --topic <topic>
#                     [--workflow <name-or-path-or-url>]
#                     [--mode local|cloud]
#   setup-workflow.sh --validate-only [--workflow <name-or-path>]
#
# --workflow accepts:
#   (omitted)          default:  ${PLUGIN_ROOT}/skills/dev-workflow/workflow/
#   cloud://author/name cloud:   named template on $DEV_WORKFLOW_SERVER
#   /abs/path          local:    absolute local path
#   ./rel/path         local:    relative local path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC=""
WORKFLOW_NAME=""
VALIDATE_ONLY=""
# Default mode is cloud — authoritative state lives on the workflowUI
# server, with a local shadow for Claude's Read/Write tools. Users who
# want a fully-offline, local-only run can either:
#   • pass `--mode=local` on the command line, or
#   • export DEV_WORKFLOW_DEFAULT_MODE=local in their shell env
MODE="${DEV_WORKFLOW_DEFAULT_MODE:-cloud}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --topic=*)      TOPIC="${1#--topic=}";                 shift ;;
    --topic)        TOPIC="$2";                            shift 2 ;;
    --workflow=*)   WORKFLOW_NAME="${1#--workflow=}";      shift ;;
    --workflow)     WORKFLOW_NAME="$2";                    shift 2 ;;
    --mode=*)       MODE="${1#--mode=}";                   shift ;;
    --mode)         MODE="$2";                             shift 2 ;;
    --validate-only) VALIDATE_ONLY="yes";                  shift ;;
    *)              shift ;;
  esac
done

# --topic is required for real setup but not for --validate-only (no state.md
# gets written in that mode).
if [[ -z "$VALIDATE_ONLY" ]] && [[ -z "$TOPIC" ]]; then
  echo "❌ Error: --topic is required" >&2
  echo "Usage: setup-workflow.sh --topic <topic> [--workflow <name-or-path-or-url>] [--mode local|cloud]" >&2
  echo "       setup-workflow.sh --validate-only [--workflow <name-or-path>]" >&2
  exit 1
fi

if [[ "$MODE" != "local" ]] && [[ "$MODE" != "cloud" ]]; then
  echo "❌ Error: --mode must be 'local' or 'cloud'" >&2
  exit 1
fi

# --validate-only is a pure local filesystem operation — it reads
# workflow.json + stage .md files and exits. Nothing about the mode
# affects it, so force local regardless of default / env / explicit
# --mode (otherwise with the new cloud default, a bare
# --validate-only would hit the cloud branch that's inapplicable).
if [[ -n "$VALIDATE_ONLY" ]]; then
  MODE="local"
fi

# ──────────────────────────────────────────────────────────────
# Resolve workflow dir for LOCAL mode validation pathway.
# In cloud mode we defer resolution until after --topic / session_id
# checks, since the source may be a URL that we need to download first.
# ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "local" ]]; then
  if [[ -z "$WORKFLOW_NAME" ]]; then
    WORKFLOW_DIR="$DEFAULT_WORKFLOW_DIR"
  elif [[ "$WORKFLOW_NAME" == /* ]]; then
    WORKFLOW_DIR="$WORKFLOW_NAME"
  elif [[ "$WORKFLOW_NAME" == cloud://* ]]; then
    echo "❌ '${WORKFLOW_NAME}' is a cloud reference — cannot be used in local mode." >&2
    echo "   Use the default (--mode=cloud) or pass a local directory path." >&2
    exit 1
  elif [[ "$WORKFLOW_NAME" == */* ]]; then
    WORKFLOW_DIR="$(cd "$WORKFLOW_NAME" 2>/dev/null && pwd || echo "$WORKFLOW_NAME")"
  else
    echo "❌ Invalid --workflow value: '${WORKFLOW_NAME}'" >&2
    echo "   In local mode use an absolute or relative path (e.g. /path/to/workflow or ./my-workflow)." >&2
    exit 1
  fi
  CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"

  if ! config_check; then
    exit 1
  fi

  if ! config_validate; then
    echo "⚠️  Workflow config has errors — fix them before starting a run." >&2
    echo "   Config: $CONFIG_FILE" >&2
    exit 1
  fi

  if [[ -n "$VALIDATE_ONLY" ]]; then
    _stages=$(config_all_stages | tr '\n' ' ' | sed 's/ $//')
    _stage_count=$(config_all_stages | wc -l | tr -d '[:space:]')
    _terminal_count=$(config_terminal_stages | wc -l | tr -d '[:space:]')
    _terminals=$(config_terminal_stages | tr '\n' ' ' | sed 's/ $//')
    _initial=$(config_initial_stage)
    echo "✓ Workflow validated: $_stage_count stages, $_terminal_count terminal"
    echo "   dir:      $WORKFLOW_DIR"
    echo "   initial:  $_initial"
    echo "   stages:   $_stages"
    echo "   terminal: $_terminals"
    exit 0
  fi

  if [[ -n "$WORKFLOW_NAME" ]]; then
    echo "✓ Custom workflow validated: $WORKFLOW_DIR"
  fi
fi

PROJECT_ROOT="$(pwd)"

SESSION_ID="$(read_cached_session_id)"
if [[ -z "$SESSION_ID" ]]; then
  echo "❌ Error: session_id is unknown." >&2
  echo "   The SessionStart hook (hooks/session-start.sh) did not populate" >&2
  echo "   the cache. Ensure the dev-workflow plugin is properly installed" >&2
  echo "   and restart your Claude Code session." >&2
  exit 1
fi

# ══════════════════════════════════════════════════════════════
# Mixed-mode guard — one session_id can only be used in ONE mode.
# Setting up the same session_id as both cloud and local creates two
# independent state.md files that drift apart (resolve_state's cloud-first
# branch makes the local copy invisible), and every cloud_reconcile_state
# fire ends up overwriting server progress with stale shadow state.
# ══════════════════════════════════════════════════════════════
_CLOUD_REG="${HOME}/.dev-workflow/cloud-registry/${SESSION_ID}.json"
_LOCAL_DIR="${PROJECT_ROOT}/.dev-workflow/${SESSION_ID}"

if [[ "$MODE" == "local" ]] && [[ -f "$_CLOUD_REG" ]]; then
  echo "❌ Error: session ${SESSION_ID} is already registered as cloud-managed." >&2
  echo "   Registry: $_CLOUD_REG" >&2
  echo "   Setting up as local would create a second state.md that drifts apart" >&2
  echo "   from the shadow at ~/.cache/dev-workflow/sessions/${SESSION_ID}/." >&2
  echo "" >&2
  echo "   Resolve this by either:" >&2
  echo "     1. /dev-workflow:cancel the cloud workflow first (archives + unregisters)" >&2
  echo "     2. Or re-run with --mode=cloud (same mode as the existing run)" >&2
  exit 1
fi

if [[ "$MODE" == "cloud" ]] && [[ -f "$_LOCAL_DIR/state.md" ]]; then
  echo "❌ Error: session ${SESSION_ID} already has a local workflow at $_LOCAL_DIR/" >&2
  echo "   Setting up as cloud would create a shadow that drifts apart from the" >&2
  echo "   local run. resolve_state's cloud-first branch would then make the local" >&2
  echo "   state.md invisible, so update-status.sh writes would silently stop" >&2
  echo "   reaching the hooks." >&2
  echo "" >&2
  echo "   Resolve this by either:" >&2
  echo "     1. /dev-workflow:cancel the local workflow first" >&2
  echo "     2. Or omit --mode=cloud (same mode as the existing run)" >&2
  exit 1
fi

unset _CLOUD_REG _LOCAL_DIR

# ══════════════════════════════════════════════════════════════
# CLOUD MODE
# ══════════════════════════════════════════════════════════════
if [[ "$MODE" == "cloud" ]]; then
  cloud_require_env || exit 1

  WORKTREE_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")"

  SCRATCH_DIR="${HOME}/.cache/dev-workflow/sessions/${SESSION_ID}"
  WORKFLOW_CACHE="${SCRATCH_DIR}/.workflow-cache"

  # Phase 0: detect existing cloud shadow (mirrors server 409 semantics
  # with a friendlier local error).
  if [[ -f "${SCRATCH_DIR}/state.md" ]]; then
    existing_status=$(_read_fm_field "${SCRATCH_DIR}/state.md" status)
    existing_topic=$(_read_fm_field "${SCRATCH_DIR}/state.md" topic)
    case "$existing_status" in
      complete|escalated|cancelled|"") ;;
      *)
        echo "⚠️  This session already has an active cloud workflow." >&2
        echo "" >&2
        echo "   Session: ${SESSION_ID}" >&2
        echo "   Existing topic: ${existing_topic:-?}   status: ${existing_status}" >&2
        echo "" >&2
        echo "   /dev-workflow:interrupt to pause, /dev-workflow:cancel to stop." >&2
        exit 2
        ;;
    esac
  fi

  mkdir -p "$WORKFLOW_CACHE"

  # ── Resolve workflow source into $WORKFLOW_CACHE ──
  WORKFLOW_URL=""
  case "$WORKFLOW_NAME" in
    "")
      cp -R "${DEFAULT_WORKFLOW_DIR}/." "${WORKFLOW_CACHE}/"
      ;;
    /*)
      cp -R "${WORKFLOW_NAME%/}/." "${WORKFLOW_CACHE}/" || {
        echo "❌ failed to copy workflow from ${WORKFLOW_NAME}" >&2
        rm -rf "$SCRATCH_DIR"
        exit 1
      }
      ;;
    cloud://*)
      # cloud://author/name — cloud named template
      _cloud_name="${WORKFLOW_NAME#cloud://}"
      WORKFLOW_URL="${DEV_WORKFLOW_SERVER}/api/workflows/${_cloud_name}"
      cloud_fetch_workflow_from_name "$_cloud_name" "$WORKFLOW_CACHE" || {
        rm -rf "$SCRATCH_DIR"
        exit 1
      }
      ;;
    */*)
      # relative/home local path (./foo, ../foo, ~/foo)
      _abs="${WORKFLOW_NAME/#\~/$HOME}"
      _abs="$(cd "$_abs" 2>/dev/null && pwd || echo "")"
      if [[ -z "$_abs" ]]; then
        echo "❌ workflow path not found: ${WORKFLOW_NAME}" >&2
        echo "   For cloud templates use cloud://author/name." >&2
        rm -rf "$SCRATCH_DIR"
        exit 1
      fi
      cp -R "${_abs}/." "${WORKFLOW_CACHE}/"
      ;;
    *)
      echo "❌ Invalid --workflow value: '${WORKFLOW_NAME}'" >&2
      echo "   Use cloud://author/name for a cloud template, or an absolute/relative path for a local workflow." >&2
      rm -rf "$SCRATCH_DIR"
      exit 1
      ;;
  esac

  WORKFLOW_DIR="$WORKFLOW_CACHE"
  CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"
  if ! config_check; then
    rm -rf "$SCRATCH_DIR"
    exit 1
  fi
  if ! config_validate; then
    echo "❌ fetched workflow config failed validation" >&2
    rm -rf "$SCRATCH_DIR"
    exit 1
  fi

  INITIAL_STAGE="$(config_initial_stage)"

  # Compute the project fingerprint (set of git root commit SHAs) so
  # cross-machine continue can verify the resume target is the same repo.
  PROJECT_FINGERPRINT="$(git_project_fingerprint "$PROJECT_ROOT")"

  # ── Build setup payload + POST to server ──
  files_json="{}"
  for f in "$WORKFLOW_CACHE"/*.md; do
    [[ -f "$f" ]] || continue
    _name="$(basename "$f")"
    _content="$(cat "$f")"
    files_json="$(jq -n --argjson base "$files_json" --arg k "$_name" --arg v "$_content" \
                  '$base + {($k): $v}')"
  done
  wfval="$(cat "${WORKFLOW_CACHE}/workflow.json")"
  payload="$(jq -n \
      --arg topic "$TOPIC" \
      --argjson workflow "$wfval" \
      --argjson files "$files_json" \
      --arg url "$WORKFLOW_URL" \
      --arg proot "$PROJECT_ROOT" \
      --arg fpr "$PROJECT_FINGERPRINT" \
      --arg wtree "$WORKTREE_ROOT" \
      '{
        topic: $topic,
        workflow: $workflow,
        workflow_files: $files,
        workflow_url: (if $url == "" then null else $url end),
        project_root: $proot,
        project_fingerprint: (if $fpr == "" then null else $fpr end),
        worktree: $wtree
      }')"

  tmp_body="$(mktemp -t dw-setup-XXXXXX)"
  trap 'rm -f "$tmp_body"' EXIT
  http_code=$(curl -sS -o "$tmp_body" -w "%{http_code}" \
      -X POST "${DEV_WORKFLOW_SERVER}/api/sessions/${SESSION_ID}/setup" \
      -H "$(_cloud_auth_header)" \
      -H "Content-Type: application/json" \
      --data "$payload" || echo "000")

  if [[ "$http_code" == "409" ]]; then
    remote_status=$(jq -r '.status // "?"' "$tmp_body" 2>/dev/null || echo "?")
    echo "⚠️  Server refused setup — an active workflow already exists for this session." >&2
    echo "    Remote status: ${remote_status}" >&2
    echo "    Use /dev-workflow:cancel to stop the existing run first." >&2
    rm -rf "$SCRATCH_DIR"
    exit 2
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "❌ setup POST failed with HTTP ${http_code}:" >&2
    cat "$tmp_body" >&2
    echo "" >&2
    rm -rf "$SCRATCH_DIR"
    exit 1
  fi

  # ── Write local shadow state.md ──
  cat > "${SCRATCH_DIR}/state.md" <<EOF
---
active: true
status: $INITIAL_STAGE
epoch: 1
resume_status:
topic: "$TOPIC"
session_id: $SESSION_ID
worktree: "$WORKTREE_ROOT"
workflow_dir: "$WORKFLOW_CACHE"
project_root: "$PROJECT_ROOT"
project_fingerprint: ${PROJECT_FINGERPRINT:-}
mode: cloud
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

  cloud_register_session "$SESSION_ID" "$DEV_WORKFLOW_SERVER" "$WORKFLOW_URL"

  # Generate run_files declared in workflow.json into the shadow dir.
  # Each init command is executed with PROJECT_ROOT as CWD.
  while IFS= read -r _rf_name; do
    [[ -z "$_rf_name" ]] && continue
    _rf_init="$(config_run_file_init "$_rf_name")"
    if [[ -z "$_rf_init" ]]; then
      echo "❌ run_file '$_rf_name' has no init command in workflow.json" >&2
      rm -rf "$SCRATCH_DIR"
      exit 1
    fi
    (cd "$PROJECT_ROOT" && bash -c "$_rf_init") > "${SCRATCH_DIR}/${_rf_name}"
  done < <(config_run_file_names)

  # Seed the server with an initial (empty) diff so the session page's
  # "Working-tree diff" panel has content to anchor on.
  cloud_post_diff "$SESSION_ID" || true

  # Force config_show_stage_context to print shadow paths, not ${project}/.dev-workflow/.
  DW_RUN_BASE="${HOME}/.cache/dev-workflow/sessions"
  export DW_RUN_BASE

  INTERRUPTIBLE_HINT=""
  if config_is_interruptible "$INITIAL_STAGE"; then
    INTERRUPTIBLE_HINT=" — interruptible"
  fi

  echo "☁️  Dev workflow activated (cloud)."
  echo ""
  echo "   Topic: $TOPIC"
  echo "   Session: $SESSION_ID"
  echo "   Worktree: $WORKTREE_ROOT"
  echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
  if [[ -n "$WORKFLOW_URL" ]]; then
    echo "   Workflow source: $WORKFLOW_URL"
  else
    echo "   Workflow source: ${WORKFLOW_NAME:-default}"
  fi

  if config_is_stage "$INITIAL_STAGE"; then
    config_show_stage_context "$INITIAL_STAGE" "$SESSION_ID" "$PROJECT_ROOT"
  fi

  echo ""
  echo "   Shadow dir: $SCRATCH_DIR"
  echo "   Server:     $DEV_WORKFLOW_SERVER"
  echo "   UI:         ${DEV_WORKFLOW_SERVER}/s/${SESSION_ID}"
  echo "   To pause:  /dev-workflow:interrupt"
  echo "   To cancel: /dev-workflow:cancel"

  # Anonymous-cloud nudge: if the user has no bearer token stored at
  # ~/.dev-workflow/auth.json, they're running as an anonymous capability
  # URL (whoever knows the session_id can read/write it). Surface the
  # benefits of logging in once, right after activation, so they don't
  # miss the browser dashboard / cross-device resume / private sessions
  # features. Non-blocking, informational only.
  if ! cloud_is_logged_in; then
    echo ""
    echo "💡 Tip — this session is running anonymously (no account attached)."
    echo "   Sign in to unlock:"
    echo "     • Your home dashboard — browse, search, and resume all your past sessions"
    echo "     • Cross-machine continue without copy-pasting session IDs"
    echo "     • Private sessions (strangers who guess the URL can't read your run)"
    echo "     • Your own rate-limit quota instead of shared anonymous"
    echo ""
    echo "   One command:"
    echo "     /dev-workflow:login"
  fi

  exit 0
fi

# ══════════════════════════════════════════════════════════════
# LOCAL MODE (original behavior)
# ══════════════════════════════════════════════════════════════

SESSION_RUN_DIR="${PROJECT_ROOT}/.dev-workflow/${SESSION_ID}"

# ──────────────────────────────────────────────────────────────
# Phase 0: Detect existing workflow for THIS session.
# ──────────────────────────────────────────────────────────────
if [[ -f "${SESSION_RUN_DIR}/state.md" ]]; then
  etopic=$(_read_fm_field "${SESSION_RUN_DIR}/state.md" topic)
  estatus=$(_read_fm_field "${SESSION_RUN_DIR}/state.md" status)
  case "$estatus" in
    complete|escalated|cancelled|"")
      # Terminal or unreadable — safe to replace.
      ;;
    *)
      echo "⚠️  This session already has an active dev-workflow." >&2
      echo "" >&2
      echo "   Session: ${SESSION_ID}" >&2
      echo "   Existing topic: ${etopic:-?}   status: ${estatus}" >&2
      echo "   Existing dir: ${SESSION_RUN_DIR}" >&2
      echo "" >&2
      echo "   /dev-workflow:interrupt to pause, /dev-workflow:cancel to stop," >&2
      echo "   /dev-workflow:continue to resume." >&2
      exit 2
      ;;
  esac
fi

# ──────────────────────────────────────────────────────────────
# Phase 1: Ensure git repo with a HEAD commit (baseline)
# ──────────────────────────────────────────────────────────────
AUTO_GIT_MSG=""
if ! git -C "${PROJECT_ROOT}" rev-parse --git-dir > /dev/null 2>&1; then
  git -C "${PROJECT_ROOT}" init -q
  AUTO_GIT_MSG="   (no git repo found — ran 'git init')"
fi

if ! git -C "${PROJECT_ROOT}" rev-parse HEAD > /dev/null 2>&1; then
  git -C "${PROJECT_ROOT}" add -A
  HAS_FILES=$(git -C "${PROJECT_ROOT}" diff --cached --name-only | head -1)
  git -C "${PROJECT_ROOT}" \
      -c user.name='dev-workflow' \
      -c user.email='dev-workflow@local' \
      commit --allow-empty -q -m "dev-workflow: initial baseline (topic=${TOPIC})"
  if [[ -n "$HAS_FILES" ]]; then
    AUTO_GIT_MSG="${AUTO_GIT_MSG}${AUTO_GIT_MSG:+\n}   (committed existing files as initial baseline)"
  else
    AUTO_GIT_MSG="${AUTO_GIT_MSG}${AUTO_GIT_MSG:+\n}   (created empty initial commit as baseline)"
  fi
fi

WORKTREE_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")"

# ──────────────────────────────────────────────────────────────
# Phase 2: Archive this session's prior run (if any) before starting fresh.
# ──────────────────────────────────────────────────────────────
ARCHIVE_MSG=""
rc=0
archive_run_dir "$SESSION_RUN_DIR" "" "" || rc=$?
case $rc in
  0) ARCHIVE_MSG="   📦 Archived previous run: $ARCHIVE_RESULT_PATH" ;;
  2) ARCHIVE_MSG="   ⚠️  Archive failed; previous run removed." ;;
  # rc=1 → nothing to archive, stay silent
esac
rm -f "${PROJECT_ROOT}/.dev-workflow/state.md"

# ──────────────────────────────────────────────────────────────
# Phase 3: Create this session's run dir and state.md
# ──────────────────────────────────────────────────────────────
TOPIC_DIR="$SESSION_RUN_DIR"
mkdir -p "$TOPIC_DIR"

INITIAL_STAGE="$(config_initial_stage)"
LOCAL_FINGERPRINT="$(git_project_fingerprint "$PROJECT_ROOT")"

cat > "${TOPIC_DIR}/state.md" <<EOF
---
active: true
status: $INITIAL_STAGE
epoch: 1
resume_status:
topic: "$TOPIC"
session_id: $SESSION_ID
worktree: "$WORKTREE_ROOT"
workflow_dir: "$WORKFLOW_DIR"
project_root: "$PROJECT_ROOT"
project_fingerprint: ${LOCAL_FINGERPRINT:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# ──────────────────────────────────────────────────────────────
# Phase 4: Generate run_files declared in workflow.json
# ──────────────────────────────────────────────────────────────
# Phase 1 above has already ensured a valid git HEAD exists, so
# "git rev-parse HEAD 2>/dev/null || echo EMPTY" is safe here.
while IFS= read -r _rf_name; do
  [[ -z "$_rf_name" ]] && continue
  _rf_init="$(config_run_file_init "$_rf_name")"
  if [[ -z "$_rf_init" ]]; then
    echo "❌ run_file '$_rf_name' has no init command in workflow.json" >&2
    exit 1
  fi
  (cd "$PROJECT_ROOT" && bash -c "$_rf_init") > "${TOPIC_DIR}/${_rf_name}"
done < <(config_run_file_names)

# ──────────────────────────────────────────────────────────────
# Phase 5: Surface context to the main agent
# ──────────────────────────────────────────────────────────────
INTERRUPTIBLE_HINT=""
if config_is_interruptible "$INITIAL_STAGE"; then
  INTERRUPTIBLE_HINT=" — interruptible"
fi

echo "🔄 Dev workflow activated."
echo ""
echo "   Topic: $TOPIC"
echo "   Session: $SESSION_ID"
echo "   Worktree: $WORKTREE_ROOT"
echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
if [[ -n "${ARCHIVE_MSG:-}" ]]; then
  echo "$ARCHIVE_MSG"
fi
if [[ -n "$AUTO_GIT_MSG" ]]; then
  printf '%b\n' "$AUTO_GIT_MSG"
fi

if config_is_stage "$INITIAL_STAGE"; then
  config_show_stage_context "$INITIAL_STAGE" "$SESSION_ID" "$PROJECT_ROOT"
fi

echo ""
echo "   Run dir: $TOPIC_DIR"
echo "   Workflow dir: $WORKFLOW_DIR"
echo "   To pause: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
