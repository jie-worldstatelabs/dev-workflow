#!/bin/bash

# Dev Workflow Setup Script
# Creates state file to activate the stop hook for the execute-review loop.
# Called after user confirms the plan.

set -euo pipefail

# Parse arguments
TOPIC=""
PLAN_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --topic)
      TOPIC="$2"
      shift 2
      ;;
    --plan-file)
      PLAN_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$TOPIC" ]] || [[ -z "$PLAN_FILE" ]]; then
  echo "❌ Error: --topic and --plan-file are required" >&2
  echo "Usage: setup-workflow.sh --topic <topic> --plan-file <path>" >&2
  exit 1
fi

# Resolve absolute project root (prevents CWD drift issues in hooks)
PROJECT_ROOT="$(pwd)"

# Create state file with absolute paths
mkdir -p "${PROJECT_ROOT}/.dev-workflow"

cat > "${PROJECT_ROOT}/.dev-workflow/state.md" <<EOF
---
active: true
status: executing
round: 1
topic: "$TOPIC"
plan_file: "$PLAN_FILE"
project_root: "$PROJECT_ROOT"
session_id: ${CLAUDE_CODE_SESSION_ID:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# Clean up ALL stale artifacts from previous workflows with the same topic
# (baselines, reports, verifies, reviews — prevents hooks from deriving wrong phase)
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-baseline"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-report.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-verify.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-review.md"
rm -f "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-"*"-qa-report.md"

# Record baseline commit for round 1 (reviewer diffs against this)
git -C "${PROJECT_ROOT}" rev-parse HEAD > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-1-baseline" 2>/dev/null || echo "EMPTY" > "${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-1-baseline"

echo "🔄 Dev workflow loop activated!"
echo ""
echo "   Topic: $TOPIC"
echo "   Plan: $PLAN_FILE"
echo "   Status: executing (round 1)"
echo ""
echo "   The loop runs until the review passes."
echo "   To pause: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
