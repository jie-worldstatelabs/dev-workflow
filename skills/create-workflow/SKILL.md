---
name: create-workflow
description: "Create a new workflow suite from a natural-language description, or edit an existing one when --workflow=<name> is passed. Interviews the user, proposes a stage design, writes files to ~/.dev-workflow/workflows/<name>/, and validates the result."
---

# Create / Edit Workflow

This skill **creates or edits** a dev-workflow definition. It does NOT run one.

- **Create mode** (no `--workflow` flag): interviews the user, designs a new workflow from scratch.
- **Edit mode** (`--workflow=<name>`): loads an existing workflow and applies the requested changes.

<CRITICAL>
- Do NOT invoke any other skill before, during, or after.
- Do NOT run `setup-workflow.sh` without `--validate-only`. This skill only creates/edits files; running a workflow is the user's next action.
- Do NOT write files until the user explicitly approves the design (create mode) or the changes (edit mode).
- Do NOT overwrite an existing `~/.dev-workflow/workflows/<name>/` without confirmation (create mode).
- Do NOT edit a cloud workflow if the user is not logged in or does not own it. Hard stop — tell the user and refuse.
- Do NOT edit plugin-bundled workflows in-place. Copy to `~/.dev-workflow/workflows/<name>/` first and edit the copy.
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

Read all six files once before proposing a stage decomposition. Match their style in the files you generate.

## Schema constraints (enforced by `config_validate`)

The generator MUST respect these. `setup-workflow.sh --validate-only` will reject anything that violates them:

- `.initial_stage` must be one of the declared stages
- `.terminal_stages` must be a non-empty array of strings. Conventional terminal stages are `complete` and `escalated` (and optionally `cancelled`). Terminal stage names do NOT need to appear in `.stages`; they're just the values the state machine settles into.
- `.stages` must be an object. Each stage has:
  - `interruptible`: boolean
  - `execution`: `{ "type": "inline" }` OR `{ "type": "subagent", "model": "<opus|sonnet|haiku>" }`. Model is optional; omit to use the generic subagent's default (sonnet).
  - `transitions`: object mapping result-value strings to next-status strings (another declared stage OR a terminal)
  - `inputs.required`: array of `{ "from_stage": "<name>", "description": "<text>" }`
  - `inputs.optional`: same shape, may be empty
- **Subagent stages MUST have `"interruptible": false`.** The main agent blocks on the Agent tool call — the stop hook has no chance to fire during a subagent run, so `interruptible: true` on a subagent stage is a silent lie the validator rejects.
- `subagent_type` as a per-stage field is **NOT supported**. All subagent stages run under the single generic `dev-workflow:workflow-subagent`, whose system prompt is the stage file the main agent passes in the prompt template. Don't write this field; the validator rejects it.
- Every declared stage must have a corresponding `<stage>.md` file next to `workflow.json`.
- Every transition target must be either another declared stage name OR a terminal stage name.
- Every `inputs.required[*].from_stage` and `inputs.optional[*].from_stage` must reference a declared stage.

## Protocol

### Step 0 — Parse arguments and dispatch

Extract the `--workflow=<name>` flag from `$ARGUMENTS` (if present) and strip it from the remaining description text:

```bash
ARGS='$ARGUMENTS'
WORKFLOW_FLAG=""
DESCRIPTION="$ARGS"
if [[ "$ARGS" =~ (^|[[:space:]])--workflow=([^[:space:]]+) ]]; then
  WORKFLOW_FLAG="${BASH_REMATCH[2]}"
  DESCRIPTION="${ARGS/--workflow=${WORKFLOW_FLAG}/}"
  DESCRIPTION="${DESCRIPTION#"${DESCRIPTION%%[![:space:]]*}"}"  # ltrim
  DESCRIPTION="${DESCRIPTION%"${DESCRIPTION##*[![:space:]]}"}"  # rtrim
fi
echo "FLAG=${WORKFLOW_FLAG}"
echo "DESC=${DESCRIPTION}"
```

