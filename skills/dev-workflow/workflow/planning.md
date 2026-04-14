# Stage: planning

_Runtime config (canonical): `workflow.json` → `stages.planning`_

**Purpose:** produce an agreed implementation plan and record user approval.
**Output artifact:** `<project>/.dev-workflow/<session_id>/planning-report.md`
**Valid results this stage writes:** `pending` (plan drafted, awaiting user approval), `approved` (user has explicitly confirmed)

<HARD-GATE>
Do NOT transition out of this stage until the user explicitly confirms the plan.
Write `result: approved` only after they have said so.
</HARD-GATE>

This is an interruptible stage — the stop hook allows natural pauses for Q&A.

> Note: picking the topic name and activating the workflow (`setup-workflow.sh`) happen in SKILL.md's protocol (Step 1 — Bootstrap), **before** any stage runs. By the time you read this file, `state.md` already exists with `status: planning` and `epoch` is set.

## Explore context

Understand the project state (files, conventions, tech stack). New project → note it. Existing codebase → respect patterns before proposing anything.

## Ask clarifying questions

Inline Q&A — the stop hook allows natural pauses.

- One question per message, prefer multiple choice (A/B/C) when possible
- Typically 3-6 questions; stop asking when you have enough
- Focus on: purpose, constraints, scope, success criteria, tech preferences
- Flag multi-subsystem scopes early and help decompose

## Propose approaches

2-3 options with trade-offs; lead with your recommendation. Let the user pick or modify.

## Present design

Architecture, components, data flow, tech stack, error handling. Iterate until agreed.

## Write the plan into the output artifact

Read `epoch` from `state.md`. Write the output artifact:

```markdown
---
epoch: <epoch>
result: pending
---
# Planning Report: <Topic>

## Design Summary
<agreed architecture, tech stack, key decisions>

## Implementation Steps
1. ...

## File Structure
<files / directories to create or modify>

## Acceptance Criteria
- [ ] ...

## Testing Strategy

### Quick Tests
- Framework: <e.g. pytest / jest / flutter test / go test — or "none">
- Coverage target: <e.g. 80%>
- Key test cases:
  - [ ] ...

### Journey Tests
- Framework: <e.g. playwright / XcodeBuildMCP / none>
- Key user paths:
  - [ ] ...
```

`result: pending` signals "plan written but not approved yet."

## Get user approval

> "Plan saved to the session's planning-report.md. Please review and confirm to start execution, or request changes."

If the user requests changes, iterate on the plan body — keep `result: pending`.

## Finalize

Once the user explicitly approves, edit the output artifact: change `result: pending` → `result: approved`.

That is the only action needed here. The SKILL.md main loop's step (e) reads the artifact's `result:` and calls `update-status.sh` to advance the state machine — do NOT call it yourself from this stage file.
