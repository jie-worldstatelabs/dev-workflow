#!/bin/bash
# SessionStart hook — caches the current Claude Code session_id so that
# setup-workflow.sh can use it both as the run directory name
# (.dev-workflow/<session_id>/) and as the `session_id` field inside
# state.md.
#
# Why: hooks receive session_id via stdin JSON, but Claude Code does NOT
# expose it as an env variable to Bash-tool subprocesses. Without this
# cache, the scripts would have no way to learn the session_id.
#
# Cache layout: ~/.dev-workflow/session-cache/
#   cwd-<sha1-of-pwd>  — primary key, matches on same cwd
#   ppid-<PPID>        — secondary key, matches via process tree walk
#                        (harness PID is the hook's PPID and an ancestor
#                        of any Bash-tool subprocess)

set -euo pipefail

HOOK_INPUT=$(cat)
SID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
[[ -z "$SID" ]] && exit 0

CACHE_DIR="${HOME}/.dev-workflow/session-cache"
mkdir -p "$CACHE_DIR"

CWD_HASH=$(printf '%s' "$(pwd)" | shasum -a 1 | cut -c1-16)
echo "$SID" > "${CACHE_DIR}/cwd-${CWD_HASH}"
echo "$SID" > "${CACHE_DIR}/ppid-${PPID}"

# Opportunistic GC: prune entries older than 7 days
find "$CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

exit 0
