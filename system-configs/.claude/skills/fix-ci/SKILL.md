---
name: fix-ci
description: Diagnose and fix GitHub Actions CI failures. Use when CI pipeline is failing.
argument-hint: "[run-id|--learn]"
context: fork
metadata:
  category: orchestration
---

# /fix-ci

## Usage

```bash
/fix-ci              # Fix latest failure
/fix-ci 12345678     # Fix specific run
/fix-ci --learn      # Show historical fix patterns
```

## Description

Two-phase CI failure resolution: diagnose with debugger agents, then fix with domain-specialized agents.

## Architecture

### Phase 1: Diagnosis (Parallel Subagents)

Fan out debugger subagents in parallel to investigate each failure. Each debugger returns:

- **Root cause**: What actually failed and why
- **Domain**: Classification for agent routing (see matrix below)
- **Files**: Specific files that need changes
- **Fix approach**: Recommended solution

### Phase 2: Fix (Specialized Subagents)

Route fixes to domain experts based on diagnosis:

| Domain | Fix Agent | Examples |
|--------|-----------|----------|
| test | test-engineer | Test failures, missing mocks, assertion errors |
| security | security-auditor | Auth issues, credential problems, vulnerability fixes |
| frontend | frontend-engineer | React/Vue errors, CSS issues, client-side bugs |
| backend | backend-engineer | API errors, server logic, microservice issues |
| data | data-engineer | Database errors, migration issues, query problems |
| pipeline | devops | Workflow syntax, CI config, deployment issues |
| architecture | architect | Design issues, unclear domains, cross-cutting concerns |

## Workflow

```text
┌─────────────────────────────────────────────────────────────────┐
│ 1. FETCH                                                        │
│    gh run view <run-id> --json jobs                            │
│    → Get failure details from GitHub Actions API                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. DIAGNOSE (Parallel Subagents)                                │
│    Fan out diagnoser-1..N subagents (one per failure)          │
│    Each returns: { root_cause, domain, files, fix_approach }    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. FIX (Parallel Subagents)                                     │
│    Fan out fixer-{domain} subagents based on classification     │
│    Each subagent fixes issues in their domain                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. VERIFY                                                       │
│    Commit fixes, push to remote                                 │
│    Monitor CI run until complete                                │
│    If still failing → iterate from step 2                       │
└─────────────────────────────────────────────────────────────────┘
```

## Execution Steps

### Step 1: Create Task Plan

```text
TaskCreate: "Fetch CI failure details" (no blockers)
TaskCreate: "Diagnose failures" (blockedBy: fetch)
TaskCreate: "Fix failures" (blockedBy: diagnose)
TaskCreate: "Verify CI passes" (blockedBy: fix)
```

### Step 2: Fetch CI Failures

```text
TaskUpdate: "Fetch CI failure details" → in_progress
```

```bash
# Get latest failed run (or use provided run-id)
gh run list --status failure --limit 1 --json databaseId,conclusion,event
gh run view <run-id> --json jobs,conclusion
```

Extract: job names, failure messages, log URLs

```text
TaskUpdate: "Fetch CI failure details" → completed
```

### Step 3: Diagnose (Parallel Subagents)

```text
TaskUpdate: "Diagnose failures" → in_progress
```

Fan out one diagnoser subagent per failure **in a SINGLE message with multiple
Task tool calls**. Assign each failure a sequential index (1..N) and pass it to
the subagent so its output file is `.tmp/diagnosis-<index>.json` — avoids
unsafe characters from CI job names ending up in filesystem paths.

```text
Task tool call 1:
  subagent_type: "general-purpose"
  description: "Diagnose <job-1-name>"
  model: "sonnet"
  prompt: |
    You are an expert debugging and performance specialist. Your capabilities:

    **Bug Investigation:**
    - Intermittent bug investigation: Race conditions, timing issues, heisenbug tracking
    - Production forensics: Log analysis, distributed tracing, failure cascade investigation
    - Memory leak detection: Heap analysis, garbage collection patterns, allocation tracking
    - Root cause analysis: Systematic investigation, evidence correlation, failure timeline

    **Performance Engineering:**
    - Performance profiling: CPU, memory, I/O profiling and bottleneck identification
    - Optimization strategies: Algorithm optimization, caching, query optimization

    ## Your Task

    Investigate CI failure in job '<job-1-name>' (diagnosis index 1):
    - Error output: <paste relevant log lines>
    - Job URL: <url>

    Analyze the failure, read relevant source files, and determine root cause.

    Write your diagnosis to .tmp/diagnosis-1.json:
    {
      "job_name": "<job-1-name>",
      "root_cause": "Brief description of what failed",
      "domain": "test|security|frontend|backend|data|pipeline|architecture",
      "files": ["list", "of", "files", "to", "fix"],
      "fix_approach": "How to fix this issue"
    }

Task tool call 2:
  subagent_type: "general-purpose"
  description: "Diagnose <job-2-name>"
  model: "sonnet"
  prompt: |
    [Same identity preamble as above]

    ## Your Task

    Investigate CI failure in job '<job-2-name>' (diagnosis index 2):
    Write diagnosis to .tmp/diagnosis-2.json (same schema, include job_name field).
    ...
```

Wait for all diagnoser subagents to return. Read diagnosis JSON files
(`.tmp/diagnosis-1.json` … `.tmp/diagnosis-N.json`) — each includes the
original `job_name` field so log output can reference it.

```text
TaskUpdate: "Diagnose failures" → completed
```

### Step 4: Classify and Fix (Parallel Subagents)

```text
TaskUpdate: "Fix failures" → in_progress
```

