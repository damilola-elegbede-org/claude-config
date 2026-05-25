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
/rebase                  # Rebase current branch on main
/rebase develop          # Rebase on specific branch
/rebase --continue       # Continue after resolving conflicts
/rebase --abort          # Abort rebase operation
```

## Description

Safely rebases the current branch on the latest version of the target branch (default: main). Automatically stashes
uncommitted changes, updates the target branch, and rebases cleanly. Follows the same direct execution pattern as
/branch for speed and reliability.

## Expected Output

Direct execution workflow for efficient rebasing:

1. **Safety Check**: Verify repository state and stash uncommitted changes if needed
2. **Update Target**: Switch to target branch and pull latest changes with rebase
3. **Rebase Operation**: Switch back to feature branch and rebase on updated target
4. **Conflict Handling**: Provide clear guidance if conflicts occur

## Behavior

### Default Mode - Rebase on Main

Execute rebase with minimal overhead:

1. **Pre-Rebase Safety Checks**

   ```bash
   # Check current branch
   current_branch=$(git branch --show-current)

   # Verify not on main/master
   if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
     echo "Cannot rebase main branch on itself"
     exit 1
   fi

   # Check for uncommitted changes and stash if needed
   stashed=false
   if ! git diff --quiet || ! git diff --cached --quiet; then
     echo "Stashing uncommitted changes..."
     git stash push -u -m "Auto-stash before rebase on $(date +%Y%m%d-%H%M%S)"
     stashed=true
   fi
   ```

2. **Update Target Branch**

   ```bash
   # Determine target branch (default: main, with master fallback for user convenience)
   if [ -z "$1" ]; then
     # No argument provided, resolve which default branch exists
     if git show-ref --verify --quiet refs/heads/main; then
       target_branch="main"
     elif git show-ref --verify --quiet refs/heads/master; then
       target_branch="master"
     else
       echo "Neither main nor master branch exists"
       exit 1
     fi
   else
     # User specified a branch, verify it exists
     target_branch="$1"
     if ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
       echo "Branch '$target_branch' does not exist"
       exit 1
     fi
   fi

   echo "Updating $target_branch..."
   git switch "$target_branch"

   # Pull latest changes with fast-forward only for safety
   git pull --ff-only

   echo "$target_branch updated to latest"
   ```

3. **Rebase Feature Branch**

   ```bash
   # Switch back to feature branch
   echo "Rebasing $current_branch on $target_branch..."
   git switch "$current_branch"

   # Rebase on updated target
   if git rebase "$target_branch"; then
     echo "Rebase complete: ${current_branch} → ${target_branch}"

     # Restore stashed changes if any were created
     if [ "$stashed" = true ]; then
       echo "Restoring stashed changes..."
       if ! git stash pop; then
         echo ""
         echo "WARNING: Stash restoration failed!"
         echo "This usually means there are conflicts between your stashed changes and the rebased commits."
         echo ""
         echo "Next steps:"
         echo "  1. Review conflicts: git status"
         echo "  2. Resolve conflicts in affected files"
         echo "  3. Stage resolved files: git add <file>"
         echo "  4. Complete restoration: git stash drop (if conflicts resolved)"
         echo "     OR manually reapply: git stash apply"
         echo ""
         exit 1
       fi
     fi

     echo ""
     echo "Branch Status:"
     git log --oneline "$target_branch..$current_branch" | head -5
   else
     echo "Rebase conflicts detected"
     handle_conflicts
   fi
   ```

4. **Confirmation**
   - Display rebase status
   - Show commits on feature branch
   - Provide next steps guidance

### Conflict Handling Function

Define the conflict handler before it's called:

```bash
handle_conflicts() {
  # Create temp directory for conflict tracking
  TMP_DIR=".tmp/rebase"
  mkdir -p "$TMP_DIR"

  # Detect conflicted files programmatically
  conflicted_files=$(git diff --name-only --diff-filter=U)

  if [ -z "$conflicted_files" ]; then
    echo "Rebase failed but no conflicts detected"
    echo "Run: git status"
    exit 1
  fi

  # Store conflicted files list for potential agent deployment
  # This prevents blind parallel edits and provides a clear list for resolution
  echo "$conflicted_files" > "${TMP_DIR}/conflicted_files.txt"

  # Count conflicts
  conflict_count=$(echo "$conflicted_files" | wc -l | tr -d ' ')

  echo ""
  echo "Rebase conflicts in $conflict_count file(s):"
  echo "$conflicted_files" | while read -r file; do
    echo "  - $file"
  done

  # Store conflict metadata for documentation/resolution
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
  echo "  3. Continue rebase: /rebase --continue"
  echo ""
  echo "Or abort the rebase: /rebase --abort"
  echo ""

  exit 1
}
```

### Conflict File Capture Strategy

The conflict handling system captures conflicted files programmatically to enable systematic resolution:

```bash
# Identify conflicted files using Git's internal state
# --diff-filter=U specifically targets "unmerged" (conflicted) files
conflicted_files=$(git diff --name-only --diff-filter=U)

# Store in temporary file for agent deployment or manual review
echo "$conflicted_files" > "${TMP_DIR}/conflicted_files.txt"

# This approach prevents:
# - Blind parallel edits without conflict awareness
# - Manual file discovery via git status parsing
# - Losing track of which files need resolution

