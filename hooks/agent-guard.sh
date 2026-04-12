#!/bin/bash

# Dev Workflow Agent Guard (PreToolUse hook for Agent tool)
# When dev-workflow is active and Claude launches an Agent,
# this hook injects a reminder about the workflow context.
#
# KEY DESIGN: Like stop-hook.sh, phase is DERIVED from artifacts on disk,
# NOT from the status field. This ensures correct guidance even if Claude
# forgot to call update-status.sh.
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
ROUND=$(echo "$FRONTMATTER" | grep '^round:' | sed 's/round: *//')
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
# DERIVE actual phase from artifacts on disk (same logic as stop-hook.sh)
# ──────────────────────────────────────────────────────────────

REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-report.md"
VERIFY_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-verify.md"
REVIEW_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-review.md"
QA_REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md"

if [[ -f "$QA_REPORT_FILE" ]]; then
  ACTUAL_PHASE="gating"
elif [[ -f "$REVIEW_FILE" ]]; then
  if grep -q 'VERDICT: PASS' "$REVIEW_FILE" 2>/dev/null; then
    ACTUAL_PHASE="qa-ing"
  else
    ACTUAL_PHASE="gating"
  fi
elif [[ -f "$VERIFY_FILE" ]]; then
  ACTUAL_PHASE="reviewing"
elif [[ -f "$REPORT_FILE" ]]; then
  ACTUAL_PHASE="verifying"
else
  ACTUAL_PHASE="executing"
fi

# ──────────────────────────────────────────────────────────────
# Auto-record baseline if missing (hard guarantee — Claude may skip setup script)
# Baseline is written ONCE at setup and never updated across rounds.
# ──────────────────────────────────────────────────────────────
BASELINE_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
if [[ "$ACTUAL_PHASE" == "executing" ]] && [[ ! -f "$BASELINE_FILE" ]]; then
  git -C "${PROJECT_ROOT}" rev-parse HEAD > "$BASELINE_FILE" 2>/dev/null || echo "EMPTY" > "$BASELINE_FILE"
fi

case "$ACTUAL_PHASE" in
  executing)
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: executing — derived from artifacts).
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-executor"
  - model: opus
  - mode: bypassPermissions
  - Prompt must include: plan path ($PLAN_FILE), round ($ROUND), output report path (.dev-workflow/${TOPIC}-round-${ROUND}-report.md), reviewer feedback (review report from previous round, or "none"), QA feedback (qa-report from previous round, or "none"), and quick test failures (verify report from previous round, or "none")
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing (if not already done)
EOF
    ;;
  verifying)
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: verifying — derived from artifacts).
Execution report exists but quick-test verify is NOT done yet.
Do NOT launch an agent for this phase. Instead, run quick tests inline:
  1. Detect test command (package.json/pytest.ini/pubspec.yaml/go.mod/Makefile)
  2. Run the tests and write .dev-workflow/${TOPIC}-round-${ROUND}-verify.md
  3. If FAIL: update-status --status executing --round <next> and loop back to executor
     If PASS/SKIPPED: update-status --status reviewing and then launch workflow-reviewer
EOF
    ;;
  reviewing)
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: reviewing — derived from artifacts).
Verify report exists at .dev-workflow/${TOPIC}-round-${ROUND}-verify.md
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-reviewer"
  - mode: bypassPermissions
  - Prompt must include: project directory, plan path ($PLAN_FILE), execution report (.dev-workflow/${TOPIC}-round-${ROUND}-report.md), verify report (.dev-workflow/${TOPIC}-round-${ROUND}-verify.md), review output path (.dev-workflow/${TOPIC}-round-${ROUND}-review.md), baseline file (.dev-workflow/${TOPIC}-baseline), QA report (.dev-workflow/${TOPIC}-round-$((ROUND-1))-qa-report.md or "none"), round ($ROUND)
After review: If PASS → update-status --status qa-ing and launch workflow-qa. If FAIL → update-status --status executing --round <next> and loop back.
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status reviewing (if not already done)
EOF
    ;;
  qa-ing)
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: qa-ing — derived from artifacts).
Review PASSED. QA report is missing at .dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-qa"
  - mode: bypassPermissions
  - Prompt must include: project directory, plan path ($PLAN_FILE), QA report output (.dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md), journey test state file (.dev-workflow/${TOPIC}-journey-tests.md), round ($ROUND)
After QA: If PASS → update-status --status complete. If FAIL → update-status --status executing --round <next> and loop back.
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status qa-ing (if not already done)
EOF
    ;;
  gating)
    if [[ -f "$QA_REPORT_FILE" ]]; then
      GATE_HINT="Read .dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md and gate on QA verdict."
    else
      GATE_HINT="Review FAILED (no QA ran). Gate decision = FAIL. Increment round and loop back."
    fi
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: gating — derived from artifacts).
$GATE_HINT
You should be making a gate decision, not launching an agent.
If you need to re-execute after a FAIL verdict, update status first:
  "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing --round <next-round>
EOF
    ;;
esac
