#!/bin/bash

# Dev Workflow Setup Script
# Model: one worktree = one run. Starting a new run DELETES any existing
# workflow in this worktree (including artifacts and state). This keeps the
# concept simple: `<project>/.dev-workflow/` always holds at most one
# workflow, and any Claude session in the worktree interacts with it.
#
# Usage: setup-workflow.sh --topic <topic> [--workflow <name-or-path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC=""
WORKFLOW_NAME=""
FORCE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --topic)
      TOPIC="$2"
      shift 2
      ;;
    --workflow)
      WORKFLOW_NAME="$2"
      shift 2
      ;;
    --force)
      FORCE="yes"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "❌ Error: --topic is required" >&2
  echo "Usage: setup-workflow.sh --topic <topic> [--workflow <name-or-path>]" >&2
  exit 1
fi

# Resolve workflow dir (bare name / absolute / relative; default if empty)
if [[ -z "$WORKFLOW_NAME" ]]; then
  WORKFLOW_DIR="$DEFAULT_WORKFLOW_DIR"
elif [[ "$WORKFLOW_NAME" == /* ]]; then
  WORKFLOW_DIR="$WORKFLOW_NAME"
elif [[ "$WORKFLOW_NAME" == */* ]]; then
  WORKFLOW_DIR="$(cd "$WORKFLOW_NAME" 2>/dev/null && pwd || echo "$WORKFLOW_NAME")"
else
  WORKFLOW_DIR="${PLUGIN_ROOT}/skills/dev-workflow/${WORKFLOW_NAME}"
fi
CONFIG_FILE="${WORKFLOW_DIR}/workflow.json"

if ! config_check; then
  exit 1
fi

PROJECT_ROOT="$(pwd)"

# ──────────────────────────────────────────────────────────────
# Resolve current session_id (written by SessionStart hook → cache).
# session_id IS the run's directory name under .dev-workflow/, so we need
# a real value. Nothing we can do without it — error out with a clear hint.
# ──────────────────────────────────────────────────────────────
SESSION_ID="$(read_cached_session_id)"
if [[ -z "$SESSION_ID" ]]; then
  echo "❌ Error: session_id is unknown." >&2
  echo "   The SessionStart hook (hooks/session-start.sh) did not populate" >&2
  echo "   the cache. Ensure the dev-workflow plugin is properly installed" >&2
  echo "   and restart your Claude Code session." >&2
  exit 1
fi

SESSION_RUN_DIR="${PROJECT_ROOT}/.dev-workflow/${SESSION_ID}"

# ──────────────────────────────────────────────────────────────
# Phase 0: Detect existing workflow for THIS session.
# Each session has its own .dev-workflow/<session_id>/ subdir, so we only
# check our own. Other sessions' dirs are independent and untouched.
# ──────────────────────────────────────────────────────────────
if [[ -z "$FORCE" ]] && [[ -f "${SESSION_RUN_DIR}/state.md" ]]; then
  etopic=$(_read_fm_field "${SESSION_RUN_DIR}/state.md" topic)
  estatus=$(_read_fm_field "${SESSION_RUN_DIR}/state.md" status)
  case "$estatus" in
    complete|escalated|"")
      # Terminal or unreadable — safe to replace without --force.
      ;;
    *)
      echo "⚠️  This session already has an active dev-workflow." >&2
      echo "" >&2
      echo "   Session: ${SESSION_ID}" >&2
      echo "   Existing topic: ${etopic:-?}   status: ${estatus}" >&2
      echo "   Existing dir: ${SESSION_RUN_DIR}" >&2
      echo "" >&2
      echo "   Starting a new workflow (topic=${TOPIC}) will DELETE this" >&2
      echo "   session's existing workflow state and artifacts." >&2
      echo "" >&2
      echo "   Options:" >&2
      echo "     1. Confirm with the user and re-run with --force:" >&2
      echo "        setup-workflow.sh --topic \"${TOPIC}\" --force" >&2
      echo "     2. Keep existing — /dev-workflow:interrupt to pause," >&2
      echo "        /dev-workflow:cancel to clean up, /dev-workflow:continue to resume." >&2
      exit 2
      ;;
  esac
