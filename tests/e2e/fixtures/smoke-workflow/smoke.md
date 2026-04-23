# Stage: smoke

_Runtime config (canonical): `workflow.json` → `stages.smoke`_

**Purpose:** Minimal E2E fixture stage — write an artifact declaring
`result: passed` and call `update-status.sh --status complete`.

**Output artifact:** write to the absolute path provided in your I/O
context (typically `<run-dir>/smoke-report.md`).

**Valid results this stage writes:** `passed` (always).

## Step 1 — Write the artifact

Use the current epoch from `state.md`:

```markdown
---
epoch: <epoch>
result: passed
---
# Smoke
E2E fixture run — nothing to do.
```

## Step 2 — Transition to terminal

Call `update-status.sh --status complete` to advance the state machine.
The stop hook will clean up `state.md` after a terminal transition.
