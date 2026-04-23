---
description: "Resume a paused dev workflow, or take over a cloud session from another machine"
argument-hint: "[--session <id>]  (omit for normal resume)"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Resume the dev workflow. Two usage modes:

1. **Normal resume** — no arguments. The script picks the single interrupted run on this machine.
2. **Cross-machine takeover** — pass `--session <server_session_id>` to continue a cloud session that was started on a different machine. The script pulls the full shadow (state + artifacts + workflow config + baseline) from the server before resuming, so nothing needs to be set up ahead of time.

Arguments from the user: `$ARGUMENTS`

## Step 1 — Restore active status

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/continue-workflow.sh" $ARGUMENTS
```

The script flips the session's `state.md` from `interrupted` back to its saved `resume_status` (or pulls a cloud shadow + registers a local alias for cross-machine takeover). Output reports the **Topic** and **Phase** (the stage to resume into). On exit code 1, halt — the script's stderr explains (no interrupted run found, project mismatch, workdir behind, etc.).

## Step 2 — Drive the loop

Invoke `Skill("stagent:stagent")` and follow its instructions exactly. It picks up the now-active `state.md`, reads the resumed stage via `loop-tick.sh`, and continues through transitions until terminal — including the per-stage `inline` vs `subagent` execution dispatch (the loop skill handles all of that internally; this command does NOT need to give per-stage instructions).

Do NOT invoke any other skill before, during, or after these two.

To interrupt again: `/stagent:interrupt`. To cancel: `/stagent:cancel`.
