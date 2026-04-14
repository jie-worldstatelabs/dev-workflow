---
description: "Create a new custom workflow suite (workflow.json + stage .md files) from a natural-language description"
argument-hint: "<brief description of the workflow you want to build>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

Generate a new dev-workflow from the user's description. The `create-workflow` skill will interview the user (if needed), propose a stage decomposition, iterate on the design, write the files under `~/.dev-workflow/workflows/<name>/`, and validate the result.

Task from user: `$ARGUMENTS`

Invoke `Skill("dev-workflow:create-workflow")` and follow its instructions exactly. The skill is self-contained — do NOT invoke any other skill before, during, or after.

When the skill finishes, the new workflow is ready to launch with:

```
/dev-workflow:dev --workflow=<name> <task description>
```
