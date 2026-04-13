# Stage: reviewing

_Runtime config (canonical): `workflow.json` → `stages.reviewing`_

**Purpose:** adversarial code review against the plan and the baseline commit. Focus is on code-level issues — correctness, completeness, design, edge cases, security. Out of this stage's scope: running tests, checking user-facing behavior (those concerns belong to other stages the workflow defines, if any).
**Output artifact:** `<project>/.dev-workflow/<topic>-reviewing-report.md`
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
5. Look up `workflow.json` → `stages.reviewing.transitions[<result>]` to get the next status. Run:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status <next>
   ```
   (replacing `<result>` with the actual value and `<next>` with the looked-up status)
