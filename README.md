# dev-workflow

A Claude Code plugin that orchestrates a complete development cycle as a **config-driven state machine**: **plan → execute → verify → review → QA → loop**.

## What It Does

`/dev-workflow:dev <task>` kicks off a self-contained workflow. Every stage is declared in a single `workflow.json` config (stages, transitions, required/optional inputs, execution params); the hooks and scripts consume that config at runtime.

1. **Planning** (*interruptible*) — Claude picks a topic name, activates the workflow, then does inline Q&A with you: clarifying questions, proposed approaches, design iteration, plan file. You confirm before anything gets built. The stop hook allows natural session pauses for user exchanges.
2. **Execute** — A dedicated executor agent (Opus) implements the plan: tests-first when specified, minimal focused changes, incremental commits.
3. **Verify** — Quick tests (unit/integration) run inline. FAIL → back to Execute (with failure output as context); PASS/SKIPPED → Review.
4. **Review** — A reviewer agent (Sonnet) runs adversarial code review against a baseline commit: correctness, completeness, design, edge cases, security. Reports only code-level issues. PASS → QA, FAIL → back to Execute.
5. **QA** — A dedicated QA agent runs real user journey tests (Playwright, XcodeBuildMCP, etc.). Distinguishes test bugs from app bugs — only confirmed app bugs block progress. PASS → complete, FAIL → back to Execute.

The `execute → verify → review → QA` loop runs **autonomously** after you approve the plan. A Stop hook guarantees the loop runs to completion: for uninterruptible stages it blocks exit until the stage's artifact is produced or a transition is made; for the interruptible planning stage it only emits a status hint. No round limit — the loop stops only when QA passes, or when you intervene.

## Installation

```bash
claude plugin marketplace add https://github.com/jie-worldstatelabs/dev-workflow
claude plugin install dev-workflow
```

## Usage

```
/dev-workflow:dev Build a REST API with user authentication
/dev-workflow:dev Fix the race condition in the payment processing module
/dev-workflow:dev Add dark mode support to the dashboard
```

Control a running workflow:

```
/dev-workflow:interrupt   — pause at the current phase (state preserved)
/dev-workflow:continue    — resume from where it was interrupted
/dev-workflow:cancel      — cancel entirely and clear all state
```

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) CLI
- `jq` (standard on macOS; `apt install jq` on Linux)

## Architecture

```
workflow.json            ← Source of truth: stages, transitions, inputs, execution params
commands/
  dev.md                 ← /dev-workflow:dev entry point (passes $ARGUMENTS to the skill)
  interrupt.md           ← /dev-workflow:interrupt to pause (state preserved)
  continue.md            ← /dev-workflow:continue to resume
  cancel.md              ← /dev-workflow:cancel to abort and clear state
agents/
  workflow-executor.md   ← Opus-powered implementation agent
  workflow-reviewer.md   ← Adversarial code review (correctness, security, edge cases)
  workflow-qa.md         ← Journey test agent; reports only confirmed app bugs
skills/
  dev-workflow/
    SKILL.md             ← Narrative layer of the workflow (loops through the state machine)
hooks/
  hooks.json             ← Hook wiring
  stop-hook.sh           ← Generic state-machine controller driven by workflow.json
  agent-guard.sh         ← Templates agent prompts from config at Agent-tool launch
scripts/
  lib.sh                 ← Shared helpers + config reader (wraps jq)
  setup-workflow.sh      ← Creates state.md at workflow start
  update-status.sh       ← The only legal way to transition (validates required inputs atomically)
  interrupt-workflow.sh  ← Pauses without clearing state
  continue-workflow.sh   ← Restores active status for resumption
```

### State Machine

Every stage artifact is written with a YAML frontmatter block:

```markdown
---
epoch: <current epoch from state.md>
result: <PASS | FAIL | done | approved | SKIPPED — or a non-terminal placeholder>
---
```

- **`epoch`** — monotonic counter incremented on every `update-status.sh` call. Tells the stop hook "this artifact is fresh, produced in the current phase."
- **`result`** — looked up in the stage's `transitions` table (from `workflow.json`) to determine the next status. Missing or unrecognized result = stage not done.
- **Artifact naming** is uniform: `{topic}-{stage}-report.md`.

