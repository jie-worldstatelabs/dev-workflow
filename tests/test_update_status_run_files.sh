#!/bin/bash
# T5 — update-status.sh: validates run_file required inputs at transition time

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T5 — update-status.sh: run_file required input validation"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

RUN="${TMP}/run"
mkdir -p "$RUN"
write_workflow_json "$TMP"
use_workflow "$TMP"
use_run_dir "$RUN"

STATUS="reviewing"
RUN_DIR_NAME="$(basename "$RUN")"
PROJECT_ROOT="${TMP}"

# ── Helper: replicate the validation loop from update-status.sh ──────────────
validate_required_inputs() {
  local stage="$1"
  local missing=()
  while IFS=$'\t' read -r type key description; do
    [[ -z "$key" ]] && continue
    local input_path
    if [[ "$type" == "run_file" ]]; then
      input_path="$(config_run_file_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    else
      input_path="$(config_artifact_path "$key" "$RUN_DIR_NAME" "$PROJECT_ROOT")"
    fi
    if [[ ! -f "$input_path" ]]; then
      missing+=("$input_path")
    fi
  done < <(config_required_inputs "$stage")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

# ── Test: transition fails when baseline run_file is missing ─────────────────

# Also create planning artifact (required too)
touch "${RUN}/planning-report.md"

missing_out="$(validate_required_inputs "reviewing" 2>&1 || true)"
echo "$missing_out" | grep -q "baseline"
check "validation fails and names missing baseline run_file" $?

# ── Test: transition succeeds when all required inputs exist ─────────────────

# Create baseline run_file
echo "abc123" > "${RUN}/baseline"

validate_required_inputs "reviewing"
check "validation passes when baseline and planning artifact both exist" $?

# ── Test: removing baseline causes failure again ─────────────────────────────

rm "${RUN}/baseline"
validate_required_inputs "reviewing" > /dev/null 2>&1 && rc=0 || rc=$?
[[ $rc -ne 0 ]]
check "validation fails again after baseline is removed" $?

# ── Regression: from_stage artifact missing still causes failure ──────────────

echo "abc123" > "${RUN}/baseline"
rm "${RUN}/planning-report.md"
missing_stage="$(validate_required_inputs "reviewing" 2>&1 || true)"
echo "$missing_stage" | grep -q "planning-report"
check "validation still catches missing from_stage artifact (regression)" $?

# ── Static check: update-status.sh uses new type/key/description format ──────

grep -q 'IFS=.*read -r type key description' "${PLUGIN_ROOT}/scripts/update-status.sh"
check "update-status.sh: validation loop uses type/key/description format" $?

grep -q 'config_run_file_path' "${PLUGIN_ROOT}/scripts/update-status.sh"
check "update-status.sh: validation loop calls config_run_file_path" $?

print_summary
