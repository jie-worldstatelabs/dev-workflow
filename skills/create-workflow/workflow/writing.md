# Stage: writing

_Runtime config (canonical): `workflow.json` → `stages.writing`_

**Purpose:** Produce `workflow.json` + one `<stage>.md` per declared stage + `readme.md` in the target directory, matching the approved plan and the schema the validator accepts. On a loop-back (validator `FAIL` from the previous epoch), address every `❌` line and try again.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `done`

> This file is the canonical protocol for the `writing` stage. The main agent launches `workflow-subagent` with this file as the stage instructions; the subagent reads this file first, then proceeds.

You are the writer subagent for the create-workflow loop. Your job is to produce files that pass `setup-workflow.sh --validate-only` on the first try, or — if `validating` sent feedback from a previous iteration — to incorporate that feedback and try again.

## Inputs

Read every input path from your prompt — do NOT construct or hardcode paths.

- **Required:** `planning` report — the approved design (suffix, target dir, stage decomposition, transitions, inputs, run_files, readme blurb).
- **Optional:** `validating` report from the previous epoch — contains the validator's stdout/stderr with every `❌` line. If present, every listed error MUST be addressed in this pass.

## Read the plugin's canonical reference first

Run this Bash call so the canonical schema and stage-file style flow into your context:

````bash
P="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/meta-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/meta-workflow/*/ 2>/dev/null | head -1)"; }
for f in workflow.json planning.md executing.md reviewing.md verifying.md qa-ing.md run_files_catalog.md; do
  echo "===== $f ====="; cat "$P/skills/meta-workflow/workflow/$f"; echo
done
````

Copy the JSON **shape** and the stage-file **style** — NOT the specific stage identities. Your workflow uses whatever names the plan defines.

## Schema constraints (the validator enforces all of these)

