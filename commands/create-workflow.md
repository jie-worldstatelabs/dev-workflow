---
description: "Create a new workflow suite (published to hub by default), or edit an existing one with --workflow=<path>"
argument-hint: "[--mode=cloud|local] [--workflow=<local-dir|cloud-url>] <brief description of the workflow / changes you want>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

Create or edit a dev-workflow. The `create-workflow` skill will interview the user (if needed), propose a stage decomposition, iterate on the design, write the files under `~/.dev-workflow/workflows/<name>/`, and validate the result.

- **No flag** → create a brand-new workflow and publish it to the hub (cloud mode by default).
- **`--mode=local`** → create locally only, skip hub publishing.
- **`--mode=cloud`** → explicit cloud mode (same as default).
- **`--workflow=<path>`** → edit the workflow at the given path (local directory or cloud URL). Cloud workflows require login and ownership.

Task from user: `$ARGUMENTS`

Invoke `Skill("dev-workflow:create-workflow")` and follow its instructions exactly. The skill is self-contained — do NOT invoke any other skill before, during, or after.

When the skill finishes, the workflow is ready to launch with:

```
/dev-workflow:dev --workflow=<path> <task description>
```
