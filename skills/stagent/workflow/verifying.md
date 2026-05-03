# Stage: verifying

_Runtime config (canonical): `workflow.json` → `stages.verifying`_

**Purpose:** run the project's quick test suite (unit / integration / type-check) to catch obvious regressions before the reviewer sees the code.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `PASS`, `FAIL`, `SKIPPED`

## Work

### 1. Detect the test command

Check the project root in this order:

| Detect | Command |
|--------|---------|
| `package.json` with a `"test"` script | `npm test` |
| `pyproject.toml` with `[tool.pytest]` (or `pytest.ini`) | `pytest` |
| `go.mod` | `go test ./...` |
| `Makefile` with a `test` target | `make test` |
| None of the above | skip the run — result is `SKIPPED` |

### 2. Run the tests

```bash
cd <project-directory> && <test-command> 2>&1
```

Use a 3-minute timeout (`timeout: 180000`). Capture full output.

### 3. Write the report

```markdown
---
epoch: <current epoch>
result: PASS | FAIL | SKIPPED
---
# Verify Report

## Test Command
<command used, or "SKIPPED — no test command detected">

## Output
<last 100 lines if long>
```

### 4. Done

Writing the artifact with the correct `result:` value is the only output required. The main loop reads `result:` and calls `update-status.sh` to advance — do NOT call it yourself from this stage file.
