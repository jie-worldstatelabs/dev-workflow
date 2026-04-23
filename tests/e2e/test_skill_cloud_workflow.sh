#!/bin/bash
# C2E-2 — stagent SKILL: cloud mode E2E (real Claude + real server)
#
# Invokes the stagent skill in cloud mode via `claude --print` and
# asserts on both local shadow state and server-side state after Claude runs.
# No mocking — real Claude, real server, real cloud mode.
#
# Design note on cloud state lifecycle:
#   In cloud mode, state lives in a shadow dir at
#   ~/.cache/stagent/sessions/<UUID>/state.md. On terminal status,
#   both update-status.sh and stop-hook.sh wipe the shadow + unregister
#   from ~/.cache/stagent/cloud-registry/. The project worktree never gets
#   a .stagent/ directory in cloud mode.
#
# Requirements: claude CLI in PATH, API access, network access to
#   STAGENT_SERVER (defaults to https://stagent.worldstatelabs.com).
# Cost: ~3-6 Sonnet API calls per test case.

set -uo pipefail   # no -e: assertions use explicit rc vars

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
source "${TESTS_DIR}/../helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "C2E-2 — stagent SKILL: cloud mode (real Claude + real server)"

SMOKE_WF="${PLUGIN_ROOT}/tests/e2e/fixtures/smoke-workflow"
INTERRUPTIBLE_WF="${PLUGIN_ROOT}/tests/e2e/fixtures/cloud-interruptible-workflow"
MODEL="claude-sonnet-4-6"
STAGENT_SERVER="${STAGENT_SERVER:-https://stagent.worldstatelabs.com}"
export STAGENT_SERVER

TMP="$(make_tmpdir)"

# Track all server sessions we create so we can clean them up.
CREATED_SESSIONS=()

cleanup() {
  for sid in "${CREATED_SESSIONS[@]}"; do
    # Best-effort server cleanup — DELETE the session so we don't leave orphans.
    curl -sS --max-time 5 \
      -X DELETE "${STAGENT_SERVER}/api/sessions/${sid}" \
      -H "$(_cloud_auth_header)" \
      >/dev/null 2>&1 || true
    # Also clean local shadow + registry in case tests left them.
    cloud_wipe_scratch "$sid" 2>/dev/null || true
    cloud_unregister_session "$sid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

# Read the session UUID from the local session cache for a project directory.
# The session-start hook writes ~/.cache/stagent/session-cache/cwd-<sha1> each
# time a Claude session opens in that project. stop-hook does NOT clean it up,
# so it persists after the workflow terminates — reliable for post-run lookups.
read_project_session() {
  local project="$1"
  local key
  key="$(cd "$project" && printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16)"
  local cache_file="${HOME}/.cache/stagent/session-cache/cwd-${key}"
  [[ -f "$cache_file" ]] && cat "$cache_file" || echo ""
}

make_git_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" -c user.name=t -c user.email=t@t commit --allow-empty -q -m init
}

# Write session cache for a project (no real Claude needed).
write_session_cache() {
  local project="$1" session_id="$2"
  local key
  key="$(cd "$project" && printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16)"
  mkdir -p "${HOME}/.cache/stagent/session-cache"
  echo "$session_id" > "${HOME}/.cache/stagent/session-cache/cwd-${key}"
}

# Seed a cloud workflow state directly (no Claude, no setup-workflow.sh).
# Creates the shadow dir, POSTs to the real server, registers in cloud
# registry, and writes state.md. Works with local fixture workflow dirs
# (setup-workflow.sh rejects local paths in cloud mode, but cloud_post_setup
# accepts any resolved workflow dir).
seed_cloud_state() {
  local project="$1" workflow="$2" topic="$3" session_id="$4"
  write_session_cache "$project" "$session_id"

  local canonical_project
  canonical_project="$(cd "$project" && pwd)"
  local worktree
  worktree="$(git -C "$canonical_project" rev-parse --show-toplevel 2>/dev/null || echo "$canonical_project")"

  # Create shadow + workflow cache.
  local scratch="${HOME}/.cache/stagent/sessions/${session_id}"
  local wf_cache="${scratch}/.workflow-cache"
  mkdir -p "$wf_cache"
  cp -R "${workflow%/}/." "${wf_cache}/"

  # Resolve initial stage from the workflow config.
  local initial_stage
  initial_stage="$(jq -r '.initial_stage' "${wf_cache}/workflow.json")"

  # POST to real server.
  if ! cloud_post_setup "$session_id" "$topic" "$wf_cache" "" "$canonical_project" "$worktree" "false"; then
    echo "seed_cloud_state: cloud_post_setup failed" >&2
    rm -rf "$scratch"
    return 1
  fi

  # Register locally.
  cloud_register_session "$session_id" "$STAGENT_SERVER" ""

  # Write shadow state.md.
  local fingerprint
  fingerprint="$(git_project_fingerprint "$canonical_project")"
  cat > "${scratch}/state.md" <<EOF
---
active: true
status: $initial_stage
epoch: 1
resume_status:
topic: "$topic"
session_id: $session_id
worktree: "$worktree"
workflow_dir: "$wf_cache"
project_root: "$canonical_project"
project_fingerprint: ${fingerprint:-}
mode: cloud
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---
EOF

  CREATED_SESSIONS+=("$session_id")
  echo "$session_id"
}

