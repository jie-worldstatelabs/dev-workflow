#!/bin/bash
# Device-code login flow.
#
# Hits POST $STAGENT_SERVER/api/auth/device/code to get a short
# user_code + verification URL, prints them, tries to open the URL in
# a browser, then polls POST /api/auth/device/token until the user
# approves in the browser. On success, writes the returned bearer
# token to ~/.config/stagent/auth.json (mode 0600) so every subsequent
# cloud_* request from lib.sh picks it up automatically.
#
# Usage: login-workflow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

LABEL="$(hostname 2>/dev/null || echo unknown)"

SERVER="${STAGENT_SERVER:-https://workflows.worldstatelabs.com}"
AUTH_DIR="${HOME}/.config/stagent"
AUTH_FILE="${AUTH_DIR}/auth.json"

mkdir -p "$AUTH_DIR"
chmod 700 "$AUTH_DIR"

# ── Demo shortcut ──────────────────────────────────────────────────────────
# Usage: login-workflow.sh --demo
# Fetches a pre-seeded plugin token for the shared demo account without
# going through the OAuth device-code flow. Intended for testing only.
if [[ "${1:-}" == "--demo" ]]; then
  if [[ -f "$AUTH_FILE" ]]; then
    existing_user="$(jq -r '.user_id // empty' "$AUTH_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_user" ]]; then
      echo "Already signed in as: $existing_user"
      echo "Run /stagent:logout first to switch to the demo account."
      exit 0
    fi
  fi
  echo "Fetching demo token from ${SERVER}…"
  resp="$(curl -sS "${SERVER}/api/auth/demo-token" 2>/dev/null)" || {
    cloud_explain_curl_exit $? "$SERVER"
    exit 1
  }
  token="$(echo "$resp" | jq -r '.token // empty')"
  user_id="$(echo "$resp" | jq -r '.user_id // empty')"
  author="$(echo "$resp" | jq -r '.author // empty')"
  if [[ -z "$token" ]]; then
    echo "❌ Server did not return a token:" >&2
    echo "$resp" >&2
    exit 1
  fi
  jq -n \
    --arg server "$SERVER" \
    --arg token "$token" \
    --arg user_id "$user_id" \
    --arg author "$author" \
    --arg lbl "demo" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{server: $server, token: $token, user_id: $user_id, author: $author, label: $lbl, created_at: $created_at}' \
    > "${AUTH_FILE}.tmp"
  mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
  echo "✓ Signed in as ${author} (${user_id})"
  echo "  Token stored in ${AUTH_FILE}"
  exit 0
fi
# ───────────────────────────────────────────────────────────────────────────

if [[ -f "$AUTH_FILE" ]]; then
  existing_user="$(jq -r '.user_id // empty' "$AUTH_FILE" 2>/dev/null || true)"
  if [[ -n "$existing_user" ]]; then
    echo "Already signed in as: $existing_user"
    echo "Run /stagent:logout first if you want to switch accounts."
    exit 0
  fi
fi

echo "Requesting device code from ${SERVER}…"
curl_rc=0
resp="$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg lbl "$LABEL" '{label: $lbl}')" \
  "${SERVER}/api/auth/device/code" 2>/dev/null)" || curl_rc=$?
if [[ $curl_rc -ne 0 ]]; then
  cloud_explain_curl_exit "$curl_rc" "$SERVER"
  exit 1
fi

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
network_warned=0
while :; do
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "❌ Timed out waiting for approval." >&2
    echo "   The browser approval window may have closed, or the network is unstable." >&2
    exit 1
  fi

  poll_rc=0
  poll="$(curl -sS -X POST \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$device_code" '{device_code: $c}')" \
    "${SERVER}/api/auth/device/token" 2>/dev/null)" || poll_rc=$?
  if [[ $poll_rc -ne 0 ]]; then
    if [[ $network_warned -eq 0 ]]; then
      cloud_explain_curl_exit "$poll_rc" "$SERVER"
      echo "   (will keep retrying silently until you approve or the code expires)" >&2
      network_warned=1
    fi
    sleep "$interval"
    continue
  fi
  # Network recovered — allow future outages to warn again.
  network_warned=0

  if echo "$poll" | jq -e '.access_token' >/dev/null 2>&1; then
    token="$(echo "$poll" | jq -r '.access_token')"
    user_id="$(echo "$poll" | jq -r '.user_id // empty')"
    author="$(echo "$poll" | jq -r '.author // "anonymous"')"
    jq -n \
      --arg server "$SERVER" \
      --arg token "$token" \
      --arg user_id "$user_id" \
      --arg author "$author" \
      --arg lbl "$LABEL" \
      --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{server: $server, token: $token, user_id: $user_id, author: $author, label: $lbl, created_at: $created_at}' \
      > "${AUTH_FILE}.tmp"
    mv "${AUTH_FILE}.tmp" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    echo
    echo "✓ Signed in as ${author} (${user_id})"
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
      echo "❌ Code expired. Run /stagent:login to try again." >&2
      exit 1
      ;;
    *)
      # Unknown server-side error. Show a one-liner the first time; keep
      # polling in case it's transient (e.g. a server redeploy).
      echo "⚠️  Server returned unexpected error '${err}' — retrying…" >&2
      sleep "$interval"
      ;;
  esac
done