fi

# ──────────────────────────────────────────────────────────────
# Phase 1: Ensure git repo with a HEAD commit (baseline)
# Do this BEFORE creating .dev-workflow/ so the workflow's own
# state files never land in the baseline commit.
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

# Resolve worktree root (may differ from PROJECT_ROOT if user ran setup from
# a subdirectory inside the repo). Used for the `worktree:` field in state.md.
WORKTREE_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")"

# ──────────────────────────────────────────────────────────────
# Phase 2: Archive this session's prior run (if any) before starting fresh.
# Other sessions' dirs are independent and must not be touched.
# Archive target: .dev-workflow/.archive/<ts>-<old_topic>/
# Hidden (.archive) so resolve_state's "$dw"/*/state.md glob — which does
# not match dot-prefixed entries in bash default globbing — skips it.
# ──────────────────────────────────────────────────────────────
ARCHIVE_ROOT="${PROJECT_ROOT}/.dev-workflow/.archive"
if [[ -d "$SESSION_RUN_DIR" ]] && [[ -n "$(ls -A "$SESSION_RUN_DIR" 2>/dev/null)" ]]; then
  # Derive a human-readable topic label for the archive dir name.
  OLD_TOPIC=""
  if [[ -f "$SESSION_RUN_DIR/state.md" ]]; then
    OLD_TOPIC=$(_read_fm_field "$SESSION_RUN_DIR/state.md" topic)
  fi
  if [[ -z "$OLD_TOPIC" ]] && [[ -f "$SESSION_RUN_DIR/planning-report.md" ]]; then
    OLD_TOPIC=$(grep -m1 '^# Planning Report' "$SESSION_RUN_DIR/planning-report.md" \
                | sed 's/^# Planning Report:* *//')
  fi
  [[ -z "$OLD_TOPIC" ]] && OLD_TOPIC="orphan"
  OLD_TOPIC_SAFE=$(printf '%s' "$OLD_TOPIC" | tr -c '[:alnum:]_-' '-' \
                   | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-40)
  [[ -z "$OLD_TOPIC_SAFE" ]] && OLD_TOPIC_SAFE="orphan"

  mkdir -p "$ARCHIVE_ROOT"
  ARCHIVE_BASE="${ARCHIVE_ROOT}/$(date -u +%Y%m%d-%H%M%S)-${OLD_TOPIC_SAFE}"
  ARCHIVE_DIR="$ARCHIVE_BASE"
  n=1
  while [[ -e "$ARCHIVE_DIR" ]]; do
    ARCHIVE_DIR="${ARCHIVE_BASE}-${n}"
    n=$((n + 1))
  done

  if mv "$SESSION_RUN_DIR" "$ARCHIVE_DIR" 2>/dev/null; then
    ARCHIVE_MSG="   📦 Archived previous run: $ARCHIVE_DIR"
  else
    rm -rf "$SESSION_RUN_DIR"
    ARCHIVE_MSG="   ⚠️  Archive failed; previous run removed."
  fi
fi
# Also clean up legacy flat layout if it happens to exist
rm -f "${PROJECT_ROOT}/.dev-workflow/state.md"

# ──────────────────────────────────────────────────────────────
# Phase 3: Create this session's run dir and state.md
# ──────────────────────────────────────────────────────────────
TOPIC_DIR="$SESSION_RUN_DIR"
mkdir -p "$TOPIC_DIR"

INITIAL_STAGE="$(config_initial_stage)"

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
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# ──────────────────────────────────────────────────────────────
# Phase 4: Record baseline (the git SHA we just ensured exists)
# ──────────────────────────────────────────────────────────────
git -C "${PROJECT_ROOT}" rev-parse HEAD > "${TOPIC_DIR}/baseline"

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
