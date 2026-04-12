#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When a dev-workflow is active and Claude launches an Agent, this hook
# injects guidance about what subagent_type / mode / prompt contents to use,
# including the current epoch that must be written into the agent's artifact.

set -euo pipefail

HOOK_INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

if ! resolve_state; then
  exit 0
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
EPOCH=$(echo "$FRONTMATTER" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' | tr -d '[:space:]' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if [[ -n "$STATE_SESSION" ]] && [[ -n "$HOOK_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Terminal / paused states — no guidance needed
case "$STATUS" in
  complete|escalated|interrupted)
    exit 0
    ;;
esac

# All stage artifacts follow: {topic}-{stage}-report.md
REPORT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-executing-report.md"
VERIFY="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verifying-report.md"
REVIEW="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-reviewing-report.md"
QAREPORT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-ing-report.md"
BASELINE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
JOURNEY="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-journey-tests.md"

# Auto-record baseline at workflow start (belt-and-suspenders)
if [[ "$STATUS" == "executing" ]] && [[ ! -f "$BASELINE" ]]; then
  git -C "${PROJECT_ROOT}" rev-parse HEAD > "$BASELINE" 2>/dev/null || echo "EMPTY" > "$BASELINE"
fi

case "$STATUS" in
  executing)
    cat <<EOF
[dev-workflow] Active workflow (phase: executing, epoch: $EPOCH).
This Agent call should use:
  - subagent_type: "dev-workflow:workflow-executor"
  - model: opus
  - mode: bypassPermissions

Prompt must include:
  - project directory: $PROJECT_ROOT
  - plan: $PLAN_FILE
  - epoch: $EPOCH
  - report output: $REPORT
  - reviewer feedback: $REVIEW (or "none" if not present)
  - QA feedback: $QAREPORT (or "none" if not present)
  - verify failures: $VERIFY (or "none" if not present or not FAIL)

The agent MUST write $REPORT with frontmatter containing epoch: $EPOCH and result: done.
EOF
    ;;
  verifying)
    cat <<EOF
[dev-workflow] Active workflow (phase: verifying, epoch: $EPOCH).
Do NOT launch an agent for this phase — run quick tests inline.
Write $VERIFY with frontmatter containing epoch: $EPOCH and result: PASS|FAIL|SKIPPED.
EOF
    ;;
  reviewing)
    cat <<EOF
[dev-workflow] Active workflow (phase: reviewing, epoch: $EPOCH).
This Agent call should use:
  - subagent_type: "dev-workflow:workflow-reviewer"
  - mode: bypassPermissions

Prompt must include:
  - project directory: $PROJECT_ROOT
  - plan: $PLAN_FILE
  - epoch: $EPOCH
  - execution report: $REPORT
  - verify report: $VERIFY
  - review output: $REVIEW
  - baseline: $BASELINE
  - QA report: $QAREPORT (or "none" if not present)

The agent MUST write $REVIEW with frontmatter containing epoch: $EPOCH and result: PASS|FAIL.
EOF
    ;;
  qa-ing)
    cat <<EOF
[dev-workflow] Active workflow (phase: qa-ing, epoch: $EPOCH).
This Agent call should use:
  - subagent_type: "dev-workflow:workflow-qa"
  - mode: bypassPermissions

Prompt must include:
  - project directory: $PROJECT_ROOT
  - plan: $PLAN_FILE
  - epoch: $EPOCH
  - QA report output: $QAREPORT
  - journey test state file: $JOURNEY

The agent MUST write $QAREPORT with frontmatter containing epoch: $EPOCH and result: PASS|FAIL.
EOF
    ;;
esac
