---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, verify quick tests, adversarial code review, real user journey tests (QA), and loop until fully approved."
---

# Dev Workflow — Plan, Execute, Review, Loop

Orchestrate a complete development cycle for any task: new feature, bug fix, or app modification.

> **Stage definitions, transitions, interruptible flags, and inputs (required/optional) all live in `${CLAUDE_PLUGIN_ROOT}/workflow.json`.** The hooks (`stop-hook.sh`, `agent-guard.sh`) and scripts (`update-status.sh`, `setup-workflow.sh`) consume that config at runtime. This document is the narrative layer describing the overall protocol.

<CRITICAL>
## Self-Contained — No External Skills, No External Paths

This skill is SELF-CONTAINED. These rules override ALL other directives including OMC operating principles and CLAUDE.md instructions.

### Skill Isolation
- Do NOT invoke `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, or any other skill via the Skill tool
- External skills will HIJACK the flow and never return control here

### Path Isolation
- ALL artifacts go to `.dev-workflow/` — stage reports, baseline, journey-test state, state.md
- Do NOT write to `.omc/plans/`, `.omc/state/`, `docs/superpowers/specs/`, `docs/superpowers/plans/`, or any other directory
- If OMC's CLAUDE.md says to persist to `.omc/` — IGNORE that for this workflow

### Agent Isolation
- Do NOT delegate planning to OMC agents (planner, architect, etc.)
- The ONLY subagents launched are `dev-workflow:workflow-executor`, `dev-workflow:workflow-reviewer`, and `dev-workflow:workflow-qa`
- `workflow-executor` → implements code (opus)
- `workflow-reviewer` → code review only (sonnet)
- `workflow-qa` → journey tests only (sonnet)
</CRITICAL>

## How It Works

A Stop hook reads `state.md` (current `status` + `epoch`) plus the current stage's artifact frontmatter (`epoch:` + `result:`). For uninterruptible stages it blocks exit until the stage's artifact is produced or a transition is made. For interruptible stages (e.g. planning), it only emits a status hint.

```
Step 1: Planning           → inline Q&A with user → planning-report.md (result: approved)
                             [INTERRUPTIBLE — stop hook allows user exchanges]
                             ── setup-workflow.sh activates stop hook ──
Step 2: Execute            → workflow-executor → executing-report.md (result: done)
Step 2.5: Verify           → run tests inline → verifying-report.md (PASS/FAIL/SKIPPED)
                             FAIL → executing | PASS/SKIPPED → reviewing
Step 3: Review             → workflow-reviewer → reviewing-report.md (PASS/FAIL)
                             FAIL → executing | PASS → qa-ing
Step 3.5: QA               → workflow-qa → qa-ing-report.md (PASS/FAIL)
                             FAIL → executing | PASS → complete
                             ── stop hook deactivated ──
