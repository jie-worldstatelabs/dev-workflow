#!/bin/bash
# T13 — logout-workflow.sh: removes auth.json, prints confirmation

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"

echo "T13 — logout-workflow.sh"

LOGOUT="${PLUGIN_ROOT}/scripts/logout-workflow.sh"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ── T13-1: No auth.json → "Not signed in", exits 0 ──────────────────────────
FAKE_HOME1="$TMP/home1"
mkdir -p "$FAKE_HOME1"
out1="$(HOME="$FAKE_HOME1" "$LOGOUT" 2>&1)"
check "no auth.json → exits 0" $?

echo "$out1" | grep -qi "not signed in"
check "no auth.json → output says 'Not signed in'" $?

# ── T13-2: auth.json present → removed after logout ─────────────────────────
FAKE_HOME2="$TMP/home2"
mkdir -p "$FAKE_HOME2/.config/meta-workflow"
cat > "$FAKE_HOME2/.config/meta-workflow/auth.json" <<'EOF'
{
  "user_id": "google:12345",
  "label": "my-laptop"
}
EOF
HOME="$FAKE_HOME2" "$LOGOUT" > /dev/null 2>&1
check "auth.json present → logout exits 0" $?

[[ ! -f "$FAKE_HOME2/.config/meta-workflow/auth.json" ]]
check "auth.json present → file removed after logout" $?

# ── T13-3: auth.json with user_id → output contains user_id ─────────────────
FAKE_HOME3="$TMP/home3"
mkdir -p "$FAKE_HOME3/.config/meta-workflow"
cat > "$FAKE_HOME3/.config/meta-workflow/auth.json" <<'EOF'
{
  "user_id": "google:99999",
  "label": "test-device"
}
EOF
out3="$(HOME="$FAKE_HOME3" "$LOGOUT" 2>&1)"
echo "$out3" | grep -q "google:99999"
check "auth.json with user_id → output contains user_id" $?

# ── T13-4: auth.json without user_id → still exits 0 ────────────────────────
FAKE_HOME4="$TMP/home4"
mkdir -p "$FAKE_HOME4/.config/meta-workflow"
echo '{"label": "anon-device"}' > "$FAKE_HOME4/.config/meta-workflow/auth.json"
HOME="$FAKE_HOME4" "$LOGOUT" > /dev/null 2>&1
check "auth.json without user_id → exits 0" $?

# ── T13-5: Output always mentions server-side token warning ──────────────────
FAKE_HOME5="$TMP/home5"
mkdir -p "$FAKE_HOME5/.config/meta-workflow"
echo '{"user_id": "demo:1"}' > "$FAKE_HOME5/.config/meta-workflow/auth.json"
out5="$(HOME="$FAKE_HOME5" "$LOGOUT" 2>&1)"
echo "$out5" | grep -qi "server"
check "logout output warns that server-side token remains valid" $?

print_summary
