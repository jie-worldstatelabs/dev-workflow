#!/bin/bash
# Checks whether the authenticated user owns a published cloud workflow.
#
# Usage:
#   check-workflow-ownership.sh <cloud://author/name | author/name>
#
# Output to stdout (one token, for skill-side branching):
#   AUTHORIZED — workflow exists, current user is the owner
#   NOT_OWNER  — workflow exists, owned by someone else (owner/me details → stderr)
#   NOT_FOUND  — workflow doesn't exist or fetch failed (network, 404, auth)
#
# Exit code is always 0 — callers branch on stdout. This lets skills
# reason about the three cases uniformly without try/catch dances.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WF_NAME="${1:-}"
if [[ -z "$WF_NAME" ]]; then
  echo "usage: $0 <cloud://author/name | author/name>" >&2
  exit 2
fi
WF_NAME="${WF_NAME#cloud://}"

SERVER="${STAGENT_SERVER:-https://stagent.worldstatelabs.com}"
MY_UID="$(jq -r '.user_id // empty' ~/.config/stagent/auth.json 2>/dev/null || echo '')"
AUTH_HEADER="$(_cloud_auth_header)"
BUNDLE="$(curl -sf -H "$AUTH_HEADER" "${SERVER}/api/workflows/${WF_NAME}" 2>/dev/null || echo '')"

if [[ -z "$BUNDLE" ]]; then
  echo NOT_FOUND
  exit 0
fi

OWNER_UID="$(echo "$BUNDLE" | jq -r '.user_id // empty')"

if [[ -n "$MY_UID" && "$OWNER_UID" == "$MY_UID" ]]; then
  echo AUTHORIZED
else
  echo NOT_OWNER
  echo "owner=${OWNER_UID:-unknown} me=${MY_UID:-unauthenticated}" >&2
fi
