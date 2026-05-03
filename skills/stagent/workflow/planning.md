# Stage: planning

_Runtime config (canonical): `workflow.json` → `stages.planning`_

**Purpose:** produce an agreed implementation plan and record user approval. Webapp-focused — the plan must specify the frontend framework, key pages/flows, test strategy, and Vercel deployment details.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `pending` (plan drafted, awaiting user approval), `approved` (user has explicitly confirmed)

<HARD-GATE>
Do NOT transition out of this stage until the user explicitly confirms the plan.
Write `result: approved` only after they have said so.
</HARD-GATE>

This is an interruptible stage — the stop hook allows natural pauses for Q&A.

> By the time you read this file, `state.md` already exists with `status: planning` and `epoch` is set. The bootstrap (topic name, `setup-workflow.sh`) ran before this stage starts.

## Explore context

Understand the project state (files, conventions, framework, package manager). New project → note it, suggest a starting framework. Existing codebase → respect patterns before proposing anything.

## Ask clarifying questions

Inline Q&A — the stop hook allows natural pauses.

- One question per message, prefer multiple choice (A/B/C) when possible
- Typically 3-6 questions; stop asking when you have enough
- Webapp-specific topics to cover: frontend framework, routing model, data layer, auth, key pages/flows, tests strategy, Vercel project name + env vars
- Flag multi-subsystem scopes early and help decompose

## Propose approaches

2-3 options with trade-offs; lead with your recommendation. Let the user pick or modify.

## Present design

Architecture, components, data flow, tech stack, error handling, deployment target. Iterate until agreed.

## Write the plan into the output artifact

Write the output artifact (use the current epoch for the frontmatter):

```markdown
---
epoch: <epoch>
result: pending
---
# Planning Report: <Topic>

## Design Summary
<agreed architecture, framework, key decisions>

## Implementation Steps
1. ...

## File Structure
<files / directories to create or modify>

## Acceptance Criteria
- [ ] ...

## Testing Strategy

### Quick Tests
- Framework: <e.g. vitest / jest / pytest — or "none">
- Coverage target: <e.g. 80%>
- Key test cases:
  - [ ] ...

### Journey Tests
- Framework: playwright (default for webapp) | none
- Key user paths:
  - [ ] ...

## Deployment (Vercel)
- Project name: <vercel project slug; will be set on first deploy via `vercel link`>
- Scope: <personal | team-slug>
- Production env vars (names only — values supplied at deploy time):
  - <NAME>
- Build command: <auto-detected, or override>
- Notes: <any deploy-time considerations — protected branches, edge runtimes, etc.>
```

`result: pending` signals "plan written but not approved yet."

## Get user approval

> "Plan saved to the session's planning-report.md. Please review and confirm to start execution, or request changes."

If the user requests changes, iterate on the plan body — keep `result: pending`.

## Finalize

Once the user explicitly approves, edit the output artifact: change `result: pending` → `result: approved`.

That is the only action needed here. The main loop reads the artifact's `result:` and calls `update-status.sh` to advance the state machine — do NOT call it yourself from this stage file.
