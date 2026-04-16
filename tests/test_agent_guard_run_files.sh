#!/bin/bash
# T4 — agent-guard.sh: run_file paths appear in prompt template; dead code removed

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T4 — agent-guard.sh: from_run_file in prompt template"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

RUN="${TMP}/run"
mkdir -p "$RUN"
write_workflow_json "$TMP"
use_workflow "$TMP"
use_run_dir "$RUN"

# ── Static check: dead BASELINE= line is gone ────────────────

! grep -q 'BASELINE=.*TOPIC_DIR.*baseline' "${PLUGIN_ROOT}/hooks/agent-guard.sh"
check "agent-guard.sh: dead BASELINE variable removed" $?

# ── Static check: build_inputs_section handles 'type key description' format ──

grep -q 'IFS=.*read -r type key description' "${PLUGIN_ROOT}/hooks/agent-guard.sh"
check "agent-guard.sh: build_inputs_section uses type/key/description" $?

grep -q 'config_run_file_path' "${PLUGIN_ROOT}/hooks/agent-guard.sh"
check "agent-guard.sh: build_inputs_section calls config_run_file_path" $?

# ── Functional: simulate build_inputs_section as agent-guard would call it ───

STATUS="reviewing"
RUN_DIR_NAME="$(basename "$RUN")"
PROJECT_ROOT="${TMP}"
EPOCH="3"

build_inputs_section() {
  local kind="$1"
  local source_fn="config_${kind}_inputs"
  local section=""
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local path
    if [[ "$type" == "run_file" ]]; then
      path="$(config_run_file_path "$key")"
    else
      path="$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    fi
    if [[ "$kind" == "optional" ]]; then
      section+="  - $path (if exists, else \"none\") — $description"$'\n'
    else
      section+="  - $path — $description"$'\n'
    fi
  done < <($source_fn "$STATUS")
  printf '%s' "$section"
}

REQUIRED_SECTION="$(build_inputs_section required)"

# baseline path must appear in the required section
echo "$REQUIRED_SECTION" | grep -q "${RUN}/baseline"
check "agent-guard prompt template includes absolute baseline path" $?

# planning artifact must still appear (regression)
echo "$REQUIRED_SECTION" | grep -q "planning-report.md"
check "agent-guard prompt template includes from_stage artifact (regression)" $?

# ── Regression: from_stage inputs still work ────────────────

STATUS="planning"
REQUIRED_PLANNING="$(build_inputs_section required)"
[[ -z "$REQUIRED_PLANNING" ]]
check "planning stage has no required inputs (regression)" $?

print_summary
