#!/bin/bash
# E2E-1 — stagent SKILL: real Claude execution
#
# Invokes the stagent skill via `claude --print` and asserts on the
# filesystem state after Claude runs. No mocking — real Claude, real scripts.
#
# Design note on state.md lifecycle:
#   For LOCAL sessions, stop-hook.sh deletes state.md when a terminal status
#   is reached (rm -f "$STATE_FILE" at stop-hook.sh:85). The run dir and
#   artifacts persist. Tests that run a workflow to completion must check the
#   run dir and artifacts, NOT state.md.
#
# Requirements: claude CLI in PATH, API access.
# Cost: ~2-4 Sonnet API calls per test case.

set -uo pipefail   # no -e: assertions use explicit rc vars so all failures are recorded
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
source "${TESTS_DIR}/../helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "E2E-1 — stagent SKILL (real Claude)"

SMOKE_WF="${PLUGIN_ROOT}/tests/e2e/fixtures/smoke-workflow"
MODEL="claude-sonnet-4-6"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

make_git_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=t -c user.email=t@t commit --allow-empty -q -m init
}

# Find the run dir written by Claude (session ID is real, unknown in advance).
# State.md is DELETED by stop-hook for terminal local sessions; we look for
# the directory itself (which persists along with artifacts).
find_run_dir() {
  local project="$1"
  find "$project/.stagent" -maxdepth 1 -mindepth 1 -type d \
       -not -name ".archive" 2>/dev/null | head -1
}

# Find state.md for ACTIVE (non-terminal) sessions.
find_state() {
  local project="$1"
  find "$project/.stagent" -name "state.md" \
       -not -path "*/.archive/*" 2>/dev/null | head -1
}

# Seed a local state.md via setup-workflow.sh (no Claude needed).
# Writes session ID to the session cache so the scripts resolve it.
seed_state() {
  local project="$1" workflow="$2" topic="$3" session_id="$4"
  local key
  # Use canonical pwd (cd first) so the key matches read_cached_session_id()
  # which also uses $(pwd) after cd — on macOS /var/ → /private/var/ symlink
  # means printf '%s' "$project" gives a different hash than $(cd && pwd).
  key="$(cd "$project" && printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16)"
  mkdir -p "$HOME/.cache/stagent/session-cache"
  echo "$session_id" > "$HOME/.cache/stagent/session-cache/cwd-$key"
  (cd "$project" && "${PLUGIN_ROOT}/scripts/setup-workflow.sh" \
      --mode=local --topic="$topic" --workflow="$workflow" > /dev/null 2>&1)
}

# Run claude --print; capture output and exit code without triggering set -e.
run_claude() {
  local dir="$1" prompt="$2" out_var="$3" rc_var="$4"
  local _out="" _rc=0
  _out="$(cd "$dir" && claude --print --model "$MODEL" -p "$prompt" 2>&1)" || _rc=$?
  eval "${out_var}=\$_out"
  eval "${rc_var}=\$_rc"
}

# ── E2E-1-1: smoke workflow runs to completion ────────────────────────────────
# The smoke stage is uninterruptible inline — instructions say write result:passed
# and call update-status. Claude should drive it to 'complete' in a single pass.
# After completion, state.md is deleted by stop-hook (expected). The run dir
# and smoke-report.md artifact remain.

P1="$TMP/project1"
make_git_project "$P1"

run_claude "$P1" \
    "/stagent:start --mode=local --workflow=${SMOKE_WF} smoke-check-e2e" \
    OUTPUT1 RC1

check "E2E-1-1: claude exits 0" "$RC1"

RUN_DIR1="$(find_run_dir "$P1")"
rc_rd1=0; [[ -n "$RUN_DIR1" ]] || rc_rd1=$?
check "E2E-1-1: run dir created under project .stagent/" "$rc_rd1"

if [[ -n "$RUN_DIR1" ]]; then
  # state.md is intentionally deleted by stop-hook on terminal status (local mode)
  rc_nostatemd=0; [[ ! -f "$RUN_DIR1/state.md" ]] || rc_nostatemd=$?
  check "E2E-1-1: state.md cleaned up after terminal (stop-hook behavior)" "$rc_nostatemd"

  ARTIFACT1="$(find "$RUN_DIR1" -name "smoke-report.md" 2>/dev/null | head -1)"
  rc_a1=0; [[ -n "$ARTIFACT1" ]] || rc_a1=$?
  check "E2E-1-1: smoke-report.md artifact written" "$rc_a1"

  if [[ -n "$ARTIFACT1" ]]; then
    result1="$(_read_fm_field "$ARTIFACT1" result)"
    rc_r1=0; [[ "$result1" == "passed" ]] || rc_r1=$?
    check "E2E-1-1: artifact result = passed" "$rc_r1"
  else
    check "E2E-1-1: artifact result = passed" 1
  fi
else
  check "E2E-1-1: state.md cleaned up after terminal (stop-hook behavior)" 1
  check "E2E-1-1: smoke-report.md artifact written" 1
  check "E2E-1-1: artifact result = passed" 1
fi

