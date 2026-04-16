---
name: dev-workflow
description: "Full development workflow: brainstorm a plan, execute with an agent, verify quick tests, adversarial code review, real user journey tests (QA), and loop until fully approved."
---

# Dev Workflow — Config-Driven State Machine

Orchestrate any development cycle as a **config-driven state machine**. This document is the workflow-agnostic meta-protocol; the specific stages, transitions, and per-stage work are declared elsewhere.

A **workflow** is a directory containing `workflow.json` (config) plus one `<stage>.md` per stage (instructions). The default workflow ships at `${CLAUDE_PLUGIN_ROOT}/skills/dev-workflow/workflow/`; alternate workflows can be selected via `setup-workflow.sh --workflow=<path>` where `<path>` is a local directory path or a `cloud://author/name` hub reference — see the **Cloud mode** section below.

The plugin's runtime behavior is defined in three places:

| File | Role |
|------|------|
| `<workflow-dir>/workflow.json` | Stages, transitions, interruptible flags, execution params, required/optional input dependencies — **source of truth for the workflow shape** |
| `<workflow-dir>/<stage>.md` | Per-stage instructions — what to actually do in each stage |
| This file (`SKILL.md`) | Meta-protocol: how to drive a state machine defined by the other two |

Which workflow is active for the current run is recorded in `state.md` → `workflow_dir` (written by `setup-workflow.sh`).

Runtime files live under the **project** root. Rule: **one Claude session = one run**. Each session's run is isolated in its own subdirectory named by the session_id, so multiple Claude sessions in the same worktree can run independent workflows without interfering. Starting a new run within the same session archives its prior run (if any) to `.dev-workflow/.archive/` before creating the new one.

