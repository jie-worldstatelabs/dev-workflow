#!/bin/bash

# Dev Workflow Stop Hook
# Prevents session exit when the execute-review loop is active.
#
# KEY DESIGN: Phase is DERIVED from artifacts on disk, NOT from the status field.
# This means even if Claude forgets to call update-status.sh, the hook still
# knows the real state by checking which files exist:
#
#   neither report nor verify exists              → executing
#   report exists, verify does NOT exist          → verifying
#   verify exists, review does NOT exist          → reviewing
#   review exists with PASS verdict, no qa-report → qa-ing
#   review exists with FAIL verdict               → gating  (reviewer failed, gate = fail)
#   qa-report exists                              → gating  (QA done, gate on QA verdict)
#
# The status field is only trusted for terminal states:
#   complete / escalated → allow exit + delete state
#   interrupted          → allow exit + KEEP state (for /dev-workflow:continue)

set -euo pipefail

HOOK_INPUT=$(cat)

# Resolve state file (handles CWD drift)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$HOOK_DIR")/scripts/lib.sh"

# No active workflow — allow exit
if ! resolve_state; then
  exit 0
fi

# Parse YAML frontmatter
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
ROUND=$(echo "$FRONTMATTER" | grep '^round:' | sed 's/round: *//')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Terminal states
case "$STATUS" in
  complete|escalated)
    # Done — clean up and allow exit
    rm -f "$STATE_FILE"
    exit 0
    ;;
  interrupted)
    # Paused by user — allow exit but KEEP state file for /dev-workflow:continue
    exit 0
    ;;
esac

# Validate round number
if [[ ! "$ROUND" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Dev workflow: State file corrupted (invalid round: '$ROUND')" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# DERIVE actual phase from artifacts on disk (don't trust STATUS)
# ──────────────────────────────────────────────────────────────

REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-report.md"
VERIFY_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-verify.md"
REVIEW_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-review.md"
QA_REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md"

if [[ -f "$QA_REPORT_FILE" ]]; then
  # QA report exists → gating on QA verdict
  ACTUAL_PHASE="gating"
elif [[ -f "$REVIEW_FILE" ]]; then
  # Review exists — check verdict: PASS → qa-ing, FAIL/ambiguous → gating
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
# Block exit and re-inject continuation prompt
# ──────────────────────────────────────────────────────────────

NEXT_ROUND=$((ROUND + 1))

case "$ACTUAL_PHASE" in
  executing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND, phase: executing).

You MUST continue executing the plan: $PLAN_FILE
Launch the workflow-executor agent (subagent_type: dev-workflow:workflow-executor, model: opus, mode: bypassPermissions).
When executor finishes, verify report at .dev-workflow/${TOPIC}-round-${ROUND}-report.md
Then update status to verifying, run quick tests inline, and write .dev-workflow/${TOPIC}-round-${ROUND}-verify.md
Then update status to reviewing and launch the workflow-reviewer agent.
Then if reviewer PASS: update status to qa-ing and launch workflow-qa agent.
Then evaluate QA PASS/FAIL.

If QA PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then you may stop.
If QA FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then loop back.

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  verifying)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND, phase: verifying).

Execution report exists at .dev-workflow/${TOPIC}-round-${ROUND}-report.md but quick-test verify is missing.

You MUST now run quick tests inline (no agent needed):
1. Detect test command: check package.json (npm test), pytest.ini (pytest), pubspec.yaml (flutter test), go.mod (go test ./...), Makefile (make test)
2. Run: cd <project-directory> && <test-command> 2>&1 (3-minute timeout)
3. Write .dev-workflow/${TOPIC}-round-${ROUND}-verify.md with result (PASS/FAIL/SKIPPED)
4. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then loop back to executor
5. If PASS or SKIPPED: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status reviewing, then launch workflow-reviewer agent

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  reviewing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND, phase: reviewing).

Verify report exists at .dev-workflow/${TOPIC}-round-${ROUND}-verify.md but review is missing.

You MUST now:
1. Launch the workflow-reviewer agent (subagent_type: dev-workflow:workflow-reviewer, mode: bypassPermissions)
   Include in prompt: project directory, plan path ($PLAN_FILE), execution report (.dev-workflow/${TOPIC}-round-${ROUND}-report.md), verify report (.dev-workflow/${TOPIC}-round-${ROUND}-verify.md), review output path (.dev-workflow/${TOPIC}-round-${ROUND}-review.md), baseline file (.dev-workflow/${TOPIC}-round-${ROUND}-baseline), QA report (.dev-workflow/${TOPIC}-round-$((ROUND-1))-qa-report.md or "none" if round 1), round ($ROUND)
2. Parse the verdict from the agent's response (look for ---VERDICT--- block)
3. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status qa-ing, then launch workflow-qa agent
4. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then loop back

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  qa-ing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND, phase: qa-ing).

Review PASSED but QA report is missing at .dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md.

You MUST now:
1. Launch the workflow-qa agent (subagent_type: dev-workflow:workflow-qa, mode: bypassPermissions)
   Include in prompt: project directory, plan path ($PLAN_FILE), QA report output (.dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md), journey test state file (.dev-workflow/${TOPIC}-journey-tests.md), round ($ROUND)
2. Parse the QA verdict from the agent's response (look for ---VERDICT--- block)
3. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then announce completion
4. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then loop back

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  gating)
    if [[ -f "$QA_REPORT_FILE" ]]; then
      GATE_CONTEXT="QA report exists at .dev-workflow/${TOPIC}-round-${ROUND}-qa-report.md. Read it and determine PASS/FAIL based on confirmed app bugs."
    else
      GATE_CONTEXT="Review at .dev-workflow/${TOPIC}-round-${ROUND}-review.md has a FAIL verdict (no QA ran). Gate decision = FAIL — increment round and loop back."
    fi
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND, phase: gating).

$GATE_CONTEXT

You MUST now make the gate decision:

1. Evaluate PASS or FAIL
2. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then announce completion
3. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then start next round

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
esac

SYSTEM_MSG="🔄 Dev workflow round $ROUND | Phase: $ACTUAL_PHASE | EXIT BLOCKED — use /dev-workflow:interrupt to pause or /dev-workflow:cancel to stop"

jq -n \
  --arg prompt "$CONTINUE_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
