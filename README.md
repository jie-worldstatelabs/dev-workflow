# dev-workflow

A Claude Code plugin that orchestrates a complete development cycle as a **config-driven state machine**: **plan → execute → verify → review → QA → loop**.

Runs in two modes — **local** (files live under `<project>/.dev-workflow/`, no server) or **cloud** (state mirrored to a hosted Next.js + Postgres webapp with a live browser viewer, cross-machine resume, and zero project-dir footprint). The state-machine protocol is identical; cloud mode is just "where do the files live". For the full cloud deep-dive plus operator guide see the **[workflowUI README](https://github.com/jie-worldstatelabs/workflowUI)**.

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

### Cloud mode (default)

```
/dev-workflow:dev Build a REST API with user authentication
/dev-workflow:dev Fix the race condition in the payment processing module
/dev-workflow:dev Add dark mode support to the dashboard
```

The setup script prints a line like:

```
UI: https://workflows.worldstatelabs.com/s/2056c1dc-6009-4094-8260-4f937f23903c
```

Paste that URL in any browser to watch the stage timeline, rendered markdown artifacts, and `git diff baseline..HEAD` update live via SSE. The project worktree gets **nothing** under `.dev-workflow/` — a transient shadow at `~/.cache/dev-workflow/sessions/<session_id>/` backs Claude's filesystem tools and is wiped on any terminal status. Authoritative state lives on the server, so you can resume from a different machine with `/dev-workflow:continue --session <id>`.

### Local mode (opt-out)

For fully offline / no-infra runs, opt out of cloud mode in one of two ways:

```
/dev-workflow:dev --mode=local Build a REST API with user authentication
```

```bash
# or flip the default for your whole shell
export DEV_WORKFLOW_DEFAULT_MODE=local
```

In local mode, state and stage reports go under `<project>/.dev-workflow/<session_id>/` and nothing touches the network.

### Control commands

```
/dev-workflow:interrupt                — pause at the current phase (state preserved)
/dev-workflow:continue                 — resume from where it was interrupted
/dev-workflow:continue --session <id>  — cross-machine takeover (cloud only)
/dev-workflow:cancel                   — cancel and archive
/dev-workflow:cancel --hard            — cancel and wipe
```

`/dev-workflow:continue --session <id>` on a machine that has never seen this cloud session pulls the full snapshot (state + artifacts + workflow config + baseline) from the server and verifies the current `pwd` is the same git project via root-commit fingerprint. On match with a different absolute path, `project_root` auto-updates so downstream `git diff` operations use the right working copy. On mismatch it exits with a clear error — `--force-project-mismatch` overrides.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) CLI
- `jq` (standard on macOS; `apt install jq` on Linux)

## Architecture

```
commands/
  dev.md                 ← /dev-workflow:dev entry point (passes $ARGUMENTS to the skill)
  interrupt.md           ← /dev-workflow:interrupt to pause (state preserved)
  continue.md            ← /dev-workflow:continue to resume
  cancel.md              ← /dev-workflow:cancel to abort and clear state
agents/
  workflow-subagent.md   ← Single generic stage executor; reads the active stage's instructions file and follows that protocol (replaces the old per-stage workflow-executor / reviewer / qa agents)
skills/
  dev-workflow/
    SKILL.md             ← Meta-protocol: how to drive the state machine (workflow-agnostic)
    workflow/            ← Default workflow package (config + stage instructions)
      workflow.json      ← State machine shape: stages, transitions, inputs, execution params
      planning.md        ← Per-stage instructions — planning stage
      executing.md       ← …executing stage
      verifying.md       ← …verifying stage
      reviewing.md       ← …reviewing stage
      qa-ing.md          ← …qa-ing stage
    (alt-workflow/)      ← Optional: sibling dirs for alternate workflows
                           (select via --workflow=<name>)
hooks/
  hooks.json             ← Hook wiring (SessionStart, Stop, PreToolUse:Agent, PostToolUse:Write|Edit|MultiEdit)
  session-start.sh       ← Caches the Claude session_id so scripts can find their own run dir
  stop-hook.sh           ← Generic state-machine controller driven by workflow.json
  agent-guard.sh         ← Templates agent prompts from config at Agent-tool launch
  postwrite-hook.sh      ← Cloud-mode only: mirrors shadow-dir writes to the server via curl
scripts/
  lib.sh                 ← Shared helpers: config reader, state routing, cloud helpers (is_cloud_session, cloud_pull_shadow, verify_project_match, git_project_fingerprint, cloud_post_*)
  setup-workflow.sh      ← Creates state.md (--topic, --workflow, --mode local|cloud, --force, --validate-only)
  update-status.sh       ← The only legal way to transition; in cloud mode also mirrors state + triggers cloud_post_diff; wipes shadow on terminal status
  interrupt-workflow.sh  ← Pauses without clearing state; mirrors interrupt to server in cloud mode
  continue-workflow.sh   ← Resumes interrupted runs; with --session does cross-machine cloud takeover; verifies project identity via root-commit fingerprint
  cancel-workflow.sh     ← Archives local runs to .archive/; cloud runs POST cancel + wipe shadow + unregister
```

