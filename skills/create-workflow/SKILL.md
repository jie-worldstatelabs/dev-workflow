---
name: create-workflow
description: "Create a new workflow suite from a natural-language description, or edit an existing one when --workflow=<path> is passed. Interviews the user, proposes a stage design, writes files to a local directory, validates the result, and publishes to the hub in cloud mode."
---

# Create / Edit Workflow

This skill **creates or edits** a dev-workflow definition. It does NOT run one.

- **Create mode** (no `--workflow` flag): interviews the user, designs a new workflow from scratch.
- **Edit mode** (`--workflow=<path>`): loads an existing workflow and applies the requested changes.

<CRITICAL>
- Do NOT invoke any other skill before, during, or after.
- Do NOT run `setup-workflow.sh` without `--validate-only`. This skill only creates/edits files; running a workflow is the user's next action.
- Do NOT write files until the user explicitly approves the design (create mode) or the changes (edit mode).
- Do NOT overwrite an existing `~/.dev-workflow/workflows/<name>/` without confirmation (create mode).
- Do NOT edit a cloud workflow if the user is not logged in or does not own it. Hard stop — tell the user and refuse.
</CRITICAL>

## Plugin path resolution

`$CLAUDE_PLUGIN_ROOT` is **not** set in the main agent's Bash-tool env — use the session-cached path (written by the SessionStart hook), with a filesystem fallback:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
```

Re-derive `$P` inside every Bash-tool call — shell vars don't persist across calls.

## Reference material

**Before drafting anything, read the plugin's default workflow as your schema reference and stage-file style guide**:

- `"$P/skills/dev-workflow/workflow/workflow.json"` — the canonical schema shape
- `"$P/skills/dev-workflow/workflow/planning.md"` — interruptible inline stage example
- `"$P/skills/dev-workflow/workflow/verifying.md"` — uninterruptible inline stage example
- `"$P/skills/dev-workflow/workflow/executing.md"` — subagent stage addressed to `workflow-subagent`, model override (opus)
- `"$P/skills/dev-workflow/workflow/reviewing.md"` — subagent stage, sonnet
- `"$P/skills/dev-workflow/workflow/qa-ing.md"` — subagent stage, loops back to executing on failure
- `"$P/skills/dev-workflow/workflow/run_files_catalog.md"` — known run_file patterns and init syntax

Read all seven files once before proposing a stage decomposition. Match their style in the files you generate.

## Schema constraints (enforced by `config_validate`)

The generator MUST respect these. `setup-workflow.sh --validate-only` will reject anything that violates them:

- `.initial_stage` must be one of the declared stages
- `.terminal_stages` must be a non-empty array of strings. Conventional terminal stages are `complete` and `escalated` (and optionally `cancelled`). Terminal stage names do NOT need to appear in `.stages`; they're just the values the state machine settles into.
- `.stages` must be an object. Each stage has:
  - `interruptible`: boolean
  - `execution`: `{ "type": "inline" }` OR `{ "type": "subagent", "model": "<opus|sonnet|haiku>" }`. Model is optional; omit to use the generic subagent's default (sonnet).
  - `transitions`: object mapping result-value strings to next-status strings (another declared stage OR a terminal)
  - `inputs.required`: array of `{ "from_stage": "<name>", "description": "<text>" }` OR `{ "from_run_file": "<name>", "description": "<text>" }`
  - `inputs.optional`: same shape, may be empty
- **`run_files` (optional top-level):** data created once at setup time and available to any stage. Each entry: `{ "description": "...", "init": "<shell command>" }`. The init command runs in `$PROJECT_ROOT`; its stdout becomes the file. Stages consume run_files via `from_run_file` in their inputs. See `run_files_catalog.md` for known patterns (e.g. `baseline` for git SHA). Every `from_run_file` reference must name a key declared in `.run_files` — the validator enforces this.
- **Subagent stages MUST have `"interruptible": false`.** The main agent blocks on the Agent tool call — the stop hook has no chance to fire during a subagent run, so `interruptible: true` on a subagent stage is a silent lie the validator rejects.
- `subagent_type` as a per-stage field is **NOT supported**. All subagent stages run under the single generic `dev-workflow:workflow-subagent`, whose system prompt is the stage file the main agent passes in the prompt template. Don't write this field; the validator rejects it.
- Every declared stage must have a corresponding `<stage>.md` file next to `workflow.json`.
- Every transition target must be either another declared stage name OR a terminal stage name.
- Every `inputs.required[*].from_stage` and `inputs.optional[*].from_stage` must reference a declared stage.

## Stage file guidelines

**All stage files should include**:
- A short header (`# Stage: <name>`)
- A purpose line
- The list of valid `result:` values (must match the keys in `transitions` for that stage)
- The frontmatter format the file must produce (epoch source differs by execution type — see below):
  ```
  ---
  epoch: <epoch>
  result: <one of the valid values>
  ---
  ```

