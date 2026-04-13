# Stage: reviewing

_Runtime config (canonical): `workflow.json` → `stages.reviewing`_

**Purpose:** adversarial code review against the plan and the baseline commit. Focus is on code-level issues — correctness, completeness, design, edge cases, security. Out of this stage's scope: running tests, checking user-facing behavior (those concerns belong to other stages the workflow defines, if any).
**Output artifact:** `<project>/.dev-workflow/<topic>-reviewing-report.md`
**Valid results this stage writes:** `PASS`, `FAIL`

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Launch the Agent tool. The `agent-guard.sh` hook injects the exact `subagent_type`, `mode`, and prompt template — including required/optional input paths and the output path — all sourced from `workflow.json` → `stages.reviewing`. Follow that injected guidance verbatim.
3. The agent MUST write the output artifact with frontmatter:
   ```
   ---
   epoch: <epoch>
   result: PASS | FAIL
   ---
   ```
4. When the agent returns, read the `result:` field from the output artifact's frontmatter.
5. Look up `workflow.json` → `stages.reviewing.transitions[<result>]` to get the next status. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status <next>
   ```
   (replacing `<result>` with the actual value and `<next>` with the looked-up status)
