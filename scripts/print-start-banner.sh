#!/bin/bash
# Print the pre-flight banner for /meta-workflow:start
# Usage: print-start-banner.sh <mode> <workflow_flag> <wf_type>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

MODE="${1:-cloud}"
WORKFLOW_FLAG="${2:-}"
WF_TYPE="${3:-}"

_server="${META_WORKFLOW_SERVER:-https://workflows.worldstatelabs.com}"
if [[ -z "$WORKFLOW_FLAG" ]]; then
  if [[ "$MODE" == "cloud" ]]; then
    _wf="demo  ←  ${_server}/hub/demo  (cloud default)"
  else
    _wf="default (bundled with plugin)"
  fi
elif [[ "$WF_TYPE" == "cloud" ]]; then
  _wf="${WORKFLOW_FLAG}  ←  ${_server}/hub/${WORKFLOW_FLAG#cloud://}"
else
  _wf="${WORKFLOW_FLAG}  (local path)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Mode:     ${MODE}"
if [[ "$MODE" == "cloud" ]]; then
  echo "  State:    ${_server}/s/<session_id>  (live after setup)"
  cloud_is_logged_in \
    && echo "  Auth:     $(jq -r '.author // "unknown"' ~/.meta-workflow/auth.json 2>/dev/null)  (logged in)" \
    || echo "  Auth:     anonymous  — run /meta-workflow:login to attach an account"
else
  echo "  State:    <project>/.meta-workflow/<session_id>/"
fi
echo "  Workflow: ${_wf}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