Group diagnosis results by domain. Fan out one fixer subagent per domain
**in a SINGLE message with multiple Task tool calls**:

| Diagnosis Domain | Subagent Description | Prompt Specialization |
|------------------|----------------------|----------------------|
| test | fixer-test | Test patterns, mock strategies, assertion fixes |
| security | fixer-security | Auth fixes, credential handling, vulnerability remediation |
| frontend | fixer-frontend | React/Vue patterns, CSS fixes, client-side debugging |
| backend | fixer-backend | API logic, server patterns, microservice fixes |
| data | fixer-data | Database queries, migration fixes, data integrity |
| pipeline | fixer-pipeline | Workflow syntax, CI config, deployment fixes |
| architecture | fixer-architecture | Design patterns, cross-cutting concerns |

```text
Task tool call:
  subagent_type: "general-purpose"
  description: "Fix {domain} failures"
  model: "sonnet"
  prompt: |
    You are a {domain} specialist. Fix the following CI failure(s):

    Failure 1:
    - Root cause: <from diagnosis>
    - Files to modify: <from diagnosis>
    - Approach: <from diagnosis>

    Implement the fix. Do not make unrelated changes.
```

Wait for all fixer subagents to return.

```text
TaskUpdate: "Fix failures" → completed
```

### Step 5: Commit and Verify

```text
TaskUpdate: "Verify CI passes" → in_progress
```

```bash
# Stage and commit fixes (use explicit file list from diagnosis, never git add -A)
git add <files from diagnosis JSONs>
git commit -m "fix(ci): <summary of fixes>"

# Push and monitor
git push
gh run watch
```

```text
TaskUpdate: "Verify CI passes" → completed
```

### Step 6: Iterate if Needed

If CI still fails after the fix is pushed:

1. **Return to Step 2** — re-fetch CI failure details. The new run's failures
   may be different (different jobs, different error messages), so don't reuse
   the previous failure list. Overwrite the previous `.tmp/diagnosis-N.json`
   files to avoid mixing stale and fresh diagnoses.
2. Proceed through Steps 3–5 again (diagnose, fix, verify).
3. Continue until green.

```text
TaskList: show final status of all phases
```

## Expected Output

```text
User: /fix-ci

🔍 Fetching CI failures from run #987654...
📊 Found 3 failures: lint, test:unit, build

🔬 Phase 1: Diagnosis
   Fanning out 3 diagnoser subagents in parallel...

   diagnoser-1 (lint):
   └─ Domain: frontend
   └─ Cause: ESLint error in auth.ts - unused variable
   └─ Files: src/auth.ts

   diagnoser-2 (test:unit):
   └─ Domain: test
   └─ Cause: Mock outdated for new API response shape
   └─ Files: tests/api.test.ts

   diagnoser-3 (build):
   └─ Domain: pipeline
   └─ Cause: Missing dependency declaration
   └─ Files: package.json

🔧 Phase 2: Fix
   Fanning out 3 fixer subagents:
   └─ fixer-frontend → src/auth.ts
   └─ fixer-test → tests/api.test.ts
   └─ fixer-pipeline → package.json

   ✓ fixer-frontend: Removed unused variable
   ✓ fixer-test: Updated mock to match new API shape
   ✓ fixer-pipeline: Added missing dependency

💾 Committed and pushed...

📊 Monitoring CI run #987655...
⏳ Running... (2 min)

✅ All CI checks passed!
🎉 CI fixed in 1 iteration
```

### Learn Mode

```text
User: /fix-ci --learn

📊 Historical Fix Patterns (last 30 days):

By Domain:
  test        │ ████████████████ │ 42% (21 fixes)
  frontend    │ ████████         │ 22% (11 fixes)
  pipeline    │ ██████           │ 16% (8 fixes)
  backend     │ ████             │ 10% (5 fixes)
  security    │ ██               │  6% (3 fixes)
  data        │ ██               │  4% (2 fixes)

Success Rate by Agent:
  test-engineer      │ 95% (20/21)
  frontend-engineer  │ 91% (10/11)
  devops             │ 88% (7/8)
  backend-engineer   │ 80% (4/5)

Common Root Causes:
  1. Outdated test mocks (18 occurrences)
  2. Lint violations (12 occurrences)
  3. Missing dependencies (6 occurrences)
```

## Notes

- Two-phase architecture separates diagnosis from fixing
- Parallelism via subagent fan-out (multiple Task calls in a single message) — no team scaffolding
- All subagents spawned with `model: "sonnet"` to match custom agent cost/behavior
- Fixer subagents for simple domains (docs, lint, config) can use `model: "haiku"` for cost savings
- Debugger identity and capabilities embedded in diagnoser spawn prompts (prompt-based specialization)
- Domain-specific context embedded in fixer spawn prompts
- Subagents are ephemeral — no cleanup needed after they return
- When [#24316][tc] fully ships (i.e. when all teammate inheritance behavior is
  supported), replace `subagent_type: "general-purpose"` with custom agent
  types. The issue is still open and partial inheritance already works (system
  prompt, tools, model are inherited via `subagent_type`); the remaining gap is
  full inheritance of custom `.claude/agents/` definitions, which would let us
  use the project's domain-specific agents instead of `general-purpose`.
- Subagent thinking level: spawned subagents inherit Claude Code's session
  thinking-mode setting. `ultrathink` is a valid keyword and a valid value in
  this repo's `thinking-level` frontmatter (see
  `scripts/validate-agent-yaml.py` `THINKING_TOKEN_MAP`); include it in the
  subagent prompt if a specific diagnosis warrants deeper reasoning.
- Iterates until GitHub shows all checks green

[tc]: https://github.com/anthropics/claude-code/issues/24316
