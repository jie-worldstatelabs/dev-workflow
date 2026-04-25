---
name: create
description: "Create a new workflow suite from a natural-language description, or edit an existing one when --flow=<path> is passed. Dispatches the create-workflow stagent (plan → write → validate loop) — does not write files directly."
---

# Create / Edit Workflow

This skill **dispatches a stagent** that creates or edits a stagent definition. It does NOT write workflow files itself — the stagent's state machine (`planning → writing → validating`) does that, with validator-driven retry until `✓ Workflow validated` prints.

- **Create mode** (no `--flow` flag): the stagent's `planning` stage interviews the user from scratch.
- **Edit mode** (`--flow=<path>` or `--flow=cloud://author/name`): `planning` pre-loads the existing workflow as the starting point, then asks for changes.

Both modes dispatch the same stagent at `$P/skills/create-workflow/workflow`. The difference is a single env var (`CREATE_WORKFLOW_CONTEXT`) passed at dispatch time.

<CRITICAL>
- Do NOT write any workflow files yourself. Parse flags, verify preconditions, set `CREATE_WORKFLOW_CONTEXT`, call `setup-workflow.sh`, stop.
- Do NOT invoke any other skill before or after.
- Do NOT edit a cloud workflow if the user is not logged in or does not own it — hard stop.
</CRITICAL>

## Plugin path resolution

`$CLAUDE_PLUGIN_ROOT` is NOT set in agent Bash-tool env. Use the session-cached path:

```bash
P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
```

Re-derive `$P` inside every Bash-tool call — shell vars don't persist across calls.

## Protocol

### Step 0 — Parse flags & announce

```bash
P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
eval "$("$P/scripts/parse-workflow-flags.sh" '$ARGUMENTS')" || exit 1
"$P/scripts/print-create-banner.sh" "$MODE" "$WORKFLOW_FLAG" "$WF_TYPE"
```

Values set by the parser:
- `$MODE` — `cloud` (default) or `local`
- `$WORKFLOW_FLAG` — empty for Create, else the `--flow=` value for Edit
- `$WF_TYPE` — for Edit only: `local` (filesystem path) or `cloud` (`cloud://author/name`)
- `$DESCRIPTION` — everything after the flags

Relay the banner to the user. If the parser emitted errors, hard stop.

### Step 1 — Verify preconditions

#### 1a — Cloud login (only when `$MODE == cloud`)

```bash
if [[ "$MODE" == "cloud" ]]; then
  P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
  [[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
  source "$P/scripts/lib.sh"
  cloud_is_logged_in && echo LOGGED_IN || echo NOT_LOGGED_IN
fi
```

`NOT_LOGGED_IN` → hard stop: tell the user to run `/stagent:login` first. Do not dispatch.

For `$MODE == local`, skip this step — no login needed.

#### 1b — Resolve source directory (only in Edit mode, i.e. `$WORKFLOW_FLAG` is non-empty)

Skip this entire sub-step if `$WORKFLOW_FLAG` is empty (Create mode). Otherwise:

For `$WF_TYPE == local`:

```bash
if [[ -n "$WORKFLOW_FLAG" && "$WF_TYPE" == "local" ]]; then
  SOURCE_DIR="${WORKFLOW_FLAG/#\~/$HOME}"
  SOURCE_DIR="${SOURCE_DIR//\$HOME/$HOME}"
  [[ -f "$SOURCE_DIR/workflow.json" ]] || { echo "No workflow.json at $SOURCE_DIR"; exit 1; }
fi
```

For `$WF_TYPE == cloud`: verify ownership, then download.

```bash
P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
[[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
"$P/scripts/check-workflow-ownership.sh" "$WORKFLOW_FLAG"
```

Exit code is always 0; branch on the stdout token.

- `NOT_FOUND` → hard stop: the cloud name does not exist.
- `NOT_OWNER` → hard stop: the workflow belongs to another account; refuse to edit.
- `AUTHORIZED` → download to a local working dir:

  ```bash
  SOURCE_DIR="${HOME}/.config/stagent/workflows/${_WF_NAME}"
  mkdir -p "$SOURCE_DIR"
  cloud_fetch_workflow_from_name "$_WF_NAME" "$SOURCE_DIR"
  ```