**For inline stages** (execution.type = `inline`): address the main agent. The epoch comes from reading `state.md`. Distinguish by `interruptible`:

- **`interruptible: true`** — the agent may pause for user input mid-stage. Instruct it to: (1) read `state.md` for the current epoch, (2) immediately write the artifact at the path shown in I/O context with `result: pending` (so the stop hook knows the stage is in progress), (3) do the work, optionally pausing for user input, (4) overwrite the artifact with the final `result:` when done.
- **`interruptible: false`** — the agent runs autonomously. Instruct it to: read `state.md` for the epoch, do the work without pausing, write the artifact with the final `result:` when done.

For both interruptible variants: instruct the agent to **read each required input from the path shown in its I/O context for that input — never construct or hardcode input paths**.

Do NOT instruct the stage to call `update-status.sh` — that is the main loop's responsibility, not the stage file's.

**For subagent stages** (execution.type = `subagent`): address the `workflow-subagent`. The epoch is provided in the subagent's prompt by the agent-guard hook — instruct it to read the epoch from its prompt, not from `state.md`. Instruct it to **read each required input from the absolute path given in its prompt for that input — never construct or hardcode input paths**. ("You are <role>. Read the inputs listed in your prompt. Do X, Y, Z. Write the output artifact at **the absolute path given in your prompt** with the frontmatter above, using the epoch from your prompt."). The subagent reads this file as its canonical protocol.

Tune the body to the stage's domain (a reviewer stage talks about severity classes, a tester stage talks about test commands, etc.). Look at `reviewing.md` and `qa-ing.md` in the default workflow for examples of domain-specific bodies.

## Protocol

### Step 0 — Parse, validate & announce

