#!/bin/bash
# Device-code login flow.
#
# Hits POST $DEV_WORKFLOW_SERVER/api/auth/device/code to get a short
# user_code + verification URL, prints them, tries to open the URL in
# a browser, then polls POST /api/auth/device/token until the user
# approves in the browser. On success, writes the returned bearer
# token to ~/.dev-workflow/auth.json (mode 0600) so every subsequent
# cloud_* request from lib.sh picks it up automatically.
#
# Usage: login-workflow.sh [--label <name>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

LABEL=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --label=*) LABEL="${1#--label=}"; shift ;;
    --label)   LABEL="$2";            shift 2 ;;
    *)         shift ;;
  esac
done

if [[ -z "$LABEL" ]]; then
  LABEL="$(hostname 2>/dev/null || echo unknown)"
fi

SERVER="${DEV_WORKFLOW_SERVER:-https://workflows.worldstatelabs.com}"
AUTH_DIR="${HOME}/.dev-workflow"
AUTH_FILE="${AUTH_DIR}/auth.json"

mkdir -p "$AUTH_DIR"
chmod 700 "$AUTH_DIR"

if [[ -f "$AUTH_FILE" ]]; then
  existing_user="$(jq -r '.user_id // empty' "$AUTH_FILE" 2>/dev/null || true)"
  if [[ -n "$existing_user" ]]; then
    echo "Already signed in as: $existing_user"
    echo "Run /dev-workflow:logout first if you want to switch accounts."
    exit 0
  fi
fi

echo "Requesting device code from ${SERVER}…"
resp="$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg label "$LABEL" '{label: $label}')" \
  "${SERVER}/api/auth/device/code")"

if ! echo "$resp" | jq -e '.device_code' >/dev/null 2>&1; then
  echo "❌ Server rejected device-code request:" >&2
  echo "$resp" >&2
  exit 1
fi

device_code="$(echo "$resp" | jq -r '.device_code')"
user_code="$(echo "$resp" | jq -r '.user_code')"
verification_uri_complete="$(echo "$resp" | jq -r '.verification_uri_complete')"
interval="$(echo "$resp" | jq -r '.interval // 5')"
expires_in="$(echo "$resp" | jq -r '.expires_in // 900')"

echo
echo "┌─────────────────────────────────────────────────┐"
echo "│  Your code:  ${user_code}"
echo "│  Visit:      ${verification_uri_complete}"
echo "└─────────────────────────────────────────────────┘"
echo

# Best-effort browser open. Never fail the flow if we can't —
# user can always copy/paste the URL.
if command -v open >/dev/null 2>&1; then
  open "$verification_uri_complete" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$verification_uri_complete" >/dev/null 2>&1 || true
fi

echo "Waiting for browser approval (expires in ${expires_in}s)…"

deadline=$(( $(date +%s) + expires_in ))
while :; do
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "❌ Timed out waiting for approval." >&2
    exit 1
  fi

  poll="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$device_code" '{device_code: $c}')" \
    "${SERVER}/api/auth/device/token")" || poll='{"error":"network"}'

  if echo "$poll" | jq -e '.access_token' >/dev/null 2>&1; then
    token="$(echo "$poll" | jq -r '.access_token')"
    user_id="$(echo "$poll" | jq -r '.user_id // empty')"
    jq -n \
      --arg server "$SERVER" \
      --arg token "$token" \
      --arg user_id "$user_id" \
      --arg label "$LABEL" \
      --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{server: $server, token: $token, user_id: $user_id, label: $label, created_at: $created_at}' \
      > "${AUTH_FILE}.tmp"
    mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo
    echo "✓ Signed in as ${user_id}"
    echo "  Token stored in ${AUTH_FILE}"
    exit 0
  fi

  err="$(echo "$poll" | jq -r '.error // "unknown"')"
  case "$err" in
    authorization_pending)
      sleep "$interval"
      ;;
    slow_down)
      interval=$(( interval + 5 ))
      sleep "$interval"
      ;;
    access_denied)
      echo "❌ Access denied in browser." >&2
      exit 1
      ;;
    expired_token)
      echo "❌ Code expired. Run /dev-workflow:login to try again." >&2
      exit 1
      ;;
    *)
      echo "❌ Unexpected response: $poll" >&2
      sleep "$interval"
      ;;
  esac
done