Runtime files (in the user's project). Rule: **one Claude session = one run**. Each session's run lives in its own session-keyed subdir, so multiple Claude sessions in the same worktree can run independent workflows without interfering. Completed or replaced runs are archived, not deleted.

```
<project>/.dev-workflow/
  <session_id>/                        ← one subdir per Claude session's run
    state.md                           ← status, epoch, topic, session_id, worktree, workflow_dir
    baseline                           ← git SHA at workflow start
    planning-report.md                 ← one file per stage; frontmatter carries epoch+result
    executing-report.md
    verifying-report.md
    reviewing-report.md
    qa-ing-report.md
    journey-tests.md                   ← cross-iteration QA state (optional)
  .archive/
    <YYYYMMDD-HHMMSS>-<topic>/                 ← natural-replace archive (new setup in same session)
    <YYYYMMDD-HHMMSS>-<topic>-cancelled/       ← soft /dev-workflow:cancel archive
```

For parallel independent workflows in one project, just open a second Claude Code session — its session_id becomes a sibling subdir and the two runs don't interact. Sidecar "observer" sessions in the same worktree are never blocked by another session's stop hook.

**Cloud mode layout** (runtime files live outside the project; the authoritative copy is the server):

```
~/.cache/dev-workflow/sessions/
  <session_id>/                        ← shadow — wiped on any terminal status
    state.md                           ← local mirror; server row is authoritative
    baseline                           ← git SHA
    planning-report.md                 ← Claude's Read/Write tools need real paths
    executing-report.md                  for the skill protocol, so we keep a
    verifying-report.md                  transient scratch dir out of the worktree
    reviewing-report.md
    qa-ing-report.md
    .workflow-cache/                   ← fetched from server://<name> or http(s)://…
      workflow.json
      planning.md
      executing.md
      …

~/.dev-workflow/cloud-registry/
  <session_id>.json                    ← single flag — existence ⇒ cloud mode
```

The registry file is what every hook and script uses to decide "local or cloud". One 2-line helper (`is_cloud_session <sid>`) in `lib.sh` checks file existence, nothing else. No env var, no state field, no global.

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
- **Artifact naming** is uniform: `<session_id>/<stage>-report.md`.

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
        └─ writes .dev-workflow/<session_id>/state.md  (status: planning, epoch: 1)
        └─ writes .dev-workflow/<session_id>/baseline  = HEAD SHA
        └─ prints planning's I/O context to stdout:
            · Required inputs: (none)
            · Optional inputs: (none)
            · Output: .dev-workflow/<session_id>/planning-report.md
MAIN  ◀ proceeds to the planning stage
```

_From here, `stop-hook` fires on every session-stop attempt; `agent-guard` fires on every Agent-tool call._

### Stage 1 — planning  (interruptible, inline)

```
MAIN  ► reads stages/planning.md
MAIN  ► reads inputs from workflow.json → stages.planning.inputs
        · Required: (none)
        · Optional: (none)
MAIN  ⇄ Q&A loop with user:
        - each turn-end → stop-hook fires
          └─ planning is interruptible → emits systemMessage hint, does NOT block
          └─ session exits cleanly, resumes when user replies
MAIN  ✎ writes <session_id>/planning-report.md  (epoch: 1, result: pending)
USER  ► approves
MAIN  ✎ edits report frontmatter  (result: pending → approved)
MAIN  ▶ runs: scripts/update-status.sh --status executing
        └─ validates executing's required inputs:
            · <session_id>/planning-report.md  ✓
        └─ bumps epoch 1 → 2, sets status: executing
        └─ deletes <session_id>/executing-report.md  (clean slate; file didn't exist)
        └─ prints executing's I/O context:
            · Required: <session_id>/planning-report.md
            · Optional: <session_id>/{reviewing,qa-ing,verifying}-report.md (from previous iteration)
            · Output: <session_id>/executing-report.md
```

### Stage 2 — executing  (uninterruptible, subagent)

```
MAIN  ► reads stages/executing.md
MAIN  ► calls Agent tool
        └─ PreToolUse: agent-guard.sh fires in MAIN's context
            └─ prints ⚠️ "hook output is visible only to main — you MUST transcribe"
            └─ prints ━ PROMPT TEMPLATE ━ block (paths, epoch, frontmatter spec)
MAIN  ✎ copies the template verbatim into the Agent tool's `prompt` argument
SUB   ▶ workflow-subagent (opus, per workflow.json.stages.executing.execution.model) runs:
        └─ reads skills/dev-workflow/workflow/executing.md (the stage protocol)
        └─ reads required input:
            · <session_id>/planning-report.md  (plan)
        └─ reads optional inputs (skip if file absent):
            · <session_id>/reviewing-report.md   (first iteration: absent)
            · <session_id>/qa-ing-report.md      (first iteration: absent)
            · <session_id>/verifying-report.md   (first iteration: absent)
        └─ implements the plan → writes source files
        └─ writes <session_id>/executing-report.md  (epoch: 2, result: done)
MAIN  ◀ subagent returns
MAIN  ▶ runs: scripts/update-status.sh --status verifying
        └─ validates verifying's required inputs: (none) ✓
        └─ bumps epoch 2 → 3, sets status: verifying
        └─ deletes <session_id>/verifying-report.md  (clean slate)
        └─ prints verifying's I/O context:
            · Required: (none)
            · Optional: (none)
            · Output: <session_id>/verifying-report.md
```

### Stage 2.5 — verifying  (uninterruptible, inline)

```
MAIN  ► reads stages/verifying.md
MAIN  ► reads inputs from workflow.json → stages.verifying.inputs
        · Required: (none)
        · Optional: (none)
MAIN  ► detects test command (e.g. package.json → `npm test`)
MAIN  ▶ runs: npm test  (3-min timeout)
MAIN  ✎ writes <session_id>/verifying-report.md  (epoch: 3, result: PASS)
MAIN  ▶ runs: scripts/update-status.sh --status reviewing
        └─ validates reviewing's required inputs:
            · <session_id>/planning-report.md   ✓
            · <session_id>/executing-report.md  ✓
            · <session_id>/verifying-report.md  ✓
        └─ bumps epoch 3 → 4, sets status: reviewing
        └─ deletes <session_id>/reviewing-report.md  (clean slate)
        └─ prints reviewing's I/O context:
            · Required: planning, executing, verifying reports
            · Optional: <session_id>/qa-ing-report.md (previous iteration; first time: absent)
            · Output: <session_id>/reviewing-report.md
```

_If tests had failed: `update-status.sh --status executing` loops back; the next executing pass reads this verifying report as optional "quick-test failures" feedback._

### Stage 3 — reviewing  (uninterruptible, subagent)

```
MAIN  ► reads stages/reviewing.md
MAIN  ► calls Agent tool → agent-guard fires → MAIN transcribes PROMPT TEMPLATE
SUB   ▶ workflow-subagent (sonnet) runs:
        └─ reads skills/dev-workflow/workflow/reviewing.md (the stage protocol)
        └─ reads required inputs:
            · <session_id>/planning-report.md   (plan to review against)
            · <session_id>/executing-report.md  (what the executor did)
            · <session_id>/verifying-report.md  (test results)
            · <session_id>/baseline              (git SHA for diff)
        └─ reads optional input:
            · <session_id>/qa-ing-report.md      (first iteration: absent)
        └─ diffs HEAD against baseline
        └─ writes <session_id>/reviewing-report.md  (epoch: 4, result: PASS)
MAIN  ▶ runs: scripts/update-status.sh --status qa-ing
        └─ validates qa-ing's required inputs:
            · <session_id>/planning-report.md  ✓
        └─ bumps epoch 4 → 5, sets status: qa-ing
        └─ deletes <session_id>/qa-ing-report.md  (clean slate)
        └─ prints qa-ing's I/O context:
            · Required: <session_id>/planning-report.md
            · Optional: (none)
            · Output: <session_id>/qa-ing-report.md
```

_On `result: FAIL`: loop back to `executing`; executor receives reviewing-report as optional feedback._

### Stage 3.5 — qa-ing  (uninterruptible, subagent)

```
MAIN  ► reads stages/qa-ing.md
MAIN  ► calls Agent tool → agent-guard fires → MAIN transcribes PROMPT TEMPLATE
SUB   ▶ workflow-subagent (sonnet) runs:
        └─ reads skills/dev-workflow/workflow/qa-ing.md (the stage protocol)
        └─ reads required input:
            · <session_id>/planning-report.md  (journey test spec)
        └─ reads optional inputs: (none declared)
        └─ reads/updates <session_id>/journey-tests.md  (cross-iteration QA state)
        └─ runs journey tests (Playwright / XcodeBuildMCP / …)
        └─ classifies failures (test bug vs app bug)
        └─ writes <session_id>/qa-ing-report.md  (epoch: 5, result: PASS)
MAIN  ▶ runs: scripts/update-status.sh --status complete
        └─ `complete` is a terminal stage:
            · no required-input validation
            · no artifact deletion
            · no I/O context print
        └─ bumps epoch 5 → 6, sets status: complete
```

_On `result: FAIL`: loop back to `executing`; confirmed app bugs become the next iteration's optional QA feedback._

### Termination

```
MAIN  ► next turn-end → stop-hook fires
        └─ sees status: complete (terminal)
        └─ deletes .dev-workflow/<session_id>/state.md
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

### Per-workflow config (`<workflow-dir>/workflow.json`)

A workflow is a directory that bundles `workflow.json` + one `<stage>.md` per stage. The plugin ships a 5-stage default at `skills/dev-workflow/workflow/`. Customize that workflow in-place, or copy the directory to `skills/dev-workflow/<my-workflow>/`, edit to taste, and select it at setup time:

```
/dev-workflow:dev --workflow=my-workflow Build X
# → setup-workflow.sh --topic=X --workflow=my-workflow
# → state.md workflow_dir = ${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/my-workflow
```

`workflow.json` fields:

- **`initial_stage`** — status written into state.md at setup
- **`terminal_stages`** — list of values that release the stop hook and end the workflow
- **`stages.*.interruptible`** — `true` to let the stop hook allow session exits during the stage
- **`stages.*.execution`** — `{ "type": "inline" }` or `{ "type": "subagent" }` (optionally `{ "type": "subagent", "model": "opus" }` to override the subagent's default model). A single generic `dev-workflow:workflow-subagent` runs every subagent stage; the per-stage protocol lives in `<workflow-dir>/<stage>.md`, which the subagent reads at runtime. Per-stage `subagent_type` is NOT supported (the validator rejects it).
- **`stages.*.transitions`** — map of `result:` values to next status
- **`stages.*.inputs.required` / `optional`** — declare which other stages' artifacts this stage reads; required artifacts are enforced by `update-status.sh`

### General settings

| Setting | Default | Description |
|---------|---------|-------------|
| Plan / state directory | `.dev-workflow/<session_id>/` (local) · `~/.cache/dev-workflow/sessions/<session_id>/` (cloud shadow) | Stage reports, baseline, state.md |
| State file | `<run-dir>/state.md` | Current status + epoch (auto-managed) |
| Loop | Infinite | Stops only on terminal status, interrupt, or cancel |

## Cloud Mode

Cloud mode mirrors every workflow file to a hosted Next.js + Postgres webapp so you can watch progress in a browser, share session URLs, and pick up a run from a different machine. The state-machine protocol is unchanged — you're running the same stages, producing the same artifacts, calling the same `update-status.sh`. The only difference is where the files live and who's authoritative.

### When to use it

- Want a **live browser UI** showing the stage timeline + rendered artifacts + working-tree diff, updated via SSE
- Want to **continue a run from another machine** (`/dev-workflow:continue --session <id>`)
- Want **zero workspace pollution** — nothing under `<project>/.dev-workflow/`, nothing to gitignore
- OK with a hosted or self-hosted webapp being the authoritative store

### What's different in cloud mode

| Concern | Local | Cloud |
|---|---|---|
| Authoritative state | `<project>/.dev-workflow/<session>/state.md` | Postgres `sessions` row; local shadow is a write-through mirror |
| Artifact storage | `<project>/.dev-workflow/<session>/<stage>-report.md` | Postgres `artifacts` table (append-only history); local shadow mirrors the latest |
| Where the files live on your disk | Project worktree | `~/.cache/dev-workflow/sessions/<session>/` — out of the worktree, wiped on terminal |
| Live viewer | None — read the files | `https://workflowui.vercel.app/s/<session_id>` |
| Cross-machine continue | Not supported | `/dev-workflow:continue --session <id>` with project-fingerprint verification |
| Project identity check | N/A | Root-commit fingerprint comparison (`git rev-list --max-parents=0 HEAD`) before resume |
| User env vars needed | None | None (server URL baked in; override with `DEV_WORKFLOW_SERVER`) |

### Workflow source (`--workflow`)

Same flag as local mode, with two cloud-specific forms:

| Form | Meaning | Forces cloud? |
|---|---|---|
| *(omitted)* | Bundled default at `skills/dev-workflow/workflow/` | — |
| `<bare-name>` | Bundled at `skills/dev-workflow/<name>/`; cloud fallback to a named server template | — |
| `/abs/path` or `./rel/path` | Local workflow directory (copied into shadow in cloud mode) | — |
| `server://<name>` | Fetched from `GET /api/workflows/<name>` on the workflowUI server | **yes** |
| `http(s)://…` | Remote dir that serves `workflow.json` + one `<stage>.md` per stage key | **yes** |

### Pointing at a self-hosted server

`DEV_WORKFLOW_SERVER` defaults to `https://workflowui.vercel.app`. Override per-shell:

```bash
export DEV_WORKFLOW_SERVER=https://your-self-hosted-workflowui.example.com
```

### Deep dive

The **[workflowUI README](https://github.com/jie-worldstatelabs/workflowUI)** has the full cloud architecture (write-through mirror table, SSE via Postgres LISTEN/NOTIFY, cross-machine protocol, API reference, database schema, server-operator deploy guide, and troubleshooting).

## Project Setup

**Local mode**: add `.dev-workflow/` to your project's `.gitignore`:

```bash
echo '/.dev-workflow/' >> .gitignore
```

Workflow artifacts persist in `.dev-workflow/` after completion. Clean up when no longer needed:

```bash
rm -rf .dev-workflow/
```

**Cloud mode**: nothing to do. The project worktree never sees a `.dev-workflow/` directory, and the shadow at `~/.cache/dev-workflow/sessions/<session>/` is wiped automatically on `/dev-workflow:cancel` or any terminal status. To manually clean up an interrupted-but-abandoned cloud session, either hit the server's cancel endpoint or just `rm -rf ~/.cache/dev-workflow/sessions/<session_id>/` plus `rm -f ~/.dev-workflow/cloud-registry/<session_id>.json`.

## License

MIT
