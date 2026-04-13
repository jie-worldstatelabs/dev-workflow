# Stage: qa-ing

**Execution:** subagent `dev-workflow:workflow-qa` (sonnet) • **Interruptible:** no
**Artifact:** `{topic}-qa-ing-report.md`
**Valid results:** `PASS`, `FAIL`
**Transitions** _(canonical in workflow.json)_: `PASS → complete`, `FAIL → executing`

Real user journey tests (Playwright, XcodeBuildMCP, etc.). The QA agent distinguishes test bugs from app bugs — only confirmed app bugs block progress. Test bugs and unresolved uncertainties are tracked in `{topic}-journey-tests.md` for future iterations.

---

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Launch the Agent tool.
   - The `agent-guard.sh` hook injects `subagent_type`, `mode`, and the prompt template — including paths for the plan (required) and the journey-test state file.
3. The agent MUST write `{topic}-qa-ing-report.md` with frontmatter:
   ```
   ---
   epoch: <epoch>
   result: PASS | FAIL
   ---
   ```
4. When the agent returns, read the `result` field from the report frontmatter.
5. Transition:
   - `result: PASS` → `update-status.sh --status complete`. Announce: "Dev workflow complete. All changes reviewed and QA-passed."
   - `result: FAIL` → `update-status.sh --status executing`, loop back to `stages/executing.md`. Announce: "QA failed: app bugs found. Starting next execution..."

The loop continues indefinitely until QA returns `result: PASS`.
