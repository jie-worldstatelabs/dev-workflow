#!/bin/bash
# T19 — baseline-tree worktree snapshot
#
# Bug motivation: cloud_post_diff ran `git diff $baseline` where
# baseline is a commit SHA. That includes uncommitted changes that
# already existed BEFORE the workflow started (e.g. tool state like
# .omc/*, unrelated subproject edits), mis-attributing them to the
# workflow run.
#
# Fix: at setup time, snapshot the worktree as a dangling tree object
# via a temp index. cloud_post_diff prefers the tree over the commit
# SHA, so pre-existing dirty state doesn't leak into the diff.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T19 — baseline-tree worktree snapshot"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ── Setup: repo with one committed file + one uncommitted dirty file ─────────
PROJ="$TMP/proj"
SHADOW="$TMP/shadow"
mkdir -p "$PROJ" "$SHADOW"

cd "$PROJ"
git -c init.defaultBranch=main init -q
echo "tracked at baseline" > tracked.txt
git -c user.email=t@t -c user.name=t add tracked.txt
git -c user.email=t@t -c user.name=t commit -q -m "initial"

# Simulate the scenario from the bug report: user's worktree already
# dirty BEFORE `/meta-workflow:start` fires.
echo "dirty before workflow started" > pre-existing-dirty.txt   # untracked, unignored
echo "tracked at baseline — modified" > tracked.txt              # modified tracked

# ── B1: _capture_baseline_tree writes baseline-tree file ────────────────────
_capture_baseline_tree "$SHADOW" "$PROJ"
[[ -s "$SHADOW/baseline-tree" ]]
check "B1: baseline-tree file exists and is non-empty" $?

BTREE="$(cat "$SHADOW/baseline-tree")"
[[ "$BTREE" =~ ^[0-9a-f]{40}$ ]]
check "B1: baseline-tree content is a 40-char SHA" $?

# ── B2: the tree object exists in .git/objects (not GC'd) ───────────────────
git -C "$PROJ" cat-file -e "${BTREE}^{tree}" 2>/dev/null
check "B2: baseline-tree object is reachable via cat-file" $?

# ── B3: user's repo is untouched — no new refs, no HEAD change ──────────────
REFS_AFTER="$(git -C "$PROJ" for-each-ref --format='%(refname)' 2>/dev/null | sort)"
[[ "$REFS_AFTER" == "refs/heads/main" ]]
check "B3: no extra refs created (only refs/heads/main)" $?

HEAD_AFTER="$(git -C "$PROJ" rev-parse HEAD)"
# No new commits on main
COUNT="$(git -C "$PROJ" rev-list --count HEAD)"
[[ "$COUNT" == "1" ]]
check "B3: no new commits added to the branch" $?

# No temp index file leaked
[[ ! -e "$SHADOW/.baseline-index.tmp" ]]
check "B3: temp index cleaned up" $?

# User's real index is clean (no staged changes left behind)
STAGED="$(git -C "$PROJ" diff --cached --name-only 2>/dev/null)"
[[ -z "$STAGED" ]]
check "B3: user's real index is unchanged (nothing staged)" $?

# Helper: replicate cloud_post_diff's tree-to-tree diff strategy.
# Captures a "current" tree via the temp-index pattern, then diffs
# baseline-tree against it. Includes untracked-but-unignored files.
tree_to_tree_diff() {
  local proot="$1" baseline_tree="$2" shadow_dir="$3"
  local cur_idx="${shadow_dir}/.current-index.tmp"
  git -C "$proot" read-tree --index-output="$cur_idx" HEAD 2>/dev/null || return 1
  GIT_INDEX_FILE="$cur_idx" git -C "$proot" add -A 2>/dev/null || { rm -f "$cur_idx"; return 1; }
  local ct; ct="$(GIT_INDEX_FILE="$cur_idx" git -C "$proot" write-tree 2>/dev/null || true)"
  rm -f "$cur_idx"
  [[ -z "$ct" ]] && return 1
  git -C "$proot" diff --no-color "$baseline_tree" "$ct" 2>/dev/null || true
}

