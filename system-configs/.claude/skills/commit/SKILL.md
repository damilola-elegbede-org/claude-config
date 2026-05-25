---
name: commit
description: Create git commits with intelligent message generation. Use when changes are ready to commit.
argument-hint: "[--amend]"
metadata:
  category: workflow
---

# /commit

## Usage

```bash
/commit                         # Analyze changes and create commit
/commit --amend                 # Amend last commit with staged changes
```

## Description

Creates git commits with intelligently generated conventional commit messages. Analyzes staged and unstaged changes,
maintains repository commit style consistency, and leverages git's built-in pre-commit hooks for quality validation.

**CRITICAL**: This command NEVER uses `--no-verify`. Quality gates exist to protect code integrity and must always be
respected. If pre-commit hooks fail, the error is reported for manual resolution.

## Behavior

### Default Mode - Intelligent Commit Creation

**What it does:** Analyzes changes, generates commit message, creates commit

1. **Check Repository State**
   - Run `git status` to identify changes
   - Run `git diff` for staged changes
   - Run `git diff HEAD` for unstaged changes
   - Check for files that shouldn't be committed (.tmp/, .DS_Store, etc.)

2. **Repository Hygiene**
   - Warn about temporary files in staging (.tmp/, *.log, build artifacts)
   - Suggest .gitignore additions for common patterns
   - Identify OS-specific files (.DS_Store, Thumbs.db)
   - Note auto-generated files that may need exclusion

3. **Generate Commit Message**
   - Analyze changed files and diff content
   - Follow conventional commit format
   - Match repository's existing commit style
   - Include clear, concise description
   - Add Claude Code attribution footer

4. **Create Commit**
   - Stage relevant files if needed
   - Execute `git commit` with generated message
   - Let pre-commit hooks validate changes
   - Report commit hash and status

### Amend Mode (--amend)

**What it does:** Amends the last commit with current staged changes

1. Check last commit authorship (ensure it's safe to amend)
2. Verify commit hasn't been pushed to remote
3. Add staged changes to previous commit
4. Preserve or update commit message as appropriate

## Expected Output

### Successful Commit

```text
User: /commit
Claude: Analyzing repository changes...

Changes Summary:
  Modified: 3 files
    - src/auth/login.ts (authentication improvements)
    - tests/auth.test.ts (test coverage additions)
    - README.md (updated installation steps)

Commit Message:
feat(auth): implement JWT token refresh mechanism

- Add automatic token refresh before expiration
- Include comprehensive test coverage for auth flows
- Update README with new authentication setup steps

Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>

Commit created: a1b2c3d
```

### Pre-commit Hook Failure

```text
User: /commit
Claude: Analyzing repository changes...

Commit Message: fix(api): resolve validation error handling

Pre-commit hook failed:
  - ESLint: 3 errors in src/api/validator.ts
    - Line 45: Unexpected console.log statement
    - Line 67: Missing return type annotation
    - Line 89: Unused variable 'result'

  - Tests: 1 failing test
    - tests/api.test.ts: Validation should reject invalid input

Please fix these issues and try again:
  1. Fix ESLint errors in src/api/validator.ts
  2. Repair failing test in tests/api.test.ts
  3. Run `/commit` again once resolved

Tip: Run `/review` to catch issues before committing
```

### Repository Hygiene Warning

```text
User: /commit
Claude: Analyzing repository changes...

Repository Hygiene Issues:
  Temporary files detected in staging:
    - .tmp/debug.log
    - .DS_Store
    - node_modules/.cache/

  Recommendations:
    1. Unstage temporary files: git reset .tmp/ .DS_Store
    2. Add to .gitignore: *.log, .DS_Store, node_modules/
    3. Clean staging area before committing

Continue with commit? (These files will be included if not removed)
```

## Commit Message Format

### Conventional Commit Structure

```text
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:** feat, fix, docs, style, refactor, test, chore, perf, ci

**Example:**

```text
feat(auth): add OAuth2 authentication support

- Implement OAuth2 authorization code flow
- Add token management and refresh logic
- Include provider configuration for Google and GitHub
- Add comprehensive integration tests

Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Quality Standards

### Repository Hygiene

**Auto-detected issues:**

- Temporary files: .tmp/, *.log,*.debug
- Build artifacts: dist/, build/, target/, out/
- IDE files: .idea/, .vscode/, *.swp
- OS files: .DS_Store, Thumbs.db, desktop.ini
- Package files: node_modules/, vendor/, .env.local

### Commit Message Quality

**Standards enforced:**

- Conventional commit format adherence
- Clear, concise subject line (<72 characters)
- Detailed body for complex changes
- Consistent tense and style with repository
- Proper scope identification

### Pre-commit Hook Respect

**Never bypass hooks:**

- Linting checks (ESLint, Prettier, Ruff, etc.)
- Test execution requirements
- Security scanning (if configured)
- Custom validation scripts

**If hooks fail:** Report errors clearly and halt commit process

## Implementation Strategy

### Change Analysis

Claude directly analyzes:

- Git status output for file changes
- Git diff for staged content
- Git log for commit style patterns
- Repository structure for scope determination

### Message Generation

Claude generates messages considering:

- Type of changes (feature, fix, refactor, etc.)
- Affected areas (scope identification)
- Change magnitude (subject and body detail)
- Repository conventions (existing commit patterns)

### Commit Execution

```bash
# Stage files if needed
git add <relevant-files>

# Create commit with generated message
git commit -m "$(cat <<'EOF'
<generated-commit-message>

Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

# Report result
git log -1 --oneline
```

## Error Handling

### Pre-commit Hook Failures

- Parse hook output to identify specific issues
- Report errors with file locations and descriptions
- Suggest remediation steps or commands
- Halt commit process (never bypass with --no-verify)

### No Changes to Commit

```text
Working tree clean - no changes to commit
```

### Amend Safety Checks

```text
Cannot amend: Last commit authored by different user
Cannot amend: Commit already pushed to remote
```

## Notes

- Streamlined design focuses on commit creation, not complex orchestration
- Trusts git's pre-commit hooks for quality validation
- Reports errors clearly without auto-remediation waves
- Fast execution: typically <5 seconds
- Repository hygiene warnings help maintain clean git history
- Conventional commit format ensures consistency
- Claude Code attribution maintains transparency
- Safe amend mode with authorship and push checks
