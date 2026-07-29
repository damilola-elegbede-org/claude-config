# Merge workflow

Direct execution — no agents.

## Argument parsing, safety, stash

```bash
strategy=""
source_arg=""
for arg in "$@"; do
  case "$arg" in
    --theirs) strategy="theirs" ;;
    --ours)   strategy="ours" ;;
    --abort)
      if [ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
        echo "No merge in progress to abort"
        exit 0
      fi
      git merge --abort
      echo "Merge aborted"
      rm -rf .tmp/merge 2>/dev/null || true
      if git stash list | grep -q "Auto-stash before merge"; then
        echo ""
        echo "Note: You may have stashed changes from a previous merge attempt."
        echo "   Check with: git stash list"
        echo "   Restore with: git stash pop"
      fi
      exit 0
      ;;
    *) source_arg="$arg" ;;
  esac
done

current_branch=$(git branch --show-current)

stashed=false
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Stashing uncommitted changes..."
  git stash push -u -m "Auto-stash before merge on $(date +%Y%m%d-%H%M%S)"
  stashed=true
fi
```

## Fetch and merge

```bash
# Resolve source branch: argument, else whichever default branch exists
if [ -z "$source_arg" ]; then
  if git show-ref --verify --quiet refs/heads/main; then
    source_branch="main"
  elif git show-ref --verify --quiet refs/heads/master; then
    source_branch="master"
  else
    echo "Neither main nor master branch exists"
    exit 1
  fi
else
  source_branch="$source_arg"
  if ! git show-ref --verify --quiet "refs/heads/$source_branch"; then
    echo "Branch '$source_branch' does not exist"
    exit 1
  fi
fi

echo "Fetching latest $source_branch..."
git fetch origin "$source_branch" 2>/dev/null || true

echo "Merging $source_branch into $current_branch..."
merge_cmd="git merge $source_branch --no-edit"
if [ -n "${strategy:-}" ]; then
  merge_cmd="git merge $source_branch -X $strategy --no-edit"
fi

merge_output=$(eval "$merge_cmd" 2>&1) && merge_status=0 || merge_status=$?

# "Already up to date" is success with nothing to do — still restore the stash
if echo "$merge_output" | grep -qi "already up to date"; then
  echo "Already up to date with $source_branch"
  echo ""
  echo "Current status:"
  git log --oneline -3
  if [ "$stashed" = true ]; then
    echo ""
    echo "Restoring stashed changes..."
    git stash pop
  fi
  exit 0
fi

if [ "$merge_status" -eq 0 ]; then
  echo "Merge complete: ${source_branch} → ${current_branch}"

  if [ "$stashed" = true ]; then
    echo "Restoring stashed changes..."
    if ! git stash pop; then
      cat <<'MSG'

WARNING: Stash restoration failed!
Conflicts between stashed changes and merged commits.

Next steps:
  1. Review conflicts: git status
  2. Resolve conflicts in affected files
  3. Stage resolved files: git add <file>
  4. Complete restoration: git stash drop
MSG
      exit 1
    fi
  fi

  echo ""
  echo "Merge Summary:"
  git log --oneline -5
else
  echo "Merge conflicts detected"
  handle_conflicts
fi
```

## Conflict handler

Define before it's called.

```bash
handle_conflicts() {
  TMP_DIR=".tmp/merge"
  mkdir -p "$TMP_DIR"

  conflicted_files=$(git diff --name-only --diff-filter=U)

  if [ -z "$conflicted_files" ]; then
    echo "Merge failed but no conflicts detected"
    echo "Run: git status"
    exit 1
  fi

  echo "$conflicted_files" > "${TMP_DIR}/conflicted_files.txt"
  conflict_count=$(echo "$conflicted_files" | wc -l | tr -d ' ')

  echo ""
  echo "Merge conflicts in $conflict_count file(s):"
  echo "$conflicted_files" | while read -r file; do echo "  - $file"; done

  cat > "${TMP_DIR}/conflict_metadata.txt" <<EOF
Merge Conflict Summary
======================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Current Branch: $(git branch --show-current)
Source Branch: $source_branch
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
  3. Complete merge: git commit

MSG
  if [ "$stashed" = true ]; then
    echo "Note: Your uncommitted changes are stashed."
    echo "   After resolving conflicts and completing the merge, run: git stash pop"
    echo ""
  fi
  echo "Or abort the merge: /merge --abort"
  echo ""
  exit 1
}
```

## Cases to handle

| Situation           | Behavior                                                              |
| ------------------- | --------------------------------------------------------------------- |
| Branch not found    | Report the name; suggest fetching from remote or checking the spelling |
| Uncommitted changes | Auto-stash with timestamped message, auto-restore after success        |
| Already up to date  | Report it, show status, restore the stash, exit 0                      |
| Network failure     | Fetch failure is non-fatal — continue on local state, warn it may be stale |
