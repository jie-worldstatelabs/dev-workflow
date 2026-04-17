# dev-workflow

A Claude Code plugin that runs **config-driven development workflows** as a state machine. You declare stages, transitions, and inputs in a single `workflow.json`; the plugin's hooks and scripts drive the loop.

Two modes:
- **Local** — state and artifacts live under `<project>/.dev-workflow/`, no network.
- **Cloud** (default) — state mirrored to a hosted Next.js + Postgres webapp with a live browser viewer, cross-machine resume, and zero project-dir footprint.

The protocol is identical; cloud mode is just "where do the files live."

## Installation

```bash
claude plugin marketplace add https://github.com/jie-worldstatelabs/dev-workflow
claude plugin install dev-workflow
```

Requires: [Claude Code](https://claude.ai/claude-code), `jq`.

## Quick Start

```
/dev-workflow:start Build a web app for diary and MBTI analysis
```

The skill prints a UI URL (cloud mode):

```
UI: https://workflows.worldstatelabs.com/s/<session_id>
```

Paste it in a browser to watch the stage timeline, rendered artifacts, and `git diff baseline..HEAD` update live via SSE. The project worktree gets **nothing** under `.dev-workflow/`.

For a fully offline run:

```
/dev-workflow:start --mode=local Build a web app for diary and MBTI analysis
```

## The Default Workflow

Bundled at `skills/dev-workflow/workflow/`, the default workflow is a **plan → execute → verify → review → QA → loop** cycle:

1. **Planning** *(interruptible)* — inline Q&A with you: clarifying questions, proposed approaches, plan file. You confirm before anything gets built.
2. **Executing** — subagent (opus) implements the plan: tests-first when specified, minimal focused changes.
3. **Verifying** — quick tests (unit/integration) run inline. FAIL → loop to Execute; PASS/SKIPPED → Review.
4. **Reviewing** — subagent (sonnet) runs adversarial code review against the baseline commit. PASS → QA; FAIL → loop to Execute.
5. **QA-ing** — subagent runs real user journey tests (Playwright, XcodeBuildMCP, etc.). Distinguishes test bugs from app bugs — only confirmed app bugs block progress. PASS → complete; FAIL → loop to Execute.

The `execute → verify → review → QA` loop runs **autonomously** after you approve the plan. A Stop hook guarantees the loop runs to completion. No round limit — the loop stops only when QA passes, or when you intervene.

## Custom Workflows

The plugin is **generic** — any stage shape works as long as it follows the schema. Create a custom workflow via natural language:

```
/dev-workflow:create-workflow Create a design workflow with plan, execute,
and evaluate stages. Plan browses the app and codebase and agrees a re-design
plan with the user. Execute implements it. Evaluate operates the app in a
browser and scores it on design quality, originality, craft, functionality,
and adherence to the plan.
```

This writes a `workflow.json` + per-stage instruction files to `~/.dev-workflow/workflows/<name>/` and publishes the bundle to the hub. Reuse it with:

```
/dev-workflow:start --workflow=cloud://<you>/<name> <task>
```

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the `workflow.json` schema.

## Commands

| Command | Purpose |
|---|---|
| `/dev-workflow:start [--mode=cloud\|local] [--workflow=<ref>] <task>` | Start a new run |
| `/dev-workflow:interrupt` | Pause the active run at the end of the current stage |
| `/dev-workflow:continue [--session <id>]` | Resume an interrupted run (`--session` for cross-machine cloud takeover) |
| `/dev-workflow:cancel [--hard]` | Cancel and archive (or wipe with `--hard`) |
| `/dev-workflow:create-workflow [--workflow=<ref>] <description>` | Create a new workflow or edit an existing one |
| `/dev-workflow:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | Publish a local workflow to the hub |
| `/dev-workflow:login` / `:logout` / `:whoami` | Manage your hub identity |

**`--workflow=<ref>`** accepts:
- *(omitted)* — bundled default workflow
- `cloud://author/name` — fetched from the hub (cloud mode)
- `/abs/path` or `./rel/path` — local workflow directory

**Env vars:**

| Variable | Default | Effect |
|---|---|---|
| `DEV_WORKFLOW_DEFAULT_MODE` | `cloud` | Set to `local` to flip the default for every run in the shell |
| `DEV_WORKFLOW_SERVER` | `https://workflows.worldstatelabs.com` | Point at a self-hosted or staging server |

## Local vs Cloud

| Concern | Local | Cloud |
|---|---|---|
| Authoritative state | `<project>/.dev-workflow/<session>/state.md` | Postgres `sessions` row; local shadow mirrors |
| Where the files live on your disk | Project worktree | `~/.cache/dev-workflow/sessions/<session>/` — wiped on terminal |
| Live viewer | None — read the files | `https://workflows.worldstatelabs.com/s/<session_id>` |
| Cross-machine continue | Not supported | `/dev-workflow:continue --session <id>` with project-fingerprint verification |
| `.gitignore` entry needed | `echo '/.dev-workflow/' >> .gitignore` | None |

For the full cloud architecture (write-through mirror, SSE, cross-machine protocol, API reference, deploy guide), see the **[workflowUI README](https://github.com/jie-worldstatelabs/workflowUI)**.

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
