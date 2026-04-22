#!/bin/bash
# T17 — max_epoch: cap enforcement + default fallback
#
# Two layers:
#   1. config_max_epoch() function: default 20, reads custom, rejects malformed
#   2. update-status.sh: when a transition would push epoch ≥ cap AND the
#      target is non-terminal, short-circuit to "escalated" (if declared as
#      terminal); terminal targets bypass the cap.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T17 — max_epoch cap"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ── A1: config_max_epoch default is 20 when field omitted ────────────────────
D1="$TMP/wf-no-cap"
mkdir -p "$D1"
write_workflow_json "$D1"
use_workflow "$D1"
v="$(config_max_epoch)"
[[ "$v" == "20" ]]
check "A1: max_epoch omitted → config_max_epoch() returns 20" $?

# ── A2: config_max_epoch reads custom value ──────────────────────────────────
D2="$TMP/wf-custom-cap"
mkdir -p "$D2"
cat > "$D2/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "max_epoch": 7,
  "stages": {
    "planning": {
      "interruptible": false,
      "execution": { "type": "inline" },
      "transitions": { "done": "complete" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
touch "$D2/planning.md"
use_workflow "$D2"
v="$(config_max_epoch)"
[[ "$v" == "7" ]]
check "A2: max_epoch=7 → config_max_epoch() returns 7" $?

# ── A3: malformed values fall back to 20 ─────────────────────────────────────
for bad in '0' '-5' '"abc"' 'null'; do
  sed "s/\"max_epoch\": 7/\"max_epoch\": $bad/" "$D2/workflow.json" > "$D2/workflow.json.tmp"
  mv "$D2/workflow.json.tmp" "$D2/workflow.json"
  use_workflow "$D2"
  v="$(config_max_epoch)"
  [[ "$v" == "20" ]] || { echo "    malformed=$bad → got '$v'" >&2; false; }
done
check "A3: malformed max_epoch (0 / -5 / \"abc\" / null) → fallback to 20" $?

# ── A4: update-status.sh short-circuits to escalated at cap ──────────────────
# Setup: real project with state.md at epoch == cap-1, --status <non-terminal>
# triggers cap (NEW_EPOCH = cap).
PROJ="$TMP/proj-cap"
WF="$TMP/wf-small-cap"
SID="fake-session-cap"

# Workflow: cap=3; planning→reviewing(transition done), reviewing→complete(done) or planning(fail)
mkdir -p "$WF"
cat > "$WF/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "max_epoch": 3,
  "stages": {
    "planning": {
      "interruptible": false,
      "execution": { "type": "inline" },
      "transitions": { "done": "reviewing" },
      "inputs": { "required": [], "optional": [] }
    },
    "reviewing": {
      "interruptible": false,
      "execution": { "type": "inline" },
      "transitions": { "PASS": "complete", "FAIL": "planning" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
touch "$WF/planning.md" "$WF/reviewing.md"

mkdir -p "$PROJ/.meta-workflow/$SID"
cat > "$PROJ/.meta-workflow/$SID/state.md" <<EOF
---
topic: cap-test
status: planning
epoch: 2
session_id: $SID
worktree: $PROJ
workflow_dir: $WF
project_root: $PROJ
project_fingerprint:
---
EOF

# FAKE_HOME so session-cache lookup doesn't match this cwd to an unrelated
# session (happens if the test runner lives under a Claude Code session).
FAKE_HOME="$TMP/fake-home-cap"
mkdir -p "$FAKE_HOME"

# No git → ensure_baseline_and_fingerprint is a no-op.
# Next transition epoch = 3 = cap. Target "reviewing" is non-terminal.
# Expected: forced to "escalated" (declared in terminal_stages).
out=$(cd "$PROJ" && HOME="$FAKE_HOME" "$PLUGIN_ROOT/scripts/update-status.sh" --status reviewing 2>&1)
rc=$?
[[ $rc -eq 0 ]]
check "A4: update-status.sh exits 0 at cap (escalated path)" $?

new_status="$(grep '^status:' "$PROJ/.meta-workflow/$SID/state.md" | awk '{print $2}')"
[[ "$new_status" == "escalated" ]]
check "A4: state.md status flipped to escalated (was heading to reviewing)" $?

echo "$out" | grep -q "reached max-epoch"
check "A4: stderr mentions 'reached max-epoch'" $?

# ── A5: user-initiated terminal transition bypasses cap ──────────────────────
# Reset state.md to epoch 2 again.
cat > "$PROJ/.meta-workflow/$SID/state.md" <<EOF
---
topic: cap-test
status: planning
epoch: 2
session_id: $SID
worktree: $PROJ
workflow_dir: $WF
project_root: $PROJ
project_fingerprint:
---
EOF
# --status cancelled is a terminal — cap check should be skipped.
out5=$(cd "$PROJ" && HOME="$FAKE_HOME" "$PLUGIN_ROOT/scripts/update-status.sh" --status cancelled 2>&1)
rc5=$?
[[ $rc5 -eq 0 ]]
check "A5: user --status cancelled at cap-1 epoch → exits 0" $?

s5="$(grep '^status:' "$PROJ/.meta-workflow/$SID/state.md" | awk '{print $2}')"
[[ "$s5" == "cancelled" ]]
check "A5: user-requested terminal honored (status=cancelled, not escalated)" $?

# ── A6: workflow without 'escalated' in terminal_stages → warn + pass through
WF6="$TMP/wf-no-escalated"
mkdir -p "$WF6"
cat > "$WF6/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "cancelled"],
  "max_epoch": 3,
  "stages": {
    "planning": {
      "interruptible": false,
      "execution": { "type": "inline" },
      "transitions": { "done": "reviewing" },
      "inputs": { "required": [], "optional": [] }
    },
    "reviewing": {
      "interruptible": false,
      "execution": { "type": "inline" },
      "transitions": { "PASS": "complete" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
touch "$WF6/planning.md" "$WF6/reviewing.md"

PROJ6="$TMP/proj-no-escalated"
SID6="fake-session-6"
mkdir -p "$PROJ6/.meta-workflow/$SID6"
cat > "$PROJ6/.meta-workflow/$SID6/state.md" <<EOF
---
topic: cap-no-escalated
status: planning
epoch: 2
session_id: $SID6
worktree: $PROJ6
workflow_dir: $WF6
project_root: $PROJ6
project_fingerprint:
---
EOF
# update-status.sh validates the current stage's artifact exists with a
# matching epoch + result before transitioning — supply one so the A6 path
# tests only the cap/warn behavior, not the artifact check.
cat > "$PROJ6/.meta-workflow/$SID6/planning-report.md" <<EOF
---
epoch: 2
result: done
---
# Planning Report
stub
EOF

out6=$(cd "$PROJ6" && HOME="$FAKE_HOME" "$PLUGIN_ROOT/scripts/update-status.sh" --status reviewing 2>&1) || true
echo "$out6" | grep -q "'escalated' is not declared"
check "A6: no 'escalated' terminal → warn, proceed to reviewing" $?

# status should be "reviewing" (not escalated — proceeded)
s6="$(grep '^status:' "$PROJ6/.meta-workflow/$SID6/state.md" | awk '{print $2}')"
[[ "$s6" == "reviewing" ]]
check "A6: state.md status proceeds to reviewing (cap skipped without 'escalated')" $?

print_summary
