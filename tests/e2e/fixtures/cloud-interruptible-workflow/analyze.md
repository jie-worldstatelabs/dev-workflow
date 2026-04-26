# Stage: analyze

_Runtime config (canonical): `workflow.json` → `stages.analyze`_

**Purpose:** Minimal interruptible E2E fixture stage. Used by
`test_skill_cloud_workflow.sh` to exercise the interrupt → continue
lifecycle (same-machine and cross-machine). Writes a single artifact
declaring `result: done` and transitions to `complete`.

**Output artifact:** write to the absolute path provided in your I/O
context (typically `<run-dir>/analyze-report.md`).

**Valid results this stage writes:** `pending` (during pause), `done`
(when ready to advance).

This stage is **interruptible** so the stop hook can pause it mid-run
when `interrupt-workflow.sh` flips the status to `interrupted`. On
resume (`/stagent:continue`), the main agent re-enters this stage at
the same epoch and finishes the work.

## Step 1 — Mark in-progress

Read the current epoch from `state.md`. Immediately write the artifact
with `result: pending` so the stop hook knows the stage is in flight:

```markdown
---
epoch: <epoch>
result: pending
---
# Analyze
In progress.
```

## Step 2 — Do the work

There is no real work — this is a fixture. Overwrite the artifact with
the final result:

```markdown
---
epoch: <epoch>
result: done
---
# Analyze
E2E fixture analysis complete — nothing to inspect.
```

## Step 3 — Transition to terminal

Call `update-status.sh --status complete`. The stop hook will clean up
`state.md` after the terminal transition; in cloud mode it also wipes
the shadow at `~/.cache/stagent/sessions/<session_id>/` and removes the
cloud-registry entry.
