#!/bin/bash
# Test runner — executes all test files and prints a combined summary.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
SUITE_FAILURES=()

run_suite() {
  local file="$1"
  local name
  name="$(basename "$file" .sh)"
  echo ""
  echo "▶ ${name}"
  if bash "$file"; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    SUITE_FAILURES+=("$name")
  fi
}

for test_file in "${TESTS_DIR}"/test_*.sh; do
  [[ -f "$test_file" ]] && run_suite "$test_file"
done

echo ""
echo "══════════════════════════════════════"
echo "  Suites: $((TOTAL_PASS + TOTAL_FAIL)) total, $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [[ $TOTAL_FAIL -gt 0 ]]; then
  for s in "${SUITE_FAILURES[@]}"; do
    echo "  ✗ $s"
  done
  exit 1
fi
echo "  All suites passed."
