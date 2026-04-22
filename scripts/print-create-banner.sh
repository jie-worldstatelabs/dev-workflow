#!/bin/bash
# Print the pre-flight banner for /meta-workflow:create-workflow
# Usage: print-create-banner.sh <mode> <workflow_flag> <wf_type>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

MODE="${1:-cloud}"
WORKFLOW_FLAG="${2:-}"
WF_TYPE="${3:-}"

_server="${META_WORKFLOW_SERVER:-https://workflows.worldstatelabs.com}"
_author_raw="$(jq -r '.author // "anonymous"' "${HOME}/.config/meta-workflow/auth.json" 2>/dev/null || echo "anonymous")"
_author="$(echo "$_author_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]][[:space:]]*/\-/g; s/[^a-z0-9._-]//g; s/^[^a-z0-9]*//')"
_author="${_author:-anonymous}"
_logged_in="$(cloud_is_logged_in && echo yes || echo no)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -n "$WORKFLOW_FLAG" ]]; then
  echo "  Action:   edit existing workflow"
  if [[ "$WF_TYPE" == "cloud" ]]; then
    echo "  Workflow: ${WORKFLOW_FLAG}  ←  ${_server}/hub/${WORKFLOW_FLAG#cloud://}"
    echo "  Auth:     ${_author}  ($([ "$_logged_in" = yes ] && echo "logged in" || echo "anonymous"))"
    echo "  After edit: changes pushed back to hub"
  else
    echo "  Workflow: ${WORKFLOW_FLAG}  (local)"
    echo "  After edit: local files updated (publish manually if needed)"
  fi
else
  echo "  Action:   create new workflow"
  echo "  Mode:     ${MODE}"
  if [[ "$MODE" == "cloud" ]]; then
    echo "  Will publish as: cloud://${_author}/<suffix>  →  ${_server}/hub/${_author}/<suffix>"
    if [[ "$_logged_in" = yes ]]; then
      echo "  Auth:     ${_author}  (logged in)"
    else
      echo "  Auth:     ❌ not signed in — cloud mode requires /meta-workflow:login first"
    fi
  else
    echo "  Will save to: ~/.config/meta-workflow/workflows/<suffix>/"
    echo "  No hub publish (local mode)"
  fi
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
