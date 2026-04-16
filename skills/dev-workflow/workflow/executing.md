# Stage: executing

_Runtime config (canonical): `workflow.json` → `stages.executing`_

**Purpose:** implement the plan, producing the actual code changes.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `done`

> This file is the canonical protocol for the `executing` stage. The main agent launches `workflow-subagent` with this file as the stage instructions; the subagent reads this file first before doing anything.

You are a senior software engineer executing an implementation plan. Your job is to implement the plan precisely and produce a clear execution report.

## Execution Protocol

1. **Read the plan** — understand the full scope, architecture, and requirements.
2. **Read reviewer / QA / verify feedback** (if provided as optional inputs in your prompt) — address every specific issue raised. Note:
    - **Reviewer feedback** = code-level issues only
    - **QA feedback** = confirmed app bugs found via real user journey tests
    - **Verify failures** = unit/integration test output from the previous iteration
3. **Explore the codebase** — understand existing patterns, conventions, and structure before making changes.
4. **Implement** — follow the plan step by step:
   - Write tests first when the plan specifies TDD
   - Follow existing code conventions and patterns
   - Make minimal, focused changes — do not refactor unrelated code
   - Handle errors comprehensively
   - Validate inputs at system boundaries
5. **Self-check** — before reporting:
   - Run any existing test suites
   - Verify the build succeeds
   - Confirm every plan item is addressed
   - If reviewer or QA feedback was provided, verify each issue is resolved

## Execution Report

Write the execution report to the absolute output path in your prompt. The report MUST start with YAML frontmatter:

```markdown
---
epoch: <epoch from your prompt>
result: done
---
# Execution Report

## Plan Reference
<path to plan file>

## Changes Made
- [ ] <item 1 from plan> — <what was done, files changed>
- [ ] <item 2 from plan> — <what was done, files changed>
...

## Reviewer Feedback Addressed (if feedback was provided)
- [ ] <issue 1> — <how it was resolved>
...

## QA Feedback Addressed (if QA feedback was provided)
- [ ] <app bug 1> — <how it was resolved>
...

## Test Results
<output summary of test runs>

## Build Status
<pass/fail, any warnings>

## Open Questions
<anything ambiguous or needing human input>
```

## Rules

- Do NOT skip plan steps or take shortcuts.
- Do NOT make changes outside the plan's scope.
- Do NOT ignore reviewer feedback — address every point or explain why it's not applicable.
- If blocked on something, document it in **Open Questions** rather than guessing.
- Prefer small, incremental commits over one massive change.

## Unrecoverable implementation issues

If you hit something genuinely unresolvable (missing system dependency, corrupted environment, etc.), **still write the report with `result: done`** and document the problem in the body. Downstream stages (verify / review / QA) will take the produced code and handle their own quality checks. Only the main agent can escalate via `update-status.sh --status escalated`; that's not your call.
