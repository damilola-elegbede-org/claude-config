---
name: merge
description: Merge a branch into current branch with conflict handling. Use when merging branches.
argument-hint: "[source_branch] [--theirs|--ours|--abort]"
metadata:
  category: workflow
---

# /merge

## Usage

```bash
/merge           # Merge main (or master) into the current branch
/merge develop   # Merge a specific branch into current
/merge --theirs  # Auto-resolve conflicts favoring incoming changes
/merge --ours    # Auto-resolve conflicts favoring current branch
/merge --abort   # Abort an in-progress merge
```

## Description

Merges a source branch into the current branch: stash uncommitted work, fetch the source, merge,
restore the stash. Non-interactive (`--no-edit`).

Full sequence, conflict handler, and the situation table: → `references/workflow.md`

## Merge or rebase?

| Aspect    | `/merge`                 | `/rebase`               |
| --------- | ------------------------ | ----------------------- |
| History   | Preserves a merge commit | Linear                  |
| Conflicts | Resolve once             | Resolve per commit      |
| Use case  | Feature integration      | Updating a branch       |
| Undo      | Easy (revert the merge)  | Complex                 |

Merge for integrating feature branches, when the merge history matters, and on shared branches.
Rebase for pulling main into your own feature branch and for clean pre-PR history — personal branches
only, since it rewrites history.

## What matters most

- **`--theirs`/`--ours` discard the other side's conflicting hunks.** That's a content decision, not a
  formatting one; don't reach for them to make a merge finish quietly.
- **Stash includes untracked files** and is restored only if this run created it.
- **A failed `stash pop` is not a completed merge.** Report it and stop — the work is still in the stash.
- **"Already up to date" still needs the stash restored** before exiting.
- **Conflicts get captured to `.tmp/merge/`**, then hand back to the user with the file list. If a
  stash is outstanding, say so — that's the step people lose work to.
- `--abort` cleans up `.tmp/merge/` and points at any `Auto-stash before merge` entry it finds.

## Expected Output

```text
User: /merge

Stashing uncommitted changes...
Fetching latest main...
Merging main into feat/auth...
Merge complete: main → feat/auth
Restoring stashed changes...

Merge Summary:
a1b2c3d Merge branch 'main' into feat/auth
e4f5g6h feat: add login handler
```

On conflict, the file list plus `.tmp/merge/` paths, the outstanding-stash reminder, and
`--abort`. Already-merged reports "Already up to date with main" and still restores the stash.

## Related

`/rebase` · `/branch` · `/push` · `/pr`
