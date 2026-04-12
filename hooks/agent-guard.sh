#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When dev-workflow is active and Claude launches an Agent,
# this hook injects a reminder about the workflow context.
#
# KEY DESIGN: Phase is read directly from the `status` field in state.md,
# which update-status.sh maintains as the authoritative source of truth.
# This ensures correct guidance even if Claude forgot to call update-status.sh
# (the artifact deletion is a belt-and-suspenders consistency check).
#
# It cannot FORCE parameters (PreToolUse can't modify tool args),
# but it CAN inject a system message that strongly steers behavior.

set -euo pipefail

# Read hook input first (stdin is only available at script start)
HOOK_INPUT=$(cat)

# Resolve state file (handles CWD drift)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

# No active workflow — pass through
if ! resolve_state; then
  exit 0
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation: only inject guidance into the session that owns the workflow
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' | tr -d '[:space:]' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
if [[ -n "$STATE_SESSION" ]] && [[ -n "$HOOK_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Terminal or paused states — no guard needed
case "$STATUS" in
  complete|escalated|interrupted)
    exit 0
    ;;
esac

# ──────────────────────────────────────────────────────────────
# STATUS IS the phase — read directly from state.md
# ──────────────────────────────────────────────────────────────
ACTUAL_PHASE="$STATUS"

# Flat artifact paths (no round suffix)
REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-report.md"
VERIFY_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verify.md"
REVIEW_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-review.md"
QA_REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-report.md"

# ──────────────────────────────────────────────────────────────
# Auto-record baseline if missing (hard guarantee — Claude may skip setup script)
# Baseline is written ONCE at setup and never updated across iterations.
# ──────────────────────────────────────────────────────────────
BASELINE_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
if [[ "$ACTUAL_PHASE" == "executing" ]] && [[ ! -f "$BASELINE_FILE" ]]; then
  git -C "${PROJECT_ROOT}" rev-parse HEAD > "$BASELINE_FILE" 2>/dev/null || echo "EMPTY" > "$BASELINE_FILE"
fi

case "$ACTUAL_PHASE" in
  executing)
    cat <<EOF
[dev-workflow] Active workflow detected (phase: executing — from status field).
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-executor"
  - model: opus
  - mode: bypassPermissions
  - Prompt must include: plan path ($PLAN_FILE), report output ($REPORT_FILE), reviewer feedback ($REVIEW_FILE or "none"), QA feedback ($QA_REPORT_FILE or "none"), and quick test failures ($VERIFY_FILE if it exists and says FAIL, otherwise "none")
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing (if not already done)
EOF
    ;;
  verifying)
    cat <<EOF
[dev-workflow] Active workflow detected (phase: verifying — from status field).
Execution report exists but quick-test verify is NOT done yet.
Do NOT launch an agent for this phase. Instead, run quick tests inline:
  1. Detect test command (package.json/pytest.ini/pubspec.yaml/go.mod/Makefile)
  2. Run the tests and write $VERIFY_FILE
  3. If FAIL: update-status --status executing and loop back to executor
     If PASS/SKIPPED: update-status --status reviewing and then launch workflow-reviewer
EOF
    ;;
  reviewing)
    cat <<EOF
[dev-workflow] Active workflow detected (phase: reviewing — from status field).
Verify report exists at $VERIFY_FILE
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-reviewer"
  - mode: bypassPermissions
  - Prompt must include: project directory, plan path ($PLAN_FILE), execution report ($REPORT_FILE), verify report ($VERIFY_FILE), review output path ($REVIEW_FILE), baseline file (${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline), QA report ($QA_REPORT_FILE or "none" if not present)
After review: If PASS → update-status --status qa-ing and launch workflow-qa. If FAIL → update-status --status executing and loop back.
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status reviewing (if not already done)
EOF
    ;;
  qa-ing)
    cat <<EOF
[dev-workflow] Active workflow detected (phase: qa-ing — from status field).
Review PASSED. QA report is missing at $QA_REPORT_FILE
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-qa"
  - mode: bypassPermissions
  - Prompt must include: project directory, plan path ($PLAN_FILE), QA report output ($QA_REPORT_FILE), journey test state file (${PROJECT_ROOT}/.dev-workflow/${TOPIC}-journey-tests.md)
After QA: If PASS → update-status --status complete. If FAIL → update-status --status executing and loop back.
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status qa-ing (if not already done)
EOF
    ;;
  gating)
    if [[ -f "$QA_REPORT_FILE" ]]; then
      GATE_HINT="Read $QA_REPORT_FILE and gate on QA verdict."
    else
      GATE_HINT="No QA report found. Check $REVIEW_FILE for reviewer verdict. Gate decision likely = FAIL."
    fi
    cat <<EOF
[dev-workflow] Active workflow detected (phase: gating — from status field).
$GATE_HINT
You should be making a gate decision, not launching an agent.
If you need to re-execute after a FAIL verdict, update status first:
  "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing
EOF
    ;;
esac