# Query server for session status.
server_session_status() {
  local sid="$1"
  local resp
  resp="$(curl -sS -fL --max-time 10 \
    -H "$(_cloud_auth_header)" \
    "${STAGENT_SERVER}/api/sessions/${sid}" 2>/dev/null)" || { echo ""; return; }
  printf '%s' "$resp" | jq -r '.session.status // ""' 2>/dev/null
}

# Run claude --print; capture output and exit code.
run_claude() {
  local dir="$1" prompt="$2" out_var="$3" rc_var="$4"
  local _out="" _rc=0
  _out="$(cd "$dir" && claude --print --model "$MODEL" -p "$prompt" 2>&1)" || _rc=$?
  eval "${out_var}=\$_out"
  eval "${rc_var}=\$_rc"
}

# ── C2E-2-1: cloud start + local workflow fixture -> complete ─────────────────
# Uses the smoke fixture workflow (single inline uninterruptible stage).
# Claude should drive it to 'complete' in a single pass. After completion,
# shadow is wiped, registry removed, and the project worktree has no
# .stagent/.

P1="$TMP/project1"
make_git_project "$P1"

run_claude "$P1" \
    "/stagent:start --mode=cloud --workflow=${SMOKE_WF} smoke-cloud-e2e" \
    OUTPUT1 RC1

check "C2E-2-1: claude exits 0" "$RC1"

# Read the session UUID from the session cache (stop-hook does not clean it up,
# so it persists even after the workflow terminates in cloud mode).
SID1="$(read_project_session "$P1")"
if [[ -n "$SID1" ]]; then
  CREATED_SESSIONS+=("$SID1")
