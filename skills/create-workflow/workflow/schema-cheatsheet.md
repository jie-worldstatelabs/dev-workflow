# Stagent Workflow Schema — Planning-Stage Cheatsheet

This is your **internal toolkit reference** — you (the planning stage
Claude) read this so you know what's available. You still talk to the
user in plain language; they don't need to hear these field names.
Use this to spot *where* a user design choice maps to a schema lever.

---

## Top-level fields of `workflow.json`

| Field | Required | Purpose / when to use |
|---|---|---|
| `initial_stage` | yes | Stage name where the run begins |
| `terminal_stages` | yes | Array of result values that end the workflow. Convention: `["complete", "escalated", "cancelled"]` |
| `stages` | yes | Object keyed by stage name |
| `max_epoch` | no (default 20) | Cap on FAIL→retry loops; forces `escalated` when exceeded. Only meaningful if the workflow has loop-back edges (e.g. `verify FAIL → execute`). Ask the user to consider a lower cap when a loop is expensive. |
| `modifies_worktree` | no (default true) | Set to `false` when the workflow writes **nothing** to the project dir. Example: `create-workflow` (writes to `~/.config/stagent/`), `publish-workflow` (pure HTTP calls). When `false`, the plugin skips worktree-diff capture and UI hides the diff panel. |
| `run_files` | no | `{name: {description, init}}`. Each `init` is a shell command run at setup; stdout becomes the file content. Use for setup-time constants (git SHA baseline, current date, env var snapshot). Stages read them via `from_run_file`. |

---

## Per-stage fields

| Field | Required | Purpose |
|---|---|---|
| `interruptible` | yes | `true` = stop-hook allows session pause mid-stage (for user Q&A or long pauses). `false` = the agent must drive the stage to a terminal result in one pass. **Subagent stages MUST be `false`** (validator rejects otherwise — the main agent blocks on the Agent tool, so the stop hook can't fire). |
| `execution` | yes | `{"type":"inline"}` OR `{"type":"subagent", "model":"opus"\|"sonnet"\|"haiku"}`. Model is optional; default is sonnet. |
| `transitions` | yes | `{<result>: <next-stage-or-terminal>}`. Values are plain strings. Result names are *your* convention — common ones: `done`, `pass`, `fail`, `approved`, `skipped`, custom names for branching. |
| `inputs` | yes | `{required: [...], optional: [...]}`. Each entry is `{from_stage: <name>, description: <text>}` OR `{from_run_file: <name>, description: <text>}`. `required` inputs are enforced at transition time — `update-status.sh` refuses to move INTO this stage if any required-input artifact is missing. |

---

## Design levers to proactively consider

When the user describes what they want, listen for these signals:

| User-described need | Schema lever |
|---|---|
| "pause for input" / "ask user" / "review before next" | `interruptible: true` + `inline` execution |
| "hard thinking" / "generate code" / "analyze design" | `subagent` + `model: opus` |
| "quick classification" / "fan-out simple task" | `subagent` + `model: haiku` |
| "run a test" / "check syntax" / "call a script" | `inline` (cheap, no subagent needed) |
| "keep retrying until X" | loop transition + consider `max_epoch` lower bound |
| "don't touch my project files" | `modifies_worktree: false` |
| "remember this setup-time value" (git SHA, date, caller context) | `run_files` |
| "branch on the result" | multiple `transitions` keys → different next stages |

---

## Hard rules the validator enforces (don't violate)

- Subagent stages → `interruptible: false` always
- Stage `<name>.md` file lives **directly next to** `workflow.json` (not in a `stages/` subdir)
- Every `from_stage` reference must name a declared stage
- Every transition target must be a declared stage OR a value in `terminal_stages`
- Terminal stage names go ONLY in the `terminal_stages` array — do NOT also add them as keys in `stages`
- `transitions` values are plain strings, not nested objects like `{"target":"x"}`
- No `subagent_type` field on stages (all subagents run under the plugin's generic runner)
- No top-level `name` / `version` / `description` fields (readme.md is the description)

---

## Things to NOT bother the user about

These are implementation details with sane defaults — pick silently:

- `terminal_stages` → default `["complete", "escalated", "cancelled"]` unless the user explicitly proposes others
- `max_epoch` → leave off unless the user mentions runaway loops (20 default is fine)
- Default model for subagents → sonnet (pick opus only for clearly heavy stages; haiku for clearly cheap)
- Stage `.md` file names → always `<stage>.md` matching the stage key

Use these defaults silently in the plan; the user sees the structure, not the boilerplate.
