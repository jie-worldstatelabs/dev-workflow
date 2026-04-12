#!/bin/bash

# Dev Workflow Stop Hook
# Prevents session exit when the workflow is active.
#
# DESIGN:
#   State machine controller. Reads state.md for (status, epoch), then:
#     1. If artifact for current stage exists with matching epoch + non-empty
#        result → stage is done, use transition table to tell Claude what to
#        do next.
#     2. Else → stage not done, tell Claude to execute the stage's work.
#
#   Epoch validates freshness. Deletion keeps file system clean (and acts as
#   belt-and-suspenders).

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
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]]; then
  if [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
    exit 0
  fi
elif [[ -n "$HOOK_SESSION" ]]; then
  sed -i '' "s/^session_id: *$/session_id: $HOOK_SESSION/" "$STATE_FILE"
fi

# Terminal states
case "$STATUS" in
  complete|escalated)
    rm -f "$STATE_FILE"
    exit 0
    ;;
  interrupted)
    exit 0
    ;;
esac

# Corrupted state
if [[ -z "$STATUS" ]] || [[ -z "$EPOCH" ]] || ! [[ "$EPOCH" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Dev workflow: State file corrupted (status='$STATUS' epoch='$EPOCH')" >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# Map STATUS to the artifact it produces
# ──────────────────────────────────────────────────────────────
case "$STATUS" in
  executing) ARTIFACT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-report.md" ;;
  verifying) ARTIFACT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verify.md" ;;
  reviewing) ARTIFACT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-review.md" ;;
  qa-ing)    ARTIFACT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-report.md" ;;
  *)
    # Unknown active status — allow exit rather than block in weird state
    exit 0
    ;;
esac

# ──────────────────────────────────────────────────────────────
# Read artifact frontmatter (if file exists)
# ──────────────────────────────────────────────────────────────
ARTIFACT_EPOCH=""
ARTIFACT_RESULT=""
if [[ -f "$ARTIFACT" ]]; then
  ART_FM=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$ARTIFACT" 2>/dev/null || true)
  ARTIFACT_EPOCH=$(echo "$ART_FM" | grep '^epoch:' | sed 's/epoch: *//' | tr -d '[:space:]' || true)
  ARTIFACT_RESULT=$(echo "$ART_FM" | grep '^result:' | sed 's/result: *//' | tr -d '[:space:]' || true)
fi

# ──────────────────────────────────────────────────────────────
# Transition table: (status, result) → next_status
# ──────────────────────────────────────────────────────────────
next_status() {
  case "$1:$2" in
    executing:done)    echo "verifying" ;;
    verifying:PASS)    echo "reviewing" ;;
    verifying:FAIL)    echo "executing" ;;
    verifying:SKIPPED) echo "reviewing" ;;
    reviewing:PASS)    echo "qa-ing" ;;
    reviewing:FAIL)    echo "executing" ;;
    qa-ing:PASS)       echo "complete" ;;
    qa-ing:FAIL)       echo "executing" ;;
    *)                 echo "" ;;
  esac
}

# Per-stage work instructions (for "not done" case)
REPORT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-report.md"
VERIFY="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-verify.md"
REVIEW="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-review.md"
QAREPORT="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-qa-report.md"
BASELINE="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-baseline"
JOURNEY="${PROJECT_ROOT}/.dev-workflow/${TOPIC}-journey-tests.md"

case "$STATUS" in
  executing)
    STAGE_WORK="Launch workflow-executor agent (subagent_type: dev-workflow:workflow-executor, model: opus, mode: bypassPermissions).
Prompt must include: project directory ($PROJECT_ROOT), plan ($PLAN_FILE), epoch ($EPOCH), report output ($REPORT), reviewer feedback ($REVIEW if it exists otherwise \"none\"), QA feedback ($QAREPORT if it exists otherwise \"none\"), verify failures ($VERIFY if it exists and result=FAIL otherwise \"none\").
Agent MUST write $REPORT with frontmatter:
---
epoch: $EPOCH
result: done
---"
    ;;
  verifying)
    STAGE_WORK="Run quick tests inline (no agent).
