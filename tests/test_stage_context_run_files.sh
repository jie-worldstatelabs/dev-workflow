#!/bin/bash
# T3 — stage-context.sh: run_file inputs appear with correct absolute paths

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T3 — stage-context.sh: from_run_file injection"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

RUN="${TMP}/run"
mkdir -p "$RUN"
write_workflow_json "$TMP"
use_workflow "$TMP"
use_run_dir "$RUN"

# Simulate state.md so resolve_state can find it (needed by stage-context.sh internals)
# We test build_inputs_section logic by sourcing the helper and calling directly.

# Source stage-context.sh helpers by extracting the build_inputs_section function.
# We replicate the call pattern from stage-context.sh manually:

STATUS="reviewing"
RUN_DIR_NAME="$(basename "$RUN")"
PROJECT_ROOT="${TMP}"

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

required_out="$(build_inputs_section required)"

# Should contain the baseline run_file with absolute path
echo "$required_out" | grep -q "${RUN}/baseline"
check "required inputs include absolute path to baseline run_file" $?

# Should contain the planning stage artifact path
echo "$required_out" | grep -q "planning-report.md"
check "required inputs still include from_stage artifact (regression)" $?

# run_file and stage entries should share same indent/format
run_file_line="$(echo "$required_out" | grep "baseline")"
stage_line="$(echo "$required_out" | grep "planning-report")"
# Both should start with "  - "
[[ "$run_file_line" == "  - "* ]]
check "run_file input line starts with '  - '" $?
[[ "$stage_line" == "  - "* ]]
check "stage input line starts with '  - ' (regression)" $?

# Description should appear after the path
echo "$run_file_line" | grep -q "Git SHA at workflow start"
check "run_file line includes its description" $?

print_summary
