#!/bin/bash
# E2E-2 — create-workflow SKILL: real Claude execution
#
# Invokes create-workflow via `claude --print` with a fully-specified
# description so Claude can proceed without asking clarifying questions.
# Asserts that the correct files are created on disk and pass validation.
#
# Requirements: claude CLI in PATH, API access.
# Cost: ~3-6 Haiku API calls per test case.
# Timeout: 180s per test case.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
source "${TESTS_DIR}/../helpers.sh"

echo "E2E-2 — create-workflow SKILL (real Claude)"

MODEL="${MODEL:-claude-sonnet-4-6}"
TIMEOUT=180
SETUP="${PLUGIN_ROOT}/scripts/setup-workflow.sh"

# macOS has no `timeout`; use perl alarm as a portable substitute.
run_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV or die $!' "$secs" "$@"
}

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# Unique suffix to avoid collision with any existing workflow of same name
SUFFIX="e2eci$(date +%s)"

# ── E2E-2-1: Create a 2-stage workflow from a complete description ─────────────
# Provide the full spec so Claude skips the design interview and writes files.
PROMPT1="$(cat <<EOF
/stagent:create-workflow --mode=local
Build a simple 2-stage code-linting workflow. Here is the complete design — please proceed directly to writing files without asking for confirmation:

Stage 1: linting
- execution: inline, interruptible: false
- purpose: run the linter and record findings
- result values: clean (no issues) → complete; issues-found → fixing

Stage 2: fixing
- execution: inline, interruptible: false
- purpose: fix the linter issues found in stage 1
- result values: done → complete
- required input: from_stage linting

Terminal stages: complete
Name: lint-fix-${SUFFIX}

The design is approved. Please write the files now.
EOF
)"

output1="$(run_timeout "$TIMEOUT" claude --print \
    --model "$MODEL" \
    -p "$PROMPT1" 2>&1)"
rc1=$?
[[ $rc1 -eq 0 ]]
check "E2E-2-1: claude exits 0" $?

WF_DIR1="$HOME/.config/stagent/workflows/lint-fix-${SUFFIX}"
[[ -d "$WF_DIR1" ]]
check "E2E-2-1: workflow directory created at ~/.config/stagent/workflows/" $?

[[ -f "$WF_DIR1/workflow.json" ]]
check "E2E-2-1: workflow.json written" $?

# Stage .md files must exist
[[ -f "$WF_DIR1/linting.md" ]]
check "E2E-2-1: linting.md stage file written" $?

[[ -f "$WF_DIR1/fixing.md" ]]
check "E2E-2-1: fixing.md stage file written" $?

# ── E2E-2-2: Generated workflow.json is valid (passes --validate-only) ─────────
validate_out="$("$SETUP" --validate-only --workflow="$WF_DIR1" 2>&1)"
rc2=$?
[[ $rc2 -eq 0 ]]
check "E2E-2-2: generated workflow.json passes --validate-only" $?

echo "$validate_out" | grep -q "✓"
check "E2E-2-2: validation output shows success" $?

# ── E2E-2-3: workflow.json has correct schema structure ───────────────────────
initial="$(jq -r '.initial_stage // empty' "$WF_DIR1/workflow.json" 2>/dev/null)"
[[ "$initial" == "linting" ]]
check "E2E-2-3: initial_stage = linting" $?

terminal_count="$(jq '.terminal_stages | length' "$WF_DIR1/workflow.json" 2>/dev/null)"
[[ "$terminal_count" -ge 1 ]]
check "E2E-2-3: terminal_stages is non-empty" $?

stage_count="$(jq '.stages | keys | length' "$WF_DIR1/workflow.json" 2>/dev/null)"
[[ "$stage_count" -ge 2 ]]
check "E2E-2-3: at least 2 stages declared" $?

# fixing stage must have linting as required input
fixing_req="$(jq -r '.stages.fixing.inputs.required[0].from_stage // empty' \
    "$WF_DIR1/workflow.json" 2>/dev/null)"
[[ "$fixing_req" == "linting" ]]
check "E2E-2-3: fixing stage has required input from_stage=linting" $?

# ── E2E-2-4: Generated workflow can start a real session ──────────────────────
# If the skill built a valid workflow, setup-workflow.sh must be able to start
# a session from it. Use a fake session via cwd-key seed (same trick as T14/T15).
source "${PLUGIN_ROOT}/scripts/lib.sh"

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.cache/stagent/session-cache"
P4="$TMP/project4"
mkdir -p "$P4"
git -C "$P4" init -q
git -C "$P4" -c user.name=t -c user.email=t@t commit --allow-empty -q -m init

key4="$(printf '%s' "$P4" | shasum -a 1 | cut -c1-16)"
echo "e2e-sess-${SUFFIX}" > "$FAKE_HOME/.cache/stagent/session-cache/cwd-$key4"

(cd "$P4" && HOME="$FAKE_HOME" "$SETUP" \
    --mode=local --topic=e2e-generated-wf \
    --workflow="$WF_DIR1" > /dev/null 2>&1)
check "E2E-2-4: setup-workflow.sh starts a session from generated workflow" $?

STATE4="$P4/.stagent/e2e-sess-${SUFFIX}/state.md"
[[ -f "$STATE4" ]]
check "E2E-2-4: state.md created from generated workflow" $?

status4="$(_read_fm_field "$STATE4" status)"
[[ "$status4" == "linting" ]]
check "E2E-2-4: initial status matches initial_stage from generated workflow" $?

# ── E2E-2-5: Edit mode — Claude can add a stage to an existing workflow ────────
PROMPT5="$(cat <<EOF
/stagent:create-workflow --mode=local --workflow=${WF_DIR1}
Add a new stage called reporting after fixing. It should be inline, uninterruptible, result: done → complete. Required input: from_stage fixing. The change is approved. Please update the files now.
EOF
)"

output5="$(run_timeout "$TIMEOUT" claude --print \
    --model "$MODEL" \
    -p "$PROMPT5" 2>&1)"
rc5=$?
[[ $rc5 -eq 0 ]]
check "E2E-2-5: edit mode claude exits 0" $?

# After edit: validate again
validate5="$("$SETUP" --validate-only --workflow="$WF_DIR1" 2>&1)"
rc5v=$?
[[ $rc5v -eq 0 ]]
check "E2E-2-5: edited workflow still passes --validate-only" $?

# Cleanup: remove the workflow dir created during this test
rm -rf "$WF_DIR1"

print_summary
