#!/bin/bash
# T2 — setup-workflow.sh: run_files generated correctly (local mode, no real session needed)
# We test the run_files loop logic directly rather than invoking the full setup script,
# because setup-workflow.sh requires a real session_id cache and git env.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T2 — setup: run_files generation loop"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

PROJ="${TMP}/project"
RUN="${TMP}/run"
mkdir -p "$PROJ" "$RUN"

write_workflow_json "$TMP"
use_workflow "$TMP"
use_run_dir "$RUN"

# ── Helper: simulate the run_files loop from setup-workflow.sh ───────────────
run_files_loop() {
  local project_root="$1"
  local run_dir="$2"
  while IFS= read -r _rf_name; do
    [[ -z "$_rf_name" ]] && continue
    _rf_init="$(config_run_file_init "$_rf_name")"
    if [[ -z "$_rf_init" ]]; then
      echo "❌ run_file '$_rf_name' has no init command" >&2
      return 1
    fi
    (cd "$project_root" && bash -c "$_rf_init") > "${run_dir}/${_rf_name}"
  done < <(config_run_file_names)
}

# ── Test: custom run_file with echo command ───────────────────────────────────

run_files_loop "$PROJ" "$RUN"

[[ -f "${RUN}/custom" ]]
check "custom run_file is created" $?

content="$(cat "${RUN}/custom")"
[[ "$content" == "hello-custom" ]]
check "custom run_file has correct content from init command" $?

# ── Test: baseline in non-git directory → EMPTY ───────────────────────────────

[[ -f "${RUN}/baseline" ]]
check "baseline run_file is created" $?

baseline_content="$(cat "${RUN}/baseline")"
[[ "$baseline_content" == "EMPTY" ]]
check "baseline is EMPTY in non-git project directory" $?

# ── Test: baseline in git repo with HEAD ──────────────────────────────────────

GIT_PROJ="${TMP}/git-project"
mkdir -p "$GIT_PROJ"
git -C "$GIT_PROJ" init -q
git -C "$GIT_PROJ" -c user.email="t@t.com" -c user.name="T" \
    commit --allow-empty -q -m "init"
SHA="$(git -C "$GIT_PROJ" rev-parse HEAD)"

GIT_RUN="${TMP}/git-run"
mkdir -p "$GIT_RUN"
run_files_loop "$GIT_PROJ" "$GIT_RUN"

baseline_sha="$(cat "${GIT_RUN}/baseline")"
[[ "$baseline_sha" == "$SHA" ]]
check "baseline contains correct git SHA in a repo with HEAD" $?

# ── Test: init command failure causes loop to fail ────────────────────────────

cat > "${TMP}/bad-workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete"],
  "run_files": {
    "will-fail": {
      "description": "always fails",
      "init": "exit 1"
    }
  },
  "stages": {
    "planning": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "done": "complete" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
touch "${TMP}/planning.md"
export CONFIG_FILE="${TMP}/bad-workflow.json"

FAIL_RUN="${TMP}/fail-run"
mkdir -p "$FAIL_RUN"
run_files_loop "$PROJ" "$FAIL_RUN" 2>/dev/null || true
file_content="$(cat "${FAIL_RUN}/will-fail" 2>/dev/null || echo "MISSING")"
[[ -z "$file_content" || "$file_content" == "MISSING" ]]
check "failed init command produces empty/missing run_file" $?

# ── Test: run_file with no init command causes error ─────────────────────────

cat > "${TMP}/no-init.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete"],
  "run_files": {
    "noinit": {
      "description": "missing init"
    }
  },
  "stages": {
    "planning": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "done": "complete" },
      "inputs": { "required": [], "optional": [] }
    }
  }
}
EOF
export CONFIG_FILE="${TMP}/no-init.json"
NO_INIT_RUN="${TMP}/noinit-run"
mkdir -p "$NO_INIT_RUN"
run_files_loop "$PROJ" "$NO_INIT_RUN" 2>/dev/null && rc=0 || rc=$?
[[ $rc -ne 0 ]]
check "run_files loop fails when run_file has no init command" $?

# ── Regression: old hardcoded baseline code is gone from setup-workflow.sh ───

! grep -q 'rev-parse HEAD > .*baseline' "${PLUGIN_ROOT}/scripts/setup-workflow.sh"
check "setup-workflow.sh no longer hardcodes baseline write" $?

print_summary