# Example usage for agent deployment:
# while read -r file; do
#   # Deploy editor agent per file with conflict context
#   echo "Resolving conflicts in: $file"
# done < "${TMP_DIR}/conflicted_files.txt"
```

### Continue Mode (--continue)

Resume rebase after resolving conflicts:

```bash
/rebase --continue
```

**What it does:**

1. Verify conflicts are resolved
2. Stage resolved files
3. Continue rebase operation
4. Report status

### Abort Mode (--abort)

Cancel rebase and return to pre-rebase state:

```bash
/rebase --abort
```

**What it does:**

1. Abort rebase operation
2. Return to original branch state
3. Restore stashed changes if any
4. Confirm cancellation

## Conflict Handling

When conflicts occur during rebase:

```yaml
Conflict Detection:
  - Identify conflicting files programmatically using git diff --diff-filter=U
  - Store conflict list in .tmp/rebase/conflicted_files.txt
  - Capture conflict metadata with line numbers and markers
  - Show conflict markers and provide resolution guidance

Conflict File Capture:
  Purpose: Enable systematic conflict resolution and prevent blind edits
  Method: |
    conflicted_files=$(git diff --name-only --diff-filter=U)
    echo "$conflicted_files" > .tmp/rebase/conflicted_files.txt
  Benefits:
    - Programmatic identification of conflicted files
    - Storage for agent deployment or manual review
    - Prevention of blind parallel edits
    - Clear tracking of resolution progress

User Guidance:
  1. List conflicting files with conflict count
  2. Save conflict data to .tmp/rebase/ directory
  3. Suggest: "Resolve conflicts in these files"
  4. Provide commands:
     - git status (see conflicts)
     - git diff (view conflicts)
     - /rebase --continue (after resolving)
     - /rebase --abort (to cancel)

Example Output:
  Rebase conflicts in 3 files:
    - src/auth/login.ts
    - src/api/routes.ts
    - tests/integration.test.ts

  Conflict data saved to: .tmp/rebase/
     - conflicted_files.txt (list of files)
     - conflict_metadata.txt (detailed conflict info)

  Next steps:
    1. Open conflicting files and resolve conflicts
    2. Stage resolved files: git add <file>
    3. Continue rebase: /rebase --continue

  Or abort: /rebase --abort
```

## Error Handling

Handle common scenarios gracefully:

```yaml
Already on Main:
  - Detect if current branch is main/master
  - Error: "Cannot rebase main on itself"
  - Suggest creating feature branch first

Uncommitted Changes:
  - Auto-stash with descriptive message
  - Include timestamp in stash message
  - Auto-restore after successful rebase

Remote Divergence:
  - Detect if branch was force-pushed
  - Warn about rewriting history
  - Suggest force push with lease after rebase

Network Issues:
  - Report connection problems
  - Suggest retry or offline rebase
  - Provide manual git commands

Already Rebased:
  - Detect if branch is already up to date
  - Report: "Branch already based on latest main"
  - Show current status
```

## Success Criteria

Simple and effective rebasing:

- Current branch rebased on latest target branch
- Uncommitted changes preserved (stashed and restored)
- Clear conflict guidance if needed
- Fast execution (5-10 seconds for clean rebase)
- Minimal overhead and complexity

## Advanced Usage

### Rebase on Specific Branch

```bash
/rebase develop
# Rebases current branch on develop instead of main
```

### Interactive Workflow

```bash
# Start rebase
/rebase

# If conflicts occur
# ... resolve conflicts manually ...
git add <resolved-files>

# Continue rebase
/rebase --continue

# Or abort if needed
/rebase --abort
```

## Command Philosophy

Transform branch rebasing from a multi-step manual process into a single, safe command. Focus on direct execution
following the /branch pattern for speed and reliability.

```yaml
Direct Execution Benefits:
  - Fast rebasing (5-10 seconds)
  - Safe handling of uncommitted changes
  - Clear conflict resolution guidance
  - Minimal system overhead
  - Predictable behavior

Key Safety Features:
  - Auto-stash uncommitted changes (including untracked files)
  - Verify not rebasing main on itself
  - Clean target branch update with fast-forward only
  - Clear error messages and guidance
  - Easy abort mechanism
  - Programmatic conflict file capture for systematic resolution
```

## Implementation Notes

### Git Operations Sequence

```bash
# Complete rebase workflow with all safety improvements
current_branch=$(git branch --show-current)

# Safety check - cannot rebase base branch on itself
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  echo "Cannot rebase base branch on itself"
  exit 1
fi

# Determine target branch with proper resolution
if [ -z "$1" ]; then
  # No argument provided, resolve which default branch exists
  if git show-ref --verify --quiet refs/heads/main; then
    target_branch="main"
  elif git show-ref --verify --quiet refs/heads/master; then
    target_branch="master"
  else
    echo "Neither main nor master branch exists"
    exit 1
  fi
else
  # User specified a branch
  target_branch="$1"
  if ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
    echo "Branch '$target_branch' does not exist"
    exit 1
  fi
fi

# Stash uncommitted changes including untracked files
stashed=false
if [[ -n "$(git status --porcelain)" ]]; then
  git stash push -u -m "Auto-stash before rebase on $(date +%Y%m%d-%H%M%S)"
  stashed=true
fi

# Update target branch with fast-forward only
git switch "$target_branch"
git pull --ff-only

# Rebase feature branch
git switch "$current_branch"
git rebase "$target_branch"

# Restore stash only if one was created
if [ "$stashed" = true ]; then
  git stash pop
fi
```

### Conflict Detection

```bash
# Check for conflicts
if ! git rebase "$target_branch"; then
  echo "Conflicts detected:"
  git diff --name-only --diff-filter=U | while read file; do
    echo "  - $file"
  done
  exit 1
fi
```

## Related Commands

- `/branch` - Create new branch from updated main
- `/push` - Push rebased branch to remote
- `/pr` - Create pull request after rebasing

## Notes

- Follows direct execution pattern like /branch
- No agents needed (Level 1 task)
- Preserves uncommitted changes safely
- Clear guidance for conflict resolution
- Fast and predictable execution
- Safe defaults with force-with-lease for subsequent push
- Programmatic conflict file capture enables systematic resolution
