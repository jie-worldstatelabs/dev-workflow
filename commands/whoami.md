---
description: "Show the signed-in dev-workflow cloud identity"
allowed-tools: ["Bash"]
---

Print the identity from ~/.dev-workflow/auth.json and verify the token
still works against the server.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/whoami-workflow.sh"
```
