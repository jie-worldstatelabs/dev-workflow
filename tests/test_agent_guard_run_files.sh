#!/bin/bash
# T4 — subagent-bootstrap.sh: run_file paths appear in the emitted stage
# context, and agent-guard no longer carries the now-removed prompt
# template helpers.
#
# (Historically this file tested agent-guard.sh's `build_inputs_section`
# + PROMPT TEMPLATE heredoc. The subagent now self-resolves its context
# via subagent-bootstrap.sh, so the run_file-in-context assertion moved
# there. The old helpers have been deleted from agent-guard; a handful
# of regression checks make sure they don't creep back.)

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T4 — subagent-bootstrap.sh: run_file paths in emitted context"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

RUN="${TMP}/run"
mkdir -p "$RUN"
write_workflow_json "$TMP"
use_workflow "$TMP"
use_run_dir "$RUN"

# ── Static checks: agent-guard no longer carries the removed helpers ──

! grep -q 'build_inputs_section' "${PLUGIN_ROOT}/hooks/agent-guard.sh"
check "agent-guard.sh: build_inputs_section removed (now lives in subagent-bootstrap.sh)" $?

! grep -q 'PROMPT TEMPLATE' "${PLUGIN_ROOT}/hooks/agent-guard.sh"
check "agent-guard.sh: PROMPT TEMPLATE heredoc removed" $?

! grep -q 'BASELINE=.*TOPIC_DIR.*baseline' "${PLUGIN_ROOT}/hooks/agent-guard.sh"
check "agent-guard.sh: dead BASELINE variable stays removed" $?

# ── Static checks: subagent-bootstrap.sh handles the run_file type ──

grep -q 'IFS=.*read -r type key description' "${PLUGIN_ROOT}/scripts/subagent-bootstrap.sh"
check "subagent-bootstrap.sh: inputs loop uses type/key/description" $?

grep -q 'config_run_file_path' "${PLUGIN_ROOT}/scripts/subagent-bootstrap.sh"
check "subagent-bootstrap.sh: calls config_run_file_path for run_file inputs" $?

# ── Functional: mirror bootstrap's inputs emission logic ──
#
# subagent-bootstrap.sh resolves the active workflow via the PPID
# chain + registry, which the isolated test harness bypasses. Rather
# than standing up a full fake registry + scratch dir, re-run
# bootstrap's documented inputs-resolution logic — same helpers,
# same output format — and assert the outcome.

STATUS="reviewing"
RUN_DIR_NAME="$(basename "$RUN")"
PROJECT_ROOT="${TMP}"
EPOCH="3"

emit_inputs() {
  local kind="$1"
  local source_fn="config_${kind}_inputs"
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local path
    if [[ "$type" == "run_file" ]]; then
      path="$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    else
      path="$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    fi
    echo "  - $path"
    echo "      $description"
  done < <($source_fn "$STATUS")
}

REQUIRED_OUT="$(emit_inputs required)"

echo "$REQUIRED_OUT" | grep -q "${RUN}/baseline"
check "bootstrap inputs emission includes absolute baseline path" $?

echo "$REQUIRED_OUT" | grep -q "planning-report.md"
check "bootstrap inputs emission includes from_stage artifact (regression)" $?

# ── Regression: stages without required inputs produce empty output ──

STATUS="planning"
REQUIRED_PLANNING="$(emit_inputs required)"
[[ -z "$REQUIRED_PLANNING" ]]
check "planning stage has no required inputs (regression)" $?

print_summary
