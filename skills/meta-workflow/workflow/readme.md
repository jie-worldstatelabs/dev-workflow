# Default meta-workflow

A complete five-stage development cycle for AI-driven engineering: plan the work with the user, have a subagent implement it, run quick tests, run adversarial review, then run real user-journey QA. The loop continues until QA passes, the user intervenes, or `max_epoch` (default `20`) is hit — the cap forces `escalated` to break runaway iteration.

This is the workflow the `meta-workflow` plugin ships with. Pick it when you want a rigorous plan → execute → verify → review → QA cycle with tests-as-gates at every step. For lighter-weight flows (just brainstorm+draft, or just a bugfix loop) publish a custom workflow to the hub and select it via `--workflow cloud://author/name`.

## Stages

```
planning ──approved──▶ executing ──done──▶ verifying
                         ▲                    │
                         │                    ├──PASS──▶ reviewing ──PASS──▶ qa-ing ──PASS──▶ complete
                         │                    └──SKIPPED─┘
                         │
                         │                                                    │
                         ├────────────────FAIL──── reviewing                   │
                         │                                                    │
                         ├────────────────FAIL──── verifying                   │
                         │                                                    │
                         └────────────────FAIL──── qa-ing ─────────────────────┘
```

### 1 · planning (interruptible, inline)

The main Claude agent runs Q&A with you: clarifying questions, proposed approaches, design iteration, acceptance criteria, test strategy. Writes the plan into `planning-report.md` with `result: pending`. When you explicitly approve, it flips to `result: approved` and transitions to `executing`.

Interruptible: the stop hook allows natural session pauses so you can take your time answering questions.

### 2 · executing (uninterruptible, subagent — Opus)

The generic `meta-workflow:workflow-subagent` is launched with `executing.md` as its stage instructions file. It reads the plan and any optional feedback from prior iterations (reviewer feedback, QA feedback, verify failures), then implements the changes: tests-first when specified in the plan, minimal focused edits, incremental commits. Writes `executing-report.md` with `result: done`.

Opus is used here because the code-change step benefits most from the deepest reasoning.

### 3 · verifying (uninterruptible, inline)

The main agent runs the project's quick-test command (unit/integration tests, type-check, lint — detected from the project structure or pulled from the plan's testing strategy section). Three possible results:

- `PASS` → move to `reviewing`
- `SKIPPED` → move to `reviewing` (no test command detected; reviewer will catch code-level issues)
- `FAIL` → loop back to `executing` with the failure output attached as optional feedback

### 4 · reviewing (uninterruptible, subagent)

The generic `meta-workflow:workflow-subagent` is launched with `reviewing.md` as its stage instructions file. It runs an adversarial code review: diffs HEAD against the baseline commit recorded at setup, checks for correctness, completeness, design quality, edge cases, and security issues. Only reports code-level issues (not bugs the executor can reproduce at runtime — those are QA's job).

- `PASS` → move to `qa-ing`
- `FAIL` → loop back to `executing` with the reviewer feedback as optional input

### 5 · qa-ing (uninterruptible, subagent)

The generic `meta-workflow:workflow-subagent` is launched with `qa-ing.md` as its stage instructions file. It runs real user-journey tests (Playwright, XcodeBuildMCP, etc.), maintains a persistent journey-test state file across iterations, and distinguishes test bugs from app bugs. Only confirmed app bugs block progress — flaky tests or test-harness issues get auto-corrected.

- `PASS` → `complete` (terminal)
- `FAIL` → loop back to `executing` with only the confirmed app bugs as optional feedback

## Terminal states

- `complete` — QA passed, all changes reviewed and journey-tested
- `escalated` — unrecoverable error; workflow was promoted out of the loop for human intervention
- `cancelled` — user ran `/meta-workflow:cancel`

## Required and optional inputs per stage

The plugin's state machine enforces that required inputs exist before a transition is allowed. Here's what each stage reads:

| Stage | Required | Optional (for retry feedback) |
|---|---|---|
| planning | — | — |
| executing | planning | reviewing, qa-ing, verifying (all from the previous iteration) |
| verifying | — | — |
| reviewing | planning, executing, verifying | qa-ing (from the previous iteration) |
| qa-ing | planning (journey test spec) | — |

The optional inputs are what make the loop converge: if the reviewer rejects the implementation, the executor sees that rejection on the next pass and knows what to fix.

## Customising

To change stage names, add/remove stages, swap models, or tweak transitions, copy this directory, edit `workflow.json`, update the stage `.md` files to match, and either point `--workflow /abs/path` at it or publish it to the hub with:

```sh
~/.claude/plugins/meta-workflow/scripts/publish-workflow.sh /path/to/your/workflow
```

The state-machine protocol (`SKILL.md`) is fully config-driven — it doesn't know or care about the specific stage names, so anything that parses as a valid `workflow.json` runs end to end.
