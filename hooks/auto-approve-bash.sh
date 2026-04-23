#!/usr/bin/env bash
#
# PreToolUse:Bash hook — auto-approves Bash commands whose substance is
# invoking stagent-owned scripts or reading stagent-owned skill files.
#
# Why this exists: Claude Code's built-in permission classifier flags
# any Bash command that execs a variable-expanded path (e.g.
# `"$P/scripts/update-status.sh"`) as needing interactive confirmation
# because it can't statically prove the expansion resolves to a safe
# binary. Every stage transition in a stagent workflow hits this
# pattern, so without this hook every end-user would have to click
# "Yes" dozens of times per session. We know these paths are safe —
# they resolve into the plugin's own cache directory that we control —
# so we tell Claude Code to skip the prompt.
#
# Safety model:
#  - We only approve commands that reference stagent's canonical paths
#    (`$P/scripts/`, `$CLAUDE_PLUGIN_ROOT/scripts/`, the cache absolute
#    form, plus the `cat ~/.config/stagent/plugin-root` preamble).
#  - We reject the approval shortcut if the command also contains
#    obviously dangerous ops (rm -rf /, sudo, piping curl into sh,
#    writing to block devices). In those cases we stay silent and
#    let CC's default prompt fire so the user stays in the loop.
#  - When the command doesn't match any stagent pattern we exit
#    silently (no output) so CC's default policy decides — this hook
#    never tightens, only loosens.

set -euo pipefail

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

[[ -z $CMD ]] && exit 0

# Hard deny: if the command has any of these, bail out and let CC's
# normal prompt fire. Keep this list tight — false positives here
# produce spurious prompts, false negatives let a malicious command
# skip confirmation.
if printf '%s' "$CMD" | grep -qE '(\brm[[:space:]]+-rf[[:space:]]+/|\bsudo\b|curl[^|]*\|[[:space:]]*(sh|bash)|>[[:space:]]*/dev/sd)'; then
  exit 0
fi

# The stagent-owned path prefixes we recognize. Anchoring on these
# prefixes (not merely `scripts/`) keeps the rule specific to our
# plugin, not any plugin that happens to have a scripts dir.
#   \$P/scripts/ or \$P/skills/            — main-agent bash preamble style
#   \$CLAUDE_PLUGIN_ROOT/(scripts|skills)/ — used inside our own hooks
#   .claude/plugins/cache/<mp>/stagent/<v>/{scripts,skills}/
#                                          — the absolute resolved form
#   ~/.config/stagent/plugin-root          — the preamble bootstrap file
STAGENT_RE='(\$P/(scripts|skills)/|\$CLAUDE_PLUGIN_ROOT/(scripts|skills)/|\.claude/plugins/cache/[^/]+/stagent/[^/]+/(scripts|skills)/|~/\.config/stagent/plugin-root|/\.config/stagent/plugin-root)'

if printf '%s' "$CMD" | grep -qE "$STAGENT_RE"; then
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "stagent-owned script/skill path — auto-approved by plugin hook"
  }
}
JSON
  exit 0
fi

# Not ours — stay silent, let CC decide.
exit 0
