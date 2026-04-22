#!/bin/bash
# T16 — --session arg guard: interrupt / continue / cancel all reject a
# bare --session (no value follows) with a clean "requires a value" error
# instead of bash's `$2: unbound variable` under `set -u`.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"

echo "T16 — --session arg guard (interrupt / continue / cancel)"

# Run a script with --session as its ONLY arg (no value). Capture exit + stderr.
# Verify exit != 0 and stderr contains the friendly error.
expect_requires_value() {
  local script_name="$1"
  local script="${PLUGIN_ROOT}/scripts/${script_name}"
  # Use a tmp HOME so the scripts don't touch real state. They'll exit at the
  # arg parser before any further resolution happens, but being hermetic is
  # cheap.
  local tmp_home; tmp_home="$(mktemp -d)"
  local out rc=0
  out="$(HOME="$tmp_home" "$script" --session 2>&1)" || rc=$?
  rm -rf "$tmp_home"
  [[ $rc -ne 0 ]] && echo "$out" | grep -q "\-\-session requires a value"
}

expect_requires_value interrupt-workflow.sh
check "interrupt-workflow.sh --session (no value) → clean error + exit 1" $?

expect_requires_value continue-workflow.sh
check "continue-workflow.sh --session (no value) → clean error + exit 1" $?

expect_requires_value cancel-workflow.sh
check "cancel-workflow.sh --session (no value) → clean error + exit 1" $?

# Regression guard: the message must NOT be bash's raw "unbound variable"
# diagnostic, which is what the unguarded `$2` used to emit.
tmp_home="$(mktemp -d)"
out_i="$(HOME="$tmp_home" "${PLUGIN_ROOT}/scripts/interrupt-workflow.sh" --session 2>&1)" || true
rm -rf "$tmp_home"
! echo "$out_i" | grep -q "unbound variable"
check "interrupt stderr does NOT leak bash 'unbound variable'" $?

print_summary
