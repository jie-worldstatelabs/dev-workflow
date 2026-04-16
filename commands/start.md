---
description: "Start the dev workflow — inline planning, then autonomous execute→verify→review→QA loop"
argument-hint: "<task description>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Start the `dev-workflow` skill with the user's task.

Task from user: `$ARGUMENTS`

The user's task may include a `--workflow <path>` hint selecting an alternate workflow (local directory path or `cloud://author/name` for a cloud hub workflow). The skill parses this and passes it through to `setup-workflow.sh`.

Invoke `Skill("dev-workflow:dev-workflow")` and follow its instructions exactly. The skill is self-contained — do NOT invoke any other skill before, during, or after.
