#!/bin/bash
# Print the pre-flight banner for /stagent:create
# Usage: print-create-banner.sh <mode> <workflow_flag> <wf_type>
#
# First-time-user framing problem: /stagent:create runs a stagent
# session whose job is to design, write, validate, and publish a
# template. Users coming in cold often conflate "the session" with
# "the template" — they think they're looking at the template itself
# when they're actually watching the creation session. This banner
# is the first touchpoint; it disambiguates up front:
#   - This is a SESSION (transient) that PRODUCES a template
#   - Shows the stage flow so users know what to expect
#   - Shows where the final template will live
# setup-workflow.sh then prints the live session URL right below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

MODE="${1:-cloud}"
WORKFLOW_FLAG="${2:-}"
WF_TYPE="${3:-}"

_server="${STAGENT_SERVER:-https://stagent.worldstatelabs.com}"
_author_raw="$(jq -r '.author // "anonymous"' "${HOME}/.config/stagent/auth.json" 2>/dev/null || echo "anonymous")"
_author="$(echo "$_author_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]][[:space:]]*/\-/g; s/[^a-z0-9._-]//g; s/^[^a-z0-9]*//')"
_author="${_author:-anonymous}"
_logged_in="$(cloud_is_logged_in && echo yes || echo no)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -n "$WORKFLOW_FLAG" ]]; then
  echo "  Template-edit session"
  echo "  ─────────────────────"
  if [[ "$WF_TYPE" == "cloud" ]]; then
    echo "  Editing:   ${WORKFLOW_FLAG#cloud://}"
    echo "  Source:    ${_server}/hub/${WORKFLOW_FLAG#cloud://}"
    echo "  Auth:      ${_author}  ($([ "$_logged_in" = yes ] && echo "logged in" || echo "anonymous"))"
    echo "  On finish: changes pushed back to the hub"
  else
    echo "  Editing:   ${WORKFLOW_FLAG}  (local directory)"
    echo "  On finish: local files updated (run /stagent:publish to share)"
  fi
else
  echo "  Template-creation session"
  echo "  ─────────────────────────"
  echo "  Mode:      ${MODE}"
  echo "  Flow:      plan → write → validate$([ "$MODE" = "cloud" ] && echo " → publish")"
  if [[ "$MODE" == "cloud" ]]; then
    echo "  Will land: cloud://${_author}/<suffix>"
    echo "             (viewable at ${_server}/hub/${_author}/<suffix> once published)"
    if [[ "$_logged_in" = yes ]]; then
      echo "  Auth:      ${_author}  (logged in)"
    else
      echo "  Auth:      ❌ not signed in — /stagent:login required for cloud"
    fi
  else
    echo "  Will save: ~/.config/stagent/workflows/<suffix>/"
    echo "             (no hub publish — local mode)"
  fi
fi
echo ""
echo "  NOTE: This opens a transient session that *builds* your"
echo "        template. The template itself does not exist until"
echo "        this session finishes. Live session URL below ↓"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
