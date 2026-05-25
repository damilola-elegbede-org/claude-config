---
name: feature-lifecycle
description: End-to-end autonomous feature implementation from plan to merged PR. Use when implementing a complete feature, bug fix, or refactor from a spec, GitHub issue, or description.
argument-hint: "[spec-file|--issue <number>|description]"
metadata:
  category: orchestration
---

# /feature-lifecycle Skill

## Repository Context

- Repo: !`basename $(git rev-parse --show-toplevel)`
- Branch: !`git branch --show-current`
- Tech stack: !`ls package.json Cargo.toml pyproject.toml go.mod requirements.txt 2>/dev/null`
- Recent commits: !`git log --oneline -5`

## Phase 0: Input Detection & Requirements Gathering

Detect the input type from `$ARGUMENTS` and normalize into a structured spec.

### Input Types

| Type | Detection | Action |
|------|-----------|--------|
| Spec file | `$ARGUMENTS` ends in `.md` and file exists | Read file, extract requirements |
| GitHub issue | `$ARGUMENTS` contains `--issue <number>` | Run `gh issue view <number>`, extract title/body/labels |
| Inline description | `$ARGUMENTS` contains text that is not a file path or flag | Parse text as requirements |
| Interactive | `$ARGUMENTS` is empty | Prompt user for feature description, acceptance criteria, and constraints |

### Normalization

Regardless of input type, produce a structured spec:

```text
FEATURE: <title>
REQUIREMENTS:
  - <functional requirement 1>
  - <functional requirement 2>
ACCEPTANCE_CRITERIA:
  - <criterion 1>
  - <criterion 2>
CONSTRAINTS:
  - <constraint 1>
TYPE: feature | bugfix | refactor
```

Ensure the output directory exists, then save the normalized spec:

```text
RUN: mkdir -p .tmp/plans
SAVE: .tmp/plans/feature-spec-<branch-name>.md
```

## Phase 1: Plan

```text
STEP 1: Create feature branch (if on main/master)
  RUN: /branch <descriptive-branch-name>

STEP 2: Generate implementation plan
  INVOKE: /plan with architect agent context
  INPUT: Normalized spec from Phase 0
  OUTPUT: Implementation plan with task breakdown, file changes, agent assignments

STEP 3: Self-review loop
  REVIEW: Does the plan cover all acceptance criteria?
  REVIEW: Are there missing edge cases or error handling?
  REVIEW: Is the task ordering correct (dependencies respected)?
  IF: gaps found → refine plan and re-review (max 2 iterations)

STEP 4: Save plan
  RUN: mkdir -p .tmp/plans
  SAVE: .tmp/plans/implementation-plan-<branch-name>.md
```

## Phase 2: Implement

```text
STEP 1: Implement features
  INVOKE: /implement with the saved plan
  TRACK: Progress via task system

STEP 2: Run tests
  INVOKE: /test
  IF: tests fail
    FIX: Address failures
    RE-RUN: /test (max 3 attempts)
  IF: still failing after 3 attempts
    HALT: Report failures and request user input
```

## Phase 3: Ship

```text
STEP 1: Ship the implementation
  INVOKE: /ship-it -t -c -r -p -pr
  CAPTURE: PR URL from output

STEP 2: Store PR reference
  SET: $PR_URL = captured PR URL
  OUTPUT: "PR created: $PR_URL"
```

## Phase 4: Monitor & Fix

```text
LOOP: max 5 iterations
  STEP 1: Check CI status
    RUN: gh pr checks $PR_URL --watch --fail-fast (timeout 5 min)
    IF: checks passing → continue to Step 2
    IF: checks failing
      INVOKE: /fix-ci
      INVOKE: /commit with fix description
      INVOKE: /push
      CONTINUE: next iteration

  STEP 2: Check review status
    RUN: gh pr view $PR_URL --json reviews,reviewRequests
    IF: no reviews yet → WAIT 30 seconds, re-check (max 3 waits)
    IF: changes requested
      INVOKE: /resolve-comments --auto
      INVOKE: /commit with review fix description
      INVOKE: /push
      CONTINUE: next iteration
    IF: approved → BREAK loop

  IF: loop exhausted (5 iterations)
    OUTPUT: "Monitor loop exhausted. Manual intervention needed."
    OUTPUT: "PR: $PR_URL"
    HALT
```

## Phase 5: Merge & Report

```text
STEP 1: Merge
  RUN: gh pr merge $PR_URL --squash --delete-branch
  IF: merge fails
    OUTPUT: "Merge failed. Manual merge needed: $PR_URL"
    HALT

STEP 2: Generate summary report
  OUTPUT:
    "Feature Lifecycle Complete
    ─────────────────────────
    Feature: <title>
    Branch:  <branch-name>
    PR:      $PR_URL
    Status:  Merged

    Phases:
      Plan:      completed
      Implement: completed (<N> files changed)
      Ship:      completed (PR created)
      Monitor:   completed (<N> CI/review iterations)
      Merge:     completed

    Files Changed:
      <list of modified files>

    Tests: <pass count> passing"
```

## SDK Delegation Patterns

This skill works across multiple invocation contexts:

### Terminal Interactive

```bash
# From spec file
/feature-lifecycle feature-spec.md

# From GitHub issue
/feature-lifecycle --issue 42

# From inline description
/feature-lifecycle "Add rate limiting to the /api/users endpoint with 100 req/min per API key"

# Interactive mode (prompts for input)
/feature-lifecycle
```

### CLI Headless

```bash
# Pipe spec via stdin
claude -p "Run /feature-lifecycle with this spec: Add pagination to the users API endpoint with cursor-based navigation, 50 items per page default"

# Reference a spec file
claude -p "/feature-lifecycle docs/specs/rate-limiting.md"

# From GitHub issue
claude -p "/feature-lifecycle --issue 42"
```

### Agent SDK (Python)

```python
import anthropic

client = anthropic.Anthropic()
message = client.messages.create(
    model="claude-opus-4-6",
    max_tokens=16384,
    messages=[{
        "role": "user",
        "content": "/feature-lifecycle --issue 42"
    }]
)
```

### Agent SDK (TypeScript)

```typescript
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic();
const message = await client.messages.create({
  model: "claude-opus-4-6",
  max_tokens: 16384,
  messages: [{
    role: "user",
    content: "/feature-lifecycle --issue 42"
  }]
});
```

### Lead Agent Delegation

```text
Use the Task tool to delegate to feature-agent:
  "Implement the feature described in docs/specs/rate-limiting.md
   using /feature-lifecycle. Report back with the PR URL when complete."
```

### CI/CD (GitHub Actions)

```yaml
- name: Implement feature from issue
  run: |
    claude -p "/feature-lifecycle --issue ${{ github.event.issue.number }}"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Notes

- Each phase validates its preconditions before executing
- Halts immediately on unrecoverable failures with clear error messages
- All intermediate artifacts saved to `.tmp/plans/` for debugging
- The monitor loop prevents infinite cycles with a hard cap of 5 iterations
- Requires `gh` CLI authenticated for GitHub operations
