---
name: pr
description: Create pull requests with smart title and description generation. Use when creating a PR.
argument-hint: "[target_branch] [--draft|--force]"
metadata:
  category: workflow
  triggers:
    - 'cmd:\bgh\b(\s+(-R|--repo)(=|\s+)\S+|\s+--\S+)*\s+pr\s+(create|new)\b'
---

# /pr

## Usage

```bash
/pr                     # Creates PR to main branch
/pr develop             # Creates PR targeting develop branch
/pr --draft             # Creates draft PR for work in progress
/pr --force             # Create PR even if one already exists
```

## Description

Opens a pull request from the current branch with a generated title and description, then hands it to `/land`.
Creating the PR is not the end of the task: CI and the review bots start once it opens, and the PR is done only
when `/land` reports it ready to merge or bounded out.

- `target_branch` (optional): base branch, default `main` (or `master` if the repo has no `main`)
- `--draft`: create as a draft
- `--force`: create a PR even if one already exists for this branch

## Behavior

```text
STEP 1: Check for existing PR
  RUN: gh pr view --json url 2>/dev/null
  IF: success AND NOT --force flag
    PARSE: url from output
    OUTPUT: "PR already exists: {url}"
    OUTPUT: "Use --force to create another PR"
    END (success)

STEP 2: Parse $ARGUMENTS
  PARSE: $ARGUMENTS for target_branch, --draft, --force flags
  IF: no target_branch given
    SET: target_branch = main (or master if the repo has no main)

STEP 2.5: Pre-PR Codex review
  INVOKE: /codex-review {target_branch}
    (skips itself when this exact diff already passed; a missing or signed-out codex CLI skips it
     with a warning)
  IF: it ends busy
    OUTPUT: "Not opening the PR: another Codex review is still running in this worktree. Re-run /pr when it finishes."
    END (failure)
  IF: it ends blocked
    OUTPUT: "Not opening the PR: Codex still reports P0/P1 findings (see above)."
    END (failure)
  Check the repository state, not what this run did: a cached pass applies no fixes, yet an
  earlier run may have left fixes uncommitted or committed but unpushed. Refuse before any
  push, so a partial fix set is never published.
  IF: `git status --porcelain -- ':!.tmp'` lists any change, untracked files included
      (a fix can add a new file, and leaving it out would publish a fix set that cannot work)
    OUTPUT: "Not opening the PR: there are uncommitted or untracked changes, so the PR would not include them. Commit them and re-run /pr."
    END (failure)
  IF: HEAD has commits its upstream lacks (or the branch has no upstream yet)
    RUN: /verify --report-only   (gates that passed before the fixes say nothing about them)
    IF: any gate failed
      OUTPUT: "Not opening the PR: {n} gate(s) fail on the unpushed commits: {names}."
      END (failure)
    INVOKE: /push   (the PR must include the fixes)

STEP 3: Analyze and create PR
  RUN: git diff {target_branch}...HEAD
  RUN: git log {target_branch}..HEAD
  GENERATE: title in conventional commit style, using the primary change type when commits are mixed
  GENERATE: description in the format below
  RUN: gh pr create --base {target_branch} --title "..." --body "..." [--draft]
  SET: pr_url = created PR URL

STEP 4: Post review acknowledgments
  READ: .tmp/coderabbit-ignored.json   (issues /codex-review or /resolve-comments chose not to fix)
  IF: file exists AND has ignored_issues
    VALIDATE: schema_version field exists in JSON
    SET: CURRENT_SCHEMA_VERSION = "1.0"
    SET: found_version = schema_version (or "missing" if field absent)
    SET: timestamp = $(date +%Y%m%d-%H%M%S)
    IF: schema_version is missing OR schema_version != CURRENT_SCHEMA_VERSION
      SET: backup_path = .tmp/coderabbit-ignored.backup-{timestamp}.json
      COPY: .tmp/coderabbit-ignored.json TO backup_path
      DELETE: .tmp/coderabbit-ignored.json
      OUTPUT: "⚠️ Schema version mismatch in coderabbit-ignored.json (found: {found_version}, expected: {CURRENT_SCHEMA_VERSION}). Backed up to {backup_path} and skipping acknowledgments."
      SKIP: to STEP 5
    RUN: git branch --show-current
    SET: current_branch = output
    VALIDATE: current_branch matches pattern ^[a-zA-Z0-9._/-]+$ (prevent path traversal)
    IF: validation fails
      OUTPUT: "Invalid branch name format, skipping acknowledgments"
      SKIP: to STEP 5
    VALIDATE: branch field in JSON matches current_branch
    IF: matches
      BUILD: comment from ignored_issues grouped by category:
        ## Review Issue Acknowledgments

        The following issues were reviewed locally and intentionally not addressed:

        ### {category}
        | Location | Issue | Reason |
        |----------|-------|--------|
        | {foreach issue in category} |

        ---
        @coderabbitai These issues were reviewed during local development. No action needed.

      RUN: gh pr comment {pr_url} --body "{comment}"
      DELETE: .tmp/coderabbit-ignored.json
      OUTPUT: "Posted acknowledgment for {count} skipped issues"

STEP 5: Report creation, then land it
  OUTPUT: "Pull request created: {pr_url}"
  INVOKE: /land {pr_url}
  NOTE: creating the PR is not the end of the task. CI and the review bots start now, and the PR
        is done only when /land reports it ready to merge or bounded out.
  END
```

The `pr-landing-gate` hook blocks the session from ending while a PR it opened is not mergeable.

### Description format

```markdown
## Summary
[1-2 sentence overview of the changes]

## Changes
- [Key change]

## Context
[Why these changes were made]

## Testing
[What was tested, or which tests were added]

## Related Issues
Closes #123 (if applicable; flag breaking changes here too)
```

## Expected Output

Illustrative; the URL and counts are examples.

```text
Pull request created: https://github.com/owner/repo/pull/123
Posted acknowledgment for 2 skipped issues
```

When a PR already exists and `--force` is not set:

```text
PR already exists: https://github.com/owner/repo/pull/123
Use --force to create another PR
```
