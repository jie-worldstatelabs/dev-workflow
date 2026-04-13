# Stage: qa-ing

_Runtime config (canonical): `workflow.json` → `stages.qa-ing`_

**Purpose:** run real user journey tests (Playwright, XcodeBuildMCP, etc.). The QA agent distinguishes test bugs from app bugs — only confirmed app bugs block progress. Test bugs and unresolved uncertainties are tracked in `<project>/.dev-workflow/<topic>-journey-tests.md` for future iterations.
**Output artifact:** `<project>/.dev-workflow/<topic>-qa-ing-report.md`
**Valid results this stage writes:** `PASS`, `FAIL`

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Launch the Agent tool. The `agent-guard.sh` hook injects the exact `subagent_type`, `mode`, and prompt template — including required/optional input paths, the output path, and the journey-test state file path — all sourced from `workflow.json` → `stages.qa-ing`. Follow that injected guidance verbatim.
3. The agent MUST write the output artifact with frontmatter:
   ```
   ---
   epoch: <epoch>
   result: PASS | FAIL
   ---
   ```
4. When the agent returns, read the `result:` field from the output artifact's frontmatter.
5. Look up `workflow.json` → `stages.qa-ing.transitions[<result>]` to get the next status. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status <next>
   ```
   (replacing `<result>` with the actual value and `<next>` with the looked-up status)

If the lookup yields a terminal status (e.g. `complete`), the next `update-status.sh` call drives the workflow to its end; announce completion to the user.