1. Detect test command: package.json (npm test), pytest.ini/pyproject.toml (pytest), pubspec.yaml (flutter test), go.mod (go test ./...), Makefile (make test). If none → SKIPPED.
2. Run with 3-minute timeout.
3. Write $VERIFY with frontmatter:
---
epoch: $EPOCH
result: PASS|FAIL|SKIPPED
---
# Verify Report
<test output>"
    ;;
  reviewing)
    STAGE_WORK="Launch workflow-reviewer agent (subagent_type: dev-workflow:workflow-reviewer, mode: bypassPermissions).
Prompt must include: project directory ($PROJECT_ROOT), plan ($PLAN_FILE), epoch ($EPOCH), execution report ($REPORT), verify report ($VERIFY), review output ($REVIEW), baseline ($BASELINE), QA report ($QAREPORT if it exists otherwise \"none\").
Agent MUST write $REVIEW with frontmatter:
---
epoch: $EPOCH
result: PASS|FAIL
---"
    ;;
  qa-ing)
    STAGE_WORK="Launch workflow-qa agent (subagent_type: dev-workflow:workflow-qa, mode: bypassPermissions).
Prompt must include: project directory ($PROJECT_ROOT), plan ($PLAN_FILE), epoch ($EPOCH), QA report output ($QAREPORT), journey test state file ($JOURNEY).
Agent MUST write $QAREPORT with frontmatter:
---
epoch: $EPOCH
result: PASS|FAIL
---"
    ;;
esac

# ──────────────────────────────────────────────────────────────
# Decide: stage done or not done?
# ──────────────────────────────────────────────────────────────
if [[ -f "$ARTIFACT" ]] && [[ "$ARTIFACT_EPOCH" == "$EPOCH" ]] && [[ -n "$ARTIFACT_RESULT" ]]; then
  # Stage done → give transition instruction
  NEXT=$(next_status "$STATUS" "$ARTIFACT_RESULT")
  if [[ -z "$NEXT" ]]; then
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — unknown result in artifact.

Status: $STATUS (epoch $EPOCH)
Artifact: $ARTIFACT
Result value: '$ARTIFACT_RESULT' — not in transition table.

Inspect $ARTIFACT, then call:
  \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status <correct-next>

DO NOT STOP."
  else
    CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — stage '$STATUS' DONE (result: $ARTIFACT_RESULT), transition not yet called.

$ARTIFACT is valid for epoch $EPOCH.
You MUST now run:
  \"\${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh\" --status $NEXT

Then continue the workflow (either do the next stage's work or, if the new status is 'complete', announce completion).

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
  fi
else
  # Stage NOT done → tell Claude to execute the stage
  if [[ ! -f "$ARTIFACT" ]]; then
    REASON="$ARTIFACT does not exist"
  elif [[ "$ARTIFACT_EPOCH" != "$EPOCH" ]]; then
    REASON="$ARTIFACT has epoch='$ARTIFACT_EPOCH' (stale; expected $EPOCH)"
  else
    REASON="$ARTIFACT has no result field (incomplete)"
  fi

  CONTINUE_PROMPT="[dev-workflow] BLOCKED EXIT — workflow in progress (phase: $STATUS, epoch: $EPOCH).

Reason: $REASON.

Execute the stage:
$STAGE_WORK

DO NOT STOP. The loop is infinite — only /dev-workflow:interrupt or /dev-workflow:cancel stops it."
fi

SYSTEM_MSG="🔄 Dev workflow | Phase: $STATUS (epoch $EPOCH) | EXIT BLOCKED — /dev-workflow:interrupt to pause, /dev-workflow:cancel to stop"

jq -n \
  --arg prompt "$CONTINUE_PROMPT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