### Step 2 — Build `CREATE_WORKFLOW_CONTEXT`

The stagent has a `setup_context` run_file that captures this env var. It's how the `planning` stage gets (a) whether this is create or edit, (b) the user's original description, and (c) the source dir for edit mode.

**Note:** `setup-workflow.sh` has no positional-argument slot for description — putting it in this env var is the only channel through which the planning stage receives it.

`publish_intent` mirrors `$MODE` and tells the stagent's `publishing` stage whether to push to the hub (`cloud`) or skip (`local`).

- **Create mode:**
  ```bash
  export CREATE_WORKFLOW_CONTEXT="$(jq -nc --arg desc "$DESCRIPTION" --arg pi "$MODE" \
    '{mode:"create", description:$desc, publish_intent:$pi}')"
  ```
- **Edit mode:**
  ```bash
  export CREATE_WORKFLOW_CONTEXT="$(jq -nc --arg d "$SOURCE_DIR" --arg desc "$DESCRIPTION" --arg pi "$MODE" \
    '{mode:"edit", source_dir:$d, description:$desc, publish_intent:$pi}')"
  ```

### Step 3 — Pick a short topic slug

Just a short kebab-case label for THIS stagent run's session (NOT the generated workflow's suffix — planning chooses that). Derive something from `$DESCRIPTION` (first few words kebabed), e.g. `create-lint-wf`, `edit-python-lib`.

### Step 4 — Dispatch the stagent

Branch on `$MODE` to pick BOTH the right workflow source AND the session-mode for `setup-workflow.sh`:

- **`$MODE=cloud`(default)** — use the hub-published anonymous mirror so this stagent session is cloud-tracked (gives the user a live `https://stagent.worldstatelabs.com/s/<sid>` link):
  ```bash
  P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
  [[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
  "$P/scripts/setup-workflow.sh" \
    --mode=cloud \
    --topic="<slug-from-step-3>" \
    --flow="cloud://create-template"
  ```

- **`$MODE=local`** — use the plugin-bundled local workflow; runs fully offline, no webapp link:
  ```bash
  P=$(cat ~/.config/stagent/plugin-root 2>/dev/null)
  [[ -n $P && -d $P/scripts ]] || P=$(ls -d ~/.claude/plugins/cache/*/stagent/*/ 2>/dev/null | head -1)
  "$P/scripts/setup-workflow.sh" \
    --mode=local \
    --topic="<slug-from-step-3>" \
    --flow="$P/skills/create-workflow/workflow"
  ```


Do NOT pass `$DESCRIPTION` as a trailing argument — `setup-workflow.sh` silently discards unknown positionals. The description travels via `CREATE_WORKFLOW_CONTEXT` (set in Step 2), which the workflow's `setup_context` run_file captures at session setup.

### Step 4a — Handle the exit code

`setup-workflow.sh`'s exit code is the source of truth for whether dispatch succeeded. Branch on it:

- **Exit 0 — dispatched.** `state.md` exists at the new session's run dir. Continue to Step 5 (report handoff).

- **Exit 2 — session already has an active (or interrupted) workflow.** Phase 0 detected a non-terminal `state.md` for this session. The script's stderr lists the existing topic + status. **Do NOT auto-`--force`** — that would silently archive in-progress work. Relay the script's message to the user and offer three choices, then halt:
  - `/stagent:interrupt` — pause the existing workflow (safe, preserves state)
  - `/stagent:continue` — resume the existing workflow (treats this `/create-workflow` call as the one to discard)
  - `/stagent:cancel` — archive (or `--hard` wipe) the existing run, then retry `/create-workflow` with the same args

  Only re-run `setup-workflow.sh ... --force` if the user **explicitly** says to discard the existing run. Default stance: refuse and ask.

