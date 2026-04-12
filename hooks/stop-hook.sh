#!/bin/bash

# Dev Workflow Stop Hook
# Prevents session exit when the execute-review loop is active.
#
# KEY DESIGN: Phase is read directly from the `status` field in state.md.
# update-status.sh DELETES the current stage's output artifact when it transitions,
# so the status field is always the authoritative source of truth:
#
#   status: executing  → report.md was deleted, executor must run
#   status: verifying  → verify.md was deleted, quick tests must run
#   status: reviewing  → review.md was deleted, reviewer must run
#   status: qa-ing     → qa-report.md was deleted, QA must run
#   status: gating     → QA done, gate decision needed
#
# The status field is trusted for ALL states including terminal:
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
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation: directory × session_id
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' | tr -d '[:space:]' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]]; then
  # Workflow already claimed — only block the owning session
  if [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
    exit 0
  fi
elif [[ -n "$HOOK_SESSION" ]]; then
  # No owner yet — first stop fires in the workflow session, claim it
  sed -i '' "s/^session_id: *$/session_id: $HOOK_SESSION/" "$STATE_FILE"
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

# Corrupted state — status field is empty or unrecognised
if [[ -z "$STATUS" ]]; then
  echo "⚠️  Dev workflow: State file corrupted (status field empty)" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# STATUS IS the phase — no artifact scanning needed
# ──────────────────────────────────────────────────────────────
ACTUAL_PHASE="$STATUS"

# Flat artifact paths (no round suffix)
REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-report.md"
VERIFY_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verify.md"
REVIEW_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-review.md"
QA_REPORT_FILE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-report.md"

# ──────────────────────────────────────────────────────────────
# Block exit and re-inject continuation prompt
# ──────────────────────────────────────────────────────────────

case "$ACTUAL_PHASE" in
  executing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: executing).

You MUST continue executing the plan: $PLAN_FILE
Launch the workflow-executor agent (subagent_type: dev-workflow:workflow-executor, model: opus, mode: bypassPermissions).

Executor prompt must include:
  - Project directory: $PROJECT_ROOT
  - Plan file: $PLAN_FILE
  - Report output: $REPORT_FILE
  - Reviewer feedback: $REVIEW_FILE (if it exists, otherwise \"none\")
  - QA feedback: $QA_REPORT_FILE (if it exists, otherwise \"none\")
  - Quick test failures: $VERIFY_FILE (if it exists and says FAIL, otherwise \"none\")

When executor finishes, update status to verifying, run quick tests inline, write $VERIFY_FILE
Then update status to reviewing and launch the workflow-reviewer agent.
Then if reviewer PASS: update status to qa-ing and launch workflow-qa agent.
Then evaluate QA PASS/FAIL.

If QA PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then you may stop.
If QA FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing, then loop back.

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  verifying)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: verifying).

Execution report exists at $REPORT_FILE but quick-test verify is missing.

You MUST now run quick tests inline (no agent needed):
1. Detect test command: check package.json (npm test), pytest.ini (pytest), pubspec.yaml (flutter test), go.mod (go test ./...), Makefile (make test)
2. Run: cd $PROJECT_ROOT && <test-command> 2>&1 (3-minute timeout)
3. Write $VERIFY_FILE with result (PASS/FAIL/SKIPPED)
4. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing, then loop back to executor
5. If PASS or SKIPPED: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status reviewing, then launch workflow-reviewer agent

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  reviewing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: reviewing).

Verify report exists at $VERIFY_FILE but review is missing.

You MUST now:
1. Launch the workflow-reviewer agent (subagent_type: dev-workflow:workflow-reviewer, mode: bypassPermissions)
   Include in prompt: project directory ($PROJECT_ROOT), plan path ($PLAN_FILE), execution report ($REPORT_FILE), verify report ($VERIFY_FILE), review output path ($REVIEW_FILE), baseline file (${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline), QA report ($QA_REPORT_FILE or \"none\" if not present)
2. Parse the verdict from the agent's response (look for ---VERDICT--- block)
3. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status qa-ing, then launch workflow-qa agent
4. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing, then loop back

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  qa-ing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: qa-ing).

Review PASSED but QA report is missing at $QA_REPORT_FILE.

You MUST now:
1. Launch the workflow-qa agent (subagent_type: dev-workflow:workflow-qa, mode: bypassPermissions)
   Include in prompt: project directory ($PROJECT_ROOT), plan path ($PLAN_FILE), QA report output ($QA_REPORT_FILE), journey test state file (${PROJECT_ROOT}/.dev-workflow/${TOPIC}-journey-tests.md)
2. Parse the QA verdict from the agent's response (look for ---VERDICT--- block)
3. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then announce completion
4. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing, then loop back

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  gating)
    if [[ -f "$QA_REPORT_FILE" ]]; then
      GATE_CONTEXT="QA report exists at $QA_REPORT_FILE. Read it and determine PASS/FAIL based on confirmed app bugs."
    else
      GATE_CONTEXT="No QA report found. Check $REVIEW_FILE for the reviewer verdict to determine gate decision."
    fi
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: gating).

$GATE_CONTEXT

You MUST now make the gate decision:

1. Evaluate PASS or FAIL
2. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then announce completion
3. If FAIL: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing, then start next execution

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
    ;;
  *)
    # Unknown status — don't block, let the session exit
    exit 0
    ;;
esac

SYSTEM_MSG="🔄 Dev workflow | Phase: $ACTUAL_PHASE | EXIT BLOCKED — use /dev-workflow:interrupt to pause or /dev-workflow:cancel to stop"

jq -n \
  --arg prompt "$CONTINUE_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
