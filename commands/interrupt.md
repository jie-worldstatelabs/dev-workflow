---
description: "Pause the active dev workflow loop without clearing state — resume later with /meta-workflow:continue"
argument-hint: "[--session <id>]  (omit to interrupt this Claude session's own workflow)"
allowed-tools: ["Bash"]
---

Pause the dev workflow at the current stage, preserving all state for resumption.

- **No arguments**: interrupts the workflow owned by THIS Claude session (resolved via PPID / cwd cache).
- **`--session <id>`**: interrupts a specific cloud session — useful when you want to pause a workflow that's running in another Claude Code window or on another machine.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/interrupt-workflow.sh" $ARGUMENTS
```
