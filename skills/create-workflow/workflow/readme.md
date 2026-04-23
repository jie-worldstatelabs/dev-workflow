# create-workflow (stagent)

Turns a natural-language description into a validated workflow definition via a plan → write → validate loop, then pushes to the hub when the caller asked for cloud mode. This is the default stagent that drives `/stagent:create-workflow`.

## Overview

`planning` interviews the user — from scratch in create mode, or pre-loaded with the existing workflow in edit mode. It records an approved design. `writing` (opus subagent) produces `workflow.json`, stage `.md` files, and `readme.md` in the target directory. `validating` runs `setup-workflow.sh --validate-only`: `PASS` advances to `publishing`, `FAIL` loops back to `writing` with the validator's verbatim `❌` lines as optional feedback. `publishing` reads `publish_intent` from the setup_context — for cloud it runs `publish-workflow.sh` and reports the hub URL; for local it's a skip. The retry loop between writing and validating is enforced by workflow.json transitions, not by agent prose.

## Stages

| Stage | Execution | Model | Purpose |
|---|---|---|---|
| `planning` | inline (interruptible) | — | Interview the user and write an approved design (branches on create vs edit) |
| `writing` | subagent | opus | Produce `workflow.json` + stage `.md` files + `readme.md` matching the plan |
| `validating` | inline | — | Run `--validate-only`; PASS → publishing, FAIL → writing |
| `publishing` | inline | — | If `publish_intent=cloud`, push to hub via `publish-workflow.sh`; else skip |

## Flow

```
planning   --(approved)--> writing
writing    --(done)--> validating
validating --(PASS)--> publishing
validating --(FAIL)--> writing
publishing --(done / skipped)--> complete
```

## Setup context

The caller (SKILL.md for `/stagent:create-workflow`) exports `CREATE_WORKFLOW_CONTEXT` as a JSON env var before dispatch. The `setup_context` run_file captures it at setup time so all stages can read it:

```json
{
  "mode": "create | edit",
  "description": "user's natural-language request (create) or change request (edit)",
  "source_dir": "<absolute-path>  (edit mode only)",
  "publish_intent": "cloud | local"
}
```

## Usage

Invoked automatically by `/stagent:create-workflow`. Not intended to be launched directly via `/stagent:start`.
