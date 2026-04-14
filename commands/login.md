---
description: "Sign in to the dev-workflow cloud server"
allowed-tools: ["Bash"]
---

Run the device-code login flow. Opens the browser, waits for approval,
and stores a bearer token at ~/.dev-workflow/auth.json.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/login-workflow.sh"
```
