# Stage: verifying

**Execution:** inline (main agent) • **Interruptible:** no
**Artifact:** `{topic}-verifying-report.md`
**Valid results:** `PASS`, `FAIL`, `SKIPPED`
**Transitions** _(canonical in workflow.json)_: `PASS → reviewing`, `FAIL → executing`, `SKIPPED → reviewing`

Quick-test verification. Runs the project's unit/integration test suite inline (no subagent — tests are a single shell command). Catches obvious regressions before spending compute on review.

---

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
| None of the above | result is `SKIPPED` (no test command — proceed without running) |

### 2. Run the tests

```bash
cd <project-directory> && <test-command> 2>&1
```

Use a 3-minute timeout (`timeout: 180000`). Capture full output.

### 3. Write the verify report

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

- `result: FAIL` → `update-status.sh --status executing` (loop back; executor receives this report as `Quick test failures` context)
- `result: PASS` or `SKIPPED` → `update-status.sh --status reviewing`

Announce the transition in one short line (e.g. "Tests passed. Starting review.").
