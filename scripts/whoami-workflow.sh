#!/bin/bash
# Print the signed-in identity and verify the token still works by
# hitting GET /api/me/sessions with it.
#
# Usage: whoami-workflow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

AUTH_FILE="${HOME}/.dev-workflow/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Not signed in."
  echo "  Run /dev-workflow:login to authenticate."
  exit 0
fi

user_id="$(jq -r '.user_id // empty' "$AUTH_FILE" 2>/dev/null || true)"
label="$(jq -r '.label // empty' "$AUTH_FILE" 2>/dev/null || true)"
server="$(jq -r '.server // empty' "$AUTH_FILE" 2>/dev/null || true)"
created_at="$(jq -r '.created_at // empty' "$AUTH_FILE" 2>/dev/null || true)"

: "${server:=${DEV_WORKFLOW_SERVER:-https://workflowui.vercel.app}}"

echo "Signed in:"
echo "  user_id:    ${user_id:-(unknown)}"
echo "  label:      ${label:-(none)}"
echo "  server:     ${server}"
echo "  created_at: ${created_at:-(unknown)}"
echo

# Round-trip test — /api/me/sessions requires auth and returns 401 if
# the token has been revoked or is otherwise invalid.
code="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "$(_cloud_auth_header)" \
  "${server}/api/me/sessions")" || code=000

case "$code" in
  200)
    echo "✓ Token is valid (GET /api/me/sessions → 200)"
    ;;
  401)
    echo "❌ Token rejected by server (HTTP 401)."
    echo "   Run /dev-workflow:login to re-authenticate."
    exit 1
    ;;
  000)
    echo "⚠ Could not reach ${server}."
    ;;
  *)
    echo "⚠ Unexpected response: HTTP ${code}"
    ;;
esac
