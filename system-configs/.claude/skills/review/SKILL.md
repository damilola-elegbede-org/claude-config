---
name: review
description: Comprehensive code review using code-reviewer agent with assertive analysis. Use when reviewing code changes.
argument-hint: "[--full|--deep]"
context: fork
metadata:
  category: orchestration
---

# /review

## Usage

```bash
/review           # Review current branch changes vs main (single reviewer)
/review --full    # Review entire codebase (single reviewer)
/review --deep    # Multi-perspective team review (code + security + accessibility)
```

## Description

Comprehensive code review that launches a code-reviewer agent with a thorough,
assertive review prompt covering security, bugs, performance, best practices,
and code quality.

With `--deep`, fans out three subagents in parallel for multi-perspective
analysis: code quality, security, and accessibility. Each reviewer writes to a
separate output file; results are merged and deduplicated before triage.

Results are passed to `/resolve-comments` for interactive triage.

## Execution

### Step 1: Validate Environment

```text
OUTPUT: "Starting code review analysis..."
```

### Step 2: Determine Scope

```text
IF: --full flag
  SCOPE: all files in repository (use git ls-files)
  OUTPUT: "Mode: Full codebase review"
ELSE:
  SCOPE: git diff $(git merge-base main HEAD)..HEAD + uncommitted changes
  RUN: git diff --name-only $(git merge-base main HEAD)..HEAD
  RUN: git diff --name-only (uncommitted)
  MERGE: both file lists (deduplicated)
  OUTPUT: "Mode: Branch delta review ({count} files)"

IF: no files to review
  OUTPUT: "No changes to review"
  END
```

### Step 3: Route by Mode

```text
IF: --deep flag
  → Go to Step 3a (Team Review)
ELSE:
  → Go to Step 3b (Single Reviewer)
```

### Step 3a: Deep Review (Subagent Fan-Out)

Fan out three specialized reviewer subagents in parallel. Read-only behavior
enforced via prompt constraints (do not modify source files).

Spawn all three reviewers **in a SINGLE message with multiple Task tool calls**:

```text
Task tool call 1:
  subagent_type: "general-purpose"
  description: "Code-quality review"
  model: "sonnet"
  prompt: contents of `references/code-review-prompt.md`, with `{file_list}` from Step 2, `{current_branch}`, and `{ISO timestamp}` substituted

Task tool call 2:
  subagent_type: "general-purpose"
  description: "Security review"
  model: "sonnet"
  prompt: contents of `references/security-review-prompt.md`, with `{file_list}` from Step 2, `{current_branch}`, and `{ISO timestamp}` substituted

Task tool call 3:
  subagent_type: "general-purpose"
  description: "Accessibility review"
  model: "haiku"
  prompt: contents of `references/a11y-review-prompt.md`, with `{file_list}` from Step 2, `{current_branch}`, and `{ISO timestamp}` substituted
```

Wait for all reviewers to complete. Then merge results:

```text
READ: .tmp/review-code.json, .tmp/review-security.json, .tmp/review-accessibility.json

FOR EACH stem in [review-code, review-security, review-accessibility]:
  VALIDATE: schema_version field exists in .tmp/{stem}.json
  SET: CURRENT_SCHEMA_VERSION = "1.0"
  IF: schema_version is missing OR schema_version != CURRENT_SCHEMA_VERSION
    SET: backup_path = .tmp/{stem}.backup-{timestamp}.json
    COPY: .tmp/{stem}.json TO backup_path
    DELETE: .tmp/{stem}.json
    OUTPUT: "⚠️ Schema version mismatch in {stem}.json (found: {schema_version}, expected: {CURRENT_SCHEMA_VERSION}). Backed up to {backup_path} — skipping this reviewer's output."
    SKIP: this file's issues in merge (do not abort entire merge)

MERGE: Combine all issues into .tmp/review-local.json
  - Concatenate all issues from all reviewers
  - If same file+line appears with substantially similar description across reviewers, keep highest severity and merge
  - Re-number issue IDs sequentially
  - Combine walkthroughs (deduplicate by file)
  - Set source: "deep-review"
```

Go to Step 4.

### Step 3b: Single Reviewer (Default)

Launch a single code-reviewer agent with the comprehensive review prompt
in `references/single-review-prompt.md`.

```yaml
Task tool:
  subagent_type: "code-reviewer"
  description: "Run comprehensive code review"
  prompt: contents of `references/single-review-prompt.md`, with `{file_list}` from Step 2, `{current_branch}`, and `{ISO timestamp}` substituted
```

### Step 4: Report Results

```text
WAIT: for reviewer(s) to complete

READ: .tmp/review-local.json

IF: --deep mode
  OUTPUT:
    Deep Review Complete

    | Reviewer | Issues Found |
    |----------|--------------|
    | Code Reviewer | {code_count} |
    | Security Reviewer | {security_count} |
    | Accessibility Reviewer | {a11y_count} |
    | **Total (deduplicated)** | **{total_count}** |

    Severity breakdown:
    - Critical: {critical_count}
    - High: {high_count}
    - Medium: {medium_count}
    - Low: {low_count}

ELSE:
  OUTPUT:
    Code Review Complete

    | Reviewer | Issues Found |
    |----------|--------------|
    | Code Reviewer | {issue_count} |

    Severity breakdown:
    - Critical: {critical_count}
    - High: {high_count}
    - Medium: {medium_count}
    - Low: {low_count}
```

### Step 5: Hand Off to Triage

```text
IF: total issues > 0
  OUTPUT: "Launching interactive triage..."
  Skill tool: skill="resolve-comments", args="--local --auto"
ELSE:
  OUTPUT: "No issues found. Code looks good!"
  END
```

## Expected Output

### Default Mode

```text
User: /review

Starting code review analysis...
Mode: Branch delta review (5 files)

[Launching code reviewer...]

Code Review Complete

| Reviewer | Issues Found |
|----------|--------------|
| Code Reviewer | 5 |

Severity breakdown:
- Critical: 0
- High: 1
- Medium: 3
- Low: 1

Launching interactive triage...
[/resolve-comments --local --auto takes over]
```

### Deep Mode

```text
User: /review --deep

Starting code review analysis...
Mode: Branch delta review (5 files)

Spawning 3 reviewer subagents in parallel...

   ✓ code-reviewer: 4 issues found
   ✓ security-reviewer: 2 issues found
   ✓ a11y-reviewer: 1 issue found

Merging and deduplicating results...

Deep Review Complete

| Reviewer | Issues Found |
|----------|--------------|
| Code Reviewer | 4 |
| Security Reviewer | 2 |
| Accessibility Reviewer | 1 |
| **Total (deduplicated)** | **6** |

Severity breakdown:
- Critical: 1
- High: 2
- Medium: 2
- Low: 1

Launching interactive triage...
[/resolve-comments --local --auto takes over]
```

## Notes

- Results stored in `.tmp/` for `/resolve-comments` consumption
- No auto-fix — all changes require user approval via triage
- `--full` mode may take longer depending on codebase size
- `--deep` fans out three subagents in parallel for multi-perspective analysis
- Code and security reviewers use `model: "sonnet"`; a11y-reviewer uses `model: "haiku"` (checklist-driven, structured output)
- Code-reviewer prompt embeds `git-conventions` skill; security-reviewer embeds `security-checklist`
- Subagents are ephemeral — no cleanup needed after they return
- When [#24316][tc] lands, replace `subagent_type: "general-purpose"` with custom agent types

[tc]: https://github.com/anthropics/claude-code/issues/24316
