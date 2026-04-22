---
description: "Start the dev workflow — inline planning, then autonomous execute→verify→review→QA loop"
argument-hint: "[--mode=cloud|local] [--workflow=<local-dir|cloud-url>] <task description>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Start a dev workflow. Two-skill chain:

- **Step 1** — `meta-workflow-setup` skill parses flags, derives a topic, and calls `setup-workflow.sh` (Phase 0 refuses to overwrite an active session; if there's already a live workflow it'll tell the user to `/meta-workflow:interrupt` / `/continue` / `/cancel` first).
- **Step 2** — `meta-workflow:meta-workflow` skill drives the state-machine loop against the `state.md` created in Step 1.

Task from user: `$ARGUMENTS`

## Step 1 — Bootstrap

Invoke `Skill("meta-workflow:meta-workflow-setup")` and follow its instructions exactly. It returns after `setup-workflow.sh` has written `state.md`.

## Step 2 — Drive the loop

Invoke `Skill("meta-workflow:meta-workflow")` and follow its instructions exactly. It picks up the freshly-created `state.md`, runs the initial stage, and continues through transitions until terminal.

Do NOT invoke any other skill before, during, or after these two.
