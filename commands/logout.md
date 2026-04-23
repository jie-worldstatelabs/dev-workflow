---
description: "Sign out — remove the local stagent cloud token"
allowed-tools: ["Bash"]
---

Remove ~/.config/stagent/auth.json. The plugin reverts to anonymous mode.
The token remains valid on the server until revoked via the web UI.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/logout-workflow.sh"
```