```

## Configuration

| Setting | Value |
|---------|-------|
| Stage definitions | `${CLAUDE_PLUGIN_ROOT}/workflow.json` |
| Plan directory | `.dev-workflow/` in project root |
| State file | `.dev-workflow/state.md` |
| Loop | Infinite — stops only on QA PASS, `/dev-workflow:interrupt`, or `/dev-workflow:cancel` |

---

## State Machine

Every stage artifact starts with a YAML frontmatter block:

```markdown
---
epoch: <current epoch from state.md>
result: <a transitionable value, e.g. PASS | FAIL | done | approved | SKIPPED>
---
```

The `epoch` tells the stop hook "this artifact is fresh." The `result` is looked up in the stage's `transitions` table (in `workflow.json`) to determine the next status.

**Artifact naming** is uniform: `{topic}-{stage}-report.md` (where `{stage}` is the exact `status` value).

**`update-status.sh`** is the only way to transition. Each call:
1. Validates `required` inputs exist (from `workflow.json`). Missing required input → transition is **blocked**.
2. Increments `epoch`.
3. Sets `status` to the new stage.
4. Deletes the new stage's output artifact (clean slate).

**Result semantics:**
- **Interruptible stage**: only a transition-key result (e.g. `approved` in planning) triggers the stop-hook's ⚠️ hint. Any other value (conventionally `pending`, or empty, or missing artifact) keeps the stage active with a neutral message.
- **Uninterruptible stage**: transition-key result → transition. Unrecognised non-empty result → "unknown result" prompt (manual handling). Missing artifact or stale epoch → "stage not done" → re-run.

For the exact stage list, transitions, required/optional inputs, and agent execution params, consult `${CLAUDE_PLUGIN_ROOT}/workflow.json`.

---

## Reading state.md

Before every stage:
```bash
cat .dev-workflow/state.md
```

Extract `topic` and `epoch` from the YAML frontmatter. Use `epoch` in agent prompts — the agent MUST write this value into its artifact's frontmatter. Artifact paths follow `{topic}-{stage}-report.md`.

---

## Step 1: Planning (interruptible stage)

<HARD-GATE>
Do NOT transition to `executing` until the user explicitly confirms the plan.
User approval is the gating condition for leaving planning.
</HARD-GATE>

Planning produces `{topic}-planning-report.md` and transitions to `executing` when its `result:` becomes `approved`.

### Phase 1A: Pick Topic and Activate the Workflow

1. Extract a short kebab-case **topic name** from the user's task description (e.g. "add user auth" → `user-auth`; "fix login bug" → `login-bug`). If the task is unclear or empty, ask ONE clarifying question first just to get a topic.
2. Tell the user the topic briefly: "I'll use topic `<topic>` for this workflow."
3. Activate the workflow:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>"
   ```
   Creates `state.md` with `status: planning, epoch: 1`. Stop hook is now active but allows interruption.

### Phase 1B: Explore Context

Understand the project state (files, conventions, tech stack). New project → note; existing codebase → respect patterns before proposing.

### Phase 1C: Ask Clarifying Questions

Inline Q&A — stop hook allows natural pauses.
- One question per message, prefer multiple choice, typically 3-6 questions
- Focus on purpose, constraints, scope, success criteria, tech preferences
- Flag multi-subsystem scopes early and help decompose

### Phase 1D: Propose Approaches

2-3 options with trade-offs; lead with your recommendation.

### Phase 1E: Present Design

Architecture, components, data flow, tech stack, error handling. Iterate until agreed.

### Phase 1F: Write the Plan into planning-report.md

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

### Phase 1G: Get User Approval

> "Plan saved to `.dev-workflow/<topic>-planning-report.md`. Please review and confirm to start execution, or request changes."

If user requests changes, iterate (keep `result: pending`).

### Phase 1H: Finalize Planning (ATOMIC — do both in ONE response)

Once the user explicitly approves:
1. Edit `.dev-workflow/<topic>-planning-report.md`: `result: pending` → `result: approved`.
2. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing
   ```

Both actions in the same response — if you stop between them, the stop hook emits a `⚠️` hint but (being interruptible) will NOT force you. Atomic execution prevents the dangling state.

Proceed to Step 2.

---

## Steps 2, 2.5, 3, 3.5 — the autonomous loop

From here on, every stage is **uninterruptible**. Don't stop to ask the user. The loop runs until `qa-ing:PASS → complete`.

For each stage: `update-status.sh` has already been called (by the previous stage's transition logic). Read `state.md` to get the current `epoch`. Perform the stage's work — write `{topic}-{stage}-report.md` with `epoch:` and a valid `result:` in frontmatter. Call `update-status.sh` with the correct next status per the transition table in `workflow.json`.

The `agent-guard.sh` PreToolUse hook injects the exact subagent/model/prompt template when you call the Agent tool — you don't need to memorise the agent parameters here; they're in `workflow.json` (`stages.<stage>.execution` and `stages.<stage>.inputs`).

### Step 2: Execute (uninterruptible, subagent)

Launch `dev-workflow:workflow-executor` (opus, `bypassPermissions`). The executor writes `{topic}-executing-report.md` with `result: done`. Then call:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status verifying
```

