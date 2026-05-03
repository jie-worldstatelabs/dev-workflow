# Webapp build → ship workflow

A six-stage cycle for building and shipping a webapp end-to-end with Claude Code: plan with the user, have a subagent implement it, run quick tests, run adversarial code review, run real user-journey QA, then deploy to Vercel. The execute → verify → review → qa loop continues until QA passes; only then does `deploy` run. The cap `max_epoch` (default `20`) forces `escalated` to break runaway iteration.

This is the default template `cloud://demo` ships with. It assumes a webapp project (Next.js, Vite + React, SvelteKit, etc.) deployable to Vercel. For other shapes, fork and edit.

## Stages

```
planning ──approved──▶ executing ──done──▶ verifying ──PASS/SKIPPED──▶ reviewing ──PASS──▶ qa-ing ──PASS──▶ deploy ──deployed──▶ complete
              ▲                              │FAIL          │FAIL          │FAIL
              │                              └──────────────┴──────────────┴────▶ executing  (retry loop)
```

### 1 · planning *(interruptible, inline)*

The main agent runs Q&A with you: clarifying questions, proposed approaches, design iteration, acceptance criteria, test strategy, deployment target details (Vercel project name, env vars). Writes `planning-report.md` with `result: pending`. When you explicitly approve, flips to `result: approved` and transitions to `executing`.

Interruptible: the stop hook allows natural session pauses.

### 2 · executing *(uninterruptible, subagent — Opus)*

The generic `stagent:workflow-subagent` is launched with `executing.md` as its stage instructions. It reads the plan and any optional feedback from prior iterations (reviewer / QA / verify), then implements the changes. Writes `executing-report.md` with `result: done`.

Opus is used here because the code-change step benefits most from the deepest reasoning.

### 3 · verifying *(uninterruptible, inline)*

The main agent runs the project's quick-test command (auto-detected from `package.json`, `pyproject.toml`, etc.). Three results:

- `PASS` → `reviewing`
- `SKIPPED` → `reviewing` (no test command detected; reviewer will catch code-level issues)
- `FAIL` → loop back to `executing` with the failure output as optional feedback

### 4 · reviewing *(uninterruptible, subagent)*

The generic `stagent:workflow-subagent` is launched with `reviewing.md`. Adversarial code review: diffs HEAD against the baseline commit, checks correctness, completeness, design, edge cases, security. Code-level issues only — runtime/UX bugs are QA's job.

- `PASS` → `qa-ing`
- `FAIL` → loop back to `executing` with reviewer feedback

### 5 · qa-ing *(uninterruptible, subagent)*

The generic `stagent:workflow-subagent` is launched with `qa-ing.md`. Runs Playwright user-journey tests, maintains a persistent journey-test state file across iterations, distinguishes test bugs (auto-fixed) from app bugs (block progress).

- `PASS` → `deploy`
- `FAIL` → loop back to `executing` with confirmed app bugs as feedback

### 6 · deploy *(interruptible, inline)*

The main agent runs the Vercel CLI to deploy: links the project on first run, syncs production env vars from the plan, runs `vercel --prod`, smoke-checks the URL. Interruptible because first-run setup may need `vercel login` in another terminal or env-var values from the user.

- `deployed` → `complete` (terminal)

## Terminal states

- `complete` — QA passed, code reviewed, journey-tested, and deployed
- `escalated` — `max_epoch` hit; loop broken for human intervention
- `cancelled` — user ran `/stagent:cancel`

## Required and optional inputs per stage

The plugin's state machine enforces that required inputs exist before a transition is allowed.

| Stage | Required | Optional (retry feedback) |
|---|---|---|
| planning | — | — |
| executing | planning | reviewing, qa-ing, verifying (previous iteration) |
| verifying | — | — |
| reviewing | planning, executing, verifying, baseline (run-file) | qa-ing (previous iteration) |
| qa-ing | planning | — |
| deploy | planning, qa-ing | — |

Optional inputs are what make the loop converge: reviewer rejection on iteration N becomes input to executor on iteration N+1.

## Customising

To change stages, swap models, or tweak transitions: fetch this template, edit `workflow.json` + the stage `.md` files, then publish:

```sh
/stagent:create --flow=cloud://your-author/your-name "<describe your changes>"
```

The state-machine protocol (`SKILL.md`) is fully config-driven — anything that parses as a valid `workflow.json` runs end to end.
