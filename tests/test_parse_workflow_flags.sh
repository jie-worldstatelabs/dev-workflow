#!/bin/bash
#
# Category A — parse-workflow-flags.sh unit tests
#
# Run from anywhere:
#   bash ~/.claude/plugins/stagent/tests/test_parse_workflow_flags.sh
#
# Exit 0 = all pass. Exit 1 = one or more failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSER="${SCRIPT_DIR}/../scripts/parse-workflow-flags.sh"

PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗\033[0m %s\n' "$*"; }

# run_ok <test-id> <description> <input> <expected-var=value> ...
# Asserts the parser exits 0 and each expected variable matches.
run_ok() {
  local id="$1" desc="$2" input="$3"
  shift 3
  local expectations=("$@")

  local out
  if ! out=$(bash "$PARSER" "$input" 2>/dev/null); then
    red "[$id] $desc — expected exit 0, got exit 1"
    FAIL=$((FAIL+1))
    return
  fi

  # Evaluate the sourciable output into local vars
  eval "$out"

  local all_ok=1
  for kv in "${expectations[@]}"; do
    local key="${kv%%=*}"
    local expected="${kv#*=}"
    local actual
    actual="$(eval echo "\$$key")"
    if [[ "$actual" != "$expected" ]]; then
      red "[$id] $desc — $key: expected '$expected', got '$actual'"
      FAIL=$((FAIL+1))
      all_ok=0
    fi
  done
  [[ $all_ok -eq 1 ]] && { green "[$id] $desc"; PASS=$((PASS+1)); }
}

# run_err <test-id> <description> <input>
# Asserts the parser exits 1 (produces an error).
run_err() {
  local id="$1" desc="$2" input="$3"
  if bash "$PARSER" "$input" >/dev/null 2>&1; then
    red "[$id] $desc — expected exit 1, got exit 0"
    FAIL=$((FAIL+1))
  else
    green "[$id] $desc"
    PASS=$((PASS+1))
  fi
}

# ── A: parse-workflow-flags.sh ────────────────────────────────────────────────

echo "─── A: parse-workflow-flags.sh ───────────────────────────────────────────"

# A1: no flags → empty WORKFLOW_FLAG, MODE defaults to cloud, empty WF_TYPE
run_ok "A1" "no flags → defaults" \
  "build something cool" \
  "WORKFLOW_FLAG=" \
  "MODE=cloud" \
  "WF_TYPE="

# A2: flat cloud:// slug (BUG-3 regression) → accepted as cloud type
run_ok "A2" "cloud://name flat slug accepted (BUG-3 regression)" \
  "--workflow=cloud://demo build task" \
  "WORKFLOW_FLAG=cloud://demo" \
  "WF_TYPE=cloud" \
  "MODE=cloud"

# A3: full cloud://author/name → accepted
run_ok "A3" "cloud://author/name accepted" \
  "--workflow=cloud://demo/my-workflow do the thing" \
  "WORKFLOW_FLAG=cloud://demo/my-workflow" \
  "WF_TYPE=cloud" \
  "MODE=cloud"

# A4: cloud ref + --mode=cloud → ok
run_ok "A4" "--workflow=cloud://... --mode=cloud → ok" \
  "--workflow=cloud://demo/wf --mode=cloud run it" \
  "WORKFLOW_FLAG=cloud://demo/wf" \
  "WF_TYPE=cloud" \
  "MODE=cloud"

# A5: cloud ref + --mode=local → error (forbidden combination)
run_err "A5" "cloud:// + --mode=local → error" \
  "--workflow=cloud://demo/wf --mode=local do it"

# A6: nonexistent local path → error
run_err "A6" "nonexistent local path → error" \
  "--workflow=/this/path/does/not/exist/workflow do it"

# A7: bare unrecognised value (no cloud://, no path prefix) → error
run_err "A7" "bare unrecognised --workflow value → error" \
  "--workflow=not-a-valid-value do it"

# A8: --mode=local without --workflow → ok (no path to validate)
run_ok "A8" "--mode=local alone → ok, no workflow to validate" \
  "--mode=local do the task" \
  "WORKFLOW_FLAG=" \
  "MODE=local" \
  "WF_TYPE="

# A9: description stripped of flag tokens
run_ok "A9" "description is residual text after flags stripped" \
  "--workflow=cloud://demo/wf my task description" \
  "DESCRIPTION=my task description"

# A10: space-separated --workflow <value> form (legacy)
run_ok "A10" "--workflow <value> space-separated form accepted" \
  "--workflow cloud://demo/legacy-wf some task" \
  "WORKFLOW_FLAG=cloud://demo/legacy-wf" \
  "WF_TYPE=cloud"

# A11: cloud:// slug with dots and dashes in name component
run_ok "A11" "cloud://author/name with dots and dashes" \
  "--workflow=cloud://my-org/my.workflow-v2 task" \
  "WORKFLOW_FLAG=cloud://my-org/my.workflow-v2" \
  "WF_TYPE=cloud"

# A12: local path that IS a directory but lacks workflow.json → error
# (We can only test this if a tmp dir exists; use /tmp itself)
run_err "A12" "local dir without workflow.json → error" \
  "--workflow=/tmp task"

# A13: local path + --mode=cloud → ok (cloud mode accepts local workflow dirs;
# setup-workflow.sh uploads the content to the server)
_SMOKE_WF="${SCRIPT_DIR}/e2e/fixtures/smoke-workflow"
run_ok "A13" "local dir + --mode=cloud → ok (allowed)" \
  "--workflow=${_SMOKE_WF} --mode=cloud do it" \
  "WORKFLOW_FLAG=${_SMOKE_WF}" \
  "WF_TYPE=local" \
  "MODE=cloud"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
