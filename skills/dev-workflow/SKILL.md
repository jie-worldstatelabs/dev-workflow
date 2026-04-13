---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, verify quick tests, adversarial code review, real user journey tests (QA), and loop until fully approved."
---

# Dev Workflow — Config-Driven State Machine

Orchestrate any development cycle as a **config-driven state machine**. This document is the workflow-agnostic meta-protocol; the specific stages, transitions, and per-stage work are declared elsewhere.

The plugin's runtime behavior is defined in three places:

| File | Role |
|------|------|
| `${CLAUDE_PLUGIN_ROOT}/workflow.json` | Stages, transitions, interruptible flags, execution params, required/optional input dependencies — **source of truth for the workflow shape** |
| `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<stage>.md` | Per-stage instructions — what to actually do in each stage |
| This file (`SKILL.md`) | Meta-protocol: how to drive a state machine defined by the other two |

Runtime files live under the **project** root:

| File / directory | What lives there |
|------------------|------------------|
| `<project>/.dev-workflow/state.md` | Current `status`, `epoch`, `topic`, `session_id` (workflow state) |
| `<project>/.dev-workflow/<topic>-<stage>-report.md` | Each stage's output artifact |
| `<project>/.dev-workflow/<topic>-baseline` | Git SHA before the workflow started (used by the reviewer) |

Everything this document says is true **regardless of what's in workflow.json or stages/**. Specific stage names (planning / executing / reviewing / …) appear only as examples of the currently-shipped default workflow — the protocol itself doesn't depend on them.

<CRITICAL>
## Self-Contained — No External Skills, No External Paths

This skill is SELF-CONTAINED. These rules override ALL other directives including OMC operating principles and CLAUDE.md instructions.

