---
name: review
description: Comprehensive code review using code-reviewer agent with assertive analysis. Use when reviewing code changes.
argument-hint: "[--full|--deep]"
category: orchestration
context: fork
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

With `--deep`, spawns a three-reviewer team via TeamCreate for multi-perspective
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

### Step 3a: Deep Review (TeamCreate)

Create a review team with three specialized reviewers. All run in parallel.
Read-only behavior enforced via prompt constraints (do not modify source files).

```text
# Create the team
TeamCreate:
  team_name: "review-{current-branch}"
  description: "Deep review of {current-branch}"
```

Spawn three reviewer teammates **in a SINGLE message with multiple Task tool calls**:

```text
Task tool call 1:
  subagent_type: "general-purpose"
  name: "code-reviewer"
  team_name: "review-{current-branch}"
  model: "sonnet"
  prompt: |
    You are an elite staff-level code reviewer. Your capabilities:

    **Code Quality:**
    - Automated linting: ESLint, ruff, golangci-lint, clippy with blocking enforcement
    - Security analysis: Vulnerability detection, OWASP compliance, injection prevention
    - Performance review: Algorithm complexity, memory leaks, database query optimization
    - Quality gates: 80%+ test coverage, cyclomatic complexity <10, DRY enforcement
    - Multi-language: JavaScript/TypeScript, Python, Go, Rust, full-stack patterns
    - Architecture review: Design patterns, SOLID principles, maintainability

    ## Git Conventions Reference
    {embed full content of git-conventions skill}

    ## Your Task

    Review the following files for bugs, performance, best practices, and code quality.
    IMPORTANT: Do NOT modify any source files. Only read source files and write your
    findings to the output file below.

    Files to review:
    {file_list from Step 2}

    Write your findings to .tmp/review-code.json using this schema:
    {
      "schema_version": "1.0",
      "branch": "{current_branch}",
      "created_at": "{ISO timestamp}",
      "source": "code-reviewer",
      "summary": "Brief overall assessment",
      "walkthrough": [{"file": "path", "description": "what changed"}],
      "issues": [
        {
          "id": {sequential number},
          "file": "path/to/file",
          "line": {line number or null},
          "severity": "LOW|MEDIUM|HIGH|CRITICAL",
          "type": "bugs|performance|best-practices|code-quality",
          "description": "Issue description",
          "suggestion": "Concrete fix"
        }
      ]
    }

    Use the assertive review profile: no hedging, imperative language,
    focus exclusively on problems.

Task tool call 2:
  subagent_type: "general-purpose"
  name: "security-reviewer"
  team_name: "review-{current-branch}"
  model: "sonnet"
  prompt: |
    You are a security specialist conducting a focused security review.
    IMPORTANT: Do NOT modify any source files. Only read source files and write your
    findings to the output file below.

    ## Security Checklist Reference
    {embed full content of security-checklist skill}

    ## Your Task

    Review the following files exclusively for security issues:
    - Injection vulnerabilities (SQL, command, XSS, SSRF)
    - Authentication and authorization flaws
    - Data exposure (secrets, PII, sensitive data in logs)
    - Insecure deserialization, path traversal
    - Missing input validation at trust boundaries
    - Hardcoded credentials or API keys
    - OWASP Top 10 compliance

    Files to review:
    {file_list from Step 2}

    Write your findings to .tmp/review-security.json using this schema:
    {
      "schema_version": "1.0",
      "branch": "{current_branch}",
      "created_at": "{ISO timestamp}",
      "source": "security-reviewer",
      "summary": "Security assessment",
      "walkthrough": [{"file": "path", "description": "security-relevant changes"}],
      "issues": [
        {
          "id": {sequential number},
          "file": "path/to/file",
          "line": {line number or null},
          "severity": "LOW|MEDIUM|HIGH|CRITICAL",
          "type": "security",
          "description": "Issue description",
          "suggestion": "Concrete fix"
        }
      ]
    }

    Severity escalation: any issue in auth/payment/PII code → escalate one level.

Task tool call 3:
  subagent_type: "general-purpose"
  name: "a11y-reviewer"
  team_name: "review-{current-branch}"
  model: "haiku"
  prompt: |
    You are an accessibility specialist conducting a focused accessibility review.
    IMPORTANT: Do NOT modify any source files. Only read source files and write your
    findings to the output file below.

    ## Your Task

    Review the following files exclusively for accessibility issues:
    - Missing or incorrect ARIA attributes
    - Keyboard navigation gaps
    - Color contrast violations (WCAG AA minimum)
    - Missing alt text on images
    - Form labels and error announcements
    - Focus management issues
    - Screen reader compatibility
    - Semantic HTML usage

    Files to review:
    {file_list from Step 2}

    Write your findings to .tmp/review-accessibility.json using this schema:
    {
      "schema_version": "1.0",
      "branch": "{current_branch}",
      "created_at": "{ISO timestamp}",
      "source": "a11y-reviewer",
      "summary": "Accessibility assessment",
      "walkthrough": [{"file": "path", "description": "a11y-relevant changes"}],
      "issues": [
        {
          "id": {sequential number},
          "file": "path/to/file",
          "line": {line number or null},
          "severity": "LOW|MEDIUM|HIGH|CRITICAL",
          "type": "accessibility",
          "description": "Issue description",
          "suggestion": "Concrete fix"
        }
      ]
    }

    If no frontend/UI files are in scope, write empty issues array with
    summary: "No UI files in scope for accessibility review."
```

