---
description: "Resume a paused dev workflow, or take over a cloud session from another machine"
argument-hint: "[--session <id>]  (omit for normal resume)"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Resume the dev workflow. Two usage modes:

1. **Normal resume** — no arguments. The script picks the single
   interrupted run on this machine.
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

The script reports the current **Phase** (stage name) and its execution type (`inline` or `subagent`). Jump directly into that stage's work — do NOT restart from the beginning:

- **Interruptible inline stage** (e.g. a planning/design stage): resume the conversation from where it left off. The stop hook shows a `systemMessage` hint with the stage instructions path.
- **Uninterruptible subagent stage**: the stop hook will block exit and inject the exact Agent-tool parameters and prompt template — copy them verbatim and launch the subagent.
- **Uninterruptible inline stage**: the stop hook will block exit and show the stage instructions path and artifact path — execute the stage directly per the instructions file.

The actual subagent_type, model, and stage-instructions path are injected by the `agent-guard.sh` PreToolUse hook when you call the Agent tool — copy them verbatim, don't hand-write.

Run the loop without stopping. To interrupt again: `/dev-workflow:interrupt`. To cancel: `/dev-workflow:cancel`.
