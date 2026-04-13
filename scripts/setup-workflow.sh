#!/bin/bash

# Dev Workflow Setup Script
# Creates a per-topic subdir `.dev-workflow/<topic>/` containing state.md +
# baseline, and activates the workflow. Multiple workflows can coexist in
# one project (one per <topic>/ subdir); at most one should be active at a
# time per session.
#
# Usage: setup-workflow.sh --topic <topic> [--workflow <name-or-path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC=""
WORKFLOW_NAME=""

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
# Phase 1: Ensure git repo with a HEAD commit (baseline)
# Do this BEFORE creating .dev-workflow/<topic>/ so the workflow's own
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

# ──────────────────────────────────────────────────────────────
# Phase 2: Create per-topic workflow dir
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
workflow_dir: "$WORKFLOW_DIR"
project_root: "$PROJECT_ROOT"
session_id: ${CLAUDE_CODE_SESSION_ID:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# ──────────────────────────────────────────────────────────────
# Phase 3: Clean up stale artifacts inside this topic's subdir
#          (previous run with the same topic)
# ──────────────────────────────────────────────────────────────
rm -f "${TOPIC_DIR}/baseline"
while IFS= read -r stage; do
  [[ -z "$stage" ]] && continue
  rm -f "${TOPIC_DIR}/${stage}-report.md"
done < <(config_all_stages)

# ──────────────────────────────────────────────────────────────
# Phase 4: Record baseline (git SHA)
# ──────────────────────────────────────────────────────────────
git -C "${PROJECT_ROOT}" rev-parse HEAD > "${TOPIC_DIR}/baseline"

# ──────────────────────────────────────────────────────────────
# Phase 5: Surface context to the main agent
# ──────────────────────────────────────────────────────────────
PLAN_PATH="${TOPIC_DIR}/planning-report.md"
INTERRUPTIBLE_HINT=""
if config_is_interruptible "$INITIAL_STAGE"; then
  INTERRUPTIBLE_HINT=" — interruptible"
fi

echo "🔄 Dev workflow activated."
echo ""
echo "   Topic: $TOPIC"
echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
if [[ -n "$AUTO_GIT_MSG" ]]; then
  printf '%b\n' "$AUTO_GIT_MSG"
fi

if config_is_stage "$INITIAL_STAGE"; then
  config_show_stage_context "$INITIAL_STAGE" "$TOPIC" "$PROJECT_ROOT"
fi

echo ""
echo "   State dir: $TOPIC_DIR"
echo "   Workflow dir: $WORKFLOW_DIR"
echo "   To pause: /dev-workflow:interrupt [--topic $TOPIC]"
echo "   To cancel: /dev-workflow:cancel [--topic $TOPIC]"