# ── B4: diff against baseline-tree at t=0 should be EMPTY ───────────────────
# (The tree was captured AT the dirty state, so diff against it should
# be empty — no changes since the snapshot.)
diff_now="$(tree_to_tree_diff "$PROJ" "$BTREE" "$SHADOW")"
[[ -z "$diff_now" ]]
check "B4: diff against baseline-tree is empty immediately after capture" $?

# ── B5: post-capture changes SHOW UP, pre-existing dirty state does NOT ─────
# Make a NEW change (simulating what a workflow subagent would do).
echo "workflow wrote this" > workflow-output.txt
echo "tracked modified AGAIN by workflow" > tracked.txt

diff_after="$(tree_to_tree_diff "$PROJ" "$BTREE" "$SHADOW")"
# The workflow's new file MUST appear
echo "$diff_after" | grep -q "workflow-output.txt"
check "B5: workflow's new file appears in diff" $?
# The workflow's change to tracked.txt MUST appear
echo "$diff_after" | grep -q "modified AGAIN by workflow"
check "B5: workflow's modification to tracked.txt appears in diff" $?
# The pre-existing dirty file MUST NOT appear (this is the bug fix)
! echo "$diff_after" | grep -q "pre-existing-dirty.txt"
check "B5: pre-existing dirty file does NOT appear in diff (bug fix)" $?

# ── B6: idempotent — second call is a no-op ─────────────────────────────────
MTIME1="$(stat -f %m "$SHADOW/baseline-tree" 2>/dev/null || stat -c %Y "$SHADOW/baseline-tree" 2>/dev/null)"
sleep 1
_capture_baseline_tree "$SHADOW" "$PROJ"
MTIME2="$(stat -f %m "$SHADOW/baseline-tree" 2>/dev/null || stat -c %Y "$SHADOW/baseline-tree" 2>/dev/null)"
[[ "$MTIME1" == "$MTIME2" ]]
check "B6: second _capture_baseline_tree call is a no-op (file mtime unchanged)" $?

# ── B7: respects .gitignore — ignored files don't enter the snapshot ────────
# Fresh repo for this one so B5's state doesn't interfere.
PROJ2="$TMP/proj2"
SHADOW2="$TMP/shadow2"
mkdir -p "$PROJ2" "$SHADOW2"
cd "$PROJ2"
git -c init.defaultBranch=main init -q
echo "ignored.log" > .gitignore
echo "hello" > real-file.txt
git -c user.email=t@t -c user.name=t add .gitignore real-file.txt
git -c user.email=t@t -c user.name=t commit -q -m "initial"
# Ignored noise that should NOT be in the baseline snapshot.
echo "noise from tool" > ignored.log

_capture_baseline_tree "$SHADOW2" "$PROJ2"
BTREE2="$(cat "$SHADOW2/baseline-tree")"

# The ignored file should not have a blob in the tree.
tree_contents="$(git -C "$PROJ2" ls-tree -r "$BTREE2" 2>/dev/null)"
! echo "$tree_contents" | grep -q "ignored.log"
check "B7: .gitignore'd files are NOT captured in the tree" $?
echo "$tree_contents" | grep -q "real-file.txt"
check "B7: tracked files ARE captured in the tree" $?

# ── B8: no-op for pre-git projects ──────────────────────────────────────────
NOGIT_PROJ="$TMP/nogit"
NOGIT_SHADOW="$TMP/nogit-shadow"
mkdir -p "$NOGIT_PROJ" "$NOGIT_SHADOW"
echo "x" > "$NOGIT_PROJ/file.txt"
_capture_baseline_tree "$NOGIT_SHADOW" "$NOGIT_PROJ"
[[ ! -e "$NOGIT_SHADOW/baseline-tree" ]]
check "B8: pre-git project → no baseline-tree file created (quiet no-op)" $?

print_summary