### Key Design Decisions

- **Config-driven** — Stages, transitions, interruptible flags, subagent types/models, and input dependencies all live in `workflow.json`. Adding a new stage or changing a transition is a config edit, not a code change.
- **Required inputs block transitions** — `update-status.sh` refuses to move into a stage if any `required` input artifact is missing. State-machine-level enforcement, not just a suggestion.
- **Epoch-stamped artifacts** — Each stage's artifact carries the epoch that was current when it was produced. The stop hook only trusts artifacts whose epoch matches `state.md` — stale artifacts from previous iterations are ignored for transition decisions.
- **Self-contained** — The skill explicitly blocks all external skill invocations (brainstorming, writing-plans, etc.) to prevent flow hijacking.
- **Interruptible vs uninterruptible stages** — Planning is interruptible (stop hook allows user Q&A pauses); execute / verify / review / QA are uninterruptible (stop hook blocks exit until transition or artifact).
- **Context isolation** — Executor, reviewer, and QA run as subagents so their large outputs stay out of the orchestrator's context window.

## Typical Workflow Walkthrough

A concrete end-to-end trace showing which scripts and hooks fire at each step. Example task: **"Build a note-taking app"** → topic `note-app`.

### Bootstrap

```
USER  ► /dev-workflow:dev Build a note-taking app
MAIN  ► reads SKILL.md (meta-protocol)
MAIN  ► derives topic `note-app` from the task
MAIN  ▶ runs: scripts/setup-workflow.sh --topic note-app
        └─ auto `git init` if no repo
        └─ creates initial baseline commit if HEAD doesn't exist
        └─ writes .dev-workflow/state.md  (status: planning, epoch: 1)
        └─ writes .dev-workflow/note-app-baseline  = HEAD SHA
        └─ prints the initial stage's I/O context to stdout
MAIN  ◀ sees state + inputs + output path, proceeds to planning stage
```

_From here, `stop-hook` fires on every session-stop attempt; `agent-guard` fires on every Agent-tool call._

### Stage 1 — planning  (interruptible, inline)

```
MAIN  ► reads stages/planning.md
MAIN  ⇄ Q&A loop with user:
        - each turn ends → stop-hook fires
          └─ planning is interruptible → emits systemMessage hint, does NOT block
          └─ session exits cleanly, resumes when user replies
MAIN  ✎ writes note-app-planning-report.md  (epoch: 1, result: pending)
USER  ► approves
MAIN  ✎ edits report frontmatter  (result: pending → approved)
MAIN  ▶ runs: scripts/update-status.sh --status executing
        └─ validates required inputs for `executing` (planning-report.md exists) ✓
        └─ bumps epoch 1 → 2, sets status: executing
        └─ deletes note-app-executing-report.md  (clean slate; file didn't exist)
        └─ prints executing's I/O context
```

### Stage 2 — executing  (uninterruptible, subagent)

```
MAIN  ► reads stages/executing.md
MAIN  ► calls Agent tool
        └─ PreToolUse: agent-guard.sh fires in MAIN's context
            └─ prints ⚠️ "hook output is visible only to main — you MUST transcribe"
            └─ prints ━ PROMPT TEMPLATE ━ block (paths, epoch, frontmatter spec)
MAIN  ✎ copies the template verbatim into the Agent tool's `prompt` argument
SUB   ▶ workflow-executor (opus) runs:
        └─ reads agents/workflow-executor.md (its own protocol)
        └─ reads note-app-planning-report.md
        └─ implements the plan → writes source files
        └─ writes note-app-executing-report.md  (epoch: 2, result: done)
MAIN  ◀ subagent returns
MAIN  ▶ runs: scripts/update-status.sh --status verifying
        └─ epoch 2 → 3, status: verifying, deletes verifying-report
```

### Stage 2.5 — verifying  (uninterruptible, inline)

