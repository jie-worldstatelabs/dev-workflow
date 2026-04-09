# dev-workflow

A Claude Code plugin that orchestrates a complete development cycle: **brainstorm → plan → execute → adversarial review → loop**.

## What It Does

`/dev <task>` kicks off a self-contained workflow:

1. **Brainstorm & Plan** — Claude asks clarifying questions, proposes approaches, presents a design, and writes an implementation plan. You confirm before anything gets built.
2. **Execute** — A dedicated executor agent (Opus) implements the plan step-by-step with TDD, tests, and incremental commits.
3. **Review** — A reviewer agent runs an adversarial code review via [Codex CLI](https://github.com/openai/codex), with automatic fallback to `oh-my-claudecode:code-reviewer` if Codex is unavailable.
4. **Gate** — If the review passes, the workflow completes. If it fails, the executor re-runs with the reviewer's feedback (up to 3 rounds).

The entire execute→review→gate loop runs **autonomously** after you confirm the plan. A Stop hook prevents the session from exiting mid-loop.

## Installation

Add the GitHub repo as a marketplace, then install the plugin:

```bash
claude plugin marketplace add https://github.com/jie-worldstatelabs/dev-workflow
claude plugin install dev-workflow
```

Or for a single session, use `--plugin-dir`:

```bash
git clone https://github.com/jie-worldstatelabs/dev-workflow.git ~/.claude/plugins/dev-workflow
claude --plugin-dir ~/.claude/plugins/dev-workflow
```

## Usage

```
/dev-workflow:dev Build a REST API with user authentication
/dev-workflow:dev Fix the race condition in the payment processing module
/dev-workflow:dev Add dark mode support to the dashboard
```

To cancel a running workflow:

```
/dev-workflow:cancel
```

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) CLI
- (Optional) [Codex CLI](https://github.com/openai/codex) for adversarial reviews
- (Optional) [oh-my-claudecode](https://github.com/anthropics/oh-my-claudecode) — used as fallback reviewer when Codex is not configured

## Architecture

```
commands/
  dev.md              ← /dev entry point with skill isolation guard
  cancel.md           ← /dev-workflow:cancel to abort a running workflow
agents/
  workflow-executor.md ← Opus-powered implementation agent
  workflow-reviewer.md ← Adversarial review agent (Codex + fallback)
skills/
  dev-workflow/
    SKILL.md          ← Main workflow orchestration logic
hooks/
  hooks.json          ← Hook configuration
  stop-hook.sh        ← Prevents exit during active workflow
  agent-guard.sh      ← Steers agent launches with correct params
scripts/
  setup-workflow.sh   ← Activates the stop hook after plan confirmation
  update-status.sh    ← Updates workflow state (executing/reviewing/gating/complete)
```

### Key Design Decisions

- **Self-contained** — The `/dev` command explicitly blocks all external skill invocations (brainstorming, writing-plans, etc.) to prevent flow hijacking.
- **Artifact-based phase detection** — Hooks derive the workflow phase from files on disk (report exists? review exists?) rather than trusting a status field. This makes the workflow resilient even if Claude forgets to update status.
- **Context isolation** — Both the executor and reviewer run as subagents, keeping their large outputs out of the orchestrator's context window.
- **Three-layer safety net** — SKILL.md instructions (soft), agent-guard hook (corrective), stop-hook (hard block).

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| Plan directory | `.dev-workflow/` | Where plans, reports, and reviews are saved |
| Max review rounds | 3 | Execute→review cycles before escalation |
| Executor model | opus | Model for the implementation agent |
| State file | `.dev-workflow/state.md` | Workflow state (auto-managed) |

## License

MIT
