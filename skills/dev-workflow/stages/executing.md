# Stage: executing

**Execution:** subagent `dev-workflow:workflow-executor` (opus) • **Interruptible:** no
**Artifact:** `{topic}-executing-report.md`
**Valid results:** `done`
**Transitions** _(canonical in workflow.json)_: `done → verifying`

Implementation stage. The executor agent reads the plan + any feedback from previous iterations, implements the plan, and writes its report.

---

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Launch the Agent tool.
   - The `agent-guard.sh` PreToolUse hook injects the exact subagent_type (`dev-workflow:workflow-executor`), model (`opus`), mode (`bypassPermissions`), and prompt template — including paths for the plan (`{topic}-planning-report.md`, required) and optional feedback artifacts (`{topic}-reviewing-report.md`, `{topic}-qa-ing-report.md`, `{topic}-verifying-report.md` from the previous iteration).
3. The agent MUST write `{topic}-executing-report.md` with frontmatter:
   ```
   ---
   epoch: <epoch>
   result: done
   ---
   ```
4. When the agent returns, verify the artifact exists with matching `epoch` and `result: done`.
5. Transition:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status verifying
   ```
6. Proceed to `stages/verifying.md`.

## Unrecoverable implementation issues

If the executor hits something it genuinely can't resolve (missing system dependency, corrupted environment, etc.), **still write the report with `result: done`** and document the problem in the body. The verifying stage's failing tests will surface it, and the loop will iterate with visible evidence. Use `update-status --status escalated` only when even writing a report is impossible.