Wait for all reviewers to complete. Then merge results:

```text
READ: .tmp/review-code.json, .tmp/review-security.json, .tmp/review-accessibility.json

FOR EACH file in [review-code.json, review-security.json, review-accessibility.json]:
  VALIDATE: schema_version field exists in JSON
  SET: CURRENT_SCHEMA_VERSION = "1.0"
  IF: schema_version is missing OR schema_version != CURRENT_SCHEMA_VERSION
    SET: backup_path = .tmp/{file}.backup-{timestamp}.json
    COPY: .tmp/{file} TO backup_path
    DELETE: .tmp/{file}
    OUTPUT: "⚠️ Schema version mismatch in {file} (found: {schema_version}, expected: {CURRENT_SCHEMA_VERSION}). Backed up to {backup_path} — skipping this reviewer's output."
    SKIP: this file's issues in merge (do not abort entire merge)

MERGE: Combine all issues into .tmp/review-local.json
  - Concatenate all issues from all reviewers
  - If same file+line appears with substantially similar description across reviewers, keep highest severity and merge
  - Re-number issue IDs sequentially
  - Combine walkthroughs (deduplicate by file)
  - Set source: "deep-review"

# Cleanup team
SendMessage shutdown_request to code-reviewer, security-reviewer, a11y-reviewer
TeamDelete
```

Go to Step 4.

### Step 3b: Single Reviewer (Default)

Launch a single code-reviewer agent with the comprehensive review prompt below.

