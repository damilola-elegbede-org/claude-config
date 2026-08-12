---
name: verify
description: Run the project's real verification gates, fix what fails, and re-run until green or bounded out. Use before declaring work done, after a risky change, or when confirming a command or skill completed correctly.
argument-hint: "[--list] [--only <gate>] [--skip <gate>] [--report-only]"
allowed-tools: [Read, Edit, Bash, Grep, Glob]
metadata:
  category: workflow
---

# /verify

## Usage

```bash
/verify                      # Discover gates, run them, fix failures, re-run
/verify --list               # Show which gates exist here, run nothing
/verify --only test          # Run one gate
/verify --skip markdownlint  # Run everything except one gate
/verify --report-only        # Run and report; fix nothing
```

## Description

Runs the verification gates the project already defines — tests, linters, type checkers, build —
then fixes what fails and re-runs until green or until the retry budget is spent.

This skill owns the bounded-retry procedure named in CLAUDE.md: retry a failing step up to three
times, then stop and report the failing check with diagnostics rather than continuing.

It reports what the tools said. It does not score the work. A verification step that emits a
confidence percentage instead of an exit code is not verification — it is a second opinion from
the same model that did the work.

## Behavior

### The loop

`$SKILL_DIR` below is the directory containing this SKILL.md — `~/.claude/skills/verify` once
synced. Resolve it before running anything; a bare `scripts/run-checks.mjs` resolves against the
target project's cwd, where the file does not exist.

```text
0. RESOLVE
   SET: SKILL_DIR = directory of this SKILL.md (synced location: ~/.claude/skills/verify)

1. DISCOVER
   RUN: node "$SKILL_DIR/scripts/run-checks.mjs" --list
   IF: no gates detected
     OUTPUT: "No verification gates detected. Nothing was checked."
     STOP — this is not a pass. Say so plainly.

2. RUN
   RUN: node "$SKILL_DIR/scripts/run-checks.mjs" --json
   PARSE: verdict, per-gate status (pass | fail | unavailable)

3. IF verdict == pass → report and STOP.

4. FOR EACH failing gate, up to 3 attempts:
   a. READ the gate's actual output. Locate the failure at file:line.
   b. FIX THE CAUSE. Never edit a test, threshold, or lint rule to make the gate go green.
      If the gate is wrong, say so and stop — that is a decision for the user, not a fix.
   c. RE-RUN that gate alone: node "$SKILL_DIR/scripts/run-checks.mjs" --only <id>
   d. IF it passes → continue to the next failing gate.
      IF attempt 3 fails → STOP. Do not try a fourth time.

5. RE-RUN EVERYTHING once all individual gates pass. A fix for one gate routinely breaks
   another, and the per-gate loop cannot see that.

6. REPORT. If anything is still failing, say so first, with the gate name, the exit code, and
   the diagnostic output. Never lead with what passed.
```

### Rules

- **Never make a gate pass by weakening it.** Deleting an assertion, loosening a threshold, or
  adding a lint-disable comment is not a fix — it is hiding the failure and is worse than
  leaving it red, because the next run reports green.
- **`unavailable` is not `pass`.** A missing binary means the gate could not run. Report it as
  unavailable and never count it toward the passing tally.
- **No gates detected is not success.** Say that nothing was checked.
- **Three attempts, then stop.** The fourth attempt on the same gate is where thrashing starts.
  Report the diagnostics and hand it back.
- **Report failures before successes.** "18 passed, 1 failed" buries the only line that matters.

### Relationship to `/test`

`/test` runs the test suite and reports; it deliberately does not fix, because a skill that both
grades and repairs its own grade cannot be trusted. `/verify` is the layer that _is_ allowed to
fix — across every gate, not just tests — under the retry bound above. Use `/test` to see where
you stand; use `/verify` to get to green.

## Expected Output

```text
User: /verify

Detected 2 gates: test, markdownlint

FAIL  test           12.4s
PASS  markdownlint    0.9s

--- test (exit 1) ---
tests/auth.test.ts:42
  expected 401, received 500
  TypeError: Cannot read properties of undefined (reading 'token')

Attempt 1/3 — src/auth/middleware.ts:31 reads req.user.token before the guard runs.
Fixed: moved the token read inside the authenticated branch.

Re-running test... PASS

Re-running all gates after fix...
PASS  test           12.1s
PASS  markdownlint    0.9s

✅ 2/2 gates passed
```

### When the budget runs out

```text
❌ 1 gate still failing after 3 attempts: typecheck

--- typecheck (exit 2) ---
src/api/client.ts:88
  Type 'string | undefined' is not assignable to type 'string'

Attempted: narrowed at call site (failed), added guard clause (failed),
widened the parameter type (rejected — that hides the null case).

Stopping per the retry bound. This needs a decision: either the API type is
wrong or the caller must handle undefined.
```

## Notes

- `scripts/run-checks.mjs` does the discovery and execution. It exits non-zero if any gate fails,
  if every detected gate was unavailable, or if `--only`/`--skip` names a gate that does not
  exist. It exits 0 when no gates are detected at all — so before relying on it as a CI step,
  run `--list` once and confirm the gates you expect are actually found. A detection regression
  would otherwise green the build silently.
- Detection is evidence-based, not directory-based: a `tests/` folder alone does not add a pytest
  gate, because pytest exits 5 on an empty collection and that reads as a failure.
- Add a project-specific gate by defining it where the runner already looks — a `package.json`
  script, a Makefile target, or a lint config — rather than by teaching this skill about it.