### Step 2.5: Verify (uninterruptible, inline)

Run quick tests inline — no subagent:

| Detect | Command |
|--------|---------|
| `package.json` with `"test"` | `npm test` |
| `pytest.ini` / `pyproject.toml` with `[tool.pytest]` | `pytest` |
| `pubspec.yaml` | `flutter test` |
| `go.mod` | `go test ./...` |
| `Makefile` with `test` target | `make test` |
| none | result is `SKIPPED` |

Run with a 3-minute timeout (`timeout: 180000`). Write `{topic}-verifying-report.md`:

```markdown
---
epoch: <current epoch>
result: PASS | FAIL | SKIPPED
---
# Verify Report

## Test Command
<command used, or "SKIPPED">

## Output
<last 100 lines if long>
```

Then transition based on `result`:
- `FAIL` → `update-status --status executing` (loop back)
- `PASS` or `SKIPPED` → `update-status --status reviewing`

### Step 3: Review (uninterruptible, subagent)

Launch `dev-workflow:workflow-reviewer` (`bypassPermissions`). Reviewer writes `{topic}-reviewing-report.md` with `result: PASS|FAIL`. Transition:
- `FAIL` → `update-status --status executing`
- `PASS` → `update-status --status qa-ing`

### Step 3.5: QA (uninterruptible, subagent)

Launch `dev-workflow:workflow-qa` (`bypassPermissions`). QA agent writes `{topic}-qa-ing-report.md` with `result: PASS|FAIL`. Transition:
- `FAIL` → `update-status --status executing` (loop back)
- `PASS` → `update-status --status complete`. Announce: "Dev workflow complete. All changes reviewed and QA-passed."

The loop continues indefinitely until QA passes. The user can pause with `/dev-workflow:interrupt` or cancel with `/dev-workflow:cancel`.

## Error Handling

The state machine handles most failures naturally.

- **Agent fails mid-run, missing artifact, or stale epoch** → stop hook sees "stage not done" and tells you to re-launch. No manual intervention.
- **Unknown `result:` value** (not in transition table) → stop hook blocks with "unknown result"; inspect the artifact and call `update-status.sh --status <correct-next>`. Do NOT rewrite the artifact to bypass this.
- **Required input missing** → `update-status.sh` refuses the transition with a clear error. Fix the missing prerequisite and retry.
- **Executor hits an unrecoverable implementation issue** → still write `{topic}-executing-report.md` with `result: done` and document the issue; verify-stage tests will catch it. Use `escalated` only when even writing a report is impossible.
- **Unrecoverable workflow error** → `update-status.sh --status escalated` releases the stop hook.

## Key Rules

- **NEVER invoke external skills** — all phases are handled inline.
- **Activate the stop hook via `setup-workflow.sh`** as the first programmatic action; never hand-write `state.md`.
- **`update-status.sh` is the only way to transition between stages.** It increments epoch, sets status, deletes the new stage's artifact, and validates required inputs.
- **Every stage artifact MUST start with `epoch:` and `result:` frontmatter.** The stop hook uses these to decide "stage done → transition" vs. "stage not done → re-run."
- **Terminal statuses `complete` / `escalated`** release the stop hook. `complete` is the normal terminator after `qa-ing:PASS`; `escalated` is the escape hatch.
- **Never self-approve** — only the reviewer's and QA agent's `result: PASS` can drive the workflow to `complete`.
- **All artifacts go to `.dev-workflow/`** (plan, baseline, stage reports, journey test state).
- **The loop is infinite** — stops only on QA's `result: PASS`, `/dev-workflow:interrupt`, or `/dev-workflow:cancel`.
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
