---
description: "Create a new workflow suite, or edit an existing one with --path=<path>"
argument-hint: "[--path=<local-dir|cloud-url>] <brief description of the workflow / changes you want>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

Create or edit a dev-workflow. The `create-workflow` skill will interview the user (if needed), propose a stage decomposition, iterate on the design, write the files under `~/.dev-workflow/workflows/<name>/`, and validate the result.

- **No flag** → create a brand-new workflow from the description.
- **`--path=<path>`** → edit the workflow at the given path (local directory or cloud URL). Cloud workflows require login and ownership.

Task from user: `$ARGUMENTS`

Invoke `Skill("dev-workflow:create-workflow")` and follow its instructions exactly. The skill is self-contained — do NOT invoke any other skill before, during, or after.

When the skill finishes, the workflow is ready to launch with:

```
/dev-workflow:dev --workflow=<name> <task description>
```
