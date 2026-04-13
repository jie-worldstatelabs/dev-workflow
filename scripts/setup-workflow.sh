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
# Phase 0: Detect existing workflow(s) in this worktree.
# If found and --force not given, exit with a clear message asking the
# user (via the main agent) whether to proceed — starting a new run
# DELETES the existing workflow's state and artifacts.
# ──────────────────────────────────────────────────────────────
if [[ -z "$FORCE" ]] && [[ -d "${PROJECT_ROOT}/.dev-workflow" ]]; then
  EXISTING=()
  for d in "${PROJECT_ROOT}/.dev-workflow"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/state.md" ]] || continue
    EXISTING+=("$d")
  done
  # Legacy flat layout
  if [[ -f "${PROJECT_ROOT}/.dev-workflow/state.md" ]]; then
    EXISTING+=("${PROJECT_ROOT}/.dev-workflow/")
  fi

  if [[ ${#EXISTING[@]} -gt 0 ]]; then
    echo "⚠️  A dev-workflow already exists in this worktree." >&2
    echo "" >&2
    echo "   Existing workflow(s):" >&2
    for d in "${EXISTING[@]}"; do
      sd="$d/state.md"
      [[ -f "$sd" ]] || continue
      etopic=$(_read_fm_field "$sd" topic)
      estatus=$(_read_fm_field "$sd" status)
      echo "     - topic: ${etopic:-?}   status: ${estatus:-?}   dir: $d" >&2
    done
    echo "" >&2
    echo "   Starting a new workflow (topic=${TOPIC}) will DELETE all existing" >&2
    echo "   workflow state and artifacts in this worktree." >&2
    echo "" >&2
    echo "   Options:" >&2
    echo "     1. Confirm with the user and re-run with --force:" >&2
    echo "        setup-workflow.sh --topic \"${TOPIC}\" --force" >&2
    echo "     2. Keep existing workflow — /dev-workflow:interrupt to pause," >&2
    echo "        /dev-workflow:cancel to clean up, /dev-workflow:continue to resume." >&2
    exit 2
  fi
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
# Phase 2: Nuke any prior workflow in this worktree (one run per worktree)
# ──────────────────────────────────────────────────────────────
if [[ -d "${PROJECT_ROOT}/.dev-workflow" ]]; then
  for d in "${PROJECT_ROOT}/.dev-workflow"/*/; do
    [[ -d "$d" ]] || continue
    rm -rf "$d"
  done
  # Legacy flat state.md (pre-v1.11)
  rm -f "${PROJECT_ROOT}/.dev-workflow/state.md"
fi

# ──────────────────────────────────────────────────────────────
# Phase 3: Create the run's dir and state.md
# ──────────────────────────────────────────────────────────────
TOPIC_DIR="${PROJECT_ROOT}/.dev-workflow/${TOPIC}"
mkdir -p "$TOPIC_DIR"

INITIAL_STAGE="$(config_initial_stage)"

cat > "${TOPIC_DIR}/state.md" <<EOF
---
active: true
status: $INITIAL_STAGE
epoch: 1
resume_status:
topic: "$TOPIC"
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
echo "   Worktree: $WORKTREE_ROOT"
echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
if [[ -n "$AUTO_GIT_MSG" ]]; then
  printf '%b\n' "$AUTO_GIT_MSG"
fi

if config_is_stage "$INITIAL_STAGE"; then
  config_show_stage_context "$INITIAL_STAGE" "$TOPIC" "$PROJECT_ROOT"
fi

echo ""
echo "   Run dir: $TOPIC_DIR"
echo "   Workflow dir: $WORKFLOW_DIR"
echo "   To pause: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
