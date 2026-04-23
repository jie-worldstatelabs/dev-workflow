#!/bin/bash
# T11 — whoami-workflow.sh: no auth.json → "Not signed in", offline fallback

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"

echo "T11 — whoami-workflow.sh"

WHOAMI="${PLUGIN_ROOT}/scripts/whoami-workflow.sh"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# We override HOME so the script reads from our fake ~/.config/stagent/auth.json
# rather than the real user's. STAGENT_SERVER is set to an unreachable
# address so curl falls back to the offline branch without hitting production.
FAKE_HOME="$TMP/home"
DEAD_SERVER="http://127.0.0.1:19753"   # nothing listens here

# ── T11-1: No auth.json → "Not signed in.", exits 0 ─────────────────────────
mkdir -p "$FAKE_HOME"
out1="$(HOME="$FAKE_HOME" STAGENT_SERVER="$DEAD_SERVER" "$WHOAMI" 2>&1)"
check "no auth.json → exits 0" $?

echo "$out1" | grep -qi "not signed in"
check "no auth.json → output says 'Not signed in'" $?

# ── T11-2: No auth.json → output does NOT say 'Signed in' ───────────────────
echo "$out1" | grep -qi "signed in:" && found=1 || found=0
[[ $found -eq 0 ]]
check "no auth.json → output does NOT say 'Signed in:'" $?

# ── T11-3: auth.json present + server unreachable → exits 0 (offline) ────────
mkdir -p "$FAKE_HOME/.config/stagent"
cat > "$FAKE_HOME/.config/stagent/auth.json" <<'EOF'
{
  "label": "my-laptop",
  "author": "alice",
  "user_id": "google:12345",
  "created_at": "2025-01-15T10:00:00Z"
}
EOF
out3="$(HOME="$FAKE_HOME" STAGENT_SERVER="$DEAD_SERVER" "$WHOAMI" 2>&1)"
check "auth.json + unreachable server → exits 0" $?

# ── T11-4: Offline output shows author from auth.json ────────────────────────
echo "$out3" | grep -q "alice"
check "offline output contains author 'alice'" $?

# ── T11-5: Offline output shows device label from auth.json ──────────────────
echo "$out3" | grep -q "my-laptop"
check "offline output contains device label 'my-laptop'" $?

print_summary
