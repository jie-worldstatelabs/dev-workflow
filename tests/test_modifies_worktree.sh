#!/bin/bash
# T20 — modifies_worktree flag
#
# Workflows whose output lives outside the project worktree (create-workflow
# writes to ~/.config/stagent/, publish-workflow doesn't touch files
# at all) set `"modifies_worktree": false` in workflow.json. The plugin:
#   - skips _capture_baseline_tree at setup (no wasted tree object)
#   - short-circuits cloud_post_diff (no noisy diff POST)
#   - leaves fingerprint/baseline-SHA writes alone (used for resume
#     regardless of diff concerns)
#
# Default (field omitted) is true for back-compat with pre-flag workflows.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T20 — modifies_worktree flag"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ── A1: config_modifies_worktree defaults to true when field is omitted ─────
D1="$TMP/wf-omit"
mkdir -p "$D1"
write_workflow_json "$D1"
use_workflow "$D1"
[[ "$(config_modifies_worktree)" == "true" ]]
check "A1: field omitted → config_modifies_worktree = true" $?

# ── A2: explicit true / false are honored ───────────────────────────────────
D2="$TMP/wf-true"
mkdir -p "$D2"
cat > "$D2/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "modifies_worktree": true,
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
[[ "$(config_modifies_worktree)" == "true" ]]
check "A2: explicit true → true" $?

D3="$TMP/wf-false"
mkdir -p "$D3"
sed 's/"modifies_worktree": true/"modifies_worktree": false/' "$D2/workflow.json" > "$D3/workflow.json"
touch "$D3/planning.md"
use_workflow "$D3"
[[ "$(config_modifies_worktree)" == "false" ]]
check "A2: explicit false → false" $?

# ── A3: malformed values default to true (don't accidentally opt out) ───────
for bad in '"maybe"' '"true"' '1' '0' 'null'; do
  sed "s/\"modifies_worktree\": false/\"modifies_worktree\": $bad/" "$D3/workflow.json" > "$D3/workflow.json.tmp"
  mv "$D3/workflow.json.tmp" "$D3/workflow.json"
  use_workflow "$D3"
  [[ "$(config_modifies_worktree)" == "true" ]] || { echo "    malformed=$bad → got '$(config_modifies_worktree)'" >&2; false; }
done
check "A3: malformed values ('maybe' / '\"true\"' / 1 / 0 / null) → default true" $?

# ── B1: _session_modifies_worktree reads from shadow state.md → workflow.json ─
# Setup: shadow with state.md pointing at a workflow_dir that declares false.
WF_FALSE="$TMP/wf-false-live"
mkdir -p "$WF_FALSE"
cat > "$WF_FALSE/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "modifies_worktree": false,
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
touch "$WF_FALSE/planning.md"

SHADOW="$TMP/shadow-false"
mkdir -p "$SHADOW"
cat > "$SHADOW/state.md" <<EOF
---
status: planning
epoch: 1
session_id: fake-sid
workflow_dir: $WF_FALSE
project_root: $TMP/someproj
---
EOF
[[ "$(_session_modifies_worktree "$SHADOW")" == "false" ]]
check "B1: _session_modifies_worktree reads false from workflow.json via state.md" $?

# Flip to true, same helper re-reads.
sed -i.bak 's/"modifies_worktree": false/"modifies_worktree": true/' "$WF_FALSE/workflow.json"
rm -f "$WF_FALSE/workflow.json.bak"
[[ "$(_session_modifies_worktree "$SHADOW")" == "true" ]]
check "B1: _session_modifies_worktree follows workflow_dir → true after flip" $?

# ── B2: missing state.md / missing workflow_dir / missing cfg → default true ─
EMPTY_SHADOW="$TMP/shadow-empty"
mkdir -p "$EMPTY_SHADOW"
[[ "$(_session_modifies_worktree "$EMPTY_SHADOW")" == "true" ]]
check "B2: empty shadow (no state.md) → default true" $?

BAD_SHADOW="$TMP/shadow-bad-path"
mkdir -p "$BAD_SHADOW"
cat > "$BAD_SHADOW/state.md" <<EOF
---
status: planning
session_id: fake
workflow_dir: /nonexistent/path
project_root: /tmp
---
EOF
[[ "$(_session_modifies_worktree "$BAD_SHADOW")" == "true" ]]
check "B2: state.md points at missing workflow_dir → default true" $?

# ── C1-C2: guard patterns are present in the source ────────────────────────
# Spinning up a real setup-workflow.sh run requires a seeded session_id
# cache + HOME + project-root dance; the end-to-end behavior is covered
# by the e2e test suite. Here we keep it tight: verify the gate is
# wired in the right places so refactors can't silently remove it.

grep -q 'config_modifies_worktree.*==.*"true"' "$PLUGIN_ROOT/scripts/setup-workflow.sh"
check "C1: setup-workflow.sh gates _capture_baseline_tree on config_modifies_worktree" $?

grep -q '_session_modifies_worktree.*==.*"false"' "$PLUGIN_ROOT/scripts/lib.sh"
check "C2: cloud_post_diff / ensure_baseline_and_fingerprint gate on _session_modifies_worktree" $?

# Cloud_post_diff must early-return (not just set a flag).
awk '/^cloud_post_diff\(\)/,/^}/' "$PLUGIN_ROOT/scripts/lib.sh" \
  | grep -q 'return 0'
check "C2: cloud_post_diff contains an early return" $?

# ── D1: bundled workflows declare the flag correctly ────────────────────────
DEV_CFG="$PLUGIN_ROOT/skills/stagent/workflow/workflow.json"
[[ "$(jq -r '.modifies_worktree' "$DEV_CFG")" == "true" ]]
check "D1: bundled dev workflow declares modifies_worktree=true" $?

CREATE_CFG="$PLUGIN_ROOT/skills/create-workflow/workflow/workflow.json"
[[ "$(jq -r '.modifies_worktree' "$CREATE_CFG")" == "false" ]]
check "D1: bundled create-workflow declares modifies_worktree=false" $?

print_summary
