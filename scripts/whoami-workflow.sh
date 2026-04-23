#!/bin/bash
# Print the signed-in identity and verify the token still works by
# hitting GET /api/me/sessions with it.
#
# Usage: whoami-workflow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

AUTH_FILE="${HOME}/.config/stagent/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Not signed in."
  echo "  Run /stagent:login to authenticate."
  exit 0
fi

label="$(jq -r '.label // empty' "$AUTH_FILE" 2>/dev/null || true)"
created_at="$(jq -r '.created_at // empty' "$AUTH_FILE" 2>/dev/null || true)"

server="${STAGENT_SERVER:-https://stagent.worldstatelabs.com}"

# Fetch live identity from the server — source of truth for user/author.
me_resp="$(curl -sS -w '\n%{http_code}' \
  -H "$(_cloud_auth_header)" \
  "${server}/api/me")" || me_resp=$'\n000'
me_code="$(echo "$me_resp" | tail -1)"
me_body="$(echo "$me_resp" | sed '$d')"

case "$me_code" in
  200)
    author="$(echo "$me_body" | jq -r '.author // empty')"
    user_id="$(echo "$me_body" | jq -r '.user_id // empty')"
    echo "Signed in:"
    echo "  user:       ${author:-(anonymous)}"
    echo "  user_id:    ${user_id:-(unknown)}"
    echo "  device:     ${label:-(unknown)}"
    echo "  signed in:  ${created_at:-(unknown)}"
    ;;
  401)
    echo "❌ Token rejected by server (HTTP 401)."
    echo "   Run /stagent:login to re-authenticate."
    exit 1
    ;;
  000)
    echo "⚠ Could not reach ${server}."
    # Fall back to local auth.json for display.
    author="$(jq -r '.author // empty' "$AUTH_FILE" 2>/dev/null || true)"
    user_id="$(jq -r '.user_id // empty' "$AUTH_FILE" 2>/dev/null || true)"
    echo "Signed in (offline):"
    echo "  user:       ${author:-(anonymous)}"
    echo "  user_id:    ${user_id:-(unknown)}"
    echo "  device:     ${label:-(unknown)}"
    echo "  signed in:  ${created_at:-(unknown)}"
    ;;
  *)
    echo "⚠ Unexpected response from server: HTTP ${me_code}"
    ;;
esac
