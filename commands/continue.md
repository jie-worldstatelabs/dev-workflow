---
description: "Resume a paused dev workflow from where it was interrupted"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Resume the interrupted dev workflow.

## Step 1: Restore Active Status

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/continue-workflow.sh"
```

The output reports the **Topic** and **Phase** (the phase at which the workflow was interrupted).

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
