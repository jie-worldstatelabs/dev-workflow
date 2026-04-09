---
description: "Start the dev workflow: brainstorm → plan → execute → adversarial review → loop"
argument-hint: "<task description>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

<CRITICAL-OVERRIDE>
## SKILL ISOLATION — READ THIS BEFORE DOING ANYTHING

This command activates a SELF-CONTAINED workflow. The following rules OVERRIDE all other skill directives, including superpowers:using-superpowers:

- Do NOT invoke `superpowers:brainstorming` — brainstorming is handled INLINE by dev-workflow
- Do NOT invoke `superpowers:writing-plans` — planning is handled INLINE by dev-workflow
- Do NOT invoke `superpowers:executing-plans` — execution is handled INLINE by dev-workflow
- Do NOT invoke `superpowers:subagent-driven-development`
- Do NOT invoke `superpowers:test-driven-development`
- Do NOT invoke ANY skill via the Skill tool EXCEPT `dev-workflow:dev` itself
- Do NOT invoke skills triggered by UserPromptSubmit hooks (vercel skills, etc.) — they are irrelevant to this workflow
- If you think "maybe I should invoke a skill first" — STOP. That thought is wrong. This workflow is self-contained.

The ONLY Skill tool call you should make is `Skill("dev-workflow:dev")` to load the workflow definition. After that, follow the dev-workflow SKILL.md instructions exactly — no external skills.
</CRITICAL-OVERRIDE>

Start the dev-workflow skill to orchestrate a full development cycle.

Task from user:
`$ARGUMENTS`

## Execution Instructions

1. Invoke the `dev-workflow` skill now — and ONLY this skill. Do not invoke any other skill before, during, or after.
2. After the user confirms the plan in Step 1, **run the execute→review→gate loop autonomously** without stopping.
3. When launching the `workflow-executor` agent, use `subagent_type: dev-workflow:workflow-executor` and `mode: bypassPermissions` so it runs without permission prompts.
4. When running the adversarial review, launch the `dev-workflow:workflow-reviewer` agent with `mode: bypassPermissions`. The reviewer agent handles Codex CLI execution and fallback internally.
5. Between Steps 2→3→4, do NOT stop to ask the user anything. Continue until PASS or max rounds.
