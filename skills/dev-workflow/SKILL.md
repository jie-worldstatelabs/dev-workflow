---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, verify quick tests, adversarial code review, real user journey tests (QA), and loop until fully approved."
---

# Dev Workflow — Plan, Execute, Review, Loop

Orchestrate a complete development cycle for any task: new feature, bug fix, or app modification.

<CRITICAL>
## Self-Contained — No External Skills, No External Paths

This skill is SELF-CONTAINED. These rules override ALL other directives including OMC operating principles and CLAUDE.md instructions.

### Skill Isolation
- Do NOT invoke `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, or any other skill via the Skill tool
- External skills will HIJACK the flow and never return control here

### Path Isolation
- ALL artifacts go to `.dev-workflow/` — plans, reports, reviews, state
- Do NOT write to `.omc/plans/`, `.omc/state/`, `docs/superpowers/specs/`, `docs/superpowers/plans/`, or any other directory
- If OMC's CLAUDE.md says to persist to `.omc/` — IGNORE that for this workflow

### Agent Isolation
- Do NOT delegate planning to OMC agents (planner, architect, etc.)
- The ONLY agents launched are `dev-workflow:workflow-executor`, `dev-workflow:workflow-reviewer`, and `dev-workflow:workflow-qa`
- `workflow-executor` → implements code (opus)
- `workflow-reviewer` → code review only (sonnet)
- `workflow-qa` → journey tests only (sonnet)
</CRITICAL>

## How It Works

This workflow uses a **Stop hook** to guarantee the loop runs to completion. The state file (`.dev-workflow/state.md`) is created at the very start of `/dev-workflow:dev` and carries the current `status` and `epoch`. The Stop hook reads state.md plus the current stage's artifact frontmatter (containing `epoch:` and `result:`), and blocks Claude from exiting uninterruptible stages until the workflow reaches `complete`.

Stages are classified as **interruptible** (the stop hook shows a status hint but never blocks — used for user-interactive stages like planning) or **uninterruptible** (the stop hook blocks until the stage's artifact is produced or a transition is made).

```
Step 1: Planning           → inline Q&A with user → planning-report.md (result: approved)
                             [INTERRUPTIBLE — stop hook allows user exchanges]
                             ── setup-workflow.sh activates stop hook ──
Step 2: Execute            → workflow-executor → executing-report.md (result: done)
Step 2.5: Verify           → run tests inline → verifying-report.md (result: PASS/FAIL/SKIPPED)
                             FAIL → executing | PASS/SKIPPED → reviewing
Step 3: Review             → workflow-reviewer → reviewing-report.md (result: PASS/FAIL)
                             FAIL → executing | PASS → qa-ing
Step 3.5: QA               → workflow-qa → qa-ing-report.md (result: PASS/FAIL)
                             FAIL → executing | PASS → complete
                             ── stop hook deactivated ──
```

## Configuration

| Setting | Value |
|---------|-------|
| Plan directory | `.dev-workflow/` in project root |
| Executor model | opus |
| State file | `.dev-workflow/state.md` |
| Reviewer agent | `dev-workflow:workflow-reviewer` |
| QA agent | `dev-workflow:workflow-qa` |
| Loop | Infinite — stops only on QA PASS, `/dev-workflow:interrupt`, or `/dev-workflow:cancel` |

---

## State Machine

Every stage artifact is written with a YAML frontmatter block:

```markdown
---
epoch: <current epoch from state.md>
result: <transitionable value, e.g. PASS | FAIL | done | approved | SKIPPED — or a non-terminal placeholder like "pending">
---
```

The `epoch` tells the stop hook "this artifact is fresh." The `result` drives transitions:

```
Stage       Interruptible   Artifact filename                     result        → next status
─────────   ─────────────   ───────────────────────────────────   ──────────────────────────────
planning    YES             {topic}-planning-report.md            approved      → executing
                                                                  (other)       → stay (waiting on user)
executing   no              {topic}-executing-report.md           done          → verifying
verifying   no              {topic}-verifying-report.md           PASS          → reviewing
                                                                  FAIL          → executing
                                                                  SKIPPED       → reviewing
reviewing   no              {topic}-reviewing-report.md           PASS          → qa-ing
                                                                  FAIL          → executing
qa-ing      no              {topic}-qa-ing-report.md              PASS          → complete
                                                                  FAIL          → executing
