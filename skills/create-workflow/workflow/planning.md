# Stage: planning

_Runtime config (canonical): `workflow.json` → `stages.planning`_

**Purpose:** Interview the user, agree on a workflow decomposition, and record it as an approved plan the writer subagent can consume deterministically.
**Output artifact:** write to the absolute path provided in your I/O context
**Valid results this stage writes:** `pending` (plan drafted, awaiting user approval), `approved` (user has explicitly confirmed)

<HARD-GATE>
Do NOT transition out of this stage until the user explicitly confirms the plan.
Write `result: approved` only after they have said so.
</HARD-GATE>

This is an interruptible stage — the stop hook allows natural pauses for Q&A.

## Understand the request

Read the session topic and any description the user provided when starting this workflow. If it is empty or too vague to decompose, ask ONE clarifying question at a time (cap at 5 total). Useful axes:

- What kind of work does this workflow orchestrate? (coding, writing, data analysis, review, research, etc.)
- What are the rough phases? A 3-line sketch is enough — you'll refine it below.
- Any phase where the user should pause for input? → interruptible inline stage.
- Any phase that benefits from a stronger model? → subagent stage with `model: opus` (or leave model unspecified for sonnet default).
- Any external validation / test run? → subagent or inline stage that runs a command.
- What's the success terminal? (usually `complete`.)

Stop asking once you can draft a stage decomposition.

## Propose the decomposition

Present the design as a table followed by the transition graph:

### Stage table

| Stage | Execution | Model | Interruptible | Purpose | Result values → next |
|---|---|---|---|---|---|
| `<name>` | inline / subagent | (if subagent) | true/false | <one-line role> | `<result>` → `<next>` |

### Transition graph

```
<initial_stage> --(<result>)--> <next_stage>
<next_stage>    --(<result>)--> <stage_or_terminal>
...
```

### Inputs per stage

For each stage, list `required` and `optional` inputs using `from_stage <name>` or `from_run_file <name>`. Required inputs are enforced at transition time by `update-status.sh`.

### Run files (optional)

If the workflow needs setup-time constants (e.g. git SHA baseline, current date), list each `run_files` entry: name, description, and the shell init command.

## Pick a workflow suffix

Derive a short, kebab-case suffix from the description (e.g. "Python library dev with docs and publish" → `python-lib`, "research paper drafting" → `paper-draft`). Confirm with the user. The local directory will always be `~/.meta-workflow/workflows/<suffix>/`.

**Collision check:** if `~/.meta-workflow/workflows/<suffix>/` already exists, tell the user and ask whether to pick a different name or overwrite. Do NOT overwrite silently.

## Iterate until approved

Ask: **"Does this design look right? Any changes to stages, order, inputs, or naming?"** Iterate until the user explicitly approves.

## Write the plan into the output artifact

Once the user has confirmed the design AND the suffix, write the output artifact (use the current epoch from `state.md`):

```markdown
---
epoch: <epoch>
result: pending
---
# Workflow Plan

## Description
<one paragraph — what this workflow orchestrates>

## Suffix
<kebab-case-suffix>

## Target directory
`/Users/<user>/.meta-workflow/workflows/<suffix>/`
(absolute path — writer will `mkdir -p` this)

## Stages

| Stage | Execution | Model | Interruptible | Purpose | Result values → next |
|---|---|---|---|---|---|
| `<name>` | inline / subagent | (omit / opus / sonnet / haiku) | true / false | <short> | `<result>` → `<next>` |

## Transition graph

```
<initial_stage> --(<result>)--> <next>
...
```

## Inputs per stage

- **`<stage-a>`** — required: (none) — optional: (none)
- **`<stage-b>`** — required: `from_stage <stage-a>` (<description>) — optional: `from_stage <stage-c>` (<description>)
- ...

## Run files

- `<name>` — description: <text> — init: `<shell command>`
- (or: "none")

## Readme blurb

<one-line summary that will become the hub card description — punchy, avoid starting with "This workflow">
```

`result: pending` signals "plan written but not approved yet."

## Get user approval

> "Plan saved. Please review and confirm to start writing, or request changes."

If the user requests changes, iterate on the plan body — keep `result: pending`.

## Finalize

Once the user explicitly approves, edit the artifact: change `result: pending` → `result: approved`.

The main loop reads the artifact's `result:` and calls `update-status.sh` to advance — do NOT call it yourself from this stage file.