Parse flags, validate them, announce what will happen, then dispatch. **Do not proceed if any error is emitted.**

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }
eval "$("$P/scripts/parse-workflow-flags.sh" '$ARGUMENTS')" || exit 1
"$P/scripts/print-create-banner.sh" "$MODE" "$WORKFLOW_FLAG" "$WF_TYPE"
```

Relay the banner to the user before continuing.

- If `WORKFLOW_FLAG` is non-empty → **Edit mode**: skip to the [Edit Mode](#edit-mode) section below.
- If `WORKFLOW_FLAG` is empty → **Create mode** (continue to Step 1). `MODE` controls whether the finished workflow is published to the hub (`cloud`, default) or kept local only (`local`).

---

### Step 1 — Understand the user's goal

Read `$ARGUMENTS` (the description the user typed after `/dev-workflow:create-workflow`). If it's empty or too vague to decompose, ask ONE clarifying question at a time (cap at 5 questions total). Useful axes:

- What kind of work does this workflow orchestrate? (coding, writing, data analysis, review, etc.)
- What are the rough phases? (a 3-line sketch is enough — you'll refine them in Step 2.)
- Any phase where the user should pause for input? (interruptible inline stages)
- Any phase that benefits from a stronger model? (subagent stages with `model: opus`)
- Any external validation or test run? (subagent or inline stage that runs a command)
- What's the success terminal? (usually `complete`. If the workflow has a meaningful "ship it" action, you might name a different terminal.)

Stop asking once you can draft a stage decomposition.

### Step 2 — Propose a stage decomposition

Present the proposed workflow as a table, followed by the transition graph. Include **every** field the schema requires:

| Stage | Execution | Model | Interruptible | Purpose | Result values |
|---|---|---|---|---|---|
| <name> | inline / subagent | (if subagent) | true/false | <one-line role> | `result: X` → next stage |

Then show the transition graph as a list:

```
<initial_stage> --(<result>)--> <stage2>
<stage2> --(done)--> <stage3>
<stage3> --(PASS)--> complete
<stage3> --(FAIL)--> <stage2>
```

Call out inputs each stage consumes (`required` and `optional`). Required inputs are enforced at transition time by `update-status.sh`.

Ask the user: **"Does this design look right? Any changes to stages, order, or inputs?"** Iterate until they approve.

### Step 3 — Pick a workflow name

Derive a short, kebab-case suffix from the user's description (e.g. "Python library dev with docs and publish" → `python-lib`, "research paper drafting" → `paper-draft`).

Ask the user to confirm the suffix.

The local directory is always `~/.dev-workflow/workflows/<suffix>/` regardless of mode. The author prefix (e.g. `jie/paper-draft`) is added by `publish-workflow.sh` at publish time from the logged-in account — the skill never constructs or stores it.

**Local collision check:** if `~/.dev-workflow/workflows/<suffix>/` already exists, tell the user and ask whether to pick a different name or overwrite. Do NOT overwrite silently.

**Cloud collision check:** `publish-workflow.sh` performs a GET pre-check before publishing. If the name is taken by another user it exits with a clear error; if you already own it, it warns "Updating existing workflow" and proceeds. No separate check needed here — the collision is caught at publish time.

### Step 4 — Write the files

Create the target directory:

```bash
mkdir -p ~/.dev-workflow/workflows/<suffix>
```

Write `workflow.json` strictly matching the schema (see the Schema constraints section + read the default `workflow.json` as reference). Validate locally by eye against the constraints list — don't leak a per-stage `subagent_type` field or set `interruptible: true` on a subagent stage.

Write one `<stage>.md` per declared stage — see the [shared Stage file guidelines](#stage-file-guidelines).

### Step 5 — Validate

Run the [shared Validate step](#validate) with `--workflow="$HOME/.dev-workflow/workflows/<suffix>"`. Do NOT proceed to Step 5.5 (cloud mode) or Step 6 (local mode) until validation passes.

### Step 5.5 — Publish to hub (cloud mode only)

Skip this step if `MODE=local`.

Run the [shared Publish step](#publish-to-hub) with `"$HOME/.dev-workflow/workflows/<suffix>"`. On failure, tell the user and continue — the workflow is still usable locally via `--workflow=~/.dev-workflow/workflows/<suffix>`.

### Step 6 — Report success

Tell the user:

- **Where**: `~/.dev-workflow/workflows/<suffix>/` (absolute path)
- **What's in it**: `workflow.json` + one `.md` per stage
- **Validator summary** from Step 5 (one line, N stages / M terminal)
- **Hub** (cloud mode only): relay the output from `publish-workflow.sh` verbatim — it already prints the hub URL, pull command, and visibility. If it failed, show the error and note the local path still works.
- **How to launch**:
  - Cloud: `/dev-workflow:start --workflow=<cloud://... from publish output> <your task>`
  - Local: `/dev-workflow:start --workflow=~/.dev-workflow/workflows/<suffix> <your task>`

Do NOT run `/dev-workflow:start` yourself — that's the user's next action. Your job is done when the files are on disk, validation passed, and (in cloud mode) the workflow is published.

---