| File / directory | What lives there |
|------------------|------------------|
| `<project>/.dev-workflow/<session_id>/state.md` | Current `status`, `epoch`, `topic`, `session_id`, `worktree` (this run's state) |
| `<project>/.dev-workflow/<session_id>/<stage>-report.md` | Each stage's output artifact |
| `<project>/.dev-workflow/<session_id>/baseline` | Git SHA before this run started (used by the reviewer) |
| `<project>/.dev-workflow/<session_id>/journey-tests.md` | Cross-iteration QA state (optional, created by QA agent) |
| `<project>/.dev-workflow/.archive/<ts>-<topic>[-cancelled]/` | Preserved prior runs — audit trail |

Routing rules:
- **Hook routing** (stop-hook, agent-guard): use the `session_id` from the hook's stdin JSON to locate `.dev-workflow/<session_id>/state.md`. Hooks in sessions that have no workflow (sidecar observers, unrelated sessions) find nothing and exit cleanly — **no bystander session is ever blocked by another session's workflow**.
- **CLI routing** (update-status, interrupt, continue, cancel): auto-resolve to the caller's own session via the session-id cache written by `hooks/session-start.sh`. Pass `--topic <name>` to disambiguate if ever needed; pass `--session <id>` to `continue-workflow.sh` to take over another session's interrupted run.
- **Enforcement**: `setup-workflow.sh` only touches its own session's subdir. If that subdir already has an active run, setup refuses without `--force`; with `--force` (or for completed/empty dirs) it archives the prior run to `.dev-workflow/.archive/` before creating the new one. Other sessions' subdirs are never touched.
- **Cancel behaviour**: `cancel-workflow.sh` archives to `.dev-workflow/.archive/<ts>-<topic>-cancelled/` by default. Pass `--hard` to skip the archive.

Everything this document says is true **regardless of what's in workflow.json or stages/**. Specific stage names (planning / executing / reviewing / …) appear only as examples of the currently-shipped default workflow — the protocol itself doesn't depend on them.

## Cloud mode

**Cloud mode is the default.** When the user runs `/dev-workflow:start <task>` without any flag, state + artifacts live on the remote **workflowUI** server. The project's `.dev-workflow/` gets nothing; a transient shadow at `~/.cache/dev-workflow/sessions/<session_id>/` backs Claude's filesystem tools locally.

**To opt OUT** (fully-offline local mode) in one of two ways:
- Pass `--mode=local` to `setup-workflow.sh`, OR
- Export `DEV_WORKFLOW_DEFAULT_MODE=local` in the shell env before launching Claude Code, which flips the default for every run in that shell.

The plugin parser accepts both `--workflow=<value>` (canonical) and `--workflow <value>` (legacy space-separated) forms.

**Requirements**: none for basic use. Authenticated users get workflow ownership (required for editing cloud workflows via `/dev-workflow:create-workflow --workflow=<path>`). Log in with `/dev-workflow:login` — a bearer token is stored at `~/.dev-workflow/auth.json` and sent on every cloud API call via `_cloud_auth_header` in `lib.sh`. Anonymous (unauthenticated) sessions are still accepted by endpoints that don't check ownership. `DEV_WORKFLOW_SERVER` can be exported to point at a self-hosted/staging/local deployment.

**Workflow source resolution** in cloud mode:
- `cloud://author/name` — fetches a named template bundle from `$DEV_WORKFLOW_SERVER/api/workflows/author/name`.
- `/abs/path` or `./rel/path` — copies a local workflow dir into the shadow (useful for iterating on a config before publishing it).
- bare name — first tries a bundled workflow under `skills/dev-workflow/<name>/`; falls back to a named template on the server.
- omitted — uses the plugin's default workflow.

**Runtime layout** in cloud mode:
- **Authoritative state lives on the server.** The project worktree gets **nothing** under `.dev-workflow/` — no state, no artifacts, no baseline. Cleanup, archive, and cancel all go through server endpoints (`/api/sessions/<session_id>/{archive,cancel}`), so a canceled cloud workflow leaves no local footprint.
- A **transient shadow** at `~/.cache/dev-workflow/sessions/<session_id>/` holds the files the skill's `Read`/`Write` tools need real paths for. Every write to the shadow is mirrored to the server by `hooks/postwrite-hook.sh` on the way out. **The shadow is wiped on any terminal status** (not just on explicit cancel): when `update-status.sh` transitions to a terminal stage, it calls `cloud_wipe_scratch` + `cloud_unregister_session`, and `stop-hook.sh` does the same as a safety net if the workflow ever reaches a terminal status out-of-band.
- A **cloud registry entry** at `~/.dev-workflow/cloud-registry/<session_id>.json` is what every script/hook uses to decide "is this session cloud-managed?". Presence of the file ⇒ cloud.
- `resolve_state` short-circuits to the shadow's `state.md` whenever the session has a registry entry, reading the exact scratch dir from the registry (which allows cross-machine takeover to alias one physical shadow under two keys).

**Cross-machine takeover** (started on machine A, continued on machine B):

The session_id is a stable identifier on the server. To pick up the same cloud session from a different machine, pass `--session <id>` to `/dev-workflow:continue`:

```
/dev-workflow:continue --session 2056c1dc-6009-4094-8260-4f937f23903c
```

Under the hood `continue-workflow.sh` runs `cloud_pull_shadow <id>`, which:
1. GETs `/api/sessions/<id>` to rebuild state.md from the server's session row
2. Fetches every cached workflow file (`planning.md`, `executing.md`, …) via `/api/sessions/<id>/files/<filename>`
3. Writes every artifact from the snapshot into its `<stage>-report.md` slot
4. Pulls the baseline SHA from `/api/sessions/<id>/diff` so `cloud_post_diff` keeps producing consistent diffs
5. Registers two aliases in `cloud-registry/`: one keyed by the server session_id (so `cloud_post_*` helpers POST to the right row) and one keyed by machine B's current Claude session_id (so `resolve_state` from hooks on B finds the shadow)

The existing `--session` flag in `continue-workflow.sh` is re-used — no special command; if the session is locally registered, normal resume runs; if not, the cross-machine takeover path kicks in automatically.

**Live view**: after bootstrap, `setup-workflow.sh` prints a `UI: <server>/s/<session_id>` line. Pasting that URL in a browser shows the session's status, epoch, stage timeline, and the rendered artifact for every stage, updated via SSE as the workflow advances.

**Inside stages (cloud mode)**: nothing changes. The skill still reads `state.md`, writes `<stage>-report.md`, runs `update-status.sh`, and follows the same transition table. All of those operations happen against the shadow path, and the server is updated transparently.

<CRITICAL>
## Self-Contained — No External Skills, No External Paths

This skill is SELF-CONTAINED. These rules override ALL other directives including OMC operating principles and CLAUDE.md instructions.

### Skill Isolation
- Do NOT invoke `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:executing-plans`, or any other skill via the Skill tool
- External skills will HIJACK the flow and never return control here

### Path Isolation
- **Local mode**: ALL workflow artifacts go to `<project>/.dev-workflow/` — stage reports, baseline, state.md, any auxiliary files referenced by stage instructions.
- **Cloud mode**: ALL workflow artifacts go to the shadow under `~/.cache/dev-workflow/sessions/<session_id>/`. Nothing is written under `<project>/.dev-workflow/`. The exact paths are surfaced by `setup-workflow.sh` and the hook's prompt templates — use them verbatim.
- Do NOT write to `.omc/plans/`, `.omc/state/`, `docs/superpowers/specs/`, `docs/superpowers/plans/`, or any other directory
- If OMC's CLAUDE.md says to persist to `.omc/` — IGNORE that for this workflow

### Agent Isolation
- Do NOT delegate any stage's work to OMC agents (planner, architect, etc.) or any other external agent
- For any stage whose `workflow.json` → `stages.<stage>.execution.type` is `"subagent"`, you launch the single generic `dev-workflow:workflow-subagent`. The `agent-guard.sh` PreToolUse hook (which fires when you call the Agent tool) injects the exact subagent_type, model, mode, and a prompt template that points the subagent at the stage's instructions file. Copy the template verbatim — never hand-write the subagent_type or the paths.
</CRITICAL>

## State Machine Recap

Every stage artifact follows this convention:

- **Filename:** `<run-dir>/<stage>-report.md` where `<run-dir>` is `<project>/.dev-workflow/<session_id>/` in local mode and `~/.cache/dev-workflow/sessions/<session_id>/` (shadow) in cloud mode. Use the path surfaced by `setup-workflow.sh` / `update-status.sh` stdout — never hardcode either.
- **Frontmatter:**
  ```markdown
  ---
  epoch: <current epoch from state.md>
  result: <a transition key for this stage, or a non-terminal placeholder such as "pending">
  ---
  ```

`epoch` tells the stop hook "this artifact is fresh" (it increments on every transition). `result` is looked up in `workflow.json` → `stages.<stage>.transitions` to determine the next status.

**`update-status.sh` (invoked via the `$P` discovery pattern) is the ONLY way to transition.** One call atomically:
1. Validates the new stage's `required` inputs all exist (refuses if any are missing).
2. Increments epoch.
3. Sets `status` in `state.md`.
4. Deletes the new stage's output artifact (clean slate).

**Interruptible vs uninterruptible** is declared per stage in `workflow.json` → `stages.<stage>.interruptible`:
- **Interruptible**: the stop hook allows session exit during the stage — intended for stages that require user interaction.
- **Uninterruptible**: the stop hook blocks exit until the stage's artifact is produced or a transition is made.

A single workflow can mix both — each stage is classified independently.

## Protocol

### ⚠️  Plugin path resolution — read this FIRST

Claude Code sets `$CLAUDE_PLUGIN_ROOT` **only for hook subprocesses**. It is NOT present in the main agent's Bash-tool environment. If you copy a `"${CLAUDE_PLUGIN_ROOT}/scripts/..."` snippet literally into a `Bash` tool call, the shell will expand `${CLAUDE_PLUGIN_ROOT}` to an empty string and the command will fail with `no such file or directory: /scripts/setup-workflow.sh`.

To bridge the gap, `hooks/session-start.sh` writes the absolute plugin root path to **`~/.dev-workflow/plugin-root`** on every session start (the hook runs with `$CLAUDE_PLUGIN_ROOT` set). Every Bash-tool call that needs to run a plugin script should read that file:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
```

Line 1: read the SessionStart-populated cache (the happy path). Line 2: fallback to a filesystem search if the cache file is missing (plugin not loaded yet, session-start hook didn't fire, etc.). After those two lines, `"$P/scripts/<name>.sh"` is the absolute path you invoke.

Note that **`P` does NOT persist across Bash-tool calls** — every Bash-tool call is a fresh shell, so you must repeat the two discovery lines (or an equivalent) at the top of each call that runs a plugin script.

### Step 0 — Pre-flight validation & announcement

Before deriving a topic or running any script, parse the flags, validate them, then announce the run configuration to the user. **Do not proceed to Step 1 if any error is emitted.**

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
source "$P/scripts/lib.sh"

ARGS='$ARGUMENTS'
eval "$("$P/scripts/parse-workflow-flags.sh" "$ARGS")" || exit 1

_server="${DEV_WORKFLOW_SERVER:-https://workflows.worldstatelabs.com}"
if [[ -z "$WORKFLOW_FLAG" ]]; then
  if [[ "$MODE" == "cloud" ]]; then
    _wf="demo  ←  ${_server}/hub/demo  (cloud default)"
  else
    _wf="default (bundled with plugin)"
  fi
elif [[ "$WF_TYPE" == "cloud" ]]; then
  _wf="${WORKFLOW_FLAG}  ←  ${_server}/hub/${WORKFLOW_FLAG#cloud://}"
else
  _wf="${WORKFLOW_FLAG}  (local path)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Mode:     ${MODE}"
if [[ "$MODE" == "cloud" ]]; then
  echo "  State:    ${_server}/s/<session_id>  (live after setup)"
  cloud_is_logged_in \
    && echo "  Auth:     $(jq -r '.author // "unknown"' ~/.dev-workflow/auth.json 2>/dev/null)  (logged in)" \
    || echo "  Auth:     anonymous  — run /dev-workflow:login to attach an account"
else
  echo "  State:    <project>/.dev-workflow/<session_id>/"
fi
echo "  Workflow: ${_wf}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

Relay the banner to the user before continuing. If errors were printed, stop and wait for the user to correct the arguments.

### Step 1 — Bootstrap (once per workflow, before the state machine exists)

1. Derive a short kebab-case **topic name** from the user's task description (e.g. "add user auth" → `user-auth`; "fix login bug" → `login-bug`). If the task is unclear or empty, ask ONE clarifying question first — just enough to pick a topic.
2. Briefly tell the user: `I'll use topic \`<topic>\` for this workflow.`
3. Pass `$WORKFLOW_FLAG` from Step 0 to `setup-workflow.sh` if non-empty; omit it otherwise (default workflow applies).
4. Activate the workflow (discover plugin root → run setup in one Bash-tool call):
   ```bash
   P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
   [[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
   "$P/scripts/setup-workflow.sh" --topic="<topic>" [--workflow="$WORKFLOW_FLAG"] [--mode="$MODE"]
   ```

5. **If setup-workflow.sh exits with code 2** (existing workflow detected), it will have printed the existing workflow's topic + status to stderr. Do NOT proceed blindly:
   - Relay the warning to the user verbatim, including which topic is currently active and its status.
   - Ask: `There's already a workflow in this worktree. Proceeding will archive it and start fresh. Continue? (yes/no)`
   - If the user confirms: re-run with `--force` (re-discover `P`):
     ```bash
     P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
     [[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
     "$P/scripts/setup-workflow.sh" --topic="<topic>" [--workflow="$WORKFLOW_FLAG"] [--mode="$MODE"] --force
     ```
   - If the user declines: stop. Suggest `/dev-workflow:interrupt` (pause), `/dev-workflow:continue` (resume), or `/dev-workflow:cancel` (remove) to handle the existing workflow first.

6. **If setup-workflow.sh exits with any OTHER non-zero code** (exit 1 — typically config validation failed, session_id cache miss, or cloud fetch failed), the stderr output contains the specific errors. Nothing was written to disk (the failure is atomic), so there's no cleanup to do. Handle it this way:
   - **Relay the stderr output to the user verbatim.** The `❌` lines from `config_validate` are already written to be actionable (e.g. `stage 'executing': instructions file missing: ...`).
   - **Do NOT try to auto-fix a custom workflow config.** If the user passed `--workflow=<path-or-name>` pointing at their own workflow, that file belongs to them. Tell them which file has errors and what the errors say, then wait for them to fix it and retry. Do not write to their workflow.json or stage instruction files yourself.
   - **If the failure is in the plugin's default workflow** (the user did NOT pass `--workflow`), that's a plugin bug — surface it as such, point the user at the config path shown in the warning, and stop. Do not try to patch the default workflow from inside the skill.
   - **If the error says `session_id is unknown`** (the SessionStart hook cache wasn't populated), tell the user to restart their Claude Code session and retry. That's the only fix.
   - **If the error is a cloud fetch failure** (`cloud fetch failed`, `could not pull session ... from server`, `DEV_WORKFLOW_SERVER` issues), relay the error and suggest retrying, checking the network, or opting into local mode for this run (`/dev-workflow:start --mode=local <task>` — cloud is the default, `--mode=local` is the escape hatch).
   - **Do NOT proceed to Step 2** until the user explicitly confirms a retry. A failed setup means there is no state.md to drive anything.

On success, setup-workflow.sh creates `state.md` in the run directory (`<project>/.dev-workflow/<session_id>/` in local mode, `~/.cache/dev-workflow/sessions/<session_id>/` in cloud mode) with:
- `status` = `workflow.json` → `initial_stage`
- `epoch` = 1
- `session_id` = the Claude session that owns this run
- `topic` = the topic name you passed
- `workflow_dir` = resolved absolute path to the active workflow
- `worktree` = absolute path to the git worktree root

The stop hook becomes active. The initial stage's I/O context (required/optional inputs + output path) prints to stdout.

### Step 2 — Stage loop (run forever until a terminal status is reached)

```
Loop:
  a. Read the run-dir's `state.md` (path surfaced by setup-workflow.sh; in local
     mode: `<project>/.dev-workflow/<session_id>/state.md`) → get current `status`,
     `epoch`, and `workflow_dir`.
  b. If `status` is in workflow.json → `terminal_stages`:
       announce completion and stop the loop.
  c. Read workflow.json → stages.<status>.execution.type to determine how to run
     this stage:

     - If "inline":
         Run stage-context.sh to get binding I/O context (re-discover $P):
             P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
             [[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
             "$P/scripts/stage-context.sh"
         Treat the printed required inputs, output artifact path, and valid
         result keys as hard constraints for this stage.
         Read <workflow_dir>/<status>.md for stage-specific work instructions.
         Do the stage's work — read all required inputs, produce the output
         artifact at the printed path with `epoch:` and a valid `result:` in
         frontmatter.

     - If "subagent":
         Call the Agent tool. The agent-guard.sh PreToolUse hook will fire and
         print a clearly-labelled PROMPT TEMPLATE — copy it verbatim into the
         Agent tool's `prompt` argument (the subagent has no access to the hook's
         output; paths must appear literally in the prompt string).
         Wait for the subagent to complete.
         Read the artifact it produced to get the `result:` frontmatter value.

  d. Look up <workflow_dir>/workflow.json → stages.<status>.transitions[<result>]
     to get the next status, then run (re-discover $P each Bash-tool call):
         P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
         [[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
         "$P/scripts/update-status.sh" --status <next>
     (The next iteration of the loop picks up the new status.)
```

The CLI scripts (`update-status.sh` / `interrupt-workflow.sh` / `continue-workflow.sh` / `cancel-workflow.sh`) auto-resolve to the current session's own run via the session-id cache written by `hooks/session-start.sh`. Pass `--topic <name>` to disambiguate by topic if needed.

### Rules for advancing between stages

- **If the current stage is uninterruptible**: do NOT stop to ask the user between stages. Run autonomously; the stop hook will re-inject a continuation prompt (blocking any exit attempt) until the stage's artifact is produced and the transition is called.
- **If the current stage is interruptible**: you MAY stop to wait for user input during the stage. The stop hook shows a status hint as a `systemMessage` but will not block the session. Resume when the user replies.
- **Check `workflow.json` → `stages.<status>.interruptible`** to determine which applies to the current stage. Different stages in the same workflow can have different settings — don't assume all non-initial stages are uninterruptible.
- **Loop termination**: the workflow stops only when `status` reaches a value listed in `workflow.json` → `terminal_stages` (arrived at via a legitimate transition in the transition table), or the user runs `/dev-workflow:interrupt` or `/dev-workflow:cancel`.

### Where stage I/O paths come from

You never need to hardcode artifact paths. Three channels surface the current stage's required/optional input paths, output path, and execution params.

**Channel 1 — `setup-workflow.sh` / `update-status.sh` stdout** (primary for every stage)
When the workflow enters a new stage, the transition script prints the stage's inputs and output. This is the main delivery mechanism for **inline stages**, which have no Agent-tool call and therefore do not trigger `agent-guard.sh`.

**Channel 2 — `agent-guard.sh`** (PreToolUse hook on the Agent tool, subagent stages only)
Fires **only in your context**, not the subagent's. PreToolUse hooks cannot modify tool parameters. The hook prints a clearly-labelled **`PROMPT TEMPLATE — copy verbatim into the Agent tool's prompt`** block; you MUST transcribe that block into the `prompt` argument of your Agent-tool call. Subagents can see only the prompt you pass them — they have no access to the hook's output. Never send a prompt like "see injected paths" — paths must appear literally in the prompt string.

**Channel 3 — `stop-hook.sh`** (safety net, fires on attempted session exit)
If the workflow is active, it either blocks (uninterruptible stages) or emits a `systemMessage` hint (interruptible stages), and re-surfaces the current stage's I/O context. Kicks in when channels 1 and 2 were missed.

All three channels read the same `workflow.json`, so the paths they show always agree.

## Error Handling

- **Agent fails mid-run, missing artifact, or stale epoch** → stop hook sees "stage not done" and tells you to re-run. No manual intervention.
- **Unknown `result:` value** (not in the current stage's transition table) → stop hook blocks with "unknown result"; inspect the artifact and run `"$P/scripts/update-status.sh" --status <correct-next>` manually (discover `$P` via the pattern at the top of the Protocol section). Do NOT rewrite the artifact to bypass.
- **Required input missing** → `update-status.sh` refuses the transition with a clear error listing the missing paths. Fix the prerequisite (usually by completing an earlier stage), then retry.
- **Stage-specific edge cases** (e.g. what an agent should do when it cannot complete the work) live in the active workflow's `<workflow_dir>/<stage>.md` — consult that file rather than inventing behavior here.
- **Unrecoverable workflow error** → run:
  ```bash
  P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
  [[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
  "$P/scripts/update-status.sh" --status escalated
  ```
  This sets `status=escalated` (a terminal stage), releasing the stop hook and letting the session exit.

## Key Rules

- **NEVER invoke external skills** — every stage's work runs inline in this conversation, or in a subagent declared by the config.
- **`setup-workflow.sh` is the only way to activate the stop hook.** Never hand-write `state.md`.
- **`update-status.sh` is the only way to transition.** It's atomic: inputs-validation + epoch + status + artifact-delete. Always invoke it via the `$P` discovery pattern (never use `${CLAUDE_PLUGIN_ROOT}` directly — it is not set in the main agent's Bash-tool environment).
- **Every stage artifact MUST start with `epoch:` and `result:` frontmatter.** Missing or wrong frontmatter means the stop hook will re-trigger the stage.
- **Transitions must come from the config.** Only call `update-status.sh --status <X>` when `<X>` is either a member of `workflow.json` → `terminal_stages` or the destination of a legitimate transition for the current stage's `result:` (i.e. `workflow.json` → `stages.<current>.transitions[<result>] == <X>`). Never guess a transition.
- **Terminal statuses** (the values in `workflow.json` → `terminal_stages`) release the stop hook and end the workflow. `complete` is the conventional normal terminator reached via the transition table; `escalated` is the escape hatch for unrecoverable errors.
- **Never self-approve** — only a subagent's or inline stage's legitimate `result:` (written to its artifact and matching a transition key) can move the workflow forward. Do not hand-write results to force a transition.
- **All artifacts go to the run directory surfaced by `setup-workflow.sh`** — `<project>/.dev-workflow/<session_id>/` in local mode, `~/.cache/dev-workflow/sessions/<session_id>/` (shadow) in cloud mode. Never hardcode either path; read it from `state.md` → `workflow_dir` or from the paths printed by the transition scripts.
- **The loop is infinite** — it stops only on reaching a terminal status, `/dev-workflow:interrupt`, or `/dev-workflow:cancel`.
  - `/dev-workflow:interrupt` — pause and preserve state (resumable via `/dev-workflow:continue`)
  - `/dev-workflow:cancel` — cancel and clear all state
