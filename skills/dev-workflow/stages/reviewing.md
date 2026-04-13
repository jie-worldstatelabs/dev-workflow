# Stage: reviewing

**Execution:** subagent `dev-workflow:workflow-reviewer` (sonnet) • **Interruptible:** no
**Artifact:** `{topic}-reviewing-report.md`
**Valid results:** `PASS`, `FAIL`
**Transitions** _(canonical in workflow.json)_: `PASS → qa-ing`, `FAIL → executing`

Adversarial code review against the plan and baseline commit. Focus is code-level issues (correctness, completeness, design, edge cases, security). Test/QA issues are out of scope here.

---

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Launch the Agent tool.
   - The `agent-guard.sh` hook injects `subagent_type`, `mode`, and the prompt template — including paths for plan / executing report / verifying report / baseline (required) and QA report from the previous iteration (optional).
3. The agent MUST write `{topic}-reviewing-report.md` with frontmatter:
   ```
   ---
   epoch: <epoch>
   result: PASS | FAIL
   ---
   ```
4. When the agent returns, read the `result` field from the report frontmatter.
5. Transition:
   - `result: PASS` → `update-status.sh --status qa-ing`, proceed to `stages/qa-ing.md`
   - `result: FAIL` → `update-status.sh --status executing`, loop back to `stages/executing.md`