## Validate

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
"$P/scripts/setup-workflow.sh" --validate-only --workflow="<absolute-path>"
```

Expected on success:

```
✓ Workflow validated: N stages, M terminal
   dir:      <absolute path>
   initial:  <initial_stage>
   stages:   <space-separated stage names>
   terminal: <space-separated terminal stages>
```

If validation fails, the output has `❌` lines for each problem (missing stage file, invalid transition target, unsupported `subagent_type` field, subagent stage with `interruptible: true`, etc.). **Read them, fix the generated files, re-run** until it passes.

---

## Publish to hub

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
"$P/scripts/publish-workflow.sh" "<absolute-path-to-workflow-dir>"
```

`publish-workflow.sh` handles auth automatically:
- **Logged in** → workflow is **private** (only you can access it)
- **Anonymous** → workflow is **public** (anyone with the link can use it)

If the name already exists under your account, the script warns "Updating existing workflow" and proceeds. If the name is taken by another user, it exits with a clear error — pick a different suffix.

---

## Edit Mode

`$WORKFLOW_FLAG` is the value extracted from `--workflow=<path>` in Step 0.

### Edit Step 1 — Classify the path

Determine whether `$WORKFLOW_FLAG` points to a local directory or a `cloud://author/name` reference:

```bash
WORKFLOW_FLAG="<value from Step 0>"

RESOLVED="${WORKFLOW_FLAG/#\~/$HOME}"
if [[ -f "${RESOLVED}/workflow.json" ]]; then
  echo "TYPE=local DIR=${RESOLVED}"
elif [[ "$WORKFLOW_FLAG" =~ ^cloud://[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "TYPE=cloud"
else
  echo "ERROR: '${WORKFLOW_FLAG}' is not a local workflow directory and does not look like a cloud://author/name reference"
fi
```

- **`local`**: a filesystem directory containing `workflow.json` → edit directly. Skip to Edit Step 3.
- **`cloud`**: `cloud://author/name` format → must validate ownership. Continue to Edit Step 2.
- **error**: path is neither → hard stop, tell the user the path is invalid.

**Mode/type consistency check** (run immediately after classification):
- If `TYPE=cloud` and `MODE=local` → **hard stop**: tell the user that `cloud://author/name` is a cloud reference and cannot be used with `--mode=local`. They should either remove `--mode=local` (cloud is the default) or pass a local directory path.
- If `TYPE=local` and `MODE=cloud` → proceed normally (editing a local workflow before publishing is valid).

This check prevents the `--mode` flag from being silently ignored when it conflicts with the workflow source type.

### Edit Step 2 — Cloud ownership validation

**This step only runs for `cloud://author/name` paths.**

The API URL is: `${DEV_WORKFLOW_SERVER}/api/workflows/${WORKFLOW_FLAG}`

#### 2a — Check login

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
source "$P/scripts/lib.sh"
cloud_is_logged_in && echo "LOGGED_IN" || echo "NOT_LOGGED_IN"
```

If `NOT_LOGGED_IN` → **hard stop**: tell the user they must run `/dev-workflow:login` first, then refuse to proceed.

#### 2b — Verify ownership

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
source "$P/scripts/lib.sh"

_WF_NAME="${WORKFLOW_FLAG#cloud://}"
CLOUD_URL="${DEV_WORKFLOW_SERVER}/api/workflows/${_WF_NAME}"
MY_USER_ID="$(jq -r '.user_id // empty' ~/.dev-workflow/auth.json 2>/dev/null)"
AUTH_HEADER="$(_cloud_auth_header)"
BUNDLE="$(curl -sf -H "$AUTH_HEADER" "$CLOUD_URL" 2>/dev/null || echo "")"

if [[ -z "$BUNDLE" ]]; then
  echo "NOT_FOUND"
elif [[ "$(echo "$BUNDLE" | jq -r '.user_id // empty')" == "$MY_USER_ID" && -n "$MY_USER_ID" ]]; then
  echo "AUTHORIZED"
else
  OWNER="$(echo "$BUNDLE" | jq -r '.user_id // "unknown"')"
  echo "NOT_OWNER owner=${OWNER} me=${MY_USER_ID}"
fi
```

