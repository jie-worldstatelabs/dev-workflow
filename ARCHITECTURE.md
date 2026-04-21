# meta-workflow Architecture

Internal reference for contributors, workflow authors, and anyone debugging the plugin.

---

## Plugin Layout

```
commands/
  start.md               ← /meta-workflow:start — kick off a run
  interrupt.md           ← pause at the current stage (state preserved)
  continue.md            ← resume from interrupt
  cancel.md              ← abort + archive (or wipe with --hard)
  create-workflow.md     ← create / edit a workflow definition
  publish.md             ← publish a local workflow to the hub
  login.md               ← sign in to the cloud server
  logout.md              ← sign out
  whoami.md              ← show current identity

agents/
  workflow-subagent.md   ← single generic stage executor; reads the active
                           stage's instructions file at runtime

skills/
  meta-workflow/
    SKILL.md             ← meta-protocol: how to drive the state machine
                           (workflow-agnostic)
    workflow/            ← bundled workflow package (local-mode fallback
                           when --workflow is omitted; cloud mode fetches
                           cloud://demo from the hub instead)
      workflow.json      ← state-machine shape
      planning.md        ← per-stage instructions
      executing.md
      verifying.md
      reviewing.md
      qa-ing.md
      run_files_catalog.md
  create-workflow/
    SKILL.md             ← interviews the user, designs + writes workflow
                           bundles, validates, publishes to hub

hooks/
  hooks.json             ← wiring: SessionStart, Stop, PreToolUse:Agent,
                           PostToolUse:Write|Edit|MultiEdit, PostToolUse (all)
  session-start.sh       ← caches Claude's session_id for scripts
  stop-hook.sh           ← state-machine controller; blocks exit during
                           uninterruptible stages
  agent-guard.sh         ← templates the subagent prompt (paths, epoch,
                           frontmatter spec) at Agent-tool launch
  postwrite-hook.sh      ← cloud-mode only: mirrors shadow writes to server
  activity-hook.sh       ← cloud-mode only: posts tool-use events to the
                           cloud activity feed

scripts/
  lib.sh                 ← shared helpers (config reader, state routing,
                           cloud helpers)
  setup-workflow.sh      ← creates state.md (--topic, --workflow, --mode,
                           --force, --validate-only)
  update-status.sh       ← the only legal way to transition; validates
                           required inputs, bumps epoch, clears next stage's
                           stale artifact; in cloud mode also mirrors state
  interrupt-workflow.sh  ← pauses without clearing state
  continue-workflow.sh   ← resumes; with --session does cross-machine cloud
                           takeover; verifies project identity via
                           root-commit fingerprint
  cancel-workflow.sh     ← archives local runs; cloud runs unregister + wipe
                           shadow
  publish-workflow.sh    ← uploads a workflow bundle to the hub
  login-workflow.sh      ← browser-based device-code flow; stores token at
                           ~/.config/meta-workflow/auth.json
  logout-workflow.sh     ← removes auth.json
  whoami-workflow.sh     ← prints identity + verifies token
  stage-context.sh       ← prints a stage's I/O context (paths) after a
                           transition
  parse-workflow-flags.sh ← shared flag parser for /start, /create-workflow
  print-start-banner.sh   ← human-readable banner at /start
  print-create-banner.sh  ← human-readable banner at /create-workflow
```

---

## Runtime Files

**Rule: one Claude session = one run.** Each session's run lives in its own session-keyed subdir. Multiple Claude sessions in the same worktree can run independent workflows without interfering. Completed or replaced runs are archived, not deleted.

### Local mode

```
<project>/.meta-workflow/
  <session_id>/
    state.md                ← status, epoch, topic, session_id, workflow_dir
    baseline                ← git SHA at workflow start
    planning-report.md      ← one file per stage; frontmatter carries epoch+result
    executing-report.md
    verifying-report.md
    reviewing-report.md
    qa-ing-report.md
    journey-tests.md        ← cross-iteration QA state (optional)
  .archive/
    <timestamp>-<topic>/            ← natural-replace archive
    <timestamp>-<topic>-cancelled/  ← soft-cancel archive
```

### Cloud mode

