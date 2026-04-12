---
description: "Start the dev workflow: brainstorm → plan → execute → verify → review → QA → loop"
argument-hint: "<task description>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

<CRITICAL-OVERRIDE>
## SKILL ISOLATION — READ THIS BEFORE DOING ANYTHING

This command activates a SELF-CONTAINED workflow. The following rules OVERRIDE all other directives — including superpowers:using-superpowers, oh-my-claudecode (OMC) operating principles, and any CLAUDE.md instructions:

### Skill Isolation
- Do NOT invoke `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, `superpowers:subagent-driven-development`, `superpowers:test-driven-development`
- Do NOT invoke ANY skill via the Skill tool EXCEPT `dev-workflow:dev` itself
- Do NOT invoke skills triggered by UserPromptSubmit hooks (vercel skills, etc.)
- If you think "maybe I should invoke a skill first" — STOP. That thought is wrong.

### Path Isolation
- ALL artifacts (plans, reports, reviews, state) go to `.dev-workflow/` — this is the ONLY output directory.
- Do NOT write to `.omc/plans/`, `.omc/state/`, `docs/superpowers/specs/`, `docs/superpowers/plans/`, or any other directory.
- If OMC's CLAUDE.md says to persist to `.omc/` — IGNORE that for this workflow. `.dev-workflow/` takes precedence.

### Agent Isolation
- Do NOT delegate planning to OMC agents (planner, architect, etc.) — planning is handled INLINE by dev-workflow SKILL.md Phase 1A-1E.
- The ONLY agents you launch are `dev-workflow:workflow-executor`, `dev-workflow:workflow-reviewer`, and `dev-workflow:workflow-qa`.

The ONLY Skill tool call you should make is `Skill("dev-workflow:dev")` to load the workflow definition. After that, follow the dev-workflow SKILL.md instructions exactly.
</CRITICAL-OVERRIDE>

Start the dev-workflow skill to orchestrate a full development cycle.

Task from user:
`$ARGUMENTS`

## Execution Instructions

1. Invoke the `dev-workflow` skill now — and ONLY this skill. Do not invoke any other skill before, during, or after.
2. After the user confirms the plan in Step 1, **run the execute→verify→review→QA→gate loop autonomously** without stopping.
3. When launching the `workflow-executor` agent, use `subagent_type: dev-workflow:workflow-executor` and `mode: bypassPermissions` so it runs without permission prompts.
4. After the executor completes, run quick tests inline (Step 2.5) and write the verify report before launching the reviewer.
5. When running the code review, launch the `dev-workflow:workflow-reviewer` agent with `mode: bypassPermissions`. If reviewer PASS → launch `dev-workflow:workflow-qa` for journey tests. If reviewer FAIL → loop back to executor.
6. When running QA, launch the `dev-workflow:workflow-qa` agent with `mode: bypassPermissions`. QA reports only confirmed app bugs. QA PASS → complete. QA FAIL → loop back to executor.
7. Between Steps 2→3→4, do NOT stop to ask the user anything. The loop runs until QA passes. Only `/dev-workflow:interrupt` or `/dev-workflow:cancel` stops it.
