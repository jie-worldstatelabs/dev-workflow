---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, adversarial review via Codex, and loop until approved or max rounds reached."
---

# Dev Workflow — Plan, Execute, Review, Loop

Orchestrate a complete development cycle for any task: new feature, bug fix, or app modification.

<CRITICAL>
## Do NOT Invoke External Skills

This skill is SELF-CONTAINED. Do NOT invoke any external skill at any point:
- Do NOT invoke `superpowers:brainstorming`
- Do NOT invoke `superpowers:writing-plans`
- Do NOT invoke `superpowers:executing-plans`
- Do NOT invoke any other skill via the Skill tool

External skills will HIJACK the flow and never return control here. All phases (brainstorming, planning, execution, review) are handled INLINE below.
</CRITICAL>

## How It Works

This workflow uses a **Stop hook** to guarantee the execute-review loop runs to completion. Once the user confirms the plan, a state file (`.claude/dev-workflow.local.md`) is created. The Stop hook reads this file and **blocks Claude from exiting** as long as the workflow status is `executing`, `reviewing`, or `gating`.

```
Step 1: Brainstorm & Plan  → inline Q&A → design → save plan → ⏸️ user confirms
                             ── stop hook activated ──
Step 2: Execute            → workflow-executor agent → execution report
Step 3: Review             → workflow-reviewer agent → verdict
Step 4: Gate               → PASS? done. FAIL + round < 3? back to Step 2.
                             ── stop hook deactivated ──
```

## Configuration

| Setting | Value |
|---------|-------|
| Plan directory | `.plans/` in project root |
| Max review rounds | 3 |
| Executor model | opus |
| State file | `.claude/dev-workflow.local.md` |
| Reviewer agent | `dev-workflow:workflow-reviewer` (Codex CLI + fallback) |

---

## Step 1: Brainstorm & Plan

<HARD-GATE>
Do NOT proceed to execution until the user explicitly confirms the plan.
This is the ONLY human checkpoint in the entire workflow.
</HARD-GATE>

### Phase 1A: Explore Context

1. Check the current project state: files, directory structure, docs, recent git commits
2. If this is a new project (empty directory), note that
3. If there is an existing codebase, understand its patterns, conventions, and tech stack before proposing anything

### Phase 1B: Ask Clarifying Questions

Understand the user's intent through focused questions:

- **One question per message** — do not overwhelm with multiple questions
- **Prefer multiple choice** (A/B/C) when possible — easier to answer than open-ended
- **Focus on**: purpose, constraints, scope, success criteria, tech preferences
- **Assess scope early**: if the request covers multiple independent subsystems, flag it and help decompose before diving in
- **Stop asking when you have enough** — typically 3-6 questions. Don't ask for the sake of asking.

### Phase 1C: Propose Approaches

Once you understand the requirements:

1. Propose **2-3 approaches** with trade-offs
2. Lead with your recommended option and explain why
3. Let the user pick or suggest modifications

### Phase 1D: Present Design

Present the design incrementally:

1. Cover: architecture, components, data flow, tech stack, error handling
2. Scale detail to complexity — a few sentences for simple parts, more for nuanced parts
3. After presenting, ask: "Does this design look right? Anything to change?"
4. Iterate based on feedback until the user approves

### Phase 1E: Write Implementation Plan

After the user approves the design, write a concrete implementation plan:

1. Create `.plans/` directory if it doesn't exist
2. Write the plan to `.plans/YYYY-MM-DD-<topic>.md` with this structure:

```markdown
# Implementation Plan: <Topic>

## Design Summary
<Brief recap of agreed design — architecture, tech stack, key decisions>

## Implementation Steps
1. <Step 1 — specific, actionable>
2. <Step 2>
...

## File Structure
<Expected files/directories to create or modify>

## Acceptance Criteria
- [ ] <Criterion 1>
- [ ] <Criterion 2>
...

## Testing Strategy
<What tests to write, what coverage to target>
```

3. Present the plan to the user:
   > "Plan saved to `.plans/<filename>`. Please review and confirm to start execution, or request changes."
4. **Wait for explicit user approval** before proceeding to Step 2.

---

## Activating the Loop (after user confirms)

Once the user confirms the plan, **immediately activate the stop hook** by running:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>" --plan-file "<path-to-plan>"
```

This creates `.claude/dev-workflow.local.md` with `status: executing`. From this point on, the Stop hook will block any attempt to exit until the workflow reaches `complete` or `escalated`.

---

## Step 2: Execute

1. **Update status to `executing`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing
   ```

2. **Launch `dev-workflow:workflow-executor` agent** (MUST use full plugin-prefixed name) with these parameters:
   - `subagent_type: dev-workflow:workflow-executor`
   - `model: opus`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Execute the implementation plan. Run autonomously — do not stop to ask questions.

   - Plan: <absolute path to plan file>
   - Round: <N>
   - Reviewer feedback: <absolute path to previous review file, or "none" if round 1>

   Read the plan, implement all items, run tests, and write your execution report to:
   <absolute path to .plans/<topic>-round-<N>-report.md>
   ```

3. **When the executor completes**, verify the report file exists, then immediately proceed to Step 3.

## Step 3: Review

1. **Update status to `reviewing`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status reviewing
   ```

2. **Launch `dev-workflow:workflow-reviewer` agent** (MUST use full plugin-prefixed name) with these parameters:
   - `subagent_type: dev-workflow:workflow-reviewer`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Run an adversarial code review for the dev-workflow cycle.

   - Project directory: <absolute path to project root>
   - Plan file: <absolute path to plan file>
   - Execution report: <absolute path to .plans/<topic>-round-<N>-report.md>
   - Review output path: <absolute path to .plans/<topic>-round-<N>-review.md>
   - Round: <N>

   Run the Codex adversarial review, save the output, and return a verdict.
   ```

3. **When the reviewer completes**, parse the `---VERDICT---` block from the agent's response:
   - Extract `verdict` (PASS or FAIL), `summary`, and `issues` (if FAIL)
   - If no verdict block found, treat as FAIL with summary "Review agent did not return a structured verdict"

4. Immediately proceed to Step 4.

## Step 4: Gate

1. **Update status to `gating`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status gating
   ```

2. Evaluate:

   - **PASS** → Update status and clean up:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status complete
     ```
     Then announce:
     > "Dev workflow complete after <N> round(s). All changes reviewed and approved."

   - **FAIL + round < 3** → Increment round and loop back:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing --round <N+1>
     ```
     Print one-line status:
     > "Review round <N>/3: issues found. Starting round <N+1>..."
     Then **immediately go back to Step 2**.

   - **FAIL + round >= 3** → Escalate:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status escalated
     ```
     Then announce:
     > "Reached max review rounds (3). Remaining issues for manual review:"
     > <list unresolved issues>

## Error Handling

- If the **reviewer agent** fails to return a verdict, treat as FAIL and log the error in the review file.
- The reviewer agent handles Codex failures internally (falls back to `oh-my-claudecode:code-reviewer`).
- If the **executor agent** fails, capture the error in the report, **still proceed to review**.
- On any unrecoverable error, set status to `escalated` to release the stop hook:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status escalated
  ```

## Key Rules

- **NEVER invoke external skills** — all phases are handled inline
- **Always activate the stop hook** after user confirms the plan
- **Always update status** before each phase transition via `update-status.sh`
- **Always set status to `complete` or `escalated`** when done to release the stop hook
- **Never self-approve** — only the reviewer agent (Codex / fallback reviewer) or the user can approve
- **Always save artifacts** (plans, reports, reviews) to `.plans/` for traceability
- **To cancel manually**: user runs `/dev-workflow:cancel`
