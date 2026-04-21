# create-workflow (meta-workflow)

Turns a natural-language description into a validated workflow definition via a plan → write → validate loop. This is the default meta-workflow that drives `/meta-workflow:create-workflow`.

## Overview

`planning` interviews the user and records an approved design (suffix, target directory, stage decomposition, transitions, inputs, run_files, readme blurb). `writing` is a subagent that produces `workflow.json`, one `<stage>.md` per declared stage, and `readme.md` in the target directory — strictly matching the schema the validator accepts. `validating` runs `setup-workflow.sh --validate-only` on the result: `PASS` terminates at `complete`, `FAIL` loops back to `writing` with the validator's `❌` lines injected as optional feedback, so the writer can address each error and try again. The state machine — not any agent's prose — enforces the retry loop.

## Stages

| Stage | Execution | Purpose |
|---|---|---|
| `planning` | inline (interruptible) | Interview the user and write an approved design |
| `writing` | subagent | Produce `workflow.json` + stage `.md` files + `readme.md` matching the plan |
| `validating` | inline | Run `--validate-only`; PASS → complete, FAIL → writing |

## Flow

```
planning   --(approved)--> writing
writing    --(done)--> validating
validating --(PASS)--> complete
validating --(FAIL)--> writing
```

## Usage

Invoked automatically by `/meta-workflow:create-workflow`. Not intended to be launched directly via `/meta-workflow:start`.