- If `WORKFLOW_FLAG` is non-empty → **Edit mode**: skip to the [Edit Mode](#edit-mode) section below.
- If `WORKFLOW_FLAG` is empty → **Create mode**: continue to Step 1.

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

Derive a short, kebab-case name from the user's description (e.g. "Python library dev with docs and publish" → `python-lib`, "research paper drafting" → `paper-draft`). Show the name and ask for confirmation.

Check for collision: if `~/.dev-workflow/workflows/<name>/` already exists, tell the user and ask whether to pick a different name or overwrite. Do NOT overwrite silently.

### Step 4 — Write the files

Create the target directory:

```bash
mkdir -p ~/.dev-workflow/workflows/<name>
```

Write `workflow.json` strictly matching the schema (see the Schema constraints section + read the default `workflow.json` as reference). Validate locally by eye against the constraints list — don't leak a per-stage `subagent_type` field or set `interruptible: true` on a subagent stage.

Write one `<stage>.md` per declared stage. Guidelines:

**All stage files should include**:
- A short header (`# Stage: <name>`)
- A purpose line
- An output-artifact path template: `<project>/.dev-workflow/<session_id>/<stage>-report.md`
- The list of valid `result:` values (must match the keys in `transitions` for that stage)
- The frontmatter format the file must produce:
  ```
  ---
  epoch: <epoch from the prompt>
  result: <one of the valid values>
  ---
  ```

**For inline stages** (execution.type = `inline`): address the main agent ("You drive this stage directly. Read state.md to get the epoch, do <the work>, write the output artifact with the frontmatter above, then call `update-status.sh --status <next>`.")

**For subagent stages** (execution.type = `subagent`): address the generic `workflow-subagent` ("You are <role>. Read the inputs listed in your prompt. Do X, Y, Z. Write the output artifact at the absolute path given in your prompt with the frontmatter above."). The subagent will be given the stage file's absolute path via `agent-guard.sh`'s prompt template — it reads the file first as its canonical protocol.

Tune the body to the stage's domain (a reviewer stage talks about severity classes, a tester stage talks about test commands, etc.). Look at `reviewing.md` and `qa-ing.md` in the default workflow for examples of domain-specific bodies.

### Step 5 — Validate

Run `setup-workflow.sh --validate-only --workflow=<absolute-path>`:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
"$P/scripts/setup-workflow.sh" --validate-only --workflow="$HOME/.dev-workflow/workflows/<name>"
```

Expected on success:

```
✓ Workflow validated: N stages, M terminal
   dir:      <absolute path>
   initial:  <initial_stage>
   stages:   <space-separated stage names>
   terminal: <space-separated terminal stages>
```

If validation fails, the output has `❌` lines for each problem (missing stage file, invalid transition target, unsupported `subagent_type` field, subagent stage with `interruptible: true`, etc.). **Read them, fix the generated files, re-run.** Do NOT proceed to Step 6 until validation passes.

### Step 6 — Report success

Tell the user:

- **Where**: `~/.dev-workflow/workflows/<name>/` (absolute path)
- **What's in it**: `workflow.json` + one `.md` per stage
- **How to launch**:
  ```
  /dev-workflow:dev --workflow=<name> <your task>
  ```
  The `--workflow=<bare-name>` resolution checks the plugin's bundled workflows first, then falls back to `~/.dev-workflow/workflows/<name>/`, so both work. If the user prefers an absolute path, `--workflow=~/.dev-workflow/workflows/<name>` is also fine.
- **Validator summary** from Step 5 (one line, N stages / M terminal).

Do NOT run `/dev-workflow:dev` yourself — that's the user's next action. Your job is done when the files are on disk and validation passed.

---

## Edit Mode

### Edit Step 1 — Resolve workflow location

Run the following to determine whether `<name>` is local, bundled, or cloud:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || { P=~/.claude/plugins/dev-workflow; [[ -d $P/scripts ]] || P="$(ls -d ~/.claude/plugins/cache/*/dev-workflow/*/ 2>/dev/null | head -1)"; }

WORKFLOW_NAME="<name>"
LOCAL_DIR="${HOME}/.dev-workflow/workflows/${WORKFLOW_NAME}"
BUNDLED_DIR="${P}/skills/dev-workflow/${WORKFLOW_NAME}"

if [[ -f "${LOCAL_DIR}/workflow.json" ]]; then
  echo "TYPE=local DIR=${LOCAL_DIR}"
elif [[ -f "${BUNDLED_DIR}/workflow.json" ]]; then
  echo "TYPE=bundled DIR=${BUNDLED_DIR}"
else
  echo "TYPE=cloud"
fi
```

- **`local`**: `~/.dev-workflow/workflows/<name>/` exists → edit directly. Skip to Edit Step 3.
- **`bundled`**: plugin-built-in workflow → do NOT edit in place. Tell the user you will copy it to `~/.dev-workflow/workflows/<name>/` as a local override and edit that copy. Ask confirmation, then `cp -R "${BUNDLED_DIR}/." "${LOCAL_DIR}/"`. Skip to Edit Step 3.
- **`cloud`**: not found locally → must validate ownership first. Continue to Edit Step 2.

### Edit Step 2 — Cloud ownership validation

**This step only runs for cloud workflows.**

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

MY_USER_ID="$(jq -r '.user_id // empty' ~/.dev-workflow/auth.json 2>/dev/null)"
AUTH_HEADER="$(_cloud_auth_header)"
BUNDLE="$(curl -sf -H "$AUTH_HEADER" "${DEV_WORKFLOW_SERVER}/api/workflows/${WORKFLOW_NAME}" 2>/dev/null || echo "")"

if [[ -z "$BUNDLE" ]]; then
  echo "NOT_FOUND"
elif [[ "$(echo "$BUNDLE" | jq -r '.user_id // empty')" == "$MY_USER_ID" && -n "$MY_USER_ID" ]]; then
  echo "AUTHORIZED"
else
  OWNER="$(echo "$BUNDLE" | jq -r '.user_id // "unknown"')"
  echo "NOT_OWNER owner=${OWNER} me=${MY_USER_ID}"
fi
```

- `NOT_FOUND` → hard stop: workflow `<name>` not found on server.
- `NOT_OWNER` → hard stop: tell the user the workflow belongs to another account and refuse to edit.
- `AUTHORIZED` → download the workflow files locally:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
source "$P/scripts/lib.sh"
DEST="${HOME}/.dev-workflow/workflows/${WORKFLOW_NAME}"
mkdir -p "$DEST"
cloud_fetch_workflow_from_name "$WORKFLOW_NAME" "$DEST"
echo "Downloaded to $DEST"
```

Continue to Edit Step 3.

### Edit Step 3 — Load and display current design

Read `~/.dev-workflow/workflows/<name>/workflow.json` and all stage `.md` files. Display the current stage decomposition as a table (same format as Create Mode Step 2) and the transition graph.

If `$DESCRIPTION` (the part of `$ARGUMENTS` after stripping `--workflow=<name>`) is non-empty, treat it as the user's requested change. Otherwise ask: **"What changes do you want to make?"**

### Edit Step 4 — Iterate on changes

Apply requested changes to the in-memory design. Show the updated table + transition graph. Ask: **"Does this look right? Any further changes?"** Iterate until the user approves.

If no changes are needed (user just wanted to view), say so and stop without writing files.

### Edit Step 5 — Write updated files

Write only the files that changed (workflow.json and/or the affected stage `.md` files). Follow the same file guidelines as Create Mode Step 4.

If this was a cloud workflow: add a note that the edits are saved locally at `~/.dev-workflow/workflows/<name>/`. To use the updated workflow, pass `--workflow=<name>` — the local copy takes precedence over the server copy.

### Edit Step 6 — Validate

Same as Create Mode Step 5:

```bash
P="$(cat ~/.dev-workflow/plugin-root 2>/dev/null)"
[[ -d $P/scripts ]] || P=~/.claude/plugins/dev-workflow
"$P/scripts/setup-workflow.sh" --validate-only --workflow="$HOME/.dev-workflow/workflows/<name>"
```

Fix any errors and re-run until validation passes.

### Edit Step 7 — Report success

Tell the user:
- **Where**: `~/.dev-workflow/workflows/<name>/` (absolute path)
- **What changed**: list of files written
- **How to launch**: `/dev-workflow:dev --workflow=<name> <your task>`
- **Validator summary** from Edit Step 6

---

## Key Rules

- Always read the default workflow files as reference before proposing a design (create mode).
- Always iterate on the design with the user before writing files.
- Always run `--validate-only` before reporting success.
- Never write to `~/.dev-workflow/workflows/<name>/` without user approval.
- Never overwrite an existing workflow dir without confirmation (create mode).
- Never set `interruptible: true` on a subagent stage.
- Never write a `subagent_type` field — all subagent stages use the generic `dev-workflow:workflow-subagent`.
- Never invoke any other skill or run the full `setup-workflow.sh` (only `--validate-only`).
- Never edit a cloud workflow unless the user is logged in AND owns it — hard stop otherwise.
- Never edit plugin-bundled workflows in-place — copy to `~/.dev-workflow/workflows/<name>/` first.