- `NOT_FOUND` → hard stop: the cloud name returned nothing.
- `NOT_OWNER` → hard stop: tell the user the workflow belongs to another account and refuse to edit.
- `AUTHORIZED` → download the workflow files to a local working directory, then continue.

To download:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
source "$P/scripts/lib.sh"

_WF_NAME="${WORKFLOW_FLAG#cloud://}"
LOCAL_DIR="${HOME}/.dev-workflow/workflows/${_WF_NAME}"
mkdir -p "$LOCAL_DIR"
cloud_fetch_workflow_from_name "$_WF_NAME" "$LOCAL_DIR"
echo "Downloaded to $LOCAL_DIR"
```

Continue to Edit Step 3 with `LOCAL_DIR` as the working directory.

### Edit Step 3 — Load and display current design

Read `workflow.json` and all stage `.md` files from the working directory (`LOCAL_DIR` for cloud, or the resolved local path from Edit Step 1). Display the current stage decomposition as a table (same format as Create Mode Step 2) and the transition graph.

If `$DESCRIPTION` (the part of `$ARGUMENTS` after stripping `--workflow=<path>`) is non-empty, treat it as the user's requested change. Otherwise ask: **"What changes do you want to make?"**

### Edit Step 4 — Iterate on changes

Apply requested changes to the in-memory design. Show the updated table + transition graph. Ask: **"Does this look right? Any further changes?"** Iterate until the user approves.

If no changes are needed (user just wanted to view), say so and stop without writing files.

### Edit Step 5 — Write updated files

Write only the files that changed (workflow.json and/or the affected stage `.md` files) back to the working directory. Follow the [shared Stage file guidelines](#stage-file-guidelines).

### Edit Step 6 — Validate

Run the [shared Validate step](#validate) with the working directory absolute path. Fix any errors and re-run until validation passes.

### Edit Step 6.5 — Push back to cloud (cloud source only)

Skip this step if the workflow came from a local path.

Run the [shared Publish step](#publish-to-hub) with `"$LOCAL_DIR"`. On success: note the hub URL for the Step 7 report. On failure: tell the user the changes are saved locally at `$LOCAL_DIR` and they can retry with `/dev-workflow:publish <LOCAL_DIR>`. Do NOT abort — the local edits are still valid.

### Edit Step 7 — Report success

Tell the user:
- **Where**: absolute path to the working directory
- **What changed**: list of files written
- **Validator summary** from Edit Step 6
- **Hub** (cloud source only):
  - If publish succeeded: "Changes pushed to hub — `<hub-url>`"
  - If publish failed: "Changes saved locally at `$LOCAL_DIR` — push manually with `/dev-workflow:publish <LOCAL_DIR>`"
- **How to launch**:
  - Cloud: `/dev-workflow:start --workflow=<cloud://... from publish output> <your task>`
  - Local: `/dev-workflow:start --workflow=<path> <your task>`

---

## Key Rules

- Always read the default workflow files as reference before proposing a design (create mode).
- Always iterate on the design with the user before writing files.
- Always run `--validate-only` before reporting success.
- Always push back to the hub after a successful edit of a cloud workflow (Edit Step 6.5).
- Never write to `~/.dev-workflow/workflows/<name>/` without user approval.
- Never overwrite an existing workflow dir without confirmation (create mode).
- Never set `interruptible: true` on a subagent stage.
- Never write a `subagent_type` field — all subagent stages use the generic `dev-workflow:workflow-subagent`.
- Never invoke any other skill or run the full `setup-workflow.sh` (only `--validate-only`).
- Never edit a cloud workflow unless the user is logged in AND owns it — hard stop otherwise.
- `--workflow=` in edit mode must be an explicit local directory path or `cloud://author/name` reference — never guess or resolve bare names.
