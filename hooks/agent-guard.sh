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

# Terminal states — no guard needed
case "$STATUS" in
  complete|escalated)
    exit 0
    ;;
esac

# ──────────────────────────────────────────────────────────────
# DERIVE actual phase from artifacts on disk (same logic as stop-hook.sh)
# ──────────────────────────────────────────────────────────────

REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-report.md"
REVIEW_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-review.md"

if [[ -f "$REVIEW_FILE" ]]; then
  ACTUAL_PHASE="gating"
elif [[ -f "$REPORT_FILE" ]]; then
  ACTUAL_PHASE="reviewing"
else
  ACTUAL_PHASE="executing"
fi

# ──────────────────────────────────────────────────────────────
# Auto-record baseline if missing (hard guarantee — Claude may skip scripts)
# ──────────────────────────────────────────────────────────────
BASELINE_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-baseline"
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
  - Prompt must include: plan path ($PLAN_FILE), round ($ROUND), and output report path (.dev-workflow/${TOPIC}-round-${ROUND}-report.md)
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing (if not already done)
EOF
    ;;
  reviewing)
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: reviewing — derived from artifacts).
Execution report exists at .dev-workflow/${TOPIC}-round-${ROUND}-report.md
Ensure this agent is launched with:
  - subagent_type: "dev-workflow:workflow-reviewer"
  - mode: bypassPermissions
  - Prompt must include: project directory, plan path ($PLAN_FILE), execution report (.dev-workflow/${TOPIC}-round-${ROUND}-report.md), review output path (.dev-workflow/${TOPIC}-round-${ROUND}-review.md), round ($ROUND)
Also remember to run: "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status reviewing (if not already done)
EOF
    ;;
  gating)
    cat <<EOF
[dev-workflow] Active workflow detected (round $ROUND, phase: gating — derived from artifacts).
Both report and review exist. You should be making a gate decision, not launching an agent.
If you need to re-execute after a FAIL verdict, update status first:
  "\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing --round <next-round>
EOF
    ;;
esac
