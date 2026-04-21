---
name: create-workflow
description: "Create a new workflow suite from a natural-language description, or edit an existing one when --workflow=<path> is passed. Dispatches the create-workflow meta-workflow (plan → write → validate loop) — does not write files directly."
---

# Create / Edit Workflow

This skill **dispatches a meta-workflow** that creates or edits a meta-workflow definition. It does NOT write workflow files itself — the meta-workflow's state machine (`planning → writing → validating`) does that, with validator-driven retry until `✓ Workflow validated` prints.

- **Create mode** (no `--workflow` flag): the meta-workflow's `planning` stage interviews the user from scratch.
- **Edit mode** (`--workflow=<path>` or `--workflow=cloud://author/name`): `planning` pre-loads the existing workflow as the starting point, then asks for changes.

Both modes dispatch the same meta-workflow at `$P/skills/create-workflow/workflow`. The difference is a single env var (`CREATE_WORKFLOW_CONTEXT`) passed at dispatch time.

<CRITICAL>
- Do NOT write any workflow files yourself. Parse flags, verify preconditions, set `CREATE_WORKFLOW_CONTEXT`, call `setup-workflow.sh`, stop.
- Do NOT invoke any other skill before or after.
- Do NOT edit a cloud workflow if the user is not logged in or does not own it — hard stop.
</CRITICAL>

## Plugin path resolution

`$CLAUDE_PLUGIN_ROOT` is NOT set in agent Bash-tool env. Use the session-cached path:

```bash
P="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/meta-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/meta-workflow/*/ 2>/dev/null | head -1)"; }
```

Re-derive `$P` inside every Bash-tool call — shell vars don't persist across calls.

## Protocol

### Step 0 — Parse flags & announce

```bash
P="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/meta-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/meta-workflow/*/ 2>/dev/null | head -1)"; }
eval "$("$P/scripts/parse-workflow-flags.sh" '$ARGUMENTS')" || exit 1
"$P/scripts/print-create-banner.sh" "$MODE" "$WORKFLOW_FLAG" "$WF_TYPE"
```

Values set by the parser:
- `$MODE` — `cloud` (default) or `local`
- `$WORKFLOW_FLAG` — empty for Create, else the `--workflow=` value for Edit
- `$WF_TYPE` — for Edit only: `local` (filesystem path) or `cloud` (`cloud://author/name`)
- `$DESCRIPTION` — everything after the flags

Relay the banner to the user. If the parser emitted errors, hard stop.

### Step 1 — Verify preconditions

#### 1a — Cloud login (required for `--mode=cloud`, regardless of create or edit)

```bash
P="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/meta-workflow
source "$P/scripts/lib.sh"
cloud_is_logged_in && echo LOGGED_IN || echo NOT_LOGGED_IN
```

`NOT_LOGGED_IN` → hard stop: tell the user to run `/meta-workflow:login` first. Do not dispatch.

#### 1b — Edit mode only: resolve the source directory

For `$WF_TYPE=local`:

```bash
SOURCE_DIR="${WORKFLOW_FLAG/#\~/$HOME}"
SOURCE_DIR="${SOURCE_DIR//\$HOME/$HOME}"
[[ -f "$SOURCE_DIR/workflow.json" ]] || { echo "No workflow.json at $SOURCE_DIR"; exit 1; }
```

For `$WF_TYPE=cloud`: verify ownership, then download.

```bash
P="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/meta-workflow
source "$P/scripts/lib.sh"

_WF_NAME="${WORKFLOW_FLAG#cloud://}"
CLOUD_URL="${META_WORKFLOW_SERVER:-https://workflows.worldstatelabs.com}/api/workflows/${_WF_NAME}"
MY_UID="$(jq -r '.user_id // empty' ~/.config/meta-workflow/auth.json 2>/dev/null)"
AUTH="$(_cloud_auth_header)"
BUNDLE="$(curl -sf -H "$AUTH" "$CLOUD_URL" 2>/dev/null || echo '')"

if [[ -z "$BUNDLE" ]]; then
  echo NOT_FOUND
elif [[ "$(echo "$BUNDLE" | jq -r '.user_id // empty')" == "$MY_UID" && -n "$MY_UID" ]]; then
  echo AUTHORIZED
else
  echo "NOT_OWNER owner=$(echo "$BUNDLE" | jq -r '.user_id // unknown') me=$MY_UID"
fi
```

- `NOT_FOUND` → hard stop: the cloud name does not exist.
- `NOT_OWNER` → hard stop: the workflow belongs to another account; refuse to edit.
- `AUTHORIZED` → download to a local working dir:

  ```bash
  SOURCE_DIR="${HOME}/.config/meta-workflow/workflows/${_WF_NAME}"
  mkdir -p "$SOURCE_DIR"
  cloud_fetch_workflow_from_name "$_WF_NAME" "$SOURCE_DIR"
  ```

### Step 2 — Build `CREATE_WORKFLOW_CONTEXT`

The meta-workflow has a `setup_context` run_file that captures this env var. It's how the `planning` stage knows whether to interview from scratch or pre-load an existing workflow.

- **Create mode:**
  ```bash
  export CREATE_WORKFLOW_CONTEXT='{"mode":"create"}'
  ```
- **Edit mode:**
  ```bash
  export CREATE_WORKFLOW_CONTEXT="$(jq -nc --arg d "$SOURCE_DIR" '{mode:"edit", source_dir:$d}')"
  ```

### Step 3 — Pick a short topic slug

Just a short kebab-case label for THIS meta-workflow run's session (NOT the generated workflow's suffix — planning chooses that). Derive something from `$DESCRIPTION` (first few words kebabed), e.g. `create-lint-wf`, `edit-python-lib`.

### Step 4 — Dispatch the meta-workflow

```bash
P="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/meta-workflow
"$P/scripts/setup-workflow.sh" \
  --mode="$MODE" \
  --topic="<slug-from-step-3>" \
  --workflow="$P/skills/create-workflow/workflow" \
  "$DESCRIPTION"
```

This starts the state machine at `planning`. The next turn will begin the interview.

### Step 5 — Report handoff, then stop

Tell the user:

- **Status**: the create-workflow meta-workflow is running (mode: create or edit).
- **Next**: the next turn begins the `planning` stage — the workflow will interview for design (create) or changes (edit), then hand off to the `writing` subagent, then validate. `FAIL` from validator loops back to writing automatically.
- **Where files land**: `~/.config/meta-workflow/workflows/<suffix>/` (suffix chosen in planning for Create; reused for Edit). The final path is echoed in the writer report.
- **Cloud publish**: for `--mode=cloud`, after the meta-workflow completes, run `/meta-workflow:publish <target-dir>` to push to the hub. This skill does NOT auto-publish — it exits after dispatch.
- **Abort**: `/meta-workflow:cancel` or `/meta-workflow:interrupt` any time.

STOP. Do NOT do anything else in this turn — no file writes, no further tool calls.

---

## Rules

- Both Create and Edit dispatch the SAME meta-workflow; the only difference is `CREATE_WORKFLOW_CONTEXT`.
- Edit mode must resolve `SOURCE_DIR` (downloading if cloud) BEFORE dispatch — the run_file init runs in the session's setup and reads `$CREATE_WORKFLOW_CONTEXT` from env.
- Cloud publish after Edit/Create is manual (`/meta-workflow:publish`) — the skill does not wait for meta-workflow completion.
- Do NOT invoke other skills. Do NOT write workflow files. Your job is flag parsing + preconditions + dispatch.
