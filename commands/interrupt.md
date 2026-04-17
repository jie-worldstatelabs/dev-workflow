---
description: "Pause the active dev workflow loop without clearing state — resume later with /meta-workflow:continue"
allowed-tools: ["Bash"]
---

Pause the active dev workflow at the current round, preserving all state for resumption:

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/interrupt-workflow.sh"
```
