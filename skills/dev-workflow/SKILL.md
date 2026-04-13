---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, verify quick tests, adversarial code review, real user journey tests (QA), and loop until fully approved."
---

# Dev Workflow — Plan, Execute, Review, Loop

Orchestrate a complete development cycle as a **config-driven state machine**.

The plugin's runtime behavior is defined in three places — this file describes the meta-protocol; the other two are the source of truth for structure and per-stage work:

| File | Role |
|------|------|
| `${CLAUDE_PLUGIN_ROOT}/workflow.json` | Stages, transitions, interruptible flags, execution params, required/optional input dependencies |
| `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<stage>.md` | Per-stage instructions — what to actually do in each stage |
| This file (`SKILL.md`) | Meta-protocol: how to drive the state machine from stage to stage |

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
- Their exact parameters are injected by `agent-guard.sh` at Agent-tool launch time
</CRITICAL>

## State Machine Recap

Every stage artifact follows this convention:

- **Filename:** `{topic}-{stage}-report.md` in `.dev-workflow/`
- **Frontmatter:**
  ```markdown
  ---
  epoch: <current epoch from state.md>
  result: <a transition key for this stage, or a non-terminal placeholder like "pending">
  ---
  ```

`epoch` tells the stop hook "this artifact is fresh" (it increments on every transition). `result` is looked up in `workflow.json`'s `stages.<stage>.transitions` to determine the next status.

**`update-status.sh` is the ONLY way to transition.** One call atomically:
1. Validates the new stage's `required` inputs all exist (refuses if missing).
2. Increments epoch.
3. Sets status in `state.md`.
4. Deletes the new stage's output artifact.

**Interruptible vs uninterruptible stages:**
- **Interruptible** (see `workflow.json` → `interruptible: true`): the stop hook allows session exit during the stage — used for user-interactive stages like `planning`.
- **Uninterruptible** (default): the stop hook blocks exit until the stage's artifact is produced or a transition is made.

## Protocol

```
1. Extract a topic name from the user's task. Run:
     ${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh --topic <topic>
   This creates state.md with the initial stage (see workflow.json →
   `initial_stage`; default: `planning`).

2. Loop forever:
     a. Read state.md → get current `status` and `epoch`.
     b. If status is a terminal stage (see workflow.json → `terminal_stages`):
          announce and stop.
     c. Read `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<status>.md`
          for stage-specific instructions.
     d. Do the stage's work — produce `{topic}-<status>-report.md` with
          `epoch:` and a valid `result:` in frontmatter.
     e. Call `update-status.sh --status <next>` where <next> is
          `workflow.json` → `stages.<status>.transitions[<result>]`.
```

For the uninterruptible loop (execute → verify → review → QA), run autonomously — do NOT stop to ask the user between stages. Only `/dev-workflow:interrupt` or `/dev-workflow:cancel` stops the loop.

At the start of each stage, the `stop-hook.sh` / `agent-guard.sh` reminders will tell you the exact artifact paths and transition keys for this stage — you don't need to memorise them.

## Error Handling

- **Agent fails mid-run, missing artifact, or stale epoch** → stop hook sees "stage not done" and tells you to re-run. No manual intervention.
- **Unknown `result:` value** (not in the stage's transition table) → stop hook blocks with "unknown result"; inspect the artifact and call `update-status.sh --status <correct-next>`. Do NOT rewrite the artifact to bypass.
- **Required input missing** → `update-status.sh` refuses the transition with a clear error listing the missing paths. Fix the prerequisite, then retry.
- **Executor hits an unrecoverable implementation issue** → still write the `executing-report.md` with `result: done` and document the problem in the body; verifying will surface it via failing tests.
- **Unrecoverable workflow error** → `update-status.sh --status escalated` releases the stop hook and lets the session exit.

## Key Rules

- **NEVER invoke external skills** — all phases are handled inline.
- **Activate the stop hook via `setup-workflow.sh`** as the first programmatic action; never hand-write `state.md`.
- **`update-status.sh` is the only way to transition.** It's atomic: inputs-validation + epoch + status + artifact-delete.
- **Every stage artifact MUST start with `epoch:` and `result:` frontmatter.** Missing or wrong frontmatter means the stop hook will re-trigger the stage.
- **Terminal statuses** (`complete` / `escalated`) release the stop hook. `complete` is the normal terminator after `qa-ing:PASS`; `escalated` is the escape hatch.
- **Never self-approve** — only the reviewer's and QA agent's `result: PASS` can drive the workflow to `complete`.
- **All artifacts go to `.dev-workflow/`**.
- **The loop is infinite** — stops only on QA's `result: PASS`, `/dev-workflow:interrupt`, or `/dev-workflow:cancel`.
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
