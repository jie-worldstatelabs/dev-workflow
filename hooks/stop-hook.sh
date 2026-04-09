#!/bin/bash

# Dev Workflow Stop Hook
# Prevents session exit when the execute-review loop is active.
#
# KEY DESIGN: Phase is DERIVED from artifacts on disk, NOT from the status field.
# This means even if Claude forgets to call update-status.sh, the hook still
# knows the real state by checking which files exist:
#
#   .dev-workflow/<topic>-round-N-report.md exists + review doesn't  → reviewing
#   .dev-workflow/<topic>-round-N-review.md exists                   → gating
#   neither exists                                            → executing
#
# The status field in the state file is only trusted for terminal states
# (complete, escalated) which Claude must set to release the hook.

set -euo pipefail

HOOK_INPUT=$(cat)

STATE_FILE=".dev-workflow/state.md"

# No active workflow — allow exit
if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# Parse YAML frontmatter
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
STATUS=$(echo "$FRONTMATTER" | grep '^status:' | sed 's/status: *//')
ROUND=$(echo "$FRONTMATTER" | grep '^round:' | sed 's/round: *//')
MAX_ROUNDS=$(echo "$FRONTMATTER" | grep '^max_rounds:' | sed 's/max_rounds: *//')
TOPIC=$(echo "$FRONTMATTER" | grep '^topic:' | sed 's/topic: *//' | sed 's/^"\(.*\)"$/\1/')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Terminal states — allow exit and clean up
case "$STATUS" in
  complete|escalated)
    rm -f "$STATE_FILE"
    exit 0
    ;;
esac

# Validate round number
if [[ ! "$ROUND" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Dev workflow: State file corrupted (invalid round: '$ROUND')" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ROUNDS" =~ ^[0-9]+$ ]]; then
  MAX_ROUNDS=3
fi

# Safety valve: max rounds exceeded
if [[ $ROUND -gt $MAX_ROUNDS ]]; then
  echo "🛑 Dev workflow: Max rounds ($MAX_ROUNDS) exceeded. Stopping."
  rm -f "$STATE_FILE"
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# DERIVE actual phase from artifacts on disk (don't trust STATUS)
# ──────────────────────────────────────────────────────────────

REPORT_FILE=".dev-workflow/${TOPIC}-round-${ROUND}-report.md"
REVIEW_FILE=".dev-workflow/${TOPIC}-round-${ROUND}-review.md"

if [[ -f "$REVIEW_FILE" ]]; then
  # Review file exists → executor AND review both done → should be gating
  ACTUAL_PHASE="gating"
elif [[ -f "$REPORT_FILE" ]]; then
  # Report exists but no review → executor done, review not done
  ACTUAL_PHASE="reviewing"
else
  # Neither exists → still executing
  ACTUAL_PHASE="executing"
fi

# ──────────────────────────────────────────────────────────────
# Also check: did a PREVIOUS round's review already pass?
# If .dev-workflow/<topic>-round-<N>-review.md contains pass signals
# but Claude forgot to mark complete, check for that too.
# ──────────────────────────────────────────────────────────────

# For all completed previous rounds, check if the latest review was a pass
# that Claude failed to act on. Scan back from current round.
for ((r = ROUND; r >= 1; r--)); do
  PREV_REVIEW=".dev-workflow/${TOPIC}-round-${r}-review.md"
  if [[ -f "$PREV_REVIEW" ]]; then
    # Check for pass signals (case insensitive)
    if grep -qi -E '(LGTM|no major issues|implementation is sound|approved|all.*(look|check).*good|pass)' "$PREV_REVIEW" 2>/dev/null; then
      # Looks like it passed but Claude didn't mark complete
      # Don't auto-complete — tell Claude to finalize
      ACTUAL_PHASE="gating"
      ROUND=$r
    fi
    break  # Only check the most recent review
  fi
done

# ──────────────────────────────────────────────────────────────
# Block exit and re-inject continuation prompt
# ──────────────────────────────────────────────────────────────

NEXT_ROUND=$((ROUND + 1))

case "$ACTUAL_PHASE" in
  executing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND/$MAX_ROUNDS, phase: executing).

You MUST continue executing the plan: $PLAN_FILE
Launch the workflow-executor agent (subagent_type: dev-workflow:workflow-executor, model: opus, mode: bypassPermissions).
When executor finishes, verify report at .dev-workflow/${TOPIC}-round-${ROUND}-report.md
Then update status to reviewing and launch the workflow-reviewer agent.
Then evaluate PASS/FAIL.

If PASS or round >= $MAX_ROUNDS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete (or escalated), then you may stop.
If FAIL and round < $MAX_ROUNDS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then continue.

DO NOT STOP until status is complete or escalated."
    ;;
  reviewing)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND/$MAX_ROUNDS, phase: reviewing).

Execution report exists at .dev-workflow/${TOPIC}-round-${ROUND}-report.md but review is missing.

You MUST now:
1. Launch the workflow-reviewer agent (subagent_type: dev-workflow:workflow-reviewer, mode: bypassPermissions)
   Include in prompt: project directory, plan path ($PLAN_FILE), execution report (.dev-workflow/${TOPIC}-round-${ROUND}-report.md), review output path (.dev-workflow/${TOPIC}-round-${ROUND}-review.md), round ($ROUND)
2. Parse the verdict from the agent's response (look for ---VERDICT--- block)
3. If PASS or round >= $MAX_ROUNDS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete (or escalated)
4. If FAIL and round < $MAX_ROUNDS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then continue executing

DO NOT STOP until status is complete or escalated."
    ;;
  gating)
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (round $ROUND/$MAX_ROUNDS, phase: gating).

Both report and review exist for round $ROUND. You MUST now make the gate decision:

1. Read .dev-workflow/${TOPIC}-round-${ROUND}-review.md
2. Determine PASS or FAIL
3. If PASS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status complete, then announce completion
4. If FAIL + round < $MAX_ROUNDS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status executing --round $NEXT_ROUND, then start next execution round
5. If FAIL + round >= $MAX_ROUNDS: run \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status escalated, then list remaining issues

DO NOT STOP until status is complete or escalated."
    ;;
esac

SYSTEM_MSG="🔄 Dev workflow round $ROUND/$MAX_ROUNDS | Phase: $ACTUAL_PHASE | EXIT BLOCKED — complete the workflow"

jq -n \
  --arg prompt "$CONTINUE_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