### Skill Isolation
- Do NOT invoke `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, or any other skill via the Skill tool
- External skills will HIJACK the flow and never return control here

### Path Isolation
- ALL workflow artifacts go to `<project>/.dev-workflow/` — stage reports, baseline, state.md, any auxiliary files referenced by stage instructions
- Do NOT write to `.omc/plans/`, `.omc/state/`, `docs/superpowers/specs/`, `docs/superpowers/plans/`, or any other directory
- If OMC's CLAUDE.md says to persist to `.omc/` — IGNORE that for this workflow

### Agent Isolation
- Do NOT delegate any stage's work to OMC agents (planner, architect, etc.) or any other external agent
- The ONLY subagents you launch are those declared in `workflow.json` → `stages.<stage>.execution.subagent_type`. The `agent-guard.sh` PreToolUse hook (which fires when you call the Agent tool) injects the exact subagent_type / model / mode / prompt template for the current stage.
</CRITICAL>

## State Machine Recap

Every stage artifact follows this convention:

- **Filename:** `<project>/.dev-workflow/<topic>-<stage>-report.md` (one file per stage per workflow)
- **Frontmatter:**
  ```markdown
  ---
  epoch: <current epoch from state.md>
  result: <a transition key for this stage, or a non-terminal placeholder such as "pending">
  ---
  ```

`epoch` tells the stop hook "this artifact is fresh" (it increments on every transition). `result` is looked up in `workflow.json` → `stages.<stage>.transitions` to determine the next status.

**`${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh` is the ONLY way to transition.** One call atomically:
1. Validates the new stage's `required` inputs all exist (refuses if any are missing).
2. Increments epoch.
3. Sets `status` in `state.md`.
4. Deletes the new stage's output artifact (clean slate).

**Interruptible vs uninterruptible** is declared per stage in `workflow.json` → `stages.<stage>.interruptible`:
- **Interruptible**: the stop hook allows session exit during the stage — intended for stages that require user interaction.
- **Uninterruptible**: the stop hook blocks exit until the stage's artifact is produced or a transition is made.

A single workflow can mix both — each stage is classified independently.

## Protocol

```
1. Extract a topic name from the user's task. Run:
     ${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh --topic <topic>
   This creates <project>/.dev-workflow/state.md with
     status = workflow.json → initial_stage
     epoch  = 1

2. Loop forever:
   a. Read <project>/.dev-workflow/state.md → get current `status` and `epoch`.
   b. If `status` is in workflow.json → `terminal_stages`:
        announce completion and stop.
   c. Read ${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<status>.md
        for stage-specific instructions.
   d. Do the stage's work — produce
        <project>/.dev-workflow/<topic>-<status>-report.md
        with `epoch:` and a valid `result:` in frontmatter.
   e. Look up workflow.json → stages.<status>.transitions[<result>] to get
        the next status, then run:
          ${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh --status <next>
```

### Rules for advancing between stages

- **If the current stage is uninterruptible**: do NOT stop to ask the user between stages. Run autonomously; the stop hook will re-inject a continuation prompt (blocking any exit attempt) until the stage's artifact is produced and the transition is called.
- **If the current stage is interruptible**: you MAY stop to wait for user input during the stage. The stop hook shows a status hint as a `systemMessage` but will not block the session. Resume when the user replies.
- **Check `workflow.json` → `stages.<status>.interruptible`** to determine which applies to the current stage. Different stages in the same workflow can have different settings — don't assume all non-initial stages are uninterruptible.
- **Loop termination**: the workflow stops only when `status` reaches a value listed in `workflow.json` → `terminal_stages` (arrived at via a legitimate transition in the transition table), or the user runs `/dev-workflow:interrupt` or `/dev-workflow:cancel`.

### When the hooks inject guidance

Two hooks surface the current stage's exact paths and parameters at the right moments — you do not need to memorise them here:

- **`stop-hook.sh`** fires when you attempt to end your turn (session stop). If the workflow is active, it either blocks (uninterruptible stages) or emits a status hint (interruptible stages), giving you the current stage's artifact path, transition keys, and stage-instructions file path.
- **`agent-guard.sh`** fires as a PreToolUse hook when you call the Agent tool. It injects the current stage's `subagent_type`, `model`, `mode`, required/optional input paths, and output path.

## Error Handling

- **Agent fails mid-run, missing artifact, or stale epoch** → stop hook sees "stage not done" and tells you to re-run. No manual intervention.
- **Unknown `result:` value** (not in the current stage's transition table) → stop hook blocks with "unknown result"; inspect the artifact and run `${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh --status <correct-next>` manually. Do NOT rewrite the artifact to bypass.
- **Required input missing** → `update-status.sh` refuses the transition with a clear error listing the missing paths. Fix the prerequisite (usually by completing an earlier stage), then retry.
- **Stage-specific edge cases** (e.g. what an agent should do when it cannot complete the work) live in `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/stages/<stage>.md` — consult that file rather than inventing behavior here.
- **Unrecoverable workflow error** → run:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status escalated
  ```
  This sets `status=escalated` (a terminal stage), releasing the stop hook and letting the session exit.

## Key Rules

- **NEVER invoke external skills** — every stage's work runs inline in this conversation, or in a subagent declared by the config.
- **Activate the stop hook** as the first programmatic action:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/setup-workflow.sh" --topic "<topic>"
  ```
  Never hand-write `state.md`.
- **`update-status.sh` is the only way to transition.** It's atomic: inputs-validation + epoch + status + artifact-delete. Always invoke it by its full path `${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh`.
- **Every stage artifact MUST start with `epoch:` and `result:` frontmatter.** Missing or wrong frontmatter means the stop hook will re-trigger the stage.
- **Transitions must come from the config.** Only call `update-status.sh --status <X>` when `<X>` is either a member of `workflow.json` → `terminal_stages` or the destination of a legitimate transition for the current stage's `result:` (i.e. `workflow.json` → `stages.<current>.transitions[<result>] == <X>`). Never guess a transition.
- **Terminal statuses** (the values in `workflow.json` → `terminal_stages`) release the stop hook and end the workflow. `complete` is the conventional normal terminator reached via the transition table; `escalated` is the escape hatch for unrecoverable errors.
- **Never self-approve** — only a subagent's or inline stage's legitimate `result:` (written to its artifact and matching a transition key) can move the workflow forward. Do not hand-write results to force a transition.
- **All artifacts go to `<project>/.dev-workflow/`**.
- **The loop is infinite** — it stops only on reaching a terminal status, `/dev-workflow:interrupt`, or `/dev-workflow:cancel`.
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