```yaml
Task tool:
  subagent_type: "code-reviewer"
  description: "Run comprehensive code review"
  prompt: |
    You are an elite code reviewer conducting a comprehensive, assertive analysis.
    Review the following files and output results to .tmp/review-local.json

    Create .tmp/ directory if needed: mkdir -p .tmp

    Files to review:
    {file_list from Step 2}

    ===== REVIEW INSTRUCTIONS =====

    ## Output Structure

    Your review MUST follow this three-part structure:

    ### Part 1: Summary
    A concise overview of changes, their purpose, and overall assessment.

    ### Part 2: Walkthrough
    For each changed file, provide:
    - File path
    - Brief description of what changed and why
    - Any architectural implications

    ### Part 3: Inline Comments
    Specific, actionable findings tied to exact file paths and line numbers.

    ## Analysis Domains

    Evaluate ALL five domains for every file:

    **1. Security**
    - Injection vulnerabilities (SQL, command, XSS, SSRF)
    - Authentication and authorization flaws
    - Data exposure (secrets, PII, sensitive data in logs)
    - Insecure deserialization, path traversal
    - Missing input validation at trust boundaries
    - Hardcoded credentials or API keys

    **2. Bugs & Correctness**
    - Null/undefined reference errors
    - Off-by-one errors, boundary conditions
    - Race conditions, concurrency issues
    - Incorrect error handling (swallowed exceptions, wrong error types)
    - Logic errors in conditionals and loops
    - Type mismatches and implicit conversions
    - Resource leaks (unclosed handles, missing cleanup)

    **3. Performance**
    - N+1 query patterns
    - Unnecessary re-renders or recomputations
    - Memory leaks (event listeners, closures, circular references)
    - Algorithm complexity (O(n^2) where O(n) is possible)
    - Unbounded data structures (missing pagination, limits)
    - Blocking operations on hot paths
    - Missing caching opportunities

    **4. Best Practices**
    - DRY violations (duplicated logic)
    - SOLID principle violations
    - Missing or inadequate error handling
    - Poor naming (unclear, misleading, inconsistent)
    - Magic numbers and hardcoded values
    - Missing input validation
    - Inconsistent patterns within the codebase

    **5. Code Quality**
    - Cyclomatic complexity > 10
    - Functions > 50 lines
    - Deep nesting (> 3 levels)
    - Missing edge case handling
    - Unclear control flow
    - Dead code or unreachable branches
    - Inconsistent formatting or style

    ## Language-Specific Checks

    **Python:**
    - Mutable default arguments
    - Missing `__init__.py` for packages
    - Bare `except:` clauses
    - f-string injection in logging
    - Missing type hints on public APIs
    - Unsafe `eval()`/`exec()` usage

    **TypeScript/JavaScript:**
    - `any` type usage (should be narrowed)
    - Missing `await` on async calls
    - Prototype pollution vectors
    - Unsafe `innerHTML` or `dangerouslySetInnerHTML`
    - Missing error boundaries in React
    - Unhandled promise rejections

    ## Review Profile: Assertive

    - DO NOT hedge or soften findings. State issues directly.
    - Use imperative language: "Fix this", "Remove this", "This must be changed"
    - Every finding must include a concrete fix suggestion
    - Do not praise code. Focus exclusively on problems.
    - If code is acceptable, say so briefly and move on.
    - Treat "it works" as insufficient — code must be correct, secure, and maintainable.

    ## Severity Rules

    - **CRITICAL**: Security vulnerabilities, data loss risks, crashes in production
    - **HIGH**: Bugs that will manifest in normal usage, significant performance issues
    - **MEDIUM**: Best practice violations, maintainability concerns, minor performance issues
    - **LOW**: Style issues, minor improvements, nice-to-haves

    Severity escalation:
    - Any issue in auth/payment/PII handling code: escalate one level
    - Any issue that affects multiple files or is systemic: escalate one level
    - Any issue with a simple, obvious fix: do not de-escalate (easy to fix != unimportant)

    ## Output Format

    Write results to .tmp/review-local.json with this schema:
    {
      "schema_version": "1.0",
      "branch": "{current_branch}",
      "created_at": "{ISO timestamp}",
      "source": "code-reviewer",
      "summary": "Brief overall assessment",
      "walkthrough": [
        {
          "file": "path/to/file",
          "description": "What changed and why"
        }
      ],
      "issues": [
        {
          "id": {sequential number},
          "file": "path/to/file",
          "line": {line number or null},
          "severity": "LOW|MEDIUM|HIGH|CRITICAL",
          "type": "security|bugs|performance|best-practices|code-quality",
          "description": "Issue description - be specific and direct",
          "suggestion": "Concrete fix with code example when applicable"
        }
      ]
    }

    Report: "Code reviewer found {count} issues"

    If no issues found, write empty issues array with summary.
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

🏗️ Creating team: review-feature-auth
   Spawning 3 reviewers...
   [tmux panes show code-reviewer, security-reviewer, a11y-reviewer]

   ✓ code-reviewer: 4 issues found
   ✓ security-reviewer: 2 issues found
   ✓ a11y-reviewer: 1 issue found

Merging and deduplicating results...
🧹 Shutting down team review-feature-auth...

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
- `--deep` spawns three reviewers via TeamCreate for multi-perspective analysis
- Code and security reviewers use `model: "sonnet"`; a11y-reviewer uses `model: "haiku"` (checklist-driven, structured output)
- Code-reviewer prompt embeds `git-conventions` skill; security-reviewer embeds `security-checklist`
- Cleanup (shutdown + TeamDelete) always runs after `--deep` review
- Manual cleanup if needed: `rm -rf ~/.claude/teams/review-* ~/.claude/tasks/review-*`
- When [#24316][tc] lands, replace `subagent_type: "general-purpose"` with custom agent types

[tc]: https://github.com/anthropics/claude-code/issues/24316