The authoritative copy is the Postgres `sessions` + `artifacts` rows on the server. The local shadow is a write-through mirror — wiped on any terminal status.

```
~/.cache/meta-workflow/sessions/
  <session_id>/              ← shadow
    state.md                 ← local mirror
    baseline
    planning-report.md       ← Claude's Read/Write tools need real paths,
    executing-report.md        so the skill protocol keeps a transient
    verifying-report.md        scratch dir out of the worktree
    reviewing-report.md
    qa-ing-report.md
    .workflow-cache/         ← fetched from hub or copied from local path
      workflow.json
      <stage>.md files

~/.cache/meta-workflow/cloud-registry/
  <session_id>.json          ← existence flag + {mode, scratch_dir, server,
                               workflow_url}; every hook/script uses this
                               file's presence to decide "local or cloud"
```

One 2-line helper (`is_cloud_session <sid>`) in `lib.sh` checks file existence. No env var, no state field, no global.

### Global config & cache (XDG split)

User-level state is split by XDG convention so clearing cache never loses user-owned data:

```
~/.config/meta-workflow/          ← persistent (do not clear)
  auth.json                       ← hub token + user_id + device label
  plugin-root                     ← absolute path to current plugin install
                                    (refreshed by SessionStart hook)
  workflows/<suffix>/             ← user-authored workflow library
    workflow.json / <stage>.md / readme.md

~/.cache/meta-workflow/           ← ephemeral (safe to clear; rebuilt on next use)
  session-cache/                  ← Claude-session-id bridge (PPID + cwd keys)
    cwd-<sha1>                    ← session_id, primary key
    ppid-<pid>                    ← session_id, secondary key
  cloud-registry/<sid>.json       ← per-cloud-session flag (above)
  sessions/<sid>/                 ← cloud shadow (above)
```

Per-project state (`<project>/.meta-workflow/<session_id>/`, local mode) is unaffected — still tracked per project.

---

## `workflow.json` Schema

A workflow is a directory that bundles `workflow.json` + one `<stage>.md` per stage.

```json
{
  "initial_stage": "<stage-name>",
  "terminal_stages": ["complete", "escalated", "cancelled"],
  "max_epoch": 10,
  "run_files": {
    "baseline": {
      "description": "Git SHA at workflow start",
      "init": "git rev-parse HEAD 2>/dev/null || echo EMPTY"
    }
  },
  "stages": {
    "<stage-name>": {
      "interruptible": true,
      "execution": { "type": "inline" },
      "transitions": { "<result>": "<next-stage>" },
      "inputs": {
        "required": [
          { "from_stage": "<other>", "description": "..." },
          { "from_run_file": "baseline", "description": "..." }
        ],
        "optional": []
      }
    }
  }
}
```

### Field reference

| Field | Meaning |
|---|---|
| `initial_stage` | Status written into `state.md` at setup |
| `terminal_stages` | Values that release the stop hook and end the workflow. Don't need to appear in `.stages` — they're just state-machine settling values |
| `max_epoch` | Optional, integer. Default `10`. `update-status.sh` forces `status=escalated` once a transition would push the epoch to or past this cap — breaks runaway loops (e.g. executing↔verifying). User-initiated terminal transitions bypass the cap. If the workflow doesn't declare `escalated` in `.terminal_stages` the cap is skipped with a warning |
| `run_files` | Optional. Data created once at setup time, available as input to any stage via `from_run_file`. `init`'s stdout becomes the file content |
| `stages.*.interruptible` | `true` = stop hook allows session exits during the stage (for user Q&A). Subagent stages MUST be `false` |
| `stages.*.execution` | `{"type":"inline"}` or `{"type":"subagent","model":"<opus\|sonnet\|haiku>"}`. Model is optional; omit to use the subagent's default (sonnet) |
| `stages.*.transitions` | Map of `result:` values to next status (another stage or a terminal) |
| `stages.*.inputs.required` / `optional` | Declares which other stages' artifacts (or run_files) this stage reads. Required artifacts are enforced by `update-status.sh` |

Per-stage `subagent_type` is **NOT supported** — all subagent stages run under the single generic `meta-workflow:workflow-subagent`. The validator rejects it.

