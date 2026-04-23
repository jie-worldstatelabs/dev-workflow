---
description: "Create a new workflow suite (published to hub by default), or edit an existing one with --flow=<path>"
argument-hint: "[--mode=cloud|local] [--flow=<local-dir|cloud-url>] <brief description of the workflow / changes you want>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

Create or edit a stagent. Runs as two-step orchestration:

- **Step 1** — `stagent:create` skill handles flag parsing, login/ownership preconditions, and dispatches the internal stagent via `setup-workflow.sh`. The stagent (planning → writing → validating → publishing) does the actual file writes and validation loop.
- **Step 2** — `stagent:stagent` skill then drives the state machine loop: reads `loop-tick.sh`, starts the `planning` interview with the user, hands off to the `writing` subagent, validates in a retry loop, and (cloud mode) pushes to the hub.

Modes:
- **No `--mode`** → cloud (default) — publish-intent flows through to the `publishing` stage.
- **`--mode=local`** → local-only, skip hub publish.
- **`--mode=cloud`** → explicit cloud mode.
- **`--flow=<path>`** → edit existing (local dir or `cloud://author/name`). Cloud edits require login and ownership.

Task from user: `$ARGUMENTS`

## Step 1 — Dispatch

Invoke `Skill("stagent:create")` and follow its instructions exactly. It sets up `CREATE_WORKFLOW_CONTEXT` and calls `setup-workflow.sh`; when it finishes the active workflow is running at the `planning` stage.

## Step 2 — Drive the loop

Invoke `Skill("stagent:stagent")` and follow its instructions exactly. It picks up the dispatched session, runs the planning interview, and continues through the retry loop to the terminal.

Do NOT invoke any other skill before, during, or after these two.

When the workflow completes, you'll see the target directory path in the writer report (default `~/.config/stagent/workflows/<suffix>/`) and — if `--mode=cloud` — a hub URL from the publish stage.
