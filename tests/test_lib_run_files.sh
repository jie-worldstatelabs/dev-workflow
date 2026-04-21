#!/bin/bash
# T1 — lib.sh unit tests for run_files support

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T1 — lib.sh: run_files functions"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

write_workflow_json "$TMP"
use_workflow "$TMP"
use_run_dir "$TMP/run"
mkdir -p "$TMP/run"

# ── config_required_inputs ───────────────────────────────────

out="$(config_required_inputs "reviewing")"

# Should contain a run_file entry for baseline
echo "$out" | grep -q "^run_file	baseline	"
check "config_required_inputs emits run_file entry for baseline" $?

# Should still contain a stage entry for planning
echo "$out" | grep -q "^stage	planning	"
check "config_required_inputs emits stage entry for planning (regression)" $?

# Verify format is type\tkey\tdescription (3 fields)
field_count="$(echo "$out" | head -1 | awk -F'\t' '{print NF}')"
[[ "$field_count" -eq 3 ]]
check "config_required_inputs output has 3 tab-separated fields" $?

# ── config_optional_inputs ───────────────────────────────────

# Planning has no optional inputs — should be empty
out_opt="$(config_optional_inputs "planning")"
[[ -z "$out_opt" ]]
check "config_optional_inputs empty for stage with no optionals" $?

# ── config_run_file_path ─────────────────────────────────────

# 2nd/3rd args are only used in the DW_RUN_BASE / fallback branches.
# TOPIC_DIR branch ignores them but they're positionally required.
path="$(config_run_file_path "baseline" "" "$TMP")"
[[ "$path" == "$TMP/run/baseline" ]]
check "config_run_file_path uses TOPIC_DIR" $?

# DW_RUN_BASE override
export DW_RUN_BASE="/tmp/shadow"
unset TOPIC_DIR
path2="$(config_run_file_path "baseline" "sess123" "$TMP")"
[[ "$path2" == "/tmp/shadow/sess123/baseline" ]]
check "config_run_file_path uses DW_RUN_BASE when set" $?
unset DW_RUN_BASE

# ── config_run_file_init ─────────────────────────────────────

init_cmd="$(config_run_file_init "baseline")"
[[ "$init_cmd" == "git rev-parse HEAD 2>/dev/null || echo EMPTY" ]]
check "config_run_file_init returns correct init command" $?

init_custom="$(config_run_file_init "custom")"
[[ "$init_custom" == "echo hello-custom" ]]
check "config_run_file_init works for custom run_file" $?

empty_init="$(config_run_file_init "nonexistent")"
[[ -z "$empty_init" ]]
check "config_run_file_init returns empty for unknown key" $?

# ── config_run_file_names ────────────────────────────────────

names="$(config_run_file_names | sort | tr '\n' ',')"
[[ "$names" == "baseline,custom," ]]
check "config_run_file_names lists all declared run_files" $?

# ── config_validate — valid config ───────────────────────────

config_validate 2>/dev/null
check "config_validate passes with valid from_run_file reference" $?

# ── config_validate — invalid from_run_file ref ──────────────

cat > "${TMP}/bad-workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete"],
  "run_files": {},
  "stages": {
    "planning": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "done": "complete" },
      "inputs": {
        "required": [
          { "from_run_file": "nonexistent", "description": "oops" }
        ],
        "optional": []
      }
    }
  }
}
EOF
touch "${TMP}/planning.md"
export CONFIG_FILE="${TMP}/bad-workflow.json"
err_out="$(config_validate 2>&1 || true)"
echo "$err_out" | grep -q "nonexistent"
check "config_validate fails with unknown from_run_file reference" $?

# Restore
use_workflow "$TMP"

# ── regression: existing from_stage validation still works ───

cat > "${TMP}/bad-stage-ref.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete"],
  "stages": {
    "planning": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "done": "complete" },
      "inputs": {
        "required": [
          { "from_stage": "ghost", "description": "stage that does not exist" }
        ],
        "optional": []
      }
    }
  }
}
EOF
export CONFIG_FILE="${TMP}/bad-stage-ref.json"
err_out2="$(config_validate 2>&1 || true)"
echo "$err_out2" | grep -q "ghost"
check "config_validate still catches unknown from_stage references (regression)" $?

print_summary
