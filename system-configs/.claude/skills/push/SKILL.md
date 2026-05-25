---
name: push
description: Push changes to remote repository with validation. Use when pushing committed changes.
argument-hint: "[--force|--dry-run]"
metadata:
  category: workflow
---

# /push

## Usage

```bash
/push                   # Push current branch to remote
/push --force           # Force push (use with caution)
/push --dry-run         # Preview what would be pushed
```

## Description

Safely pushes changes to remote repository with basic validation checks. Runs tests if configured, executes git push,
and reports results. Leverages git's pre-push hooks for quality validation.

**CRITICAL**: This command NEVER uses `--no-verify`. Pre-push hooks are the last line of defense before code reaches
the remote repository. If hooks fail, issues must be fixed, not bypassed.

## Behavior

### Default Mode - Safe Push

**What it does:** Validates and pushes current branch to remote

1. **Check Repository State**

   ```bash
   git status
   git branch --show-current
   git rev-list @{u}.. # commits ahead of remote
   ```

2. **Run Tests** (if test command configured)
   - Check for test script in package.json, Makefile, etc.
   - Run tests before pushing
   - Report test results

3. **Execute Push**

   ```bash
   git push origin <current-branch>
   ```

   - Pre-push hooks run automatically
   - Report push result
   - Show pushed commits

4. **Confirm Success**
   - Verify push completed
   - Display remote URL and branch
   - Note any warnings or messages

### Force Push (--force)

**What it does:** Force pushes to remote (dangerous operation)

1. **Safety Checks**
   - Verify not on main/master branch
   - Confirm user understands risks
   - Check for uncommitted changes

2. **Execute Force Push**

   ```bash
   git push --force-with-lease origin <current-branch>
   ```

   - Uses --force-with-lease for safety
   - Reports result

**Warning:** Force push rewrites remote history. Only use when necessary and coordinated with team.

### Dry Run (--dry-run)

**What it does:** Shows what would be pushed without actually pushing

```bash
git push --dry-run origin <current-branch>
```

Reports:

- Commits that would be pushed
- Remote branch status
- Any potential issues

## Expected Output

### Successful Push

```text
User: /push
Claude: Pushing changes to remote...

Repository Status:
  Current branch: feature/auth-improvements
  Remote: origin/feature/auth-improvements
  Commits ahead: 3

Running tests...
  All 127 tests passing
  Coverage: 94.2%

Pushing to origin/feature/auth-improvements...
  Push successful

Pushed 3 commits:
  - a1b2c3d feat(auth): add JWT refresh token
  - b2c3d4e fix(auth): handle expired tokens
  - c3d4e5f test(auth): add token expiry tests

Next steps:
  - Create PR: /pr main
  - Or continue development on this branch
```

### Pre-Push Hook Failure

```text
User: /push
Claude: Preparing to push...

Running tests...
  Tests passing

Executing push...
Pre-push hook failed:

  Hook: .git/hooks/pre-push
  Error: Branch protection check failed
    - Branch 'main' requires pull request
    - Direct pushes to 'main' are not allowed

Resolution:
  1. Push to feature branch instead:
     git checkout -b feature/my-changes
     /push

  2. Or create PR from current branch:
     /pr main
```

### Test Failure

```text
User: /push
Claude: Preparing to push...

Running tests...
Test failures detected:

  Failed Tests (2):
    - tests/auth.test.ts: Token refresh should handle network errors
    - tests/auth.test.ts: Expired tokens should redirect to login

Cannot push with failing tests

Fix these issues first:
  1. Run tests locally: npm test
  2. Fix failing tests
  3. Commit fixes: /commit
  4. Try push again: /push

Tip: Run `/review` to check for other issues
```

### Force Push Warning

```text
User: /push --force
Claude: Force Push Warning

This will rewrite remote history on: origin/feature/experiment

Are you sure? Force push can cause issues for collaborators.

Safe to force push because:
  - Not on main/master branch
  - Using --force-with-lease (won't overwrite others' work)

Risks:
  - Collaborators may have pulled old commits
  - Requires team coordination

Proceed with force push? (yes/no)
```

### Dry Run Output

```text
User: /push --dry-run
Claude: Dry run - showing what would be pushed...

Push Preview:
  From: feature/auth-improvements
  To: origin/feature/auth-improvements
  Status: Would push 3 new commits

Commits to push:
  a1b2c3d feat(auth): add JWT refresh token
  b2c3d4e fix(auth): handle expired tokens
  c3d4e5f test(auth): add token expiry tests

No issues detected
Pre-push hooks would pass
Safe to push

Run '/push' to execute actual push
```

## Validation Checks

### Pre-Push Validation

Automatic checks before pushing:

1. **Repository State**
   - Working tree clean or changes committed
   - Current branch identified
   - Remote tracking configured

2. **Test Execution** (if configured)
   - Detect test command (package.json, Makefile, etc.)
   - Run test suite
   - Verify all tests pass

3. **Branch Protection**
   - Check if pushing to protected branch
   - Validate branch naming conventions
   - Ensure proper workflow followed

### Pre-Push Hooks

Git's pre-push hooks run automatically:

- Linting validation
- Security scanning
- Build verification
- Custom validation scripts

**If hooks fail:** Report error, halt push, suggest fixes

## Error Handling

### Common Errors and Solutions

**Authentication Failed:**

```text
Authentication failed
Fix: Update git credentials or SSH key
  - SSH: Check ~/.ssh/ keys and GitHub settings
  - HTTPS: Run: git credential-cache exit
```

**Branch Diverged:**

```text
Branch diverged from remote
Fix: Pull and rebase before pushing
  - git pull --rebase origin <branch>
  - Resolve any conflicts
  - /push
```

**No Upstream Branch:**

```text
No upstream branch configured
Setting upstream: git push -u origin <branch>
Upstream configured, pushing...
```

**Protected Branch:**

```text
Cannot push to protected branch 'main'
Fix: Create feature branch and PR instead
  - git checkout -b feature/my-changes
  - /push
  - /pr main
```

## Test Command Detection

Automatically detects and runs tests:

```yaml
JavaScript/TypeScript:
  - package.json: npm test, npm run test
  - Look for test script in package.json

Python:
  - pytest, python -m pytest
  - Look for pytest.ini, pyproject.toml

Go:
  - go test ./...
  - Check for go.mod

Rust:
  - cargo test
  - Check for Cargo.toml

Generic:
  - Makefile: make test
  - test.sh script
```

If no test command detected, skip test phase and proceed to push.

## Safety Features

### Branch Protection

- Warns when pushing to main/master
- Suggests PR workflow instead
- Prevents accidental overwrites

### Force Push Safety

- Uses --force-with-lease instead of --force
- Prevents overwriting others' work
- Requires confirmation
- Blocks force push to main/master

### Pre-Push Hooks

- Always runs pre-push hooks (never --no-verify)
- Reports hook failures clearly
- Suggests fixes for common issues

## Notes

- Streamlined design focuses on push operation essentials
- Trusts git's pre-push hooks for validation
- Runs tests if configured, skips if not
- Fast execution: typically 10-30 seconds (depends on tests)
- CI/CD monitoring handled by CI system, not this command
- Reports errors clearly without auto-recovery complexity
- Safe defaults with --force-with-lease for force pushes
- Automatic upstream branch configuration when needed
- Clear next steps guidance after successful push