---

## State Machine Protocol

### Artifact frontmatter

Every stage artifact is written with a YAML frontmatter block:

```markdown
---
epoch: <current epoch from state.md>
result: <one of the valid values for this stage>
---
# Report body
```

- **`epoch`** — monotonic counter, incremented on every `update-status.sh` call. Tells the stop hook "this artifact is fresh, produced in the current phase."
- **`result`** — looked up in the stage's `transitions` table to determine the next status. Missing or unrecognized result = stage not done.
- **Artifact naming** is uniform: `<session_id>/<stage>-report.md`.

### Transitions

`update-status.sh --status <next>` is the **only** legal way to transition:

1. Validate every required input artifact for `<next>` exists
2. Bump epoch
3. Set `status: <next>` in `state.md`
4. Delete `<session_id>/<next>-report.md` (clean slate)
5. Print `<next>`'s I/O context (required + optional input paths, output path)
6. Cloud mode: mirror state to server; trigger `cloud_post_diff`; wipe shadow on terminal status

### Stop-hook behavior

The stop hook fires at every Claude turn-end. It reads `state.md` and the current stage's artifact:

| Situation | stop-hook behaviour |
|---|---|
| Uninterruptible stage, artifact missing or stale epoch | **Blocks exit** — re-injects "execute the stage" prompt |
| Uninterruptible stage, artifact `result:` matches a transition key | **Blocks exit** — re-injects "call update-status.sh --status <next>" |
| Uninterruptible stage, artifact `result:` unrecognised | **Blocks exit** — asks for manual inspection |
| Interruptible stage | **Never blocks** — emits a `systemMessage` status hint |
| Status is terminal (`complete` / `escalated` / `cancelled`) | Deletes `state.md`, allows exit |
| Status is `interrupted` | Allows exit; keeps `state.md` for `/meta-workflow:continue` |

---

## End-to-End Cycle (default workflow)

Example task: **"Build a note-taking app"** → topic `note-app`.

### Bootstrap

```
USER  ► /meta-workflow:start Build a note-taking app
MAIN  ► reads SKILL.md (meta-protocol)
MAIN  ► derives topic `note-app`
MAIN  ▶ scripts/setup-workflow.sh --topic note-app
        └─ auto `git init` if no repo; creates initial baseline if HEAD is absent
        └─ writes <run-dir>/state.md  (status: planning, epoch: 1)
        └─ writes <run-dir>/baseline  = HEAD SHA
        └─ prints planning's I/O context
```

_From here, `stop-hook` fires on every session-stop attempt; `agent-guard` fires on every Agent-tool call._

### Stage 1 — planning (interruptible, inline)

```
MAIN  ► reads stages/planning.md
MAIN  ⇄ Q&A loop with user (each turn-end → stop-hook emits hint but does NOT block)
MAIN  ✎ writes planning-report.md  (epoch: 1, result: pending)
USER  ► approves
MAIN  ✎ edits frontmatter  (result: pending → approved)
MAIN  ▶ update-status.sh --status executing
        └─ validates planning-report.md exists ✓
        └─ bumps epoch 1 → 2, sets status: executing
        └─ deletes executing-report.md (clean slate)
        └─ prints executing's I/O context
```

### Stage 2 — executing (uninterruptible, subagent opus)

```
MAIN  ► reads stages/executing.md
MAIN  ► calls Agent tool
        └─ PreToolUse: agent-guard prints PROMPT TEMPLATE (paths, epoch, frontmatter spec)
MAIN  ✎ copies the template verbatim into the Agent tool's prompt argument
SUB   ▶ workflow-subagent (opus) runs:
        └─ reads stages/executing.md (stage protocol)
        └─ reads required: planning-report.md
        └─ reads optional: reviewing/qa-ing/verifying (first iter: absent)
        └─ implements plan → writes source files
        └─ writes executing-report.md (epoch: 2, result: done)
MAIN  ▶ update-status.sh --status verifying
```

### Stage 2.5 — verifying (uninterruptible, inline)

