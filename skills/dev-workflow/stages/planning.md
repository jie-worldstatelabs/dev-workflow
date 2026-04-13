# Stage: planning

**Execution:** inline (main agent) • **Interruptible:** yes
**Artifact:** `{topic}-planning-report.md`
**Valid results:** `pending` (in progress), `approved` (user confirmed)
**Transitions** _(canonical in workflow.json)_: `approved → executing`

<HARD-GATE>
Do NOT transition to `executing` until the user explicitly confirms the plan.
User approval is the gating condition for leaving planning.
</HARD-GATE>

This stage produces the plan AND records user approval. Because it is interruptible, the stop hook allows natural session pauses for Q&A.

---

## Phase 1A: Pick Topic and Activate the Workflow

1. Extract a short kebab-case **topic name** from the user's task description (e.g. "add user auth" → `user-auth`; "fix login bug" → `login-bug`). If the task is unclear or empty, ask ONE clarifying question first just to get enough signal for a topic.
2. Tell the user the topic briefly: "I'll use topic `<topic>` for this workflow."
3. Activate the workflow:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>"
   ```
   Creates `state.md` with `status: planning, epoch: 1`. The stop hook is now active but allows interruption.

## Phase 1B: Explore Context

Understand the project state (files, conventions, tech stack). New project → note it; existing codebase → respect patterns before proposing anything.

## Phase 1C: Ask Clarifying Questions

Inline Q&A — the stop hook allows natural pauses between user exchanges.

- One question per message, prefer multiple choice (A/B/C) when possible
- Typically 3-6 questions, stop asking when you have enough
- Focus on: purpose, constraints, scope, success criteria, tech preferences
- Flag multi-subsystem scopes early and help decompose

## Phase 1D: Propose Approaches

2-3 options with trade-offs; lead with your recommendation.

## Phase 1E: Present Design

Architecture, components, data flow, tech stack, error handling. Iterate until agreed.

## Phase 1F: Write the Plan into planning-report.md

Read `epoch` from `state.md` (should be `1`). Write `.dev-workflow/<topic>-planning-report.md`:

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
- Framework: <pytest / jest / flutter test / go test — or "none">
- Coverage target: <e.g. 80%>
- Key test cases:
  - [ ] ...

### Journey Tests
- Framework: <playwright / XcodeBuildMCP / none>
- Key user paths:
  - [ ] ...
```

`result: pending` signals "plan written but not approved yet."

## Phase 1G: Get User Approval

> "Plan saved to `.dev-workflow/<topic>-planning-report.md`. Please review and confirm to start execution, or request changes."

If user requests changes, iterate (rewrite the plan body, keep `result: pending`).

## Phase 1H: Finalize Planning (ATOMIC — do both in ONE response)

Once the user explicitly approves:

1. Edit `.dev-workflow/<topic>-planning-report.md`: change `result: pending` → `result: approved`.
2. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing
   ```
   This increments epoch, sets status=executing, and deletes `<topic>-executing-report.md` for the clean slate.

Both actions **must be in the same response**. If you stop between them, the stop hook emits a `⚠️` hint but (being interruptible) will NOT force you. Atomic execution prevents dangling approved-but-not-transitioned state.

Proceed to the `executing` stage — read `stages/executing.md`.
