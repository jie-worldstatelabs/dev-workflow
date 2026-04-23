---
name: stagent-setup
description: "Bootstrap a dev workflow session (for /stagent:start): parse flags, derive a topic from the task description, call setup-workflow.sh, and hand off to the workflow loop skill. Does NOT drive the state machine — that's stagent:stagent's job."
---

# Workflow Setup

Single-purpose skill: **materialize a new `state.md`** for the current Claude Code session by parsing the user's flags, picking a kebab-case topic, and invoking `setup-workflow.sh`. Used by `/stagent:start`; not invoked directly by users.

## Boundary

| Responsibility | Who |
|---|---|
| Parse `--mode` / `--workflow` / task description from `$ARGUMENTS` | This skill |
| Derive a kebab-case topic from the task | This skill |
| Run `setup-workflow.sh` (which writes `state.md`, sets up scratch, registers cloud session) | This skill |
| Handle `setup-workflow.sh` exit codes (0 → success, 2 → active conflict, other → error) | This skill |
| Read `state.md`, run stage loop, post artifacts, advance state machine | **`stagent:stagent` skill (not this one)** |

By the time this skill returns control, `state.md` exists at the session's run dir. The caller (`commands/start.md`) then invokes `stagent:stagent` to drive the loop.

## Plugin path resolution

Every Bash tool call that runs a plugin script starts with the same two lines — session-cached path then filesystem fallback:

```bash
P="$(cat ~/.config/stagent/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/stagent; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)"; }
```

Shell vars don't persist across Bash-tool calls — repeat these two lines in every call.

## Protocol

### Step 0 — Parse flags and announce

```bash
P="$(cat ~/.config/stagent/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/stagent; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)"; }
eval "$("$P/scripts/parse-workflow-flags.sh" '$ARGUMENTS')" || exit 1
"$P/scripts/print-start-banner.sh" "$MODE" "$WORKFLOW_FLAG" "$WF_TYPE"
```

Parser exports `MODE` / `WORKFLOW_FLAG` / `WF_TYPE` / `DESCRIPTION`. Relay the banner to the user. If errors were printed, stop and wait for the user to retry with valid flags.

### Step 1 — Derive a topic

Pick a short kebab-case slug from `$DESCRIPTION` (e.g. `"add user auth"` → `user-auth`; `"fix login bug"` → `login-bug`). If the description is empty or too vague, ask ONE clarifying question, just enough to name the topic.

Briefly tell the user: `I'll use topic \`<topic>\` for this workflow.`

### Step 2 — Call setup-workflow.sh

```bash
P="$(cat ~/.config/stagent/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/stagent; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)"; }
"$P/scripts/setup-workflow.sh" --topic="<topic>" [--workflow="$WORKFLOW_FLAG"] [--mode="$MODE"]
```

Pass `--workflow` only when `$WORKFLOW_FLAG` is non-empty. Pass `--mode` only when the user was explicit (otherwise the script defaults).

### Step 3 — Handle the exit code

**Exit 0 — success.** `setup-workflow.sh` already printed the run directory and the initial stage's I/O context. Tell the user **exactly one** line: `Workflow session initialised; stage loop will take over.` Then return control — do not invoke any other skill or script from here. `commands/start.md` Step 2 invokes `stagent:stagent` to start the loop.

**Exit 2 — session already has an active (or interrupted) workflow.** The script prints the existing topic + status. Do NOT offer to archive-and-restart blindly (that silently discards in-progress work). Relay the script's message verbatim and give the user three choices:

- `/stagent:interrupt` — pause the existing workflow (safe, preserves state)
- `/stagent:continue` — resume the existing workflow (treat this new request as the one to discard)
- `/stagent:cancel` — archive or hard-delete the existing run, then retry `/stagent:start` with the new task

Only re-run `setup-workflow.sh --force` if the user **explicitly** asks to discard the existing run in this turn. Default stance: refuse, ask user to choose.

**Exit 1 or other — real error.** Relay the stderr verbatim. Common cases:

- Config validation errors (`❌ stage '<x>': ...`) — workflow.json / stage .md problems. If the user passed `--workflow=<their-path>`, that's their config; point at the offending file and stop. If no `--workflow` was passed, it's a plugin bug — surface it.
- `session_id is unknown` — SessionStart hook didn't populate the cache. Tell the user to restart their Claude Code session.
- Cloud fetch failure — relay and suggest retry / network check / `--mode=local` escape hatch.

Do NOT auto-fix the user's workflow files. Do NOT proceed. Wait for user confirmation before retrying.

## Rules

- This skill **does not drive the stage loop**. It exits after `setup-workflow.sh` succeeds. The loop is `stagent:stagent`'s job.
- This skill **does not call `update-status.sh`**, **does not read stage artifacts**, **does not launch subagents**. Just bootstrap.
- Do NOT invoke any other skill from here. The chain is coordinated at the command-file level (`commands/start.md`).
- When `setup-workflow.sh` returns exit 2, **do not auto-force**. The user's active work must be preserved unless they explicitly say otherwise.
