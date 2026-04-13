# Stage: planning

_Runtime config (canonical): `workflow.json` → `stages.planning`_

**Purpose:** produce an agreed implementation plan and record user approval.
**Output artifact:** `<project>/.dev-workflow/<topic>-planning-report.md`
**Valid results this stage writes:** `pending` (plan drafted, awaiting user approval), `approved` (user has explicitly confirmed)

<HARD-GATE>
Do NOT transition out of this stage until the user explicitly confirms the plan.
Write `result: approved` only after they have said so.
</HARD-GATE>

This is an interruptible stage — the stop hook allows natural pauses for Q&A.

## Phase 1A: Pick topic and activate the workflow

1. Extract a short kebab-case **topic name** from the user's task description (e.g. "add user auth" → `user-auth`; "fix login bug" → `login-bug`). If the task is unclear or empty, ask ONE clarifying question first just to get a topic.
2. Tell the user the topic briefly: "I'll use topic `<topic>` for this workflow."
3. Activate the workflow:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>"
   ```
   Creates `state.md` with this stage active (`status: planning, epoch: 1`). The stop hook becomes active but allows interruption for this stage.

## Phase 1B: Explore context

Understand the project state (files, conventions, tech stack). New project → note it. Existing codebase → respect patterns before proposing anything.

## Phase 1C: Ask clarifying questions

Inline Q&A — the stop hook allows natural pauses.

- One question per message, prefer multiple choice (A/B/C) when possible
- Typically 3-6 questions; stop asking when you have enough
- Focus on: purpose, constraints, scope, success criteria, tech preferences
- Flag multi-subsystem scopes early and help decompose

## Phase 1D: Propose approaches

2-3 options with trade-offs; lead with your recommendation. Let the user pick or modify.

## Phase 1E: Present design

Architecture, components, data flow, tech stack, error handling. Iterate until agreed.

## Phase 1F: Write the plan into the output artifact

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

## Phase 1G: Get user approval

> "Plan saved to `.dev-workflow/<topic>-planning-report.md`. Please review and confirm to start execution, or request changes."

If the user requests changes, iterate on the plan body — keep `result: pending`.

## Phase 1H: Finalize (ATOMIC — do both in ONE response)

Once the user explicitly approves:

1. Edit the output artifact: change `result: pending` → `result: approved`.
2. Look up `workflow.json` → `stages.planning.transitions["approved"]` to get the next status. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status <next>
   ```
   (replacing `<next>` with the looked-up value)

Both actions **must be in the same response**. If you stop between them, the stop hook emits a `⚠️` hint but (being interruptible) will NOT force you. Atomic execution prevents dangling approved-but-not-transitioned state.
