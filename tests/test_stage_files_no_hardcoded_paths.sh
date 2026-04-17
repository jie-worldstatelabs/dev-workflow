#!/bin/bash
# T6 — Static check: stage .md files must not contain hardcoded run-dir paths

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"

WORKFLOW_DIR="${PLUGIN_ROOT}/skills/meta-workflow/workflow"

echo "T6 — stage files: no hardcoded run-dir path placeholders"

# No stage file should contain <project>/.meta-workflow/<session_id> style paths
for f in "${WORKFLOW_DIR}"/*.md; do
  [[ "$(basename "$f")" == "run_files_catalog.md" ]] && continue
  name="$(basename "$f")"

  ! grep -q '\.meta-workflow/<session_id>' "$f"
  check "${name}: no .meta-workflow/<session_id> placeholder" $?

  ! grep -q '<project>/\.meta-workflow' "$f"
  check "${name}: no <project>/.meta-workflow placeholder" $?
done

# Output artifact lines must not contain path placeholders
for f in "${WORKFLOW_DIR}"/*.md; do
  [[ "$(basename "$f")" == "run_files_catalog.md" ]] && continue
  name="$(basename "$f")"

  # The "**Output artifact:**" line should only say "write to the absolute path..."
  if grep -q '^\*\*Output artifact:\*\*' "$f"; then
    ! grep -E '^\*\*Output artifact:\*\*.*<session_id>' "$f" > /dev/null
    check "${name}: Output artifact line has no <session_id> placeholder" $?
  fi
done

# reviewing.md specifically must not have hardcoded baseline path
! grep -q '<project>/\.meta-workflow' "${WORKFLOW_DIR}/reviewing.md"
check "reviewing.md: no hardcoded baseline path" $?

# reviewing.md should say "provided in your" to confirm it reads from prompt
grep -q 'provided in your' "${WORKFLOW_DIR}/reviewing.md"
check "reviewing.md: baseline described as 'provided in your prompt'" $?

print_summary
