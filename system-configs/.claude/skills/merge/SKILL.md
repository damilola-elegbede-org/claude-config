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
/merge                   # Merge main into current branch (default)
/merge develop           # Merge specific branch into current
/merge --theirs          # Auto-resolve conflicts favoring incoming
/merge --ours            # Auto-resolve conflicts favoring current
/merge --abort           # Abort in-progress merge
```

## Description

Safely merges a source branch into the current branch (default: main). Automatically stashes uncommitted changes,
fetches the latest from remote, and merges cleanly. Follows the same direct execution pattern as /rebase for speed
and reliability.

## Expected Output

Direct execution workflow for efficient merging:

1. **Safety Check**: Verify repository state and stash uncommitted changes if needed
2. **Update Source**: Fetch latest changes for the source branch
3. **Merge Operation**: Merge source branch into current branch
4. **Conflict Handling**: Provide clear guidance if conflicts occur

## Behavior

### Default Mode - Merge Main into Current

Execute merge with minimal overhead:

1. **Pre-Merge Safety Checks**

   ```bash
   # Parse arguments for strategy flags
   strategy=""
   source_arg=""
   for arg in "$@"; do
     case "$arg" in
       --theirs) strategy="theirs" ;;
       --ours) strategy="ours" ;;
       --abort)
        # Check if merge is in progress
        if [ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
          echo "No merge in progress to abort"
          exit 0
        fi
        git merge --abort
        echo "Merge aborted"
        # Clean up conflict tracking directory
        rm -rf .tmp/merge 2>/dev/null || true
        # Check for merge-related stash
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

   # Check current branch
   current_branch=$(git branch --show-current)

   # Check for uncommitted changes and stash if needed
   stashed=false
   if ! git diff --quiet || ! git diff --cached --quiet; then
     echo "Stashing uncommitted changes..."
     git stash push -u -m "Auto-stash before merge on $(date +%Y%m%d-%H%M%S)"
     stashed=true
   fi
   ```

2. **Fetch and Merge**

   ```bash
   # Determine source branch (default: main, with master fallback)
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

   # Fetch latest for source branch
   echo "Fetching latest $source_branch..."
   git fetch origin "$source_branch" 2>/dev/null || true

   # Merge source into current
   echo "Merging $source_branch into $current_branch..."

   # Build merge command with optional strategy
   merge_cmd="git merge $source_branch --no-edit"
   if [ -n "${strategy:-}" ]; then
     merge_cmd="git merge $source_branch -X $strategy --no-edit"
   fi

   # Capture merge output to detect "already up to date"
   merge_output=$(eval "$merge_cmd" 2>&1) && merge_status=0 || merge_status=$?

   # Check for "already up to date" (successful but no-op)
   if echo "$merge_output" | grep -qi "already up to date"; then
     echo "Already up to date with $source_branch"
     echo ""
     echo "Current status:"
     git log --oneline -3

     # Restore stash even if no merge was needed
     if [ "$stashed" = true ]; then
       echo ""
       echo "Restoring stashed changes..."
       git stash pop
     fi
     exit 0
   fi

   if [ "$merge_status" -eq 0 ]; then
     echo "Merge complete: ${source_branch} → ${current_branch}"

     # Restore stashed changes if any were created
     if [ "$stashed" = true ]; then
       echo "Restoring stashed changes..."
       if ! git stash pop; then
         echo ""
         echo "WARNING: Stash restoration failed!"
         echo "Conflicts between stashed changes and merged commits."
         echo ""
         echo "Next steps:"
         echo "  1. Review conflicts: git status"
         echo "  2. Resolve conflicts in affected files"
         echo "  3. Stage resolved files: git add <file>"
         echo "  4. Complete restoration: git stash drop"
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

3. **Confirmation**
   - Display merge status
   - Show recent commits
   - Provide next steps guidance

### Conflict Handling Function

Define the conflict handler before it's called:

```bash
handle_conflicts() {
  # Create temp directory for conflict tracking
  TMP_DIR=".tmp/merge"
  mkdir -p "$TMP_DIR"

  # Detect conflicted files programmatically
  conflicted_files=$(git diff --name-only --diff-filter=U)

  if [ -z "$conflicted_files" ]; then
    echo "Merge failed but no conflicts detected"
    echo "Run: git status"
    exit 1
  fi

  # Store conflicted files list
  echo "$conflicted_files" > "${TMP_DIR}/conflicted_files.txt"

  # Count conflicts
  conflict_count=$(echo "$conflicted_files" | wc -l | tr -d ' ')

  echo ""
  echo "Merge conflicts in $conflict_count file(s):"
  echo "$conflicted_files" | while read -r file; do
    echo "  - $file"
  done

  # Store conflict metadata
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

  # Append conflict details for each file
  echo "$conflicted_files" | while read -r file; do
    if [ -f "$file" ]; then
      echo "" >> "${TMP_DIR}/conflict_metadata.txt"
      echo "=== $file ===" >> "${TMP_DIR}/conflict_metadata.txt"
      grep -n "^<<<<<<< \|^======= \|^>>>>>>> " "$file" | head -20 >> "${TMP_DIR}/conflict_metadata.txt" 2>/dev/null || true
    fi
  done

  echo ""
  echo "Conflict data saved to: ${TMP_DIR}/"
  echo "   - conflicted_files.txt (list of files)"
  echo "   - conflict_metadata.txt (detailed conflict info)"
  echo ""
  echo "Next steps:"
  echo "  1. Open conflicting files and resolve conflicts (look for <<<<<<< markers)"
  echo "  2. Stage resolved files: git add <file>"
  echo "  3. Complete merge: git commit"
  echo ""
  # Remind about stashed changes if any
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

### Strategy Mode (--theirs / --ours)

Auto-resolve conflicts with a merge strategy:

```bash
/merge --theirs develop
# Merge develop, preferring incoming changes on conflict

/merge --ours develop
# Merge develop, preferring current branch changes on conflict
```

**Implementation:**

```bash
if [ "$strategy" = "theirs" ]; then
  git merge "$source_branch" -X theirs --no-edit
elif [ "$strategy" = "ours" ]; then
  git merge "$source_branch" -X ours --no-edit
fi
```

### Abort Mode (--abort)

Cancel merge and return to pre-merge state:

```bash
/merge --abort
```

**What it does:**

1. Abort merge operation
2. Return to original branch state
3. Check for merge-related stashed changes and remind user
4. Clean up .tmp/merge/ directory
5. Confirm cancellation

**Note:** The `--abort` flag checks for stashes created by `/merge` (matching "Auto-stash before merge") and reminds you to restore them if found.

## Conflict Handling

When conflicts occur during merge:

```yaml
Conflict Detection:
  - Identify conflicting files using git diff --diff-filter=U
  - Store conflict list in .tmp/merge/conflicted_files.txt
  - Capture conflict metadata with line numbers
  - Show conflict markers and provide resolution guidance

User Guidance:
  1. List conflicting files with conflict count
  2. Save conflict data to .tmp/merge/ directory
  3. Suggest: "Resolve conflicts in these files"
  4. Provide commands:
     - git status (see conflicts)
     - git diff (view conflicts)
     - git add <file> (stage resolved)
     - git commit (complete merge)
     - /merge --abort (to cancel)

Example Output:
  Merge conflicts in 3 files:
    - src/auth/login.ts
    - src/api/routes.ts
    - tests/integration.test.ts

  Conflict data saved to: .tmp/merge/
     - conflicted_files.txt (list of files)
     - conflict_metadata.txt (detailed conflict info)

  Next steps:
    1. Open conflicting files and resolve conflicts
    2. Stage resolved files: git add <file>
    3. Complete merge: git commit

  Or abort: /merge --abort
```

## Error Handling

Handle common scenarios gracefully:

```yaml
Branch Not Found:
  - Verify branch exists locally or remotely
  - Error: "Branch 'xyz' does not exist"
  - Suggest fetching from remote or checking name

Uncommitted Changes:
  - Auto-stash with descriptive message
  - Include timestamp in stash message
  - Auto-restore after successful merge

Already Up to Date:
  - Detect if already merged
  - Report: "Already up to date with $source_branch"
  - Show current status

Network Issues:
  - Report connection problems on fetch
  - Continue with local state
  - Warn if local may be outdated
```

## Merge vs Rebase

| Aspect | /merge | /rebase |
|--------|--------|---------|
| History | Preserves merge commit | Linear history |
| Conflicts | Resolve once | Resolve per commit |
| Use case | Feature integration | Branch updates |
| Undo | Easy (revert merge commit) | Complex |

**When to use /merge:**

- Integrating feature branches
- When merge history is important
- For shared branches

**When to use /rebase:**

- Updating feature branch with main
- Before PR for clean history
- Personal branches only

## Success Criteria

Simple and effective merging:

- Source branch merged into current branch
- Uncommitted changes preserved (stashed and restored)
- Clear conflict guidance if needed
- Fast execution (5-10 seconds for clean merge)
- Minimal overhead and complexity

## Related Commands

- `/rebase` - Rebase current branch on another branch
- `/branch` - Create new branch from updated main
- `/push` - Push merged branch to remote
- `/pr` - Create pull request

## Notes

- Follows direct execution pattern like /rebase and /branch
- No agents needed (Level 1 task)
- Preserves uncommitted changes safely
- Clear guidance for conflict resolution
- Fast and predictable execution
- Uses --no-edit for non-interactive merge commits
