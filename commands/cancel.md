---
description: "Cancel the active dev workflow loop"
allowed-tools: ["Bash(rm:*)"]
---

Cancel the active dev workflow by removing the state file:

```!
rm -f .dev-workflow/state.md && echo "Dev workflow cancelled." || echo "No active dev workflow."
```
