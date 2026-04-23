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

# Trust the server's own ownership computation. The webapp API resolves
# the caller's identity from the Bearer auth header against plugin_tokens
# and emits `is_owner: boolean`. We used to re-derive this client-side by
# reading `.user_id` off the bundle, but the API doesn't return `.user_id`
# on the detail payload (by design — it exposes `is_owner` instead), so
# the old check always saw owner=unknown and refused every edit.
IS_OWNER="$(echo "$BUNDLE" | jq -r '.is_owner // false')"

if [[ "$IS_OWNER" == "true" ]]; then
  echo AUTHORIZED
else
  echo NOT_OWNER
  # Diagnostic: show the caller's provider-scoped id and the workflow's
  # public author slug, so a confused user can at least see whether
  # they're logged in as the wrong account.
  AUTHOR_SLUG="$(echo "$BUNDLE" | jq -r '.author // "unknown"')"
  echo "is_owner=false  author=${AUTHOR_SLUG}  me=${MY_UID:-unauthenticated}" >&2
fi
