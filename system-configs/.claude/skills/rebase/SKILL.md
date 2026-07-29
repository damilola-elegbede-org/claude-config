---
name: rebase
description: Rebase current branch on latest main or specified branch. Use when updating branch with upstream changes.
argument-hint: "[target_branch] [--continue|--abort]"
metadata:
  category: workflow
---

# /rebase

## Usage

```bash
/rebase            # Rebase current branch on main (or master)
/rebase develop    # Rebase on a specific branch
/rebase --continue # Continue after resolving conflicts
/rebase --abort    # Abort and return to the pre-rebase state
```

## Description

Rebases the current branch on the latest target branch: stash uncommitted work, fast-forward the
target, rebase, restore the stash. Direct execution, no agents.

Full sequence, conflict handler, and the situation table: → `references/workflow.md`

## What matters most

- **Never rebase main/master on itself.** Check the current branch before anything else.
- **Stash includes untracked files** (`git stash push -u`) and is restored only if this run created
  it — popping someone else's stash is a data-loss bug.
- **`git pull --ff-only`** when updating the target. A merge commit created here silently changes what
  you're rebasing onto.
- **A failed `stash pop` is not a completed rebase.** Report it and stop; the changes are still in the
  stash and saying "done" loses them.
- **Conflicts get captured to `.tmp/rebase/`**, then hand back to the user with the file list. Don't
  resolve conflicts by guessing at intent.
- After a rebase, the branch's history is rewritten — subsequent push needs `--force-with-lease`.

## Expected Output

```text
User: /rebase

Stashing uncommitted changes...
Updating main...
main updated to latest
Rebasing feat/auth on main...
Rebase complete: feat/auth → main
Restoring stashed changes...

Branch Status:
a1b2c3d feat: add login handler
e4f5g6h test: cover token refresh
```

On conflict, the file list plus `.tmp/rebase/` paths and the `--continue` / `--abort` next steps.

## Related

`/branch` (new branch from updated main) · `/push` (push rebased branch) · `/pr` (open PR after)