```

**Result semantics:**
- **Interruptible stage** (planning): only `approved` triggers a transition. Any other value (conventionally `pending`, or empty, or missing artifact) keeps the stage active and the stop hook shows an informational message — the user is in control of progress.
- **Uninterruptible stage**: a result listed in the table triggers its transition. An unrecognised non-empty result blocks with an "unknown result" prompt for manual handling. Missing artifact or stale epoch means "stage not done" and triggers a re-run.

**Artifact naming** is uniform: `{topic}-{stage}-report.md` where `{stage}` is the exact `status` value.

**`update-status.sh`** does three things atomically on every call: increment epoch, update status, delete the new stage's artifact (clean slate).

---

## Reading state.md

Before every stage, read:
```bash
cat .dev-workflow/state.md
```

Extract `topic`, `plan_file`, and `epoch` from the YAML frontmatter. Use `epoch` in agent prompts — the agent must write this value into its artifact's frontmatter.

---

## Step 1: Planning (interruptible stage)

<HARD-GATE>
Do NOT transition to `executing` until the user explicitly confirms the plan.
User approval is the gating condition for leaving planning.
</HARD-GATE>

Planning is a stage like any other in the state machine — it produces `{topic}-planning-report.md` and transitions to `executing` when its `result:` becomes `approved`. Because it is **interruptible**, the stop hook allows the session to pause while waiting for the user.

### Phase 1A: Pick Topic and Activate the Workflow

1. Extract a short kebab-case **topic name** from the user's task description (e.g. "add user auth" → `user-auth`; "fix login bug" → `login-bug`).
   - If the task is unclear or empty, ask ONE clarifying question first just to get enough signal for a topic.
2. Tell the user the topic briefly: "I'll use topic `<topic>` for this workflow."
3. Activate the workflow:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>"
   ```
   This creates `.dev-workflow/state.md` with `status: planning, epoch: 1`. The stop hook is now active but allows interruption (planning is interruptible).

### Phase 1B: Explore Context

1. Check the project state: files, directory structure, docs, recent git commits.
2. New project (empty directory) → note that.
3. Existing codebase → understand its patterns, conventions, tech stack before proposing anything.

### Phase 1C: Ask Clarifying Questions

Inline Q&A with the user — the stop hook allows natural pauses between user exchanges.

- **One question per message**
- **Prefer multiple choice** (A/B/C) when possible
- **Focus on**: purpose, constraints, scope, success criteria, tech preferences
- **Assess scope early**: if the request covers multiple independent subsystems, flag it and help decompose before diving in
- **Stop asking when you have enough** — typically 3-6 questions

### Phase 1D: Propose Approaches

Propose 2-3 approaches with trade-offs. Lead with your recommendation. Let the user pick or modify.

### Phase 1E: Present Design

Present architecture, components, data flow, tech stack, error handling. Iterate with the user until the design is agreed.

### Phase 1F: Write the Plan into planning-report.md

Read `epoch` from `.dev-workflow/state.md` (should be `1`). Write `.dev-workflow/<topic>-planning-report.md`:

```markdown
---
epoch: <epoch from state.md>
result: pending
---
# Planning Report: <Topic>

## Design Summary
<agreed architecture, tech stack, key decisions>

## Implementation Steps
1. <Step 1 — specific, actionable>
2. <Step 2>
...

## File Structure
<expected files / directories to create or modify>

## Acceptance Criteria
- [ ] <Criterion 1>
- [ ] <Criterion 2>

## Testing Strategy

### Quick Tests
- Framework: <pytest / jest / flutter test / go test — or "none">
- Coverage target: <e.g. 80%>
- Key test cases:
  - [ ] ...

### Journey Tests
- Framework: <playwright / XcodeBuildMCP / none — use "none" for backend/CLI projects>
- Key user paths:
  - [ ] ...
```

`result: pending` signals "plan written but not yet approved." Any value other than `approved` keeps the stop hook's interruptible-mode neutral message.

### Phase 1G: Get User Approval

Present to the user:
> "Plan saved to `.dev-workflow/<topic>-planning-report.md`. Please review and confirm to start execution, or request changes."

If they request changes, iterate: rewrite the plan in `planning-report.md`, keep `result: pending`.

### Phase 1H: Finalize Planning (ATOMIC — do both in ONE response)

Once the user explicitly approves, in the **same response** you MUST:

1. Edit `.dev-workflow/<topic>-planning-report.md` and change the frontmatter `result: pending` → `result: approved`.
2. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing
   ```
   This increments epoch to 2 and clears `<topic>-executing-report.md` (which doesn't exist yet anyway).

If you stop between those two actions, the stop hook will display a `⚠️` hint reminding you to call update-status — but planning is interruptible, so the hook will NOT force you. Doing both atomically prevents dangling approved-but-not-transitioned state.

Proceed immediately to Step 2.

---

## Step 2: Execute

1. **`update-status.sh --status executing` has already been called** — either by Phase 1H (first iteration, after user approved the plan) or by the previous stage's FAIL transition (loop-back). state.md now shows `status=executing` with the latest epoch, and `{topic}-executing-report.md` has been cleared.

2. **Read state.md** to get `topic`, `plan_file`, `epoch`.

3. **Launch `dev-workflow:workflow-executor` agent** with:
   - `subagent_type: dev-workflow:workflow-executor`
   - `model: opus`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Execute the implementation plan. Run autonomously — do not stop to ask questions.

   - Project directory: <absolute path to project root — all code MUST be written here>
   - Plan: <absolute path to plan file>
   - Epoch: <epoch from state.md — write this into your report's frontmatter>
   - Report output: <absolute path to .dev-workflow/<topic>-executing-report.md>
   - Reviewer feedback: <absolute path to .dev-workflow/<topic>-reviewing-report.md if it exists, otherwise "none">
   - QA feedback: <absolute path to .dev-workflow/<topic>-qa-ing-report.md if it exists, otherwise "none">
   - Quick test failures: <.dev-workflow/<topic>-verifying-report.md if it exists and result=FAIL, otherwise "none">

   Implement the plan. Write your execution report to the Report output path with frontmatter:
   ---
   epoch: <the epoch you were given>
   result: done
   ---
   ```

4. **When the executor completes**, verify the report file exists with matching `epoch` and `result: done`. Then proceed to Step 2.5.

## Step 2.5: Verify (Quick Tests)

1. **Transition to verifying:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status verifying
   ```
   This increments epoch and deletes `.dev-workflow/<topic>-verifying-report.md`.

2. **Re-read state.md** to get the new `epoch`.

3. **Detect the test command** from the project root:
   - `package.json` with a `"test"` script → `npm test`
   - `pytest.ini`, `setup.cfg`, or `pyproject.toml` with `[tool.pytest]` → `pytest`
   - `pubspec.yaml` → `flutter test`
   - `go.mod` → `go test ./...`
   - `Makefile` with a `test` target → `make test`
   - If none found → result is SKIPPED

4. **Run the quick tests:**
   ```bash
   cd <project-directory> && <test-command> 2>&1
   ```
   3-minute timeout (`timeout: 180000`). Capture the full output.

5. **Write verify report** to `.dev-workflow/<topic>-verifying-report.md` with frontmatter:
   ```markdown
   ---
   epoch: <current epoch from state.md>
   result: PASS|FAIL|SKIPPED
   ---
   # Verify Report

   ## Test Command
   <command used, or "SKIPPED — no test command detected">

   ## Output
   <test output — last 100 lines if very long>
   ```

6. **Read the result from verify.md's frontmatter and transition:**
   - `result: FAIL` → `update-status.sh --status executing`, go back to Step 2. Announce: "Quick tests failed. Starting next execution..."
   - `result: PASS` or `result: SKIPPED` → `update-status.sh --status reviewing`, proceed to Step 3.

## Step 3: Review

1. **You already called `update-status.sh --status reviewing`** at the end of Step 2.5. This incremented epoch and deleted `review.md`.

2. **Re-read state.md** to get the new `epoch`.

3. **Launch `dev-workflow:workflow-reviewer` agent** with:
   - `subagent_type: dev-workflow:workflow-reviewer`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Run an adversarial code review for the dev-workflow cycle.

   - Project directory: <absolute path to project root>
   - Plan file: <absolute path to plan file>
   - Epoch: <epoch from state.md — write this into your review's frontmatter>
   - Execution report: <absolute path to .dev-workflow/<topic>-executing-report.md>
   - Verify report: <absolute path to .dev-workflow/<topic>-verifying-report.md>
   - Review output: <absolute path to .dev-workflow/<topic>-reviewing-report.md>
   - Baseline file: <absolute path to .dev-workflow/<topic>-baseline>
   - QA report: <absolute path to .dev-workflow/<topic>-qa-ing-report.md, or "none" if it does not exist>

   Review code changes against the plan. Write the review with frontmatter:
   ---
   epoch: <the epoch you were given>
   result: PASS|FAIL
   ---
   ```