- Top-level keys are exactly: `initial_stage`, `terminal_stages`, `max_epoch` (optional), `run_files` (optional), `stages`. Do NOT add `name`, `version`, `description`, or any other top-level field.
- `max_epoch`: optional integer, default `10`. `update-status.sh` forces `status=escalated` once a stage transition would push the epoch to or past this cap — breaks runaway FAIL→retry loops. Requires `escalated` in `.terminal_stages`; otherwise the cap is skipped with a warning.
- `.stages` is a JSON **object keyed by stage name** (NOT an array of `{id,...}`).
- Each stage has exactly these keys: `interruptible` (bool), `execution` (`{"type":"inline"}` or `{"type":"subagent","model":"opus|sonnet|haiku"}` — model optional), `transitions` (object), `inputs` (object with `required` and `optional` arrays).
- `transitions` values are plain strings (`"done": "next-stage"`) — NEVER nested objects like `{"target":"next"}` or `{"id":"done","nextStage":"next"}`.
- `inputs.required[]` / `inputs.optional[]` entries are `{from_stage, description}` or `{from_run_file, description}` — nothing else.
- **Subagent stages MUST have `"interruptible": false`** (the main agent blocks on the Agent tool, so the stop hook can't fire during a subagent run).
- NO `subagent_type` field — validator rejects it. All subagent stages run under the generic `meta-workflow:workflow-subagent`.
- Every declared stage MUST have a corresponding `<stage>.md` file placed **directly next to `workflow.json`** — NOT in a `stages/` subdirectory.
- Every transition target must be another declared stage name OR a terminal stage name (`complete`, `escalated`, `cancelled` are conventional).
- Every `from_stage` reference must name a declared stage; every `from_run_file` reference must name a key in top-level `.run_files`.
- Terminal stage names go in `.terminal_stages` array ONLY — do NOT also add them as keys under `.stages`.

## Writing protocol

1. **Create the target directory** from the plan's `Target directory` line:
   ```bash
   mkdir -p "<absolute-target-dir>"
   ```

2. **Write `workflow.json`** strictly matching the plan and the schema above.

3. **Write one `<stage>.md` per declared stage** directly in the target dir (NOT in a subdirectory). Follow the [Stage file style](#stage-file-style) section below.

4. **Write `readme.md`** for the workflow (see [Readme shape](#readme-shape)).

5. **Post-write sanity check** — run this before producing the report:
   ```bash
   DIR="<absolute-target-dir>"
   ls -1 "$DIR"
   echo "--- declared stages ---"
   jq -r '.stages | keys[]' "$DIR/workflow.json"
   ```
   Every name printed under `--- declared stages ---` MUST appear above as `<name>.md`. If any is missing, write it before producing the report.

6. **Write the execution report** (see [Execution report](#execution-report) below).

## Stage file style

Every stage file should contain:
- Header: `# Stage: <name>`
- Purpose line
- The valid `result:` values this stage writes — MUST exactly match the keys in that stage's `transitions` in `workflow.json` (plus `pending` for interruptible inline stages)
- The frontmatter block the stage's agent must write into its output artifact:
  ```
  ---
  epoch: <epoch>
  result: <one of the valid values>
  ---
  ```

**Inline stages** (execution.type = `inline`): address the body to the main agent (it reads this file and executes the stage directly).
- `interruptible: true` — the body should tell the main agent to: (1) read `state.md` for the current epoch, (2) immediately write the artifact at the path shown in its I/O context with `result: pending` so the stop hook knows the stage is in progress, (3) do the work, pausing for user input as needed, (4) overwrite the artifact with the final `result:` when done.
- `interruptible: false` — the body should tell the main agent to: read `state.md` for the epoch, run autonomously without pausing, write the artifact with the final `result:` when done.

For both variants: the stage file should tell the agent to **read each required input from the path shown in its I/O context — never construct or hardcode paths**.

**Subagent stages** (execution.type = `subagent`): address the body to `workflow-subagent`. Instruct it to read the epoch and all input paths **from its prompt** (injected by agent-guard — NOT from `state.md`), do the work, and write the output artifact with the frontmatter at the absolute path given in its prompt.

Stage files must NEVER instruct the agent to call `update-status.sh` — that is the main loop's job, not the stage's.

## Readme shape

Use this template (adapt to the workflow's actual domain):

````markdown
# <Workflow title — human-readable, not the suffix slug>

<One-line summary of what this workflow does. Kept punchy — this line is lifted verbatim for the hub card description. Avoid starting with "This workflow"; lead with the outcome.>

## Overview

<2–4 sentences describing the topology in prose: what the initial stage does, how the loop progresses, what each transition decides. Name the stages inline with backticks.>

## Stages

| Stage | Execution | Model | Purpose |
|---|---|---|---|
| `<name>` | inline / subagent | <omit col if all inline> | <short> |

## Flow

```
<initial_stage> --(<result>)--> <next_stage>
<next_stage>    --(<result>)--> <terminal>
```

## Usage

```
/meta-workflow:start --workflow <author>/<suffix> <your task description>
```
````

Rules:
- The blurb line (below the `# Title`) must be a single non-heading sentence — it's what the hub card lifts.
- Stage names in monospace. Terminal stage names in the flow graph are fine in prose (no backticks required).
- Do NOT embed the full stage instruction protocols — users already see those via the stage files. The readme is an overview, not a reference manual.

## Execution report

Write the output artifact to the absolute path given in your prompt:

```markdown
---
epoch: <epoch from your prompt>
result: done
---
# Writer Report

## Target directory
<absolute path>

## Files written
- `workflow.json`
- `<stage-name-1>.md`
- `<stage-name-2>.md`
- ... (one line per declared stage)
- `readme.md`

## Post-write sanity check
<paste the output of step 5 verbatim — `ls -1` and `jq .stages | keys[]`>

## Validator feedback addressed
(Include this section ONLY if the optional `validating` input was provided this epoch. Otherwise omit it.)

- [ ] <❌ line 1 copied from validating report> — <what file changed and how>
- [ ] <❌ line 2 copied from validating report> — <what file changed and how>
```

## Rules

- Do NOT skip the post-write sanity check — it's the guard against missing stage files or wrong-filename bugs.
- Do NOT put stage `.md` files inside a subdirectory — they go next to `workflow.json`.
- Do NOT invent top-level or per-stage schema fields not listed above.
- Do NOT call `setup-workflow.sh --validate-only` yourself — that is the next stage's job.
- If validator feedback is provided, address every `❌` line. If a line can't be addressed, document why in the report's "Validator feedback addressed" section rather than silently dropping it.
