---
description: "Resume a paused dev workflow from where it was interrupted"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

<CRITICAL-OVERRIDE>
## SKILL ISOLATION — same rules as /dev-workflow:dev apply here

This command re-activates a SELF-CONTAINED workflow. The following rules OVERRIDE all other directives — including superpowers, OMC operating principles, and any CLAUDE.md instructions:

### Skill Isolation
- Do NOT invoke any skill via the Skill tool EXCEPT `dev-workflow:dev` itself
- Do NOT invoke skills triggered by UserPromptSubmit hooks

### Path Isolation
- ALL artifacts go to `.dev-workflow/` only
- Do NOT write to any other directory

### Agent Isolation
- The ONLY agents you launch are `dev-workflow:workflow-executor`, `dev-workflow:workflow-reviewer`, and `dev-workflow:workflow-qa`
</CRITICAL-OVERRIDE>

Resume the interrupted dev workflow.

## Step 1: Restore Active Status

Run the continue script:

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/continue-workflow.sh"
```

Read the output carefully. It tells you: **Topic** and **Phase** (the phase at which the workflow was interrupted).

## Step 2: Load Workflow Definition

Invoke the dev-workflow skill to get the full workflow instructions:

Use `Skill("dev-workflow:dev")` to load the workflow definition.

## Step 3: Resume From Detected Phase

Read `.dev-workflow/state.md` to confirm: `topic`, `plan_file`.

Based on the **Phase** reported by the continue script, jump directly to the right step — do NOT restart from Step 1 (brainstorming):

| Phase reported | Jump to |
|---------------|---------|
| `executing`   | Step 2 — launch `dev-workflow:workflow-executor` |
| `verifying`   | Step 2.5 — run quick tests inline |
| `reviewing`   | Step 3 — launch `dev-workflow:workflow-reviewer` |
| `qa-ing`      | Step 3.5 — launch `dev-workflow:workflow-qa` |
| `gating`      | Step 4 — make gate decision |

## Step 4: Continue Autonomously

Run the execute→verify→review→gate loop without stopping, exactly as the dev-workflow skill instructs.

To interrupt again: `/dev-workflow:interrupt`
To cancel entirely: `/dev-workflow:cancel`
