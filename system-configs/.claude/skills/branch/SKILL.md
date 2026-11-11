---
name: branch
description: Create branches with intelligent naming patterns. Use when creating a new git branch.
argument-hint: "[description]"
metadata:
  category: workflow
  triggers:
    - 'cmd:\bgit\b(\s+-[A-Za-z]\s+\S+|\s+--\S+)*\s+(checkout\s+-[bB]\b|switch\s+(-c|--create)\b|worktree\s+add\b.*\s-[bB]\s)'
---

# /branch

## Usage

```bash
/branch user-dashboard     # → feature/user-dashboard
/branch JIRA-123           # → feature/jira-123
/branch fix-auth-bug       # → fix/auth-bug
/branch                    # no arguments: suggest a name from context
```

## Description

Creates a branch from the latest `main` with a prefix and name derived from the description, and switches
to it.

## Behavior

### Name

Always run `${HOME}/.claude/skills/commit/scripts/classify.sh branch "<description>"` before choosing the prefix
(it logs the Jev call even when it withholds the answer). Only when its `mode` is `enforce`, treat `type` as the
default prefix and, if `mixed` is true (uncommitted changes mix unrelated concerns), suggest committing them
separately first; otherwise ignore the output.

Otherwise pick the prefix from the description:

| Prefix         | When                                                           |
| -------------- | -------------------------------------------------------------- |
| `feature/`     | default; ticket ids (`JIRA-123`, `GH-456`); component names    |
| `fix/`         | "fix", "bug", "bugfix"; `BUG-` tickets                         |
| `hotfix/`      | "hotfix", "critical", "urgent"; production issues              |
| `enhancement/` | "improve", "optimize", "refactor", "cleanup"; performance work |
| `experiment/`  | "experiment", "poc", "prototype", "spike"                      |

Sanitize the rest: lowercase, spaces to hyphens, drop other special characters, trim leading and trailing
hyphens, at most 50 characters. A description that already carries a prefix (`chore/x`) keeps it. If the name
is taken, append a timestamp (`feature/user-dashboard-20250109-143052`) and confirm with the user first.

### Create

The branch must start from the latest remote `main`, so a failed fetch aborts instead of branching from a
stale base.

```bash
# Check current repository state
git status --porcelain

# Handle uncommitted changes if needed (-u includes untracked files)
stashed=false
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  # PID + random suffix: two runs in the same second must never share a tag (the stash is shared)
  tag="Auto-stash before branch creation $(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
  git stash push -u -m "$tag"
  stash_sha=$(git stash list --format='%H %gs' | grep -F "$tag" | head -1 | cut -d' ' -f1)
  stashed=true
fi

# Switch to main branch (with fallback to master)
git checkout main 2>/dev/null || git checkout master

# Pull latest changes with rebase to keep history clean (FAIL if unable)
git pull --rebase || { echo "ERROR: Cannot fetch latest main. Branch creation aborted."; exit 1; }

# Create and switch to new branch from updated main
git checkout -b <generated-branch-name>

# Restore only the stash this run created (the stash stack is shared across worktrees)
if [ "$stashed" = true ]; then
  git stash apply "$stash_sha" && echo "Restored stash $stash_sha; drop it by its stash@{n} once confirmed"
fi

# Confirm creation
git branch --show-current
```

In a worktree, `main` is usually checked out elsewhere and `git checkout main` fails. Branch from the remote
instead: `git fetch origin main`, then `git checkout -b <generated-branch-name> origin/main`. In a repository
that has `master` and no `main`, use `master` in both commands.

If the stash does not apply cleanly, stop and report the stash entry. On a network or permission failure,
report the error and stop; do not fall back to a local-only branch.

### No arguments

Read recent commits and uncommitted changes, propose branch names, and present them through
`AskUserQuestion`. Create the branch only after the user picks one.

## Expected Output

Illustrative; the name is an example.

```text
Created and switched to feature/user-dashboard (from origin/main)
```
