# stagent

A Claude Code plugin that runs **config-driven development workflows** as a state machine. You declare stages, transitions, and inputs in a single `workflow.json`; the plugin's hooks and scripts drive the loop.

Two modes:
- **Cloud** (default) — state mirrored to a hosted webapp with a live browser viewer, cross-machine resume, and zero project-dir footprint.
- **Local** — state and artifacts live under `<project>/.stagent/`, no network.

## Installation

Run these slash commands **inside a Claude Code session**. Cloud mode is on by default — no config or keys required; anonymous sessions work for `/stagent:start` and `/stagent:continue`. An account (`/stagent:login`) is only needed to publish workflows to the hub or claim authenticated ownership.

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent@stagent
```

Requires: [Claude Code](https://claude.ai/claude-code), `jq`, `curl`, `git` (cloud mode also relies on standard POSIX tools like `sha256sum` / `shasum`).

## Quick Start

Start a workflow — the default development workflow builds what you describe:

```
/stagent:start "Build a journaling app with MBTI insights"
```

The skill prints a live UI URL:

```
UI: https://stagent.worldstatelabs.com/s/<session_id>
```

Paste it in a browser to watch the stage timeline, rendered artifacts, and `git diff baseline..HEAD` update live via SSE. The project worktree stays clean — nothing under `.stagent/`.

Or define your own workflow from a natural-language prompt — stagent scaffolds the stages:

```
/stagent:create "plan, implement, critique & score UX"
```

For a fully offline run, switch to local mode:

```
/stagent:start --mode=local "Build a journaling app with MBTI insights"
```

## The Default Workflow

With no `--flow` flag:

- **Cloud mode** (default) fetches `cloud://demo` from the hub — a hosted template that may evolve independently of this README
- **Local mode** uses the plugin-bundled workflow at `skills/stagent/workflow/` (offline fallback) — the canonical source for the cycle described below

The bundled workflow runs a **plan → execute → verify → review → QA → loop** cycle:

1. **Planning** *(interruptible)* — inline Q&A with you: clarifying questions, proposed approaches, plan file. You confirm before anything gets built.
2. **Executing** — subagent (opus) implements the plan: tests-first when specified, minimal focused changes.
3. **Verifying** — quick tests (unit/integration) run inline. FAIL → loop to Execute; PASS/SKIPPED → Review.
4. **Reviewing** — subagent runs adversarial code review against the baseline commit. PASS → QA; FAIL → loop to Execute.
5. **QA-ing** — subagent runs real user journey tests (Playwright, XcodeBuildMCP, etc.). Distinguishes test bugs from app bugs — only confirmed app bugs block progress. PASS → complete; FAIL → loop to Execute.

The `execute → verify → review → QA` loop runs **autonomously** after you approve the plan. A Stop hook guarantees the loop runs to completion. The loop stops on one of: QA passes (terminal `complete`), `max_epoch` is hit (default `20`, configured in `workflow.json` → `.max_epoch`; breaks runaway iteration by forcing terminal `escalated`), or you intervene with `/stagent:interrupt` (pauses) or `/stagent:cancel` (terminal `cancelled`). All three — `complete`, `escalated`, `cancelled` — are declared in `workflow.json` → `.terminal_stages`.

## Custom Workflows

The plugin is **generic** — any stage shape works as long as it follows the schema. Running `/stagent:create` (see Quick Start) dispatches an internal stagent that interviews you, writes `workflow.json` + per-stage instruction files under `~/.config/stagent/workflows/<name>/`, validates them in a retry loop, and publishes the bundle to the hub (cloud mode only). Reuse it with:

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the `workflow.json` schema.

Need ideas for what to turn into a workflow? See the [cookbook](./docs/claude-code-cookbook.md) — seven common Claude Code misbehaviors (no-research coding, self-approved done, scope creep, symptom-only bug fixes, ignored TDD, skipped visual QA, forgotten constraints) with ready-to-run `/stagent:create` prompts for each.

## Commands

