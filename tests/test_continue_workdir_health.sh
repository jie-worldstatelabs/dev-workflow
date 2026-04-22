#!/bin/bash
# T18 — continue-workflow.sh workdir health check
#
# last_seen_head is recorded in state.md on every stage transition and on
# /interrupt. When the user /continues, the script compares current HEAD
# to last_seen_head and:
#
#   current == last_seen_head          → quiet resume
#   current is ANCESTOR of last_seen   → HARD BLOCK (behind / missing commits)
#                                          unless --force-project-mismatch
#   current is DESCENDANT of last_seen → soft warn, proceed
#   current and last_seen diverged     → HARD BLOCK, same override
#
# Catches cross-clone takeovers where the new workdir is missing commits
# the subagent produced elsewhere.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T18 — continue-workflow.sh workdir health check"

CONT="${PLUGIN_ROOT}/scripts/continue-workflow.sh"
TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME"

# ── Setup: git repo with C1 → C2, "last_seen_head" = C2 ──────────────────────
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cd "$PROJ"
git -c init.defaultBranch=main init -q
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "C1"
C1=$(git rev-parse HEAD)
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "C2"
C2=$(git rev-parse HEAD)
FP=$(git rev-list --max-parents=0 HEAD)

# Workflow dir (minimal; just enough for config_check to pass).
WF="$TMP/wf"
mkdir -p "$WF"
cat > "$WF/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "stages": {
    "planning": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "approved": "complete" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
touch "$WF/planning.md"

SID="fake-session-health"
RUN="$PROJ/.meta-workflow/$SID"
mkdir -p "$RUN"

# Helper: rewrite state.md with fresh epoch + given current HEAD.
seed_state() {
  local last_seen="$1"
  cat > "$RUN/state.md" <<EOF
---
topic: health-test
status: interrupted
epoch: 1
resume_status: planning
session_id: $SID
worktree: $PROJ
workflow_dir: $WF
project_root: $PROJ
project_fingerprint: $FP
started_at: "2026-04-21T00:00:00Z"
last_seen_head: $last_seen
---
EOF
}

run_continue() {
  cd "$PROJ"
  HOME="$FAKE_HOME" "$CONT" "$@" 2>&1
}

# ── B1: current HEAD == last_seen_head → succeeds (no health complaint) ─────
seed_state "$C2"
git -c advice.detachedHead=false checkout -q "$C2"
out=$(run_continue) ; rc=$?
[[ $rc -eq 0 ]]
check "B1: HEAD == last_seen_head → exit 0" $?
! echo "$out" | grep -qi 'behind\|diverged'
check "B1: no 'behind' / 'diverged' warning" $?

# Reset state (continue flipped interrupted → planning); re-seed for next case.
seed_state "$C2"

# ── B2: current HEAD behind last_seen (C1 ← C2) → HARD BLOCK ────────────────
git -c advice.detachedHead=false checkout -q "$C1"
out=$(run_continue) ; rc=$? || true
[[ $rc -ne 0 ]]
check "B2: HEAD behind last_seen → exit non-zero" $?
echo "$out" | grep -q "behind the workflow's last-seen commit"
check "B2: error mentions 'behind the workflow's last-seen commit'" $?

# ── B3: --force-project-mismatch overrides the behind-block ─────────────────
seed_state "$C2"
git -c advice.detachedHead=false checkout -q "$C1"
out=$(run_continue --force-project-mismatch) ; rc=$?
[[ $rc -eq 0 ]]
check "B3: --force-project-mismatch allows behind workdir → exit 0" $?

# ── B4: current HEAD advanced past last_seen (C1 → C2, last_seen=C1) → warn ─
seed_state "$C1"
git -c advice.detachedHead=false checkout -q "$C2"
out=$(run_continue) ; rc=$?
[[ $rc -eq 0 ]]
check "B4: HEAD advanced past last_seen_head → exit 0 (soft warn only)" $?
echo "$out" | grep -q "advanced since the workflow was last seen"
check "B4: stderr has 'advanced since the workflow was last seen' warning" $?

# ── B5: empty last_seen_head (legacy run pre-field) → no health check at all
seed_state ""
git -c advice.detachedHead=false checkout -q "$C2"
out=$(run_continue) ; rc=$?
[[ $rc -eq 0 ]]
check "B5: legacy state.md without last_seen_head → exit 0 (skip check)" $?
! echo "$out" | grep -qi 'behind\|diverged\|advanced'
check "B5: no health-check warnings when field is empty" $?

print_summary