```
MAIN  ► reads stages/verifying.md
MAIN  ► detects test command (e.g. package.json → `npm test`)
MAIN  ▶ runs: npm test  (3-min timeout)
MAIN  ✎ writes note-app-verifying-report.md  (epoch: 3, result: PASS)
MAIN  ▶ runs: scripts/update-status.sh --status reviewing
        └─ epoch 3 → 4, status: reviewing, deletes reviewing-report
```

_If tests had failed: `update-status.sh --status executing` loops back; the next executing pass reads this verifying report as optional "quick-test failures" feedback._

### Stage 3 — reviewing  (uninterruptible, subagent)

```
MAIN  ► reads stages/reviewing.md
MAIN  ► calls Agent tool → agent-guard fires → transcribe template
SUB   ▶ workflow-reviewer runs:
        └─ diffs HEAD against .dev-workflow/note-app-baseline
        └─ reviews against the plan
        └─ writes note-app-reviewing-report.md  (epoch: 4, result: PASS)
MAIN  ▶ runs: scripts/update-status.sh --status qa-ing
        └─ epoch 4 → 5, status: qa-ing, deletes qa-ing-report
```

_On `result: FAIL`: loop back to `executing`; executor receives reviewing-report as optional feedback._

### Stage 3.5 — qa-ing  (uninterruptible, subagent)

```
MAIN  ► reads stages/qa-ing.md
MAIN  ► calls Agent tool → agent-guard fires → transcribe template
SUB   ▶ workflow-qa runs:
        └─ runs journey tests (Playwright / XcodeBuildMCP / …)
        └─ classifies failures (test bug vs app bug)
        └─ writes note-app-qa-ing-report.md  (epoch: 5, result: PASS)
MAIN  ▶ runs: scripts/update-status.sh --status complete
        └─ status: complete (terminal)
```

_On `result: FAIL`: loop back to `executing`; confirmed app bugs become the next iteration's optional QA feedback._

### Termination

```
MAIN  ► next turn-end → stop-hook fires
        └─ sees status: complete (terminal)
        └─ deletes .dev-workflow/state.md
        └─ exit allowed
MAIN  ● announces: "Dev workflow complete. All changes reviewed and QA-passed."
```

### Safety net: stop-hook during the loop

The stop hook fires at every Claude turn-end. It reads `state.md` and the current stage's artifact:

| Situation | stop-hook behaviour |
|-----------|--------------------|
| Uninterruptible stage, artifact missing or stale epoch | **Blocks exit** — re-injects "execute the stage" prompt |
| Uninterruptible stage, artifact `result:` matches a transition key | **Blocks exit** — re-injects "call update-status.sh --status &lt;next&gt;" |
| Uninterruptible stage, artifact `result:` unrecognised | **Blocks exit** — asks for manual inspection |
| Interruptible stage | **Never blocks** — emits a `systemMessage` status hint |
| Status is terminal (`complete` / `escalated`) | Deletes state.md, allows exit |
| Status is `interrupted` | Allows exit; keeps state.md for `/dev-workflow:continue` |

## Configuration

### Per-workflow config (`workflow.json`)

The plugin ships with a 5-stage default workflow. Edit `workflow.json` at the plugin root to customize:

- **`stages.*.interruptible`** — `true` to let the stop hook allow session exits during the stage
- **`stages.*.execution`** — `{ "type": "inline" }` or `{ "type": "subagent", "subagent_type": "…", "model": "…" }`
- **`stages.*.transitions`** — map of `result:` values to next status
- **`stages.*.inputs.required` / `optional`** — declare which other stages' artifacts this stage reads; required artifacts are enforced by `update-status.sh`

### General settings

| Setting | Default | Description |
|---------|---------|-------------|
| Plan / state directory | `.dev-workflow/` | Stage reports, baseline, state.md |
| State file | `.dev-workflow/state.md` | Current status + epoch (auto-managed) |
| Loop | Infinite | Stops only on terminal status, interrupt, or cancel |

## Project Setup

Add `.dev-workflow/` to your project's `.gitignore`:

```bash
echo '/.dev-workflow/' >> .gitignore
```

Workflow artifacts persist in `.dev-workflow/` after completion. Clean up when no longer needed:

```bash
rm -rf .dev-workflow/
```

## License

MIT
