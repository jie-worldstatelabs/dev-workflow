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

if ! config_check; then
  exit 1
fi

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

INITIAL_STAGE="$(config_initial_stage)"

cat > "${PROJECT_ROOT}/.dev-workflow/state.md" <<EOF
---
active: true
status: $INITIAL_STAGE
epoch: 1
resume_status:
topic: "$TOPIC"
project_root: "$PROJECT_ROOT"
session_id: ${CLAUDE_CODE_SESSION_ID:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# Clean up stale artifacts from previous workflows with the same topic.
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

# Baseline: git SHA before any workflow changes. Reviewer diffs against this across all iterations.
git -C "${PROJECT_ROOT}" rev-parse HEAD > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline" 2>/dev/null || echo "EMPTY" > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"

PLAN_PATH="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-planning-report.md"
INTERRUPTIBLE_HINT=""
if config_is_interruptible "$INITIAL_STAGE"; then
  INTERRUPTIBLE_HINT=" — interruptible"
fi

echo "🔄 Dev workflow activated."
echo ""
echo "   Topic: $TOPIC"
echo "   Status: $INITIAL_STAGE (epoch 1)$INTERRUPTIBLE_HINT"
echo ""
echo "   Plan lives in: $PLAN_PATH"
echo "   Stage definitions: $CONFIG_FILE"
echo "   To pause: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
