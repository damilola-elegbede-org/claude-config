---
name: fix-ci
description: Diagnose and fix GitHub Actions CI failures. Use when CI pipeline is failing.
argument-hint: "[run-id|--learn]"
context: fork
metadata:
  category: orchestration
  triggers:
    - 'cmd:\bgh\b(\s+(-R|--repo)(=|\s+)\S+|\s+--\S+)*\s+run\s+(view\b.*--log-failed|rerun\b)'
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

| Domain       | Fixer (general-purpose) | Examples                                               |
| ------------ | ----------------------- | ------------------------------------------------------ |
| test         | fixer-test              | Test failures, missing mocks, assertion errors         |
| security     | fixer-security          | Auth issues, credential problems, vulnerability fixes  |
| frontend     | fixer-frontend          | React/Vue errors, CSS issues, client-side bugs         |
| backend      | fixer-backend           | API errors, server logic, microservice issues          |
| data         | fixer-data              | Database errors, migration issues, query problems      |
| pipeline     | fixer-pipeline          | Workflow syntax, CI config, deployment issues          |
| architecture | fixer-architecture      | Design issues, unclear domains, cross-cutting concerns |

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

### Step 1: Fetch CI Failures

```bash
# Get latest failed run (or use provided run-id)
gh run list --status failure --limit 1 --json databaseId,conclusion,event
gh run view <run-id> --json jobs,conclusion
```

Extract: job names, failure messages, log URLs

Always, before any retry (it logs the Jev call even when it withholds the answer): pipe the log of the job or step that
holds the error through
`${HOME}/.claude/hooks/jev/failure-classify.sh ci` and follow its `steer` when `class` is `infra` or `flaky`
(one `gh run rerun <run-id> --failed` before diagnosing). `real` or `unknown` changes nothing. An aggregator job that
only reports other jobs' status (for example a required-checks or gate-status job) holds no error: classify the
failing job it points to instead, or the classifier sees a status summary and steers wrongly.

### Step 2: Diagnose (Parallel Subagents)

Fan out one diagnoser subagent per failure **in a SINGLE message with multiple
Agent tool calls**. Assign each failure a sequential index (1..N) and pass it to
the subagent so its output file is `.tmp/diagnosis-<index>.json` — avoids
unsafe characters from CI job names ending up in filesystem paths.

```text
Agent tool call 1:
  subagent_type: "general-purpose"
  description: "Diagnose <job-1-name>"
  prompt: |
    You are diagnosing a single failed GitHub Actions job. Find the root cause from the log and the source, not the symptom.

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

Agent tool call 2:
  subagent_type: "general-purpose"
  description: "Diagnose <job-2-name>"
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

### Step 3: Classify and Fix (Parallel Subagents)

Group diagnosis results by domain. Fan out one fixer subagent per domain
**in a SINGLE message with multiple Agent tool calls**:

| Diagnosis Domain | Subagent Description | Prompt Specialization                                      |
| ---------------- | -------------------- | ---------------------------------------------------------- |
| test             | fixer-test           | Test patterns, mock strategies, assertion fixes            |
| security         | fixer-security       | Auth fixes, credential handling, vulnerability remediation |
| frontend         | fixer-frontend       | React/Vue patterns, CSS fixes, client-side debugging       |
| backend          | fixer-backend        | API logic, server patterns, microservice fixes             |
| data             | fixer-data           | Database queries, migration fixes, data integrity          |
| pipeline         | fixer-pipeline       | Workflow syntax, CI config, deployment fixes               |
| architecture     | fixer-architecture   | Design patterns, cross-cutting concerns                    |

```text
Agent tool call:
  subagent_type: "general-purpose"
  description: "Fix {domain} failures"
  prompt: |
    You are a {domain} specialist. Fix the following CI failure(s):

    Failure 1:
    - Root cause: <from diagnosis>
    - Files to modify: <from diagnosis>
    - Approach: <from diagnosis>

    Implement the fix. Do not make unrelated changes.
```

Wait for all fixer subagents to return.

### Step 4: Commit and Verify

```bash
# Stage and commit fixes (use explicit file list from diagnosis, never git add -A)
git add <files from diagnosis JSONs>
git commit -m "fix(ci): <summary of fixes>"

# Push and monitor
git push
gh run watch
```

### Step 5: Iterate if Needed

If CI still fails after the fix is pushed:

1. **Return to Step 1** — re-fetch CI failure details. The new run's failures
   may be different (different jobs, different error messages), so don't reuse
   the previous failure list. Overwrite the previous `.tmp/diagnosis-N.json`
   files to avoid mixing stale and fresh diagnoses.
2. Proceed through Steps 2–4 again (diagnose, fix, verify).
3. Stop after 3 fix iterations that leave CI red, and report the still-failing jobs with their latest diagnoses.

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

`--learn`: summarize past `fix(ci):` commits on this branch's history (`git log --grep='^fix(ci)'`) by domain and root
cause. If none exist, say so — don't estimate.

## Notes

- Two-phase architecture separates diagnosis from fixing
- Parallelism via subagent fan-out (multiple Task calls in a single message) — no team scaffolding
- Subagents carry no `model:` pin, so they use the settings.json subagent model
  (`env.CLAUDE_CODE_SUBAGENT_MODEL`) and one settings line moves them all
- Diagnoser spawn prompts carry a one-line role plus the job's log, URL, and output schema
- Domain-specific context embedded in fixer spawn prompts
- Subagents are ephemeral — no cleanup needed after they return
- Subagent thinking level: spawned subagents inherit Claude Code's session
  thinking-mode setting. `ultrathink` is a valid session-level keyword, but
  there is no per-agent `thinking-level`/`thinking-tokens` frontmatter in this
  repo anymore (reasoning depth is controlled by model + effort — see
  `docs/agents/AGENT_TEMPLATE.md`); include `ultrathink` directly in the
  subagent prompt if a specific diagnosis warrants deeper reasoning.
- Iterates up to 3 times, then reports what is still failing
