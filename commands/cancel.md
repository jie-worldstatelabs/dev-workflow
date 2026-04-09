---
description: "Cancel the active dev workflow loop"
allowed-tools: ["Bash(rm:*)"]
---

Cancel the active dev workflow by removing the state file:

```!
rm -f .claude/dev-workflow.local.md && echo "✅ Dev workflow cancelled." || echo "⚠️ No active dev workflow."
```
