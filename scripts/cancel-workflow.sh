#!/bin/bash
# Cancel the active dev-workflow by removing state file and breadcrumb.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

if resolve_state; then
  rm -f "$STATE_FILE"
  echo "Dev workflow cancelled."
else
  echo "No active dev workflow."
fi