| Command | Purpose |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | Start a new run |
| `/stagent:interrupt` | Pause the active run without clearing state (can be called mid-stage; resume with `/stagent:continue`) |
| `/stagent:continue [--session <id>]` | Resume an interrupted run (`--session` for cross-machine cloud takeover) |
| `/stagent:cancel [--hard]` | Cancel the run. Default archives; `--hard` hard-deletes. Local-mode files are archived/removed accordingly; in cloud mode the local shadow is wiped either way and the difference is only on the server (archived vs hard-deleted) |
| `/stagent:create [--flow=<ref>] <description>` | Create a new workflow or edit an existing one |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | Publish a local workflow to the hub |
| `/stagent:login` / `:logout` / `:whoami` | Manage your hub identity |

**`--flow=<ref>`** accepts:
- *(omitted)* — cloud mode fetches `cloud://demo` from the hub; local mode uses the plugin-bundled workflow
- `cloud://author/name` — fetched from the hub (cloud mode)
- `/abs/path` or `./rel/path` — local workflow directory

**Env vars:**

| Variable | Default | Effect |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | Set to `local` to flip the default for every run in the shell |
| `STAGENT_SERVER` | `https://stagent.worldstatelabs.com` | Point at a self-hosted or staging server |

## Local vs Cloud

| Concern | Local | Cloud |
|---|---|---|
| Authoritative state | `<project>/.stagent/<session>/state.md` | Postgres `sessions` row; local shadow mirrors |
| Where the files live on your disk | Project worktree | `~/.cache/stagent/sessions/<session>/` — wiped on terminal |
| Live viewer | None — read the files | `https://stagent.worldstatelabs.com/s/<session_id>` |
| Cross-machine continue | Not supported | `/stagent:continue --session <id>` with project-fingerprint verification |
| `.gitignore` entry needed | `echo '/.stagent/' >> .gitignore` | None |

### Cross-machine / cross-clone takeover caveat

`/stagent:continue --session <id>` mirrors the workflow's **state** (`state.md`, stage reports, `baseline`) to the new machine — it does **not** copy the project's source code. Code lives in your git repo, not in the plugin.

`continue-workflow.sh` verifies:

1. The new workdir is the same repo (root-commit fingerprint).
2. The new workdir's HEAD is not behind / diverged from the HEAD the workflow last saw (`last_seen_head` in `state.md`, updated on every stage transition and on `/interrupt`). A behind / diverged HEAD is a **hard block** unless `--force-project-mismatch` is passed — the resumed stage would otherwise run against stale code and re-do or contradict finished work.
3. Uncommitted changes in the new workdir emit a soft warning — they may conflict with the next stage's output.

If the original session committed its subagent work before interrupting, `git fetch && git checkout <last_seen_head>` (or merge that branch) on the new machine brings you in sync before `/continue`.

## Key Design Decisions

- **Config-driven** — stages, transitions, interruptible flags, subagent types/models, and input dependencies all live in `workflow.json`. Adding a stage or changing a transition is a config edit, not a code change.
- **One generic subagent** — every subagent stage runs under a single `workflow-subagent`; the per-stage protocol lives in `<workflow-dir>/<stage>.md`, which the subagent reads at runtime. No per-stage `subagent_type` field.
- **Required inputs block transitions** — `update-status.sh` refuses to move into a stage if any `required` input artifact is missing. State-machine-level enforcement.
- **Epoch-stamped artifacts** — each stage's artifact carries the epoch that was current when it was produced. The stop hook only trusts artifacts whose epoch matches `state.md` — stale artifacts from previous iterations are ignored.
- **Self-contained** — the skill blocks all external skill invocations to prevent flow hijacking.
- **One session = one run** — each Claude session's run lives in its own session-keyed subdir. Multiple Claude sessions in the same worktree can run independent workflows without interfering.

## Architecture & Internals

See [ARCHITECTURE.md](./ARCHITECTURE.md) for:
- Plugin directory layout
- Runtime file layout (local + cloud)
- `workflow.json` schema reference
- State machine protocol (epoch, result, transitions)
- Stop-hook behavior
- End-to-end cycle walkthrough

## License

MIT
