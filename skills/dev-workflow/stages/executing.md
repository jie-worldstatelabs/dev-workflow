# Stage: executing

_Runtime config (canonical): `workflow.json` → `stages.executing`_

**Purpose:** implement the plan, producing the actual code changes.
**Output artifact:** `<project>/.dev-workflow/<topic>-executing-report.md`
**Valid results this stage writes:** `done`

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Launch the Agent tool. The `agent-guard.sh` PreToolUse hook injects the exact `subagent_type`, `model`, `mode`, and prompt template — including required/optional input paths and the output path — all sourced from `workflow.json` → `stages.executing`. Follow that injected guidance verbatim.
3. The agent MUST write the output artifact with frontmatter:
   ```
   ---
   epoch: <epoch>
   result: done
   ---
   ```
4. When the agent returns, verify the output artifact exists with matching `epoch` and `result: done`.
5. Look up `workflow.json` → `stages.executing.transitions["done"]` to get the next status. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status <next>
   ```
   (replacing `<next>` with the looked-up value)

## Unrecoverable implementation issues

If the agent hits something it genuinely can't resolve (missing system dependency, corrupted environment, etc.), it should **still write the report with `result: done`** and document the problem in the body. The workflow continues normally; whatever downstream stages the config defines will take the produced code and handle their own quality checks.

Use `update-status --status escalated` only when even writing a report is impossible.
