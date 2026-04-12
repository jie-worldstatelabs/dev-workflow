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

This workflow uses a **Stop hook** to guarantee the execute-review loop runs to completion. Once the user confirms the plan, a state file (`.dev-workflow/state.md`) is created. The Stop hook reads this file and **blocks Claude from exiting** as long as the workflow status is `executing`, `verifying`, `reviewing`, `qa-ing`, or `gating`.

```
Step 1: Brainstorm & Plan  → inline Q&A → design → save plan → ⏸️ user confirms
                             ── stop hook activated ──
Step 2: Execute            → workflow-executor agent → execution report
Step 2.5: Verify           → run quick tests inline → verify report
                             (FAIL → back to Step 2 next round)
Step 3: Review             → workflow-reviewer agent → code review → review report
                             (FAIL → back to Step 2 next round)
Step 3.5: QA               → workflow-qa agent → journey tests → QA report
                             (FAIL → back to Step 2 next round)
Step 4: Gate               → QA PASS? done. (infinite loop until PASS)
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

This creates `.dev-workflow/state.md` with `status: executing`. From this point on, the Stop hook will block any attempt to exit until the review passes (`complete`) or the user runs `/dev-workflow:interrupt` or `/dev-workflow:cancel`.

---

## Step 2: Execute

1. **Update status to `executing`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing
   ```

2. **Read state file to resolve variables** (critical for context recovery after compaction):
   ```bash
   cat .dev-workflow/state.md
   ```
   Extract: `topic`, `round`, `plan_file` from the YAML frontmatter. Use these to construct all paths below.

3. **Launch `dev-workflow:workflow-executor` agent** (MUST use full plugin-prefixed name) with these parameters:
   - `subagent_type: dev-workflow:workflow-executor`
   - `model: opus`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Execute the implementation plan. Run autonomously — do not stop to ask questions.

   - Project directory: <absolute path to project root — all code MUST be written here, not in a subdirectory>
   - Plan: <absolute path to plan file>
   - Round: <N>
   - Reviewer feedback: <absolute path to .dev-workflow/<topic>-round-<N-1>-review.md, or "none" if no review yet>
   - QA feedback: <absolute path to .dev-workflow/<topic>-round-<N-1>-qa-report.md, or "none" if no QA yet>
   - Quick test failures: <check .dev-workflow/<topic>-round-<N-1>-verify.md — if it says "Result: FAIL", pass its absolute path; otherwise "none">

   Read the plan, implement all items, run tests, and write your execution report to:
   <absolute path to .dev-workflow/<topic>-round-<N>-report.md>
   ```

4. **When the executor completes**, verify the report file exists, then immediately proceed to Step 2.5.

## Step 2.5: Verify (Quick Tests)

1. **Update status to `verifying`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status verifying
   ```

2. **Detect the test command** from the project root (check in this order):
   - `package.json` with a `"test"` script → `npm test`
   - `pytest.ini`, `setup.cfg`, or `pyproject.toml` with `[tool.pytest]` → `pytest`
   - `pubspec.yaml` → `flutter test`
   - `go.mod` → `go test ./...`
   - `Makefile` with a `test` target → `make test`
   - If none found → write verify report as SKIPPED and proceed to Step 3

3. **Run the quick tests:**
   ```bash
   cd <project-directory> && <test-command> 2>&1
   ```
   Use a 3-minute timeout (`timeout: 180000`). Capture the full output.

4. **Write verify report** to `.dev-workflow/<topic>-round-<N>-verify.md`:
   ```markdown
   # Verify Report — Round <N>

   ## Test Command
   <command used, or "SKIPPED — no test command detected">

   ## Result
   PASS / FAIL / SKIPPED

   ## Output
   <test output — last 100 lines if very long>
   ```

5. **If quick tests FAIL:**
   - Increment round and update status:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing --round <N+1>
     ```
   - Announce: "Quick tests failed (round <N>). Starting round <N+1>..."
   - Go back to Step 2. Pass the verify report path as "Quick test failures" context to the executor.

6. **If quick tests PASS or SKIPPED:** proceed to Step 3.

## Step 3: Review

1. **Update status to `reviewing`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status reviewing
   ```

2. **Read state file to resolve variables** (if not already in context):
   ```bash
   cat .dev-workflow/state.md
   ```
   Extract: `topic`, `round`, `plan_file` from the YAML frontmatter.

3. **Launch `dev-workflow:workflow-reviewer` agent** (MUST use full plugin-prefixed name) with these parameters:
   - `subagent_type: dev-workflow:workflow-reviewer`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Run an adversarial code review for the dev-workflow cycle.

   - Project directory: <absolute path to project root>
   - Plan file: <absolute path to plan file>
   - Execution report: <absolute path to .dev-workflow/<topic>-round-<N>-report.md>
   - Verify report: <absolute path to .dev-workflow/<topic>-round-<N>-verify.md>
   - Review output path: <absolute path to .dev-workflow/<topic>-round-<N>-review.md>
   - Baseline file: <absolute path to .dev-workflow/<topic>-baseline>
   - QA report: <absolute path to .dev-workflow/<topic>-round-<N-1>-qa-report.md, or "none" if no QA ran yet>
   - Round: <N>

   Read the baseline file to get the git commit hash from before the executor ran.
   Review the code changes against the plan and return a verdict.
   ```

4. **When the reviewer completes**, parse the `---VERDICT---` block from the agent's response:
   - Extract `verdict` (PASS or FAIL), `summary`, and `issues` (if FAIL)
   - If no verdict block found, treat as FAIL with summary "Review agent did not return a structured verdict"

5. **If reviewer verdict = FAIL** → increment round and go back to Step 2:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing --round <N+1>
   ```
   Announce: "Code review failed (round <N>). Starting round <N+1>..."

6. **If reviewer verdict = PASS** → proceed to Step 3.5.

## Step 3.5: QA (Journey Tests)

1. **Update status to `qa-ing`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status qa-ing
   ```

2. **Read state file to resolve variables** (if not already in context):
   ```bash
   cat .dev-workflow/state.md
   ```

3. **Launch `dev-workflow:workflow-qa` agent** (MUST use full plugin-prefixed name) with these parameters:
   - `subagent_type: dev-workflow:workflow-qa`
   - `mode: bypassPermissions`
   - Prompt:

   ```
   Run real user journey tests for the dev-workflow QA phase.

   - Project directory: <absolute path to project root>
   - Plan file: <absolute path to plan file>
   - QA report output: <absolute path to .dev-workflow/<topic>-round-<N>-qa-report.md>
   - Journey test state file: <absolute path to .dev-workflow/<topic>-journey-tests.md>
   - Round: <N>
   ```

4. **When the QA agent completes**, parse the `---VERDICT---` block from the agent's response:
   - Extract `verdict` (PASS or FAIL), `summary`, and `issues` (if FAIL)
   - If no verdict block found, treat as FAIL with summary "QA agent did not return a structured verdict"

5. Immediately proceed to Step 4.

## Step 4: Gate

The verdict being evaluated here is the **QA agent's verdict** from Step 3.5.

1. **Update status to `gating`:**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status gating
   ```

2. Evaluate the QA verdict:

   - **PASS** → Mark complete:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status complete
     ```
     Then announce:
     > "Dev workflow complete after <N> round(s). All changes reviewed and QA-passed."

   - **FAIL** → Increment round and loop back:
     ```bash
     "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status executing --round <N+1>
     ```
     Print one-line status:
     > "QA round <N>: app bugs found. Starting round <N+1>..."
     Then **immediately go back to Step 2**.

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