- **Exit 1 or other — real error.** Relay stderr to the user verbatim. Common cases: workflow.json validation errors, `session_id is unknown` (the SessionStart hook cache wasn't populated — tell the user to restart Claude Code), cloud fetch / network failure. Do NOT proceed to Step 5; do NOT auto-fix. Wait for user confirmation before retrying.

On exit 0 only, the state machine is at `planning` and the next turn begins the interview.

### Step 5 — Report handoff (VERBATIM TEXT REQUIRED)

Print the handoff block below **verbatim** — substitute only the
placeholders in angle brackets with real values. Then return control;
the `commands/create-workflow.md` wrapper will invoke `stagent:stagent`
as its next step.

**Hard prohibitions for this step. Read all of them before you type.**

- **DO NOT** add a "Dispatch summary" header, or any other header, on
  top of the block. The block's opening paragraph IS the header.
- **DO NOT** add a "Status: create-workflow stagent dispatched" line,
  or any variant. That line does not exist in this template.
- **DO NOT** rename, reorder, reword, or omit any of the seven
  bullets below. The field labels (`Session (transient)`,
  `Live progress`, `Template (final artifact)`, `Current stage`,
  `Where source files land on disk`, `Cloud publish`, `Abort`) are
  the contract. They are not suggestions.
- **DO NOT** paraphrase, abbreviate, or rewrite the opening paragraph.
  Its wording is the whole reason this step exists — the session /
  template distinction must land exactly as phrased.
- **DO NOT** invent extra fields (e.g. `Change requested`,
  `Editing: ... (ownership verified: is_owner: true)`,
  `Source dir: (downloaded with stages: ...)`). Every field you
  synthesize on top of this template defeats the contract.
- **DO NOT** invoke any other skill from here; the command wrapper
  does that.

---

#### Create mode — print this block verbatim

```
This opens a transient **template-creation session** — it runs the
plan → write → validate → publish flow and leaves behind a new
reusable template in your hub. The template itself does not exist
yet; it appears at cloud://<author>/<suffix> when the session
reaches `complete`.

- **Session (transient)**: <session_id>
- **Live progress**: <stagent.worldstatelabs.com/s/<session_id>>
- **Template (final artifact)**: cloud://<author>/<suffix>
  → visible at <stagent.worldstatelabs.com/hub/<author>/<suffix>>
  once published. Suffix is chosen during planning.
- **Current stage**: `planning` (interruptible) — interview starts next.
- **Where source files land on disk**: `~/.config/stagent/workflows/<suffix>/`
- **Cloud publish** (mode=cloud only): auto-runs after the validator
  passes. If publish fails (expired token, network, name collision),
  the session still terminates at `complete` and you can retry with
  `/stagent:publish <target-dir>`.
- **Abort**: `/stagent:cancel` or `/stagent:interrupt` anytime.
```

#### Edit mode — print this block verbatim

```
This opens a transient **template-edit session** — it re-runs the
plan → write → validate → publish flow against your existing
template `<name>`. Your live template at cloud://<name> is NOT
mutated until this session publishes.

- **Session (transient)**: <session_id>
- **Live progress**: <stagent.worldstatelabs.com/s/<session_id>>
- **Template being edited**: cloud://<name>
  → <stagent.worldstatelabs.com/hub/<name>>
- **Current stage**: `planning` (interruptible) — interview starts next.
- **Source dir (local checkout for this edit)**: `~/.config/stagent/workflows/<name>/`
- **Cloud publish** (mode=cloud only): auto-runs after the validator
  passes, overwriting the hub version with your edits.
- **Abort**: `/stagent:cancel` or `/stagent:interrupt` anytime.
```

**Self-check before sending your response.** Re-read what you're
about to output. If any of the prohibitions above appear in your
text — rewrite it. The block must begin with `This opens a transient`
and have exactly seven bullets in the listed order.

Do NOT call `setup-workflow.sh` again, and do NOT run `loop-tick.sh`
here — that's the next skill's job.

---

## Rules

- Both Create and Edit dispatch the SAME stagent; the only difference is `CREATE_WORKFLOW_CONTEXT`.
- Edit mode must resolve `SOURCE_DIR` (downloading if cloud) BEFORE dispatch — the run_file init runs in the session's setup and reads `$CREATE_WORKFLOW_CONTEXT` from env.
- Cloud publish is handled by the stagent's `publishing` stage (gated on `publish_intent` in `setup_context`). The skill itself does not wait for or call publish.
- Do NOT invoke other skills. Do NOT write workflow files. Your job is flag parsing + preconditions + dispatch.
