# Stage: user_review

_Runtime config (canonical): `workflow.json` → `stages.user_review`_

**Purpose:** After publishing, surface where the workflow lives (hub URL for cloud mode, local path for local mode) and pause for the user to either approve into `complete` or send free-form feedback that loops back to `writing` for another iteration.
**Output artifact:** write to the absolute path provided in your I/O context
**Valid results this stage writes:** `approve` (user explicitly OK'd shipping), `revise` (user sent feedback — feedback body becomes the writer's top-priority change list next round)

This is an **inline + interruptible** stage. The main agent runs it directly — print the review summary, then **stop the turn and wait for the user's reply**. Do not write the artifact until the user has actually responded.

## Inputs

Read every input path from your I/O context — never construct or hardcode paths.

- **Required:** `publishing` report — body contains the publish outcome. For cloud, it includes the hub URL and pull command in `## Script output`. For local mode, it states "nothing to publish" with the target dir.
- **Required:** `writing` report — `## Target directory` line is the absolute local path.
- **Optional:** `setup_context` run_file — JSON with `publish_intent`. Fall back to `"local"` if missing.

## Protocol

1. Parse the publishing artifact:
   - Extract the **mode** (`cloud` / `local`) — usually the `## Mode` line of the publish report.
   - For cloud mode: extract the **hub URL** and **pull command** from the `## Script output` block. (`publish-workflow.sh` prints both verbatim.)
   - Note whether publish succeeded or failed-but-files-are-valid.

2. Parse the writing artifact's `## Target directory` line for the **local path**.

3. Print **one** concise review-ready message to the user. No filler, no chatter. Format:

   **Cloud mode (publish OK):**
   ```
   Workflow published — review and reply.

   Hub URL:    <https://stagent.worldstatelabs.com/hub/<name>>
   Pull:       <command from publish output>
   Local dir:  <absolute path>
   Iteration:  <epoch>

   Reply "approve" / "ok" / "shipit" to finish, or send any feedback to revise.
   ```

   **Cloud mode (publish failed):**
   ```
   Workflow files written but the hub push failed — review locally.

   Local dir:   <absolute path>
   Push retry:  /stagent:publish <absolute path>
   Iteration:   <epoch>
   Reason:      <one-line summary from publish report>

   Reply "approve" / "ok" to finish (you can retry the push later), or send feedback to revise.
   ```

   **Local mode:**
   ```
   Workflow ready locally — review and reply.

   Local dir:  <absolute path>
   Iteration:  <epoch>

   Reply "approve" / "ok" / "shipit" to finish, or send any feedback to revise.
   ```

4. **<HARD-GATE>** End the turn here. Do NOT write the artifact yet. Do NOT call `update-status.sh`. The plugin's stop-hook will set `awaiting_user`; the workflow loop will pause until the user actually replies.

5. When the user replies, classify the reply:

   - **Approve tokens** (case-insensitive, exact match on the trimmed reply, or the reply starts with one followed by punctuation): `approve`, `approved`, `ok`, `okay`, `shipit`, `ship it`, `lgtm`, `looks good`, `yes`, `done`. → write `result: approve`. Body restates what was approved (URL + local dir, one short paragraph).

   - **Anything else** (any free-form text that isn't an approve token, including English/Chinese/etc. critique, edit requests, "change X to Y", paste of error logs): treat as **revise**. → write `result: revise`. Body is the user's reply VERBATIM under the H1 heading `# User Review Feedback`. Do NOT paraphrase or summarize — the writer reads this as the change list and needs the user's exact words.

   - **Empty or whitespace-only reply**: do NOT write the artifact. Re-prompt the user once with: `Need a reply — "approve" to ship or any feedback to revise.` Then end the turn again.

6. After writing the artifact, the main loop reads `result:` and transitions:
   - `approve` → `complete`
   - `revise` → `writing` (epoch bumps; writer reads this artifact as the highest-priority change list)

## Artifact shape

**On approve:**
```markdown
---
epoch: <epoch>
result: approve
---
# User Review — approved

User reviewed the workflow at `<URL or local path>` and approved at iteration <epoch>.
```

**On revise:**
```markdown
---
epoch: <epoch>
result: revise
---
# User Review Feedback

<paste the user's reply here, verbatim, exactly as they typed it>
```

## Rules

- Do NOT auto-classify ambiguous replies as approve. When in doubt, treat as revise. Approve must be explicit.
- Do NOT pre-fill or guess the user's feedback. The artifact body for `revise` is **only** what the user typed.
- Do NOT call `update-status.sh` — the main loop advances on the artifact's `result:`.
- Do NOT add chatter to the review-ready message (no "Hope you like it!", no emojis, no extra paragraphs). The user is reviewing — keep their attention on the URL/path and the approve-or-feedback choice.

## Edge cases

- **Redesign requests**: if the user's feedback essentially asks for "rebuild the whole stage decomposition", you should still write `result: revise` and pass it to writing — but mention in the artifact body's first line: `NOTE: user is requesting deep changes; if writing cannot accommodate without redesigning the stage graph, surface that to the user via planner.md once they cancel + restart.` v1 of this stage does not loop back to `planning`; that's a `cancel + /stagent:create` story.

- **User keeps replying with more feedback during a revise iteration**: each revise round is a new epoch with one user reply per epoch. If the user sends a second message before writing finishes, the workflow loop should already buffer it for the next user_review pass.

- **Feedback contains code blocks, ANSI escapes, or unusual whitespace**: keep them verbatim. The writer needs to see exactly what the user wrote.