# ── E2E-1-2: run dir name encodes the session_id; workflow_dir was correct ───
# The run dir is named after the real Claude session ID (written by setup-workflow.sh
# using the value from the session-start hook's cache). The artifact existing at the
# right path confirms workflow_dir was set correctly.
if [[ -n "$RUN_DIR1" ]]; then
  sid1="$(basename "$RUN_DIR1")"
  # Claude session IDs are UUID v4: 8-4-4-4-12 hex digits
  rc_uuid1=0
  [[ "$sid1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || rc_uuid1=$?
  check "E2E-1-2: run dir name is UUID v4 (session_id from SessionStart hook)" "$rc_uuid1"

  # smoke-report.md at the right path confirms workflow.json was loaded from SMOKE_WF
  rc_wf1=0; [[ -f "$RUN_DIR1/smoke-report.md" ]] || rc_wf1=$?
  check "E2E-1-2: artifact path confirms correct workflow_dir used" "$rc_wf1"
else
  check "E2E-1-2: run dir name is UUID v4 (session_id from SessionStart hook)" 1
  check "E2E-1-2: artifact path confirms correct workflow_dir used" 1
fi

# ── E2E-1-3: interrupt → real-Claude continue lifecycle ──────────────────────
# Seed an interrupted local state (no Claude needed for setup), then invoke
# real Claude via /stagent:continue and verify it drives the stage to done.
WF3="$TMP/wf-interruptible"
mkdir -p "$WF3"
cat > "$WF3/workflow.json" <<'EOF'
{
  "initial_stage": "thinking",
  "terminal_stages": ["complete"],
  "stages": {
    "thinking": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "done": "complete" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
cat > "$WF3/thinking.md" <<'EOF'
# Stage: thinking

Write one sentence about the task (test of interrupt/continue lifecycle).
Produce the artifact at the path shown in your I/O context with:

```
---
epoch: <epoch>
result: done
---
<your one-sentence summary>
```

Then call `update-status.sh --status complete`.
Valid result values: `done`
EOF

P3="$TMP/project3"
make_git_project "$P3"

SID3="e2e-int-$(date +%s)"
seed_state "$P3" "$WF3" "e2e-interrupt-test" "$SID3"
rc_seed3=$?
check "E2E-1-3: setup-workflow.sh seeds initial state" "$rc_seed3"

STATE3="$P3/.stagent/$SID3/state.md"
rc_s3=0; [[ -f "$STATE3" ]] || rc_s3=$?
check "E2E-1-3: state.md exists after seed" "$rc_s3"

if [[ -f "$STATE3" ]]; then
  # Interrupt the seeded state
  int_rc=0
  (cd "$P3" && "${PLUGIN_ROOT}/scripts/interrupt-workflow.sh" 2>/dev/null) || int_rc=$?
  check "E2E-1-3: interrupt-workflow.sh exits 0" "$int_rc"

  int_status="$(_read_fm_field "$STATE3" status)"
  rc_int3=0; [[ "$int_status" == "interrupted" ]] || rc_int3=$?
  check "E2E-1-3: status = interrupted after interrupt-workflow.sh" "$rc_int3"

  if [[ "$int_status" == "interrupted" ]]; then
    # Real Claude invocation to continue the interrupted workflow
    run_claude "$P3" "/stagent:continue" OUT3_CONT RC3_CONT
    check "E2E-1-3: /stagent:continue (real Claude) exits 0" "$RC3_CONT"

    # After continue, Claude drives the stage to terminal; run dir persists, state.md gone
    RUN_DIR3="$(find_run_dir "$P3")"
    rc_rd3=0; [[ -n "$RUN_DIR3" ]] || rc_rd3=$?
    check "E2E-1-3: run dir persists after continue completes" "$rc_rd3"

    if [[ -n "$RUN_DIR3" ]]; then
      # continue-workflow.sh renames the run dir to the new real session UUID;
      # find_run_dir returns that renamed dir. The artifact is thinking-report.md.
      rc_cont3=0
      [[ -f "$RUN_DIR3/thinking-report.md" ]] || rc_cont3=$?
      check "E2E-1-3: thinking-report.md artifact written after continue" "$rc_cont3"
    else
      check "E2E-1-3: thinking-report.md artifact written after continue" 1
    fi
  else
    check "E2E-1-3: /stagent:continue (real Claude) exits 0" 1
    check "E2E-1-3: run dir persists after continue completes" 1
    check "E2E-1-3: continue drove workflow to completion" 1
  fi
else
  check "E2E-1-3: interrupt-workflow.sh exits 0" 1
  check "E2E-1-3: status = interrupted after interrupt-workflow.sh" 1
  check "E2E-1-3: /stagent:continue (real Claude) exits 0" 1
  check "E2E-1-3: run dir persists after continue completes" 1
  check "E2E-1-3: continue drove workflow to completion" 1
fi

# ── E2E-1-4: cancel removes the run dir ──────────────────────────────────────
# Seed a fresh local state, then cancel it. This tests that cancel-workflow.sh
# properly removes the run dir when called on an active (non-terminal) state.
P4="$TMP/project4"
make_git_project "$P4"

SID4="e2e-cancel-$(date +%s)"
rc_seed4=0
seed_state "$P4" "$SMOKE_WF" "e2e-cancel-test" "$SID4" || rc_seed4=$?
check "E2E-1-4: seed_state creates initial state" "$rc_seed4"

STATE4="$P4/.stagent/$SID4/state.md"
rc_state4=0; [[ -f "$STATE4" ]] || rc_state4=$?
check "E2E-1-4: state.md exists after seed" "$rc_state4"

if [[ -f "$STATE4" ]]; then
  RUN_DIR4="$(dirname "$STATE4")"
  can_rc=0
  (cd "$P4" && "${PLUGIN_ROOT}/scripts/cancel-workflow.sh" > /dev/null 2>&1) || can_rc=$?
  check "E2E-1-4: cancel-workflow.sh exits 0" "$can_rc"

  rc_gone=0; [[ ! -d "$RUN_DIR4" ]] || rc_gone=$?
  check "E2E-1-4: run dir removed after cancel" "$rc_gone"
else
  check "E2E-1-4: cancel-workflow.sh exits 0" 1
  check "E2E-1-4: run dir removed after cancel" 1
fi

print_summary
