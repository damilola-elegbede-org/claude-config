# Rebase workflow

The canonical sequence. Direct execution — no agents.

## Conflict handler

Defined here, before the main sequence that calls it. Conflicted files are captured
programmatically so resolution is systematic rather than rediscovered by parsing `git status` — and
so nothing edits a file without knowing it's conflicted.

```bash
handle_conflicts() {
  TMP_DIR=".tmp/rebase"
  mkdir -p "$TMP_DIR"

  # --diff-filter=U targets exactly the unmerged (conflicted) files
  conflicted_files=$(git diff --name-only --diff-filter=U)

  if [ -z "$conflicted_files" ]; then
    echo "Rebase failed but no conflicts detected"
    echo "Run: git status"
    exit 1
  fi

  echo "$conflicted_files" > "${TMP_DIR}/conflicted_files.txt"
  conflict_count=$(echo "$conflicted_files" | wc -l | tr -d ' ')

  echo ""
  echo "Rebase conflicts in $conflict_count file(s):"
  echo "$conflicted_files" | while read -r file; do echo "  - $file"; done

  cat > "${TMP_DIR}/conflict_metadata.txt" <<EOF
Rebase Conflict Summary
=======================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Branch: $(git branch --show-current)
Target: $target_branch
Conflicted Files: $conflict_count

Files requiring resolution:
$conflicted_files

Conflict Details:
EOF

  echo "$conflicted_files" | while read -r file; do
    if [ -f "$file" ]; then
      {
        echo ""
        echo "=== $file ==="
        grep -n "^<<<<<<< \|^======= \|^>>>>>>> " "$file" | head -20
      } >> "${TMP_DIR}/conflict_metadata.txt" 2>/dev/null || true
    fi
  done

  cat <<MSG

Conflict data saved to: ${TMP_DIR}/
   - conflicted_files.txt (list of files)
   - conflict_metadata.txt (detailed conflict info)

Next steps:
  1. Open conflicting files and resolve conflicts (look for <<<<<<< markers)
  2. Stage resolved files: git add <file>
  3. Continue rebase: /rebase --continue

Or abort the rebase: /rebase --abort

MSG
  exit 1
}
```

## Main sequence

```bash
current_branch=$(git branch --show-current)

# Cannot rebase the base branch on itself
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  echo "Cannot rebase base branch on itself"
  exit 1
fi

# Resolve target branch: argument, else whichever default branch exists
if [ -z "$1" ]; then
  if git show-ref --verify --quiet refs/heads/main; then
    target_branch="main"
  elif git show-ref --verify --quiet refs/heads/master; then
    target_branch="master"
  else
    echo "Neither main nor master branch exists"
    exit 1
  fi
else
  target_branch="$1"
  if ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
    echo "Branch '$target_branch' does not exist"
    exit 1
  fi
fi

# Stash uncommitted work, untracked files included
stashed=false
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Stashing uncommitted changes..."
  git stash push -u -m "Auto-stash before rebase on $(date +%Y%m%d-%H%M%S)"
  stashed=true
fi

# Update the target, fast-forward only
echo "Updating $target_branch..."
git switch "$target_branch"
git pull --ff-only

# Rebase
echo "Rebasing $current_branch on $target_branch..."
git switch "$current_branch"
if git rebase "$target_branch"; then
  echo "Rebase complete: ${current_branch} → ${target_branch}"

  if [ "$stashed" = true ]; then
    echo "Restoring stashed changes..."
    if ! git stash pop; then
      cat <<'MSG'

WARNING: Stash restoration failed!
This usually means your stashed changes conflict with the rebased commits.

Next steps:
  1. Review conflicts: git status
  2. Resolve conflicts in affected files
  3. Stage resolved files: git add <file>
  4. Complete restoration: git stash drop (if conflicts resolved)
     OR manually reapply: git stash apply

MSG
      exit 1
    fi
  fi

  echo ""
  echo "Branch Status:"
  git log --oneline "$target_branch..$current_branch" | head -5
else
  handle_conflicts
fi
```

## `--continue` / `--abort`

- `--continue`: confirm conflicts are actually resolved, stage them, `git rebase --continue`, report.
- `--abort`: `git rebase --abort`, then restore the auto-stash if one was created, and say so.

## Cases to handle

| Situation            | Behavior                                                                 |
| -------------------- | ------------------------------------------------------------------------ |
| On main/master       | Refuse; suggest creating a feature branch first                          |
| Uncommitted changes  | Auto-stash with timestamped message, auto-restore after success          |
| Remote divergence    | Warn that the rebase rewrites history; suggest `push --force-with-lease` |
| Network failure      | Report it; offer retry or the manual git commands                        |
| Already up to date   | Report "already based on latest {target}" and show status                |
