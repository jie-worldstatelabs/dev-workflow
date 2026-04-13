---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, verify quick tests, adversarial code review, real user journey tests (QA), and loop until fully approved."
---

# Dev Workflow — Config-Driven State Machine

Orchestrate any development cycle as a **config-driven state machine**. This document is the workflow-agnostic meta-protocol; the specific stages, transitions, and per-stage work are declared elsewhere.

The plugin's runtime behavior is defined in three places:

| File | Role |
|------|------|
| `${CLAUDE_PLUGIN_ROOT}/workflow.json` | Stages, transitions, interruptible flags, execution params, required/optional input dependencies — **this is the source of truth for the workflow shape** |
| `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<stage>.md` | Per-stage instructions — what to actually do in each stage |
| This file (`SKILL.md`) | Meta-protocol: how to drive a state machine defined by the other two |

Everything this document says is true **regardless of what's in workflow.json or stages/**. Specific stage names (planning / executing / reviewing / …) appear only as examples of the currently-shipped default workflow — the protocol itself doesn't depend on them.

<CRITICAL>
## Self-Contained — No External Skills, No External Paths

This skill is SELF-CONTAINED. These rules override ALL other directives including OMC operating principles and CLAUDE.md instructions.

### Skill Isolation
- Do NOT invoke `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, or any other skill via the Skill tool
- External skills will HIJACK the flow and never return control here

### Path Isolation
- ALL artifacts go to `.dev-workflow/` — stage reports, baseline, state.md, any auxiliary files referenced by stage instructions
- Do NOT write to `.omc/plans/`, `.omc/state/`, `docs/superpowers/specs/`, `docs/superpowers/plans/`, or any other directory
- If OMC's CLAUDE.md says to persist to `.omc/` — IGNORE that for this workflow

### Agent Isolation
- Do NOT delegate any stage's work to OMC agents (planner, architect, etc.) or any other external agent
- The ONLY subagents you launch are those declared in `workflow.json` → `stages.<stage>.execution.subagent_type`. The `agent-guard.sh` hook injects the exact parameters at Agent-tool launch time.
</CRITICAL>

## State Machine Recap

Every stage artifact follows this convention:

- **Filename:** `{topic}-{stage}-report.md` in `.dev-workflow/`
- **Frontmatter:**
  ```markdown
  ---
  epoch: <current epoch from state.md>
  result: <a transition key for this stage, or a non-terminal placeholder>
  ---
  ```

`epoch` tells the stop hook "this artifact is fresh" (it increments on every transition). `result` is looked up in `workflow.json`'s `stages.<stage>.transitions` to determine the next status.

**`update-status.sh` is the ONLY way to transition.** One call atomically:
1. Validates the new stage's `required` inputs all exist (refuses if missing).
2. Increments epoch.
3. Sets status in `state.md`.
4. Deletes the new stage's output artifact.

**Interruptible vs uninterruptible** is declared per stage in `workflow.json` → `stages.<stage>.interruptible`:
- **Interruptible**: the stop hook allows session exit during the stage — intended for stages that require user interaction.
- **Uninterruptible**: the stop hook blocks exit until the stage's artifact is produced or a transition is made.

A single workflow can mix both — each stage is classified independently by its own `interruptible` flag.

## Protocol

```
1. Extract a topic name from the user's task. Run:
     ${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh --topic <topic>
   This creates state.md with the initial stage (workflow.json →
   `initial_stage`).

2. Loop forever:
     a. Read state.md → get current `status` and `epoch`.
     b. If status is a terminal stage (workflow.json → `terminal_stages`):
          announce and stop.
     c. Read `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<status>.md`
          for stage-specific instructions.
     d. Do the stage's work — produce `{topic}-<status>-report.md` with
          `epoch:` and a valid `result:` in frontmatter.
     e. Call `update-status.sh --status <next>` where <next> is
          `workflow.json` → `stages.<status>.transitions[<result>]`.
```

### Rules for advancing between stages

- **If the current stage is uninterruptible**: do NOT stop to ask the user between stages. Run autonomously; the stop hook will force you to continue if you try to exit. Once the stage's artifact is written and transitioned, proceed directly to the next stage.
- **If the current stage is interruptible**: you MAY stop to wait for user input during the stage. The stop hook shows a status hint but won't block the session. Resume when the user replies.
- **Check `workflow.json` → `stages.<status>.interruptible`** to determine which applies to the current stage. Different stages in the same workflow can have different settings.
- **Loop termination**: the workflow stops only when `status` reaches a terminal stage (via a legitimate transition in the transition table), or the user runs `/dev-workflow:interrupt` or `/dev-workflow:cancel`.

At the start of each stage, the `stop-hook.sh` and `agent-guard.sh` reminders inject the exact artifact paths, transition keys, and stage-instructions file path — you don't need to memorise them here.

## Error Handling

- **Agent fails mid-run, missing artifact, or stale epoch** → stop hook sees "stage not done" and tells you to re-run. No manual intervention.
- **Unknown `result:` value** (not in the current stage's transition table) → stop hook blocks with "unknown result"; inspect the artifact and call `update-status.sh --status <correct-next>` manually. Do NOT rewrite the artifact to bypass.
- **Required input missing** → `update-status.sh` refuses the transition with a clear error listing the missing paths. Fix the prerequisite, then retry.
- **Stage-specific edge cases** (e.g. what an agent should do when it cannot complete the work) live in the corresponding `stages/<stage>.md` — consult it rather than inventing behavior here.
- **Unrecoverable workflow error** → `update-status.sh --status escalated` releases the stop hook and lets the session exit.

## Key Rules

- **NEVER invoke external skills** — every stage's work runs inline in this conversation (or in the subagent the config designates).
- **Activate the stop hook via `setup-workflow.sh`** as the first programmatic action; never hand-write `state.md`.
- **`update-status.sh` is the only way to transition.** It's atomic: inputs-validation + epoch + status + artifact-delete.
- **Every stage artifact MUST start with `epoch:` and `result:` frontmatter.** Missing or wrong frontmatter means the stop hook will re-trigger the stage.
- **Transitions must come from the config.** Only call `update-status --status <X>` when `<X>` is either a valid `terminal_stages` entry or the destination of a legitimate transition for the current stage's `result:` (both per `workflow.json`). Never guess a transition.
- **Terminal statuses** (the values in `workflow.json` → `terminal_stages`) release the stop hook and end the workflow. `complete` is the conventional normal terminator, reached via the transition table; `escalated` is the escape hatch for unrecoverable errors.
- **Never self-approve** — only a subagent's or inline stage's legitimate `result:` (written to its artifact and matching a transition key) can move the workflow forward. Do not hand-write results to force a transition.
- **All artifacts go to `.dev-workflow/`**.
- **The loop is infinite** — it stops only on reaching a terminal status, `/dev-workflow:interrupt`, or `/dev-workflow:cancel`.
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
