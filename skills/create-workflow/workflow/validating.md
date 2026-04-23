# Stage: validating

_Runtime config (canonical): `workflow.json` → `stages.validating`_

**Purpose:** Run `setup-workflow.sh --validate-only` on the workflow produced by the writer. Gate success on the validator's actual exit — `PASS` transitions to `complete`, `FAIL` loops back to `writing` with the validator output as feedback.
**Output artifact:** write to the absolute path provided in your I/O context
**Valid results this stage writes:** `PASS`, `FAIL`

This is an uninterruptible inline stage. Read `state.md` for the current `epoch`, run autonomously, write the artifact with the final `result:` when done.

## Inputs

Read every input path from your I/O context — do NOT construct or hardcode paths.

- **Required:** `writing` report — contains the absolute path to the workflow directory under its `## Target directory` section.

## Protocol

1. Parse the target directory from the writer report's `## Target directory` section.

2. Run the validator and capture both stdout+stderr AND the exit code:

   ```bash
   P="$(cat ~/.config/stagent/plugin-root 2>/dev/null)"
   [[ -d $P/scripts ]] || P=~/.claude/plugins/stagent
   TARGET="<absolute-path-from-writer-report>"
   OUTPUT="$("$P/scripts/setup-workflow.sh" --validate-only --flow="$TARGET" 2>&1)"
   RC=$?
   echo "=== VALIDATOR OUTPUT ==="
   echo "$OUTPUT"
   echo "=== EXIT CODE: $RC ==="
   ```

3. Classify:
   - Exit 0 AND the output contains the line `✓ Workflow validated:` → `PASS`.
   - Anything else → `FAIL`.

4. Write the output artifact (see [Artifact](#artifact)).

## Artifact

Write the output artifact with this shape (quoting the full validator output verbatim — do not summarize):

````markdown
---
epoch: <epoch>
result: <PASS or FAIL>
---
# Validator Report

## Target directory
<absolute path>

## Exit code
<number>

## Validator output

```
<paste the full stdout + stderr verbatim — do not abbreviate>
```

## Summary

- On PASS: one line, e.g. "Workflow validated — N stages, M terminal. Ready to publish or launch."
- On FAIL: list every `❌` line from the validator output on its own bullet, copied verbatim so the writer can address each one next iteration.
````

## Rules

- Do NOT edit any file inside the workflow directory — your job is only to run the validator and classify. Fixing is the writer's job on the FAIL loop.
- Do NOT swallow, paraphrase, or truncate the validator output. The writer relies on the verbatim `❌` lines to know what to fix.
- Do NOT call `update-status.sh` — the main loop reads the artifact's `result:` and advances.
- On FAIL, the state machine automatically loops back to `writing`, which receives this report as its optional `validating` input for the next epoch.
