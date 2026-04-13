# Stage: verifying

_Runtime config (canonical): `workflow.json` → `stages.verifying`_

**Purpose:** run the project's quick test suite to catch obvious regressions.
**Output artifact:** `<project>/.dev-workflow/<topic>/verifying-report.md`
**Valid results this stage writes:** `PASS`, `FAIL`, `SKIPPED`

## Work

### 1. Detect the test command

Check the project root in this order:

| Detect | Command |
|--------|---------|
| `package.json` with a `"test"` script | `npm test` |
| `pytest.ini`, `setup.cfg`, or `pyproject.toml` with `[tool.pytest]` | `pytest` |
| `pubspec.yaml` | `flutter test` |
| `go.mod` | `go test ./...` |
| `Makefile` with a `test` target | `make test` |
| None of the above | skip the run — result is `SKIPPED` |

### 2. Run the tests

```bash
cd <project-directory> && <test-command> 2>&1
```

Use a 3-minute timeout (`timeout: 180000`). Capture full output.

### 3. Write the report

Output artifact:

```markdown
---
epoch: <from state.md>
result: PASS | FAIL | SKIPPED
---
# Verify Report

## Test Command
<command used, or "SKIPPED — no test command detected">

## Output
<last 100 lines if long>
```

### 4. Transition

Look up `workflow.json` → `stages.verifying.transitions[<result>]` to get the next status. Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/update-status.sh" --status <next>
```
(replacing `<result>` with the actual value you wrote and `<next>` with the looked-up status)