```
MAIN  ► detects test command (package.json → npm test, etc.)
MAIN  ▶ runs the test command (3-min timeout)
MAIN  ✎ writes verifying-report.md (epoch: 3, result: PASS | FAIL | SKIPPED)
MAIN  ▶ update-status.sh --status reviewing    (PASS/SKIPPED)
        or update-status.sh --status executing (FAIL → loop; next executing pass
                                                 reads this verifying report as
                                                 optional "quick-test failures")
```

### Stage 3 — reviewing (uninterruptible, subagent sonnet)

```
MAIN  ► calls Agent tool → agent-guard fires → MAIN transcribes PROMPT TEMPLATE
SUB   ▶ workflow-subagent (sonnet) runs:
        └─ reads required: planning-report, executing-report, verifying-report, baseline
        └─ diffs HEAD against baseline
        └─ writes reviewing-report.md (epoch: 4, result: PASS | FAIL)
MAIN  ▶ update-status.sh --status qa-ing   (PASS)
        or update-status.sh --status executing (FAIL → executor receives
                                                 reviewing-report as optional feedback)
```

### Stage 3.5 — qa-ing (uninterruptible, subagent sonnet)

```
SUB   ▶ workflow-subagent (sonnet) runs:
        └─ reads required: planning-report (journey test spec)
        └─ reads/updates journey-tests.md (cross-iteration QA state)
        └─ runs journey tests (Playwright / XcodeBuildMCP / …)
        └─ classifies failures (test bug vs app bug)
        └─ writes qa-ing-report.md (epoch: 5, result: PASS | FAIL)
MAIN  ▶ update-status.sh --status complete   (PASS)
        or update-status.sh --status executing (FAIL → confirmed app bugs become
                                                 next iteration's optional QA feedback)
```

### Termination

```
MAIN  ► next turn-end → stop-hook fires
        └─ sees status: complete (terminal)
        └─ deletes state.md
        └─ exit allowed
MAIN  ● announces completion
```

---

## Cloud Mode Internals

Cloud mode mirrors every workflow file to the hosted webapp so you can watch progress in a browser, share session URLs, and pick up a run from a different machine. The state-machine protocol is unchanged — same stages, same artifacts, same `update-status.sh`. The only differences are **where files live** and **who's authoritative**.

### When to use it

- Want a live browser UI with stage timeline + rendered artifacts + working-tree diff (SSE)
- Want to continue a run from another machine
- Want zero workspace pollution
- OK with a hosted webapp as authoritative store

### Cross-machine continue

`/meta-workflow:continue --session <id>` on a machine that has never seen this cloud session:

1. Pulls the full snapshot (state + artifacts + workflow config + baseline) from the server
2. Verifies the current `pwd` is the same git project via **root-commit fingerprint** (`git rev-list --max-parents=0 HEAD`)
3. On match with a different absolute path: `project_root` auto-updates so `git diff` uses the right working copy
4. On mismatch: exits with a clear error (`--force-project-mismatch` overrides)

### Deep dive

The **[workflowUI README](https://github.com/jie-worldstatelabs/workflowUI)** has the full cloud architecture: write-through mirror table, SSE via Postgres LISTEN/NOTIFY, cross-machine protocol, API reference, database schema, server-operator deploy guide, and troubleshooting.

---

## Design Rationale

- **Config-driven** so workflow shapes are data, not code. Changing a transition is a JSON edit, not a plugin rebuild.
- **One generic subagent** so the model-type decision lives in the workflow config, not in separate agent manifests. Adding a new subagent stage is a single `workflow.json` entry.
- **Epoch counter** because stale artifacts from failed iterations would otherwise confuse the stop hook. Epoch lets us say "only artifacts produced in THIS phase count."
- **Required inputs at the state machine layer** so a misconfigured workflow fails loudly at transition time, not silently at the next stage.
- **One session = one run** so multiple parallel Claude sessions in the same worktree don't collide, and sidecar "observer" sessions are never blocked by another session's stop hook.
- **Cloud registry file as a flag** (not env var, not state field) so every script makes the local-vs-cloud decision with a 2-line helper and no global state.
- **Self-contained skill** (blocks other skill invocations) so the workflow protocol can't be hijacked by brainstorming / planning skills that aren't aware of the state machine.
