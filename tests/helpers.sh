#!/bin/bash
# Shared test helpers and fixtures for meta-workflow tests.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force read_cached_session_id to use cwd-cache directly, skipping the
# PPID walk. The e2e suite writes cwd-cache manually per test; when the
# suite itself is running inside a parent Claude Code session, the
# PPID chain would otherwise resolve to the parent session's cached
# entry and shadow the test's intent. Only effective in tests — real
# plugin runs never source this file.
export _DW_FORCE_CWD_CACHE=1

# ── Counters ──────────────────────────────────────────────────
PASS=0
FAIL=0
ERRORS=()

assert_pass() {
  local name="$1"
  PASS=$((PASS + 1))
  printf '  ✓ %s\n' "$name"
}

assert_fail() {
  local name="$1"
  local detail="${2:-}"
  FAIL=$((FAIL + 1))
  ERRORS+=("$name${detail:+: $detail}")
  printf '  ✗ %s%s\n' "$name" "${detail:+ — $detail}"
}

check() {
  local name="$1"
  local result="$2"   # 0 = pass
  local detail="${3:-}"
  if [[ "$result" -eq 0 ]]; then
    assert_pass "$name"
  else
    assert_fail "$name" "$detail"
  fi
}

print_summary() {
  echo ""
  echo "  Results: $PASS passed, $FAIL failed"
  if [[ $FAIL -gt 0 ]]; then
    for e in "${ERRORS[@]}"; do
      echo "    ✗ $e"
    done
    return 1
  fi
  return 0
}

# ── Fixture helpers ───────────────────────────────────────────

# Create a temp directory and register it for cleanup.
make_tmpdir() {
  local d
  d="$(mktemp -d)"
  echo "$d"
}

# Create a minimal valid workflow.json with run_files support.
write_workflow_json() {
  local dir="$1"
  cat > "${dir}/workflow.json" <<'EOF'
{
  "initial_stage": "planning",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "run_files": {
    "baseline": {
      "description": "Git SHA at workflow start",
      "init": "git rev-parse HEAD 2>/dev/null || echo EMPTY"
    },
    "custom": {
      "description": "Custom test file",
      "init": "echo hello-custom"
    }
  },
  "stages": {
    "planning": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "approved": "reviewing" },
      "inputs": { "required": [], "optional": [] }
    },
    "reviewing": {
      "interruptible": false,
      "execution": { "type": "subagent" },
      "transitions": { "PASS": "complete", "FAIL": "planning" },
      "inputs": {
        "required": [
          { "from_stage": "planning",    "description": "Plan" },
          { "from_run_file": "baseline", "description": "Git SHA at workflow start" }
        ],
        "optional": []
      }
    }
  }
}
EOF
  # Minimal stage .md files required by config_validate
  touch "${dir}/planning.md"
  touch "${dir}/reviewing.md"
}

# Set CONFIG_FILE and WORKFLOW_DIR env vars for lib.sh functions.
use_workflow() {
  local dir="$1"
  export CONFIG_FILE="${dir}/workflow.json"
  export WORKFLOW_DIR="$dir"
}

# Set TOPIC_DIR so config_run_file_path returns deterministic paths.
use_run_dir() {
  local dir="$1"
  export TOPIC_DIR="$dir"
  unset DW_RUN_BASE
  unset RUN_DIR_NAME
  unset PROJECT_ROOT
}
