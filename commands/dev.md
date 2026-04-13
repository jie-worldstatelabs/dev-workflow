---
description: "Start the dev workflow — inline planning, then autonomous execute→verify→review→QA loop"
argument-hint: "<task description>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Start the `dev-workflow` skill with the user's task.

Task from user: `$ARGUMENTS`

Invoke `Skill("dev-workflow:dev")` and follow its instructions exactly. The skill is self-contained — do NOT invoke any other skill before, during, or after.