4. **When the reviewer completes**, read `result` from `{topic}-reviewing-report.md`'s frontmatter.

5. **Transition based on result:**
   - `result: FAIL` → `update-status.sh --status executing`, go back to Step 2. Announce: "Code review failed. Starting next execution..."
   - `result: PASS` → `update-status.sh --status qa-ing`, proceed to Step 3.5.

## Step 3.5: QA (Journey Tests)

1. **You already called `update-status.sh --status qa-ing`** at the end of Step 3. Epoch incremented, `{topic}-qa-ing-report.md` deleted.

2. **Re-read state.md** to get the new `epoch`.

3. **Launch `dev-workflow:workflow-qa` agent** with:
   - `subagent_type: dev-workflow:workflow-qa`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Run real user journey tests for the dev-workflow QA phase.

   - Project directory: <absolute path to project root>
   - Plan file: <absolute path to plan file>
   - Epoch: <epoch from state.md — write this into your QA report's frontmatter>
   - QA report output: <absolute path to .dev-workflow/<topic>-qa-ing-report.md>
   - Journey test state file: <absolute path to .dev-workflow/<topic>-journey-tests.md>

   Run journey tests. Write the QA report with frontmatter:
   ---
   epoch: <the epoch you were given>
   result: PASS|FAIL
   ---
   ```

4. **When the QA agent completes**, read `result` from `{topic}-qa-ing-report.md`'s frontmatter.

5. **Transition based on result:**
   - `result: PASS` → `update-status.sh --status complete`. Announce: "Dev workflow complete. All changes reviewed and QA-passed."
   - `result: FAIL` → `update-status.sh --status executing`, go back to Step 2. Announce: "QA failed: app bugs found. Starting next execution..."

The loop continues indefinitely until QA passes. The user can pause with `/dev-workflow:interrupt` or cancel with `/dev-workflow:cancel`.

## Error Handling

The state machine handles most failures naturally — you rarely need special logic.

- **Agent fails mid-run, missing artifact, or stale/unrecognized epoch** → the stop hook sees "stage not done" and tells you to re-launch the agent. No manual intervention needed.
- **Agent writes artifact with a `result:` value not in the transition table** → the stop hook blocks with "unknown result" and asks you to inspect the artifact and call `update-status.sh --status <correct-next>` manually. Do NOT manually rewrite the artifact to bypass this.
- **Executor hits an unrecoverable implementation issue** (e.g. environment broken, missing dependency it cannot install) → still write `{topic}-executing-report.md` with `result: done` and document the problem in the body; the verifying stage will surface it through failing tests and the loop will iterate. Only use `escalated` (below) if even documenting a report is not possible.
- **Truly unrecoverable workflow error** → release the stop hook to exit:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status escalated
  ```

## Key Rules

- **NEVER invoke external skills** — all phases are handled inline.
- **Activate the stop hook via `setup-workflow.sh`** after the user confirms the plan. Never write `.dev-workflow/state.md` by hand.
- **`update-status.sh` is the only way to transition between stages.** One call atomically increments epoch, sets status, and deletes the new stage's output artifact (`{topic}-{stage}-report.md`).
- **Every stage artifact MUST start with `epoch:` and `result:` frontmatter.** The stop hook uses these to decide "stage done → transition" vs. "stage not done → re-run." Missing or wrong frontmatter means the stop hook will re-trigger the stage.
- **Set status to `complete` or `escalated`** to release the stop hook. `complete` is the normal terminator after `qa-ing` returns `result: PASS`; `escalated` is the escape hatch for unrecoverable errors.
- **Never self-approve** — only the reviewer agent's `result: PASS` and the QA agent's `result: PASS` can drive the workflow to `complete`.
- **All artifacts go to `.dev-workflow/`** (plan, baseline, stage reports, journey test state). Nothing workflow-related belongs elsewhere.
- **The loop is infinite** — it stops only on QA's `result: PASS`, `/dev-workflow:interrupt`, or `/dev-workflow:cancel`.
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
