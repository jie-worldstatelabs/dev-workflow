---
description: "Resume a paused dev workflow, or take over a cloud session from another machine"
argument-hint: "[--session <id>]  (omit for normal resume)"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Resume the dev workflow. Two usage modes:

1. **Normal resume** — no arguments. The script picks the single
   interrupted run on this machine (or the one matching `--topic <name>`
   if given).
2. **Cross-machine takeover** — pass `--session <server_session_id>` to
   continue a cloud session that was started on a different machine.
   The script pulls the full shadow (state + artifacts + workflow
   config + baseline) from the server before resuming, so nothing
   needs to be set up ahead of time.

Arguments from the user: `$ARGUMENTS`

## Step 1: Restore Active Status

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/continue-workflow.sh" $ARGUMENTS
```

The output reports the **Topic** and **Phase** (the phase to jump back into).

## Step 2: Load the Workflow Skill

Invoke `Skill("dev-workflow:dev")` and follow its instructions exactly. The skill is self-contained — do NOT invoke any other skill.

## Step 3: Resume From the Detected Phase

Based on the **Phase** reported above, jump directly into the matching skill step — do NOT restart from Step 1 planning unless the phase is `planning`:

| Phase reported | Jump to |
|---------------|---------|
| `planning`    | Step 1 — resume planning conversation (interruptible) |
| `executing`   | Step 2 — launch `dev-workflow:workflow-executor` |
| `verifying`   | Step 2.5 — run quick tests inline |
| `reviewing`   | Step 3 — launch `dev-workflow:workflow-reviewer` |
| `qa-ing`      | Step 3.5 — launch `dev-workflow:workflow-qa` |

Run the loop without stopping. To interrupt again: `/dev-workflow:interrupt`. To cancel: `/dev-workflow:cancel`.