fi
rc_sid1=0
[[ -n "$SID1" ]] && [[ "$SID1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || rc_sid1=1
check "C2E-2-1: session UUID recoverable from session cache" "$rc_sid1"

if [[ -n "$SID1" ]]; then
  # Shadow should be wiped after terminal (cloud_wipe_scratch).
  SHADOW1="${HOME}/.cache/stagent/sessions/${SID1}"
  rc_shadow1=0; [[ ! -d "$SHADOW1" ]] || rc_shadow1=1
  check "C2E-2-1: shadow wiped after terminal" "$rc_shadow1"

  # Cloud registry should be removed after terminal.
  REG1="${HOME}/.cache/stagent/cloud-registry/${SID1}.json"
  rc_reg1=0; [[ ! -f "$REG1" ]] || rc_reg1=1
  check "C2E-2-1: cloud registry removed after terminal" "$rc_reg1"

  # Server status should be complete (or escalated — smoke only has complete).
  srv_status1="$(server_session_status "$SID1")"
  rc_srv1=0; [[ "$srv_status1" == "complete" ]] || rc_srv1=1
  check "C2E-2-1: server status = complete" "$rc_srv1" "got '$srv_status1'"

  # No .stagent/ in the project (cloud doesn't pollute the worktree).
  rc_nolocal1=0; [[ ! -d "$P1/.stagent" ]] || rc_nolocal1=1
  check "C2E-2-1: no .stagent/ in project worktree" "$rc_nolocal1"
else
  check "C2E-2-1: shadow wiped after terminal" 1
  check "C2E-2-1: cloud registry removed after terminal" 1
  check "C2E-2-1: server status = complete" 1
  check "C2E-2-1: no .stagent/ in project worktree" 1
fi

# ── C2E-2-2: cancel removes shadow + unregisters ─────────────────────────────
# Seed a cloud state, then cancel it. Verify local cleanup + server status.

P2="$TMP/project2"
make_git_project "$P2"

SID2="$(uuidgen | tr '[:upper:]' '[:lower:]')"
seed_rc2=0
seed_cloud_state "$P2" "$SMOKE_WF" "cancel-cloud-e2e" "$SID2" >/dev/null || seed_rc2=$?
check "C2E-2-2: seed_cloud_state works" "$seed_rc2"

SHADOW2="${HOME}/.cache/stagent/sessions/${SID2}"
rc_shadow2a=0; [[ -f "${SHADOW2}/state.md" ]] || rc_shadow2a=1
check "C2E-2-2: shadow state.md exists after seed" "$rc_shadow2a"

REG2="${HOME}/.cache/stagent/cloud-registry/${SID2}.json"
rc_reg2a=0; [[ -f "$REG2" ]] || rc_reg2a=1
check "C2E-2-2: cloud registry exists after seed" "$rc_reg2a"

# Cancel the seeded workflow.
can_rc2=0
(cd "$P2" && "${PLUGIN_ROOT}/scripts/cancel-workflow.sh" >/dev/null 2>&1) || can_rc2=$?
check "C2E-2-2: cancel-workflow.sh exits 0" "$can_rc2"

rc_shadow2b=0; [[ ! -d "$SHADOW2" ]] || rc_shadow2b=1
check "C2E-2-2: shadow wiped after cancel" "$rc_shadow2b"

rc_reg2b=0; [[ ! -f "$REG2" ]] || rc_reg2b=1
check "C2E-2-2: cloud registry removed after cancel" "$rc_reg2b"

srv_status2="$(server_session_status "$SID2")"
rc_srv2=0; [[ "$srv_status2" == "cancelled" ]] || rc_srv2=1
check "C2E-2-2: server status = cancelled" "$rc_srv2" "got '$srv_status2'"

# ── C2E-2-3: interrupt -> continue (same machine) ────────────────────────────
# Seed a cloud state with the interruptible workflow, interrupt it, then
# use real Claude to continue. Verify the full lifecycle.

P3="$TMP/project3"
make_git_project "$P3"

SID3="$(uuidgen | tr '[:upper:]' '[:lower:]')"
seed_rc3=0
seed_cloud_state "$P3" "$INTERRUPTIBLE_WF" "interrupt-continue-e2e" "$SID3" >/dev/null || seed_rc3=$?
check "C2E-2-3: seed_cloud_state" "$seed_rc3"

SHADOW3="${HOME}/.cache/stagent/sessions/${SID3}"

# Interrupt the seeded state.
int_rc3=0
(cd "$P3" && "${PLUGIN_ROOT}/scripts/interrupt-workflow.sh" >/dev/null 2>&1) || int_rc3=$?
check "C2E-2-3: interrupt-workflow.sh exits 0" "$int_rc3"

if [[ -f "${SHADOW3}/state.md" ]]; then
  int_status3="$(_read_fm_field "${SHADOW3}/state.md" status)"
  rc_int3=0; [[ "$int_status3" == "interrupted" ]] || rc_int3=1
  check "C2E-2-3: status = interrupted in shadow" "$rc_int3" "got '$int_status3'"
else
  check "C2E-2-3: status = interrupted in shadow" 1 "shadow state.md missing"
fi

# Real Claude invocation to continue the interrupted workflow.
# Must pass --session explicitly: the new Claude session's UUID overwrites the
# session cache for P3, so continue-workflow.sh can't find SID3 via the cache.
run_claude "$P3" "/stagent:continue --session ${SID3}" OUT3_CONT RC3_CONT
check "C2E-2-3: /stagent:continue --session (real Claude) exits 0" "$RC3_CONT"

# After continue drives to terminal: check for artifact in shadow (it may
# already be wiped if stop-hook fired). The artifact is analyze-report.md.
# We check both the shadow (if it still exists) and the server.
if [[ -d "$SHADOW3" ]] && [[ -f "${SHADOW3}/analyze-report.md" ]]; then
  assert_pass "C2E-2-3: analyze-report.md artifact written in shadow"
else
  # Shadow may already be wiped by terminal cleanup. Check server for
  # the artifact instead.
  srv_resp3="$(curl -sS -fL --max-time 10 \
    -H "$(_cloud_auth_header)" \
    "${STAGENT_SERVER}/api/sessions/${SID3}" 2>/dev/null || echo "{}")"
  has_artifact3="$(printf '%s' "$srv_resp3" | jq '[.artifacts[]? | select(.stage == "analyze")] | length' 2>/dev/null || echo "0")"
  rc_art3=0; [[ "$has_artifact3" -gt 0 ]] || rc_art3=1
  check "C2E-2-3: analyze-report.md artifact written (server)" "$rc_art3"
fi

# Shadow should be wiped after continuation completes (terminal).
# Give a small grace period — stop-hook runs asynchronously.
rc_shadow3=0; [[ ! -d "$SHADOW3" ]] || rc_shadow3=1
check "C2E-2-3: shadow wiped after continuation completes" "$rc_shadow3"

REG3="${HOME}/.cache/stagent/cloud-registry/${SID3}.json"
rc_reg3=0; [[ ! -f "$REG3" ]] || rc_reg3=1
check "C2E-2-3: cloud registry removed after continuation" "$rc_reg3"

# ── C2E-2-4: cross-machine continue ──────────────────────────────────────────
# Seed a cloud state, interrupt it, then wipe ALL local traces (shadow +
# registry), simulating a machine switch. Then use real Claude with
# /stagent:continue --session UUID from the same project dir.
# Claude should pull the shadow from the server and complete the workflow.

P4="$TMP/project4"
make_git_project "$P4"

SID4="$(uuidgen | tr '[:upper:]' '[:lower:]')"
seed_rc4=0
seed_cloud_state "$P4" "$INTERRUPTIBLE_WF" "cross-machine-e2e" "$SID4" >/dev/null || seed_rc4=$?
check "C2E-2-4: seed_cloud_state" "$seed_rc4"

SHADOW4="${HOME}/.cache/stagent/sessions/${SID4}"

# Interrupt the workflow on the server.
int_rc4=0
(cd "$P4" && "${PLUGIN_ROOT}/scripts/interrupt-workflow.sh" >/dev/null 2>&1) || int_rc4=$?
check "C2E-2-4: interrupt-workflow.sh exits 0" "$int_rc4"

# Wipe ALL local traces — simulate switching to a different machine.
rm -rf "${HOME}/.cache/stagent/sessions/${SID4}"
rm -f "${HOME}/.cache/stagent/cloud-registry/${SID4}.json"

rc_noshadow4=0; [[ ! -d "${HOME}/.cache/stagent/sessions/${SID4}" ]] || rc_noshadow4=1
check "C2E-2-4: shadow wiped (simulating machine switch)" "$rc_noshadow4"

rc_noreg4=0; [[ ! -f "${HOME}/.cache/stagent/cloud-registry/${SID4}.json" ]] || rc_noreg4=1
check "C2E-2-4: cloud registry wiped (simulating machine switch)" "$rc_noreg4"

# Real Claude: continue with explicit --session from the same project dir.
run_claude "$P4" "/stagent:continue --session ${SID4}" OUT4_CONT RC4_CONT
check "C2E-2-4: /stagent:continue --session UUID exits 0" "$RC4_CONT"

# After cross-machine takeover + continue, check that the registry was
# restored (cloud_pull_shadow + cloud_register_session in continue-workflow.sh).
# Note: by the time we check, the workflow may have completed and cleaned up.
# We verify via server status instead.
srv_status4="$(server_session_status "$SID4")"
rc_srv4=0; [[ "$srv_status4" == "complete" ]] || rc_srv4=1
check "C2E-2-4: server status = complete after cross-machine continue" "$rc_srv4" "got '$srv_status4'"

# Check server has the analyze artifact (written during continuation).
srv_resp4="$(curl -sS -fL --max-time 10 \
  -H "$(_cloud_auth_header)" \
  "${STAGENT_SERVER}/api/sessions/${SID4}" 2>/dev/null || echo "{}")"
has_artifact4="$(printf '%s' "$srv_resp4" | jq '[.artifacts[]? | select(.stage == "analyze")] | length' 2>/dev/null || echo "0")"
rc_art4=0; [[ "$has_artifact4" -gt 0 ]] || rc_art4=1
check "C2E-2-4: analyze-report.md artifact on server after cross-machine continue" "$rc_art4"

# Shadow should be wiped after terminal.
rc_shadow4f=0; [[ ! -d "${HOME}/.cache/stagent/sessions/${SID4}" ]] || rc_shadow4f=1
check "C2E-2-4: shadow wiped after terminal" "$rc_shadow4f"

print_summary
