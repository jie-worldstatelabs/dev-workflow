#!/bin/bash
# Delete ~/.meta-workflow/auth.json so the plugin falls back to anonymous
# mode. Does NOT revoke the token on the server — use the web UI for
# that if you want to invalidate it everywhere.
#
# Usage: logout-workflow.sh

set -euo pipefail

AUTH_FILE="${HOME}/.meta-workflow/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Not signed in (no ${AUTH_FILE})."
  exit 0
fi

user_id="$(jq -r '.user_id // empty' "$AUTH_FILE" 2>/dev/null || true)"
rm -f "$AUTH_FILE"

if [[ -n "$user_id" ]]; then
  echo "✓ Signed out ${user_id}"
else
  echo "✓ Signed out"
fi
echo "  Local token removed. Server-side token is still valid — revoke it"
echo "  in the web UI if you want it invalidated everywhere."
