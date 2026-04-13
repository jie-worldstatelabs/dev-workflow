#!/bin/bash

# Dev Workflow Setup Script
# Creates state.md to activate the workflow at the START of /dev-workflow:dev,
# before planning begins. The initial stage is `planning`, which is interruptible
# — the stop hook allows the session to exit naturally between user exchanges.
#
# Usage: setup-workflow.sh --topic <topic>
# (plan_file is derived: {topic}-planning-report.md)

set -euo pipefail

TOPIC=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --topic)
      TOPIC="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "❌ Error: --topic is required" >&2
  echo "Usage: setup-workflow.sh --topic <topic>" >&2
  exit 1
fi

PROJECT_ROOT="$(pwd)"
mkdir -p "${PROJECT_ROOT}/.dev-workflow"

# Plan lives inside the planning stage's artifact — no separate file.
PLAN_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-planning-report.md"

cat > "${PROJECT_ROOT}/.dev-workflow/state.md" <<EOF
---
active: true
status: planning
epoch: 1
resume_status:
topic: "$TOPIC"
plan_file: "$PLAN_FILE"
project_root: "$PROJECT_ROOT"
session_id: ${CLAUDE_CODE_SESSION_ID:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# Clean up stale artifacts from previous workflows with the same topic.
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
for stage in planning executing verifying reviewing qa-ing; do
  rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-${stage}-report.md"
done
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

# Baseline: git SHA before any workflow changes. Reviewer diffs against this across all iterations.
git -C "${PROJECT_ROOT}" rev-parse HEAD > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline" 2>/dev/null || echo "EMPTY" > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"

echo "🔄 Dev workflow activated."
echo ""
echo "   Topic: $TOPIC"
echo "   Status: planning (epoch 1) — interruptible"
echo ""
echo "   Plan lives in: $PLAN_FILE"
echo "   When user approves: set its result: approved, then update-status.sh --status executing"
echo "   To pause: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
