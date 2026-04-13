# Stage: qa-ing

_Runtime config (canonical): `workflow.json` → `stages.qa-ing`_

**Purpose:** run real user journey tests (Playwright, XcodeBuildMCP, etc.). The QA agent distinguishes test bugs from app bugs — only confirmed app bugs block progress. Test bugs and unresolved uncertainties are tracked in `<project>/.dev-workflow/<topic>-journey-tests.md` for future iterations.
**Output artifact:** `<project>/.dev-workflow/<topic>-qa-ing-report.md`
**Valid results this stage writes:** `PASS`, `FAIL`

## Work

1. Read `state.md` to get `topic` and `epoch`.
2. Call the Agent tool.
   - **Before the call fires**, the `agent-guard.sh` PreToolUse hook prints guidance to you (the main agent), including a labelled block **`PROMPT TEMPLATE — copy verbatim into the Agent tool's prompt`**. The hook cannot modify Agent-tool parameters and the subagent cannot see the hook's output — **you must copy that template into the `prompt` argument of your Agent-tool call**.
   - Use the `subagent_type` and `mode` values the hook shows you. Transcribe every path fully; do not abbreviate to "see injected paths".
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
