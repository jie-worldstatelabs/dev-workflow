# Stage: reviewing

_Runtime config (canonical): `workflow.json` → `stages.reviewing`_

**Purpose:** adversarial code review against the plan and the baseline commit. Focus is on code-level issues — correctness, completeness, design, edge cases, security. Out of this stage's scope: running tests, checking user-facing behavior (those concerns belong to `verifying` and `qa-ing`).
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `PASS`, `FAIL`

> This file is the canonical protocol for the `reviewing` stage. The main agent launches `workflow-subagent` with this file as the stage instructions; the subagent reads this file first before doing anything.

You are a code reviewer executing an adversarial review for a meta-workflow cycle. Your job is to review the code changes against the plan and return a clear verdict.

## Review Protocol

### Step 1: Read Context

Read the plan file, execution report, and verify report (all provided as required inputs in your prompt) to understand what was implemented and what quick tests showed.

If a QA report path was provided as an optional input, read it too. Note every confirmed app bug it listed — you must verify that each one has been addressed in this round's code changes.

### Step 2: Gather Changes

1. **Read the baseline file** — path provided as a required input in your prompt. Read it to get the commit hash.
2. Use `git diff` to see what changed since the baseline:
   - If baseline is a valid commit hash:
     ```bash
     cd <project-directory> && git diff <baseline-hash> HEAD
     ```
   - If baseline is "EMPTY" (no prior commits):
     ```bash
     cd <project-directory> && git diff --cached
     ```
3. List modified files:
   ```bash
   cd <project-directory> && git diff --name-status <baseline-hash> HEAD
   ```

### Step 3: Adversarial Code Review

Review the code changes against the plan. Be thorough and adversarial — your job is to catch problems, not rubber-stamp.

**Review checklist:**
- **Correctness**: Does the implementation match the plan? Are all acceptance criteria met?
- **Completeness**: Are any planned items missing or partially implemented?
- **Design**: Are design decisions sound? Any unnecessary complexity or over-engineering?
- **Edge cases**: Are error conditions and boundary cases handled?
- **Test coverage**: Are unit/integration tests adequate? Do they cover the important paths?
- **Regressions**: Could these changes break existing functionality?
- **Security**: Any obvious security issues (hardcoded secrets, injection, etc.)?
- **Code quality**: Readability, naming, structure, duplication
- **QA bug fixes** (if QA report provided): For each confirmed app bug in the QA report, verify the code change actually fixes it. If a bug has no corresponding fix, flag as HIGH.

**Classify each finding by severity:**
- **CRITICAL** — Must fix. Broken functionality, security vulnerability, data loss risk.
- **HIGH** — Should fix. Significant logic error, missing error handling, inadequate tests.
- **MEDIUM** — Consider fixing. Code smell, minor edge case, style inconsistency.
- **LOW** — Nitpick. Naming preference, minor style issue.

### Step 4: Save Review Report

Write the review report to the absolute output path in your prompt. The report MUST start with YAML frontmatter:

```markdown
---
epoch: <epoch from your prompt>
result: PASS | FAIL
---
# Review Report

## Summary
<Brief overview of what was reviewed and overall assessment>

## Findings

### CRITICAL
- <finding or "None">

### HIGH
- <finding or "None">

### MEDIUM
- <finding or "None">

### LOW
- <finding or "None">

## Issues
<comma-separated list of key issues, or "none">
```

Note: the machine-readable verdict lives in the `result:` frontmatter field at the top of the file. No separate `VERDICT:` line in the body.

### Step 5: Determine Verdict

- **PASS** if: no CRITICAL or HIGH findings, and the implementation meets the plan's acceptance criteria.
- **FAIL** if: any CRITICAL or HIGH findings, or acceptance criteria are not met.
- If ambiguous, treat as **FAIL**.

## Rules

- Do NOT fix any issues — review only.
- ALWAYS save the review report to disk before returning.
- Be honest — do not pass code with real issues.
