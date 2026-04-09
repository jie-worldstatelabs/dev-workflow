#!/bin/bash

# Dev Workflow Setup Script
# Creates state file to activate the stop hook for the execute-review loop.
# Called after user confirms the plan.

set -euo pipefail

# Parse arguments
TOPIC=""
PLAN_FILE=""
MAX_ROUNDS=3

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
    --max-rounds)
      MAX_ROUNDS="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$TOPIC" ]] || [[ -z "$PLAN_FILE" ]]; then
  echo "❌ Error: --topic and --plan-file are required" >&2
  echo "Usage: setup-workflow.sh --topic <topic> --plan-file <path> [--max-rounds <n>]" >&2
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
max_rounds: $MAX_ROUNDS
topic: "$TOPIC"
plan_file: "$PLAN_FILE"
project_root: "$PROJECT_ROOT"
session_id: ${CLAUDE_CODE_SESSION_ID:-}
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

# Breadcrumb for cross-directory state discovery
echo "${PROJECT_ROOT}/.dev-workflow/state.md" > "${HOME}/.dev-workflow-active"

echo "🔄 Dev workflow loop activated!"
echo ""
echo "   Topic: $TOPIC"
echo "   Plan: $PLAN_FILE"
echo "   Max rounds: $MAX_ROUNDS"
echo "   Status: executing (round 1)"
echo ""
echo "   The stop hook will prevent exit until the workflow completes."
echo "   To cancel: /dev-workflow:cancel"
