# Stage: publishing

_Runtime config (canonical): `workflow.json` → `stages.publishing`_

**Purpose:** After the validator confirms the workflow files are correct, push the workflow to the hub if the user invoked `/stagent:create` with `--mode=cloud`. For `--mode=local` this stage is a no-op pass-through.
**Output artifact:** write to the absolute path provided in your I/O context
**Valid results this stage writes:** `done` (published, or gracefully noted failure), `skipped` (local mode — nothing to publish)

This is an uninterruptible inline stage. Read `state.md` for the current `epoch`, run autonomously, write the artifact with the final `result:` when done.

## Inputs

Read every input path from your I/O context — never construct or hardcode paths.

- **Required:** `writing` report — contains the absolute path to the workflow directory under `## Target directory`.
- **Required:** `validating` report — confirmation that the validator printed `✓ Workflow validated`. You should only be running if the previous transition was `PASS`.
- **Optional:** `setup_context` run_file — JSON with `publish_intent` field: `"cloud"` means publish, `"local"` means skip.

## Protocol

1. Parse `publish_intent` from `setup_context`. If the file doesn't exist or the JSON lacks the field, default to `"local"` (fail-safe: don't publish unless explicitly asked).

2. Parse the target directory from the writer's report (the path under `## Target directory`).

3. Branch on `publish_intent`:

### If `publish_intent == "local"` — skip

Write the artifact with `result: skipped` and a one-line explanation:

```markdown
---
epoch: <epoch>
result: skipped
---
# Publish Report

## Mode
local — nothing to publish. Workflow files are ready at `<target-dir>`.
```

Done.

### If `publish_intent == "cloud"` — publish

Run `publish-workflow.sh` on the target directory and capture output + exit code:

```bash
P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
TARGET="<absolute-path-from-writer-report>"
OUTPUT="$("$P/scripts/publish-workflow.sh" "$TARGET" 2>&1)"
RC=$?
echo "=== PUBLISH OUTPUT ==="
echo "$OUTPUT"
echo "=== EXIT CODE: $RC ==="
```

Classify:
- Exit 0 → published successfully. Write artifact with `result: done` and copy the script's output (it already prints the template URL, pull command, visibility).
- Non-zero → publish failed. **Still write `result: done`** (the workflow files are valid locally — the failure is at push time, not fatal to the run). Include the full `OUTPUT` verbatim so the user can diagnose and retry with `/stagent:publish <target-dir>`.

Artifact shape:

````markdown
---
epoch: <epoch>
result: done
---
# Publish Report

## Mode
cloud

## Target directory
<absolute-path>

## Exit code
<number>

## Script output

```
<paste full stdout + stderr verbatim>
```

## Summary

- On success (exit 0): copy the template URL and pull command from the output; note "Published".
- On failure (non-zero): "Publish failed — files are valid locally at `<target-dir>`. Retry with `/stagent:publish <target-dir>` after resolving the issue. Common causes: expired token (`/stagent:login` again), network, or name collision with another user."
````

## Rules

- Do NOT fail the stage on publish errors. The state machine terminates at `complete` after this stage; an `escalated` terminal would suggest the whole run is broken, which is wrong — the local workflow files are valid and usable.
- Do NOT modify any file in the target workflow directory. Your job is to push it up (or skip), nothing else.
- Do NOT call `update-status.sh` — the main loop reads this artifact's `result:` and advances.
