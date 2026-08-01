---
name: test
description: Auto-discover and run tests for any project. Use when running or creating tests.
argument-hint: "[--create|--framework|--coverage]"
metadata:
  category: workflow
---

# /test

## Usage

```bash
/test                     # Auto-discover and run tests
/test --create            # Generate a test suite if none exists
/test --framework <name>  # Force a framework (jest, pytest, go, ...)
/test --coverage          # Run with coverage reporting
```

## Description

Universal test runner. Finds the right test command for the repository — checking README, package
manager config, framework config, then file patterns — runs it, and reports results.

Discovery order, the per-language config/command/pattern table, coverage flags, and how to read common
environment failures: → `references/discovery.md`

`--framework` skips discovery. `--create` generates a suite (the only mode that delegates, to
`test-engineer`).

## What matters most

- **Report the real output.** Stream the runner's own output and surface each failure with its file,
  line, and assertion. Don't summarize a failing suite as passing, and don't paraphrase counts.
- **Don't fix failing tests here.** This skill runs and reports; failures go back to the developer.
  Fixing behavior behind a green checkmark is the failure mode to avoid.
- **Distinguish "no tests" from "tests failed" from "can't run tests."** Each needs a different next
  step, and reporting a missing framework as a test failure sends the reader the wrong way.
- **Ask when several suites exist** (unit vs. integration vs. e2e) instead of assuming the broadest.
- With `--create`, run the generated tests before claiming the suite works.

## Expected Output

```text
User: /test

🔍 Discovering test command...
✅ Found: pytest -v (from pytest.ini)

🧪 Running tests...
[runner output streams through unmodified]

❌ 2 of 5 tests failed

Failed tests:
  1. test_logout (tests/test_auth.py:12) — AssertionError: assert False == True
  2. test_create_user (tests/test_api.py:25) — KeyError: 'email'
```

When nothing is discoverable, report what was searched (README, package config, test files, test
config) and offer `--create` or `--framework`.
