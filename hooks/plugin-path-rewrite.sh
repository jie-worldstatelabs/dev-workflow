#!/usr/bin/env bash
#
# PreToolUse:Bash hook — plugin path rewrite.
#
# Stagent's skill files tell the agent to invoke plugin scripts via a
# two-line preamble that discovers the plugin root into `$P`, then
# calls `"$P/scripts/foo.sh"`. Claude Code's permission classifier
# flags every variable-path exec as `simple_expansion` requiring
# interactive confirmation, so end users get prompted dozens of times
# per workflow run.
#
# What this hook does — and nothing else:
#   1. Strips the `$P`-discovery preamble (both the quoted and
#      unquoted forms) from the command.
#   2. Substitutes literal `$P/` with the resolved absolute plugin
#      path. The hook is a hook subprocess, so `$CLAUDE_PLUGIN_ROOT`
#      is available here (unlike in the main agent's Bash env).
#
# What this hook does NOT do:
#   - Does NOT emit `permissionDecision`. CC's default prompt flow
#     stays in charge; users keep their "Don't ask again" control,
#     now over clean absolute-path patterns instead of variable
#     expansions.
#   - Does NOT touch commands that don't reference `$P/` — those
#     passthrough untouched.
#   - Does NOT modify environment, settings, or anything outside
#     this single tool invocation's command string.
#
# Soft-degradation: if this hook is disabled, absent, or errors,
# the Bash tool runs the agent's original command verbatim. The
# preamble's own `$P` discovery then takes over and the workflow
# keeps working — the only visible difference is that CC's
# permission prompts come back (today's behavior).
#
# Opt-out: set `STAGENT_NO_PATH_REWRITE=1` in the environment to
# make this hook a no-op (useful if a user has policy reasons to
# keep every Bash command unmutated).

set -eu

# Opt-out kill switch.
[[ "${STAGENT_NO_PATH_REWRITE:-}" == "1" ]] && exit 0

# Hook provides CLAUDE_PLUGIN_ROOT. Without it we cannot resolve
# paths, so stay silent and let the command through unchanged.
[[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] && exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
[[ -z "$CMD" ]] && exit 0

# Fast path: if the command doesn't reference `$P/`, nothing for us
# to do. This keeps the hook O(0) for the common case of non-plugin
# Bash calls.
if ! printf '%s' "$CMD" | grep -qE '\$P/'; then
  exit 0
fi

# Strip the two-line plugin-root discovery preamble. Patterns match
# both the current (unquoted) and the legacy (double-quoted) forms
# used across SKILL.md and stage files.
#
# Line 1: `P=$(cat ~/.config/stagent/plugin-root ...)`
# Line 2: `[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/.../stagent/.../ ...)`
STRIPPED="$(printf '%s' "$CMD" | sed -E '
  /^[[:space:]]*P="?\$\(cat ~\/\.config\/stagent\/plugin-root/d
  /^[[:space:]]*\[\[[[:space:]]+-n[[:space:]]+"?\$P"?[[:space:]]+&&[[:space:]]+-d[[:space:]]+"?\$P\/scripts.*P="?\$\(ls[[:space:]]+-d[[:space:]]+~\/\.claude\/plugins\/cache/d
')"

# Substitute `$P/` with the absolute plugin root. `|` is a safe sed
# delimiter here because filesystem paths never contain it.
REWRITTEN="$(printf '%s' "$STRIPPED" | sed "s|\$P/|${CLAUDE_PLUGIN_ROOT}/|g")"

# Emit only updatedInput — no permissionDecision. CC's default
# policy (prompt / honor 'Don't ask again') stays in charge.
jq -nc --arg cmd "$REWRITTEN" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: { command: $cmd }
  }
}'
