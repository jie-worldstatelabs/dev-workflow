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

This workflow uses a **Stop hook** to guarantee the execute-review loop runs to completion. Once the user confirms the plan, a state file (`.dev-workflow/state.md`) is created with `status` and `epoch`. The Stop hook reads state.md plus the current stage's artifact frontmatter (containing `epoch:` and `result:`), and blocks Claude from exiting until the workflow reaches `complete`.

```
Step 1: Brainstorm & Plan  → inline Q&A → design → save plan → ⏸️ user confirms
                             ── stop hook activated ──
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

1. Create `.dev-workflow/` directory if it doesn't exist
2. Write the plan to `.dev-workflow/YYYY-MM-DD-<topic>.md` with this structure:

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

### Quick Tests
- Framework: <e.g. pytest / jest / flutter test / go test — or "none">
- Coverage target: <e.g. 80%>
- Key test cases:
  - [ ] <test case 1>
  - [ ] <test case 2>

### Journey Tests
- Framework: <e.g. playwright / XcodeBuildMCP / none — use "none" for backend-only or CLI projects>
- Key user paths:
  - [ ] <user path 1 — e.g. "User registers, logs in, and reaches the dashboard">
  - [ ] <user path 2>
```

3. Present the plan to the user:
   > "Plan saved to `.dev-workflow/<filename>`. Please review and confirm to start execution, or request changes."
4. **Wait for explicit user approval** before proceeding to Step 2.

---

## Activating the Loop (after user confirms)

Once the user confirms the plan, **immediately activate the stop hook** by running:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>" --plan-file "<path-to-plan>"
```

This creates `.dev-workflow/state.md` with `status: executing` and `epoch: 1`. From this point on, the Stop hook will block any attempt to exit until the workflow reaches `complete` or the user runs `/dev-workflow:interrupt` or `/dev-workflow:cancel`.

---

## State Machine

Every active artifact is written with a YAML frontmatter block:

```markdown
---
epoch: <current epoch from state.md>
result: <PASS|FAIL|done|SKIPPED>
---
```

The `epoch` tells the stop hook "this artifact is fresh." The `result` drives transitions:

```
Stage       Artifact filename                     result    → next status
─────────   ───────────────────────────────────   ─────────────────────────
executing   {topic}-executing-report.md           done      → verifying
verifying   {topic}-verifying-report.md           PASS      → reviewing
                                                  FAIL      → executing
                                                  SKIPPED   → reviewing
reviewing   {topic}-reviewing-report.md           PASS      → qa-ing
                                                  FAIL      → executing
qa-ing      {topic}-qa-ing-report.md              PASS      → complete
                                                  FAIL      → executing
```

Artifact naming is uniform: `{topic}-{stage}-report.md` where `{stage}` is the exact `status` value.

`update-status.sh` does three things atomically on every call: increment epoch, update status, delete the new stage's artifact (clean slate).

---

## Reading state.md

Before every stage, read:
```bash
cat .dev-workflow/state.md
```

Extract `topic`, `plan_file`, and `epoch` from the YAML frontmatter. Use `epoch` in agent prompts — the agent must write this value into its artifact's frontmatter.

---

## Step 2: Execute

1. **Setup already set `status=executing` and `epoch=1`** for the first iteration. For loop-backs from later stages, `update-status.sh --status executing` was already called by that stage.

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

- If the **reviewer agent** fails to return a verdict, treat as FAIL and log the error in the review file.
- The reviewer agent handles review failures internally.
- If the **executor agent** fails, capture the error in the report, **still proceed to review**.
- On any unrecoverable error, set status to `escalated` to release the stop hook (this allows exit):
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status escalated
  ```

## Key Rules

- **NEVER invoke external skills** — all phases are handled inline
- **Always activate the stop hook** after user confirms the plan
- **Always update status** before each phase transition via `update-status.sh`
- **Always set status to `complete` or `escalated`** when done to release the stop hook
- **Never self-approve** — only the reviewer agent or the user can approve
- **Always save artifacts** (plans, reports, reviews) to `.dev-workflow/` for traceability
- **The loop is infinite** — it stops only when the review passes. The user controls it with:
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
