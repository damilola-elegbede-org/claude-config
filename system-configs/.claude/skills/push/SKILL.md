---
name: push
description: Push changes to remote repository with validation. Use when pushing committed changes.
argument-hint: "[--force|--dry-run]"
metadata:
  category: workflow
  triggers:
    - 'cmd:\bgit\b(\s+-[A-Za-z]\s+\S+|\s+--\S+)*\s+push\b'
---

# /push

## Usage

```bash
/push                   # Push current branch to remote
/push --force           # Force push with lease (feature branches only)
/push --dry-run         # Preview what would be pushed
```

## Description

Safely pushes the current branch to its remote: runs the project's tests when it has them, pushes, and reports
what went up.

This command does not use `--no-verify`: pre-push hooks are the last check before code reaches the remote, so
a failing hook gets fixed, not bypassed.

## Behavior

### Default mode

1. **Check the state.**

   ```bash
   git status
   git branch --show-current
   git rev-list @{u}.. # commits ahead of remote
   ```

   Never push to `main` or `master`. On one of those, stop and move the work to a feature branch, then open a
   pull request with `/pr`.

2. **Run the tests, if the project has a test command.** A push with failing tests is refused: report the
   failures, fix them, commit with `/commit`, and push again. With no test command, skip this step and say so.

   | Project marker                      | Command         |
   | ----------------------------------- | --------------- |
   | `package.json` with a `test` script | `npm test`      |
   | `pytest.ini` or `pyproject.toml`    | `pytest`        |
   | `go.mod`                            | `go test ./...` |
   | `Cargo.toml`                        | `cargo test`    |
   | `Makefile` with a `test` target     | `make test`     |
   | `test.sh`                           | `./test.sh`     |

3. **Push.**

   ```bash
   git push origin <current-branch>      # add -u when the branch has no upstream yet
   ```

   Pre-push hooks run as part of this. If one fails, report its output, stop, and fix the cause.

4. **Report** the remote branch and the commits pushed.

### Force push (`--force`)

A force push rewrites remote history, so it is limited to feature branches and always uses the lease form,
which refuses to overwrite commits someone else pushed:

```bash
git push --force-with-lease origin <current-branch>
```

Refuse on `main` or `master`. Confirm through `AskUserQuestion` before pushing.

### Dry run (`--dry-run`)

`git push --dry-run origin <current-branch>`, then report the commits that would be pushed and the remote
branch's state. Nothing is pushed.

### Errors

- **Authentication failed:** report it; the fix is the user's SSH key or git credentials.
- **Branch diverged from remote:** `git pull --rebase origin <branch>`, resolve conflicts, push again.
- **Protected branch:** push a feature branch and open a pull request with `/pr` instead.

## Expected Output

Illustrative; the branch, counts and hashes are examples.

```text
Branch: feature/auth-improvements (3 commits ahead)
Tests: 127 passing
Pushed to origin/feature/auth-improvements:
  a1b2c3d feat(auth): add JWT refresh token
  b2c3d4e fix(auth): handle expired tokens
  c3d4e5f test(auth): add token expiry tests
```
