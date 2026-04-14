---
description: "Cancel the active dev workflow loop (archives by default, --hard to wipe)"
allowed-tools: ["Bash"]
---

Cancel the current session's active dev workflow.

**Default behaviour**: archives the run dir to `.dev-workflow/.archive/<YYYYMMDD-HHMMSS>-<topic>-cancelled/` so the stage reports (planning / executing / verifying / reviewing / qa-ing) and baseline survive as an audit trail. The dir name's `-cancelled` suffix distinguishes cancelled runs from natural replacements.

**`--hard`**: skip the archive and `rm -rf` the run dir. Use when you really don't want any artifacts left behind.

**Cloud mode**: POSTs a cancel to the server, then wipes the local shadow dir. The server keeps the audit trail on its side; nothing local is preserved.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cancel-workflow.sh" $ARGUMENTS
```
