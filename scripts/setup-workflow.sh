#!/bin/bash

# Dev Workflow Setup Script
# Creates state.md to activate the workflow at the START of /dev-workflow:dev.
# The initial stage is read from workflow.json (→ `initial_stage`). For the
# default config this is `planning` — interruptible, so the stop hook allows
# natural Q&A pauses.
#
# Usage: setup-workflow.sh --topic <topic>

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

# Resolve workflow dir:
#  - empty → default (skills/dev-workflow/workflow)
#  - absolute path → use as-is
#  - name without slash → plugin-relative (skills/dev-workflow/<name>)
#  - relative path with slash → resolved from CWD
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
# Do this BEFORE creating .dev-workflow/ so the workflow's own
# state files never land in the baseline commit.
# ──────────────────────────────────────────────────────────────
AUTO_GIT_MSG=""
if ! git -C "${PROJECT_ROOT}" rev-parse --git-dir > /dev/null 2>&1; then
  git -C "${PROJECT_ROOT}" init -q
  AUTO_GIT_MSG="   (no git repo found — ran 'git init')"
fi

if ! git -C "${PROJECT_ROOT}" rev-parse HEAD > /dev/null 2>&1; then
  # Stage existing files (if any) and commit so HEAD exists.
  # Inline user config: works even without global git user.name/email.
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
# Phase 2: Create workflow directory and state file
# ──────────────────────────────────────────────────────────────
mkdir -p "${PROJECT_ROOT}/.dev-workflow"

INITIAL_STAGE="$(config_initial_stage)"

cat > "${PROJECT_ROOT}/.dev-workflow/state.md" <<EOF
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
# Phase 3: Clean up stale artifacts from previous workflows with the same topic
# ──────────────────────────────────────────────────────────────
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
while IFS= read -r stage; do
  [[ -z "$stage" ]] && continue
  rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-${stage}-report.md"
done < <(config_all_stages)

# Legacy flat names (v1.4–v1.5)
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-report.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verify.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-review.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-report.md"
# Legacy separate plan file (pre-v1.7)
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-plan.md"
# Legacy round-numbered (pre-v1.4)
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-baseline"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-report.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-verify.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-review.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-qa-report.md"

# ──────────────────────────────────────────────────────────────
# Phase 4: Record baseline (the git SHA we just ensured exists)
# ──────────────────────────────────────────────────────────────
git -C "${PROJECT_ROOT}" rev-parse HEAD > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"

# ──────────────────────────────────────────────────────────────
# Phase 5: Surface context to the main agent
# ──────────────────────────────────────────────────────────────
PLAN_PATH="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-planning-report.md"
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

# Surface the initial stage's I/O context for the main agent
# (especially important when the initial stage is inline).
if config_is_stage "$INITIAL_STAGE"; then
  config_show_stage_context "$INITIAL_STAGE" "$TOPIC" "$PROJECT_ROOT"
fi

echo ""
echo "   Plan lives in: $PLAN_PATH"
echo "   Workflow dir: $WORKFLOW_DIR"
echo "   To pause: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
