---
description: "Sign in to the dev-workflow cloud server"
allowed-tools: ["Bash"]
---

Run the device-code login flow. Opens the browser, waits for approval,
and stores a bearer token at ~/.dev-workflow/auth.json.

Pass `--demo` to skip OAuth and sign in instantly as the shared demo
account (useful for testing).

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/login-workflow.sh" $ARGUMENTS
```
