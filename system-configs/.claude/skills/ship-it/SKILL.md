---
name: ship-it
description: Orchestrate development workflows with composable flags. Use when shipping code through docs, test, commit, review, push, and PR stages.
argument-hint: "[-d] [-t] [-c] [-r] [-p] [-pr] [--dry-run]"
metadata:
  category: orchestration
---

# /ship-it

## Usage

```bash
/ship-it                    # Full: docs → test → review → commit-push-pr
/ship-it -c -p              # Quick: delegate commit+push to commit-commands:commit-push-pr (no PR)
/ship-it -t -c -p           # Test first, then commit+push
/ship-it -r -c -p           # Review gate, then commit+push
/ship-it -d -t -c -r -p     # Everything except PR
/ship-it -pr                # Just create PR (uses /pr for CodeRabbit acknowledgment if present)
/ship-it --dry-run          # Preview without executing
```

## Description

A thin orchestrator that runs heavy optional steps (docs, test, review) and
then delegates the commit/push/pr triplet to the Anthropic-published
`commit-commands:commit-push-pr` skill — a 21-line skill that does all three
git operations in a single tool message. That's the lean common path.

When a step needs features specific to our skills (e.g., the CodeRabbit
PR-comment integration in `/pr`, or `--dry-run` in `/push`), `/ship-it` falls
back to invoking our own skill instead.

## Flags

| Flag | What it enables |
|------|-----------------|
| `-d` | Run `/docs` first |
| `-t` | Run `/test` first |
| `-r` | Run `/review` first |
| `-c -p -pr` | Commit + push + PR (delegated to `commit-commands:commit-push-pr`) |
| `-c -p` (no `-pr`) | Commit + push only (`commit-commands:commit-push-pr` without the PR step is not available, so fall back to `/commit` + `/push`) |
| `-c` alone | Run `/commit` only |
| `-p` alone | Run `/push` only |
| `-pr` alone | Create PR via `/pr` (preserves `--draft`, CodeRabbit acknowledgment) |
| Other combinations | Any other partial combination (e.g., `-c -pr` without `-p`) is rejected with an error. |
| `--dry-run` | Print the plan, don't execute |

## Execution

Parse flags from `$ARGUMENTS`. With no flags, enable every step.

Run enabled steps in this fixed order; halt immediately on failure:

1. **`-d`**: Invoke `/docs`. Skip if no doc-relevant changes detected.
2. **`-t`**: Invoke `/test`.
3. **`-r`**: Invoke `/review`. If issues found, hand off to `/resolve-comments` per its own flow.
4. **Commit + push + PR** (after any of -d/-t/-r have run): pick the right path
   based on which of `-c`, `-p`, `-pr` are set (in the no-flag default, all
   three are set, so this step runs `commit-commands:commit-push-pr`):
   - All three of `-c -p -pr` set (including the no-flag default):
     - **Check** that `commit-commands:commit-push-pr` is available (the
       Anthropic-published `commit-commands` plugin installs it).
     - **If available:** one tool call to `commit-commands:commit-push-pr`.
       No TaskCreate ceremony, no orchestration.
     - **If not available:** output `commit-commands:commit-push-pr not
       installed, falling back to local skills` and invoke our `/commit` →
       `/push` → `/pr` in sequence.
   - `-c -p` without `-pr`: `commit-commands:commit-push-pr` always creates a
     PR, so for "commit + push only" invoke our `/commit` followed by `/push`.
   - `-pr` alone or alongside only `-d`/`-t`/`-r` (not `-c`/`-p`): invoke our
     `/pr` so the CodeRabbit comment integration (via
     `.tmp/coderabbit-ignored.json`) and flags like `--draft` work.
   - `-c` alone: invoke our `/commit`.
   - `-p` alone: invoke our `/push`.
   - Other partial combinations (e.g., `-c -pr` without `-p`): reject with a
     clear error before doing any work.

Why delegate to `commit-commands:commit-push-pr` for the common case: it does
status + commit + push + `gh pr create` in a single message with parallel tool
calls (its frontmatter pre-injects `git status`, `git diff HEAD`, and the
current branch — no extra round-trips). For routine ship-it invocations, that
beats our previous chain of TaskCreate ceremony + 3 sequential sub-skills.

## Dry-run

When `--dry-run` is set, print the enabled steps and which path will run for
the commit/push/pr triplet. Don't execute anything.

## Expected Output

```text
🚀 ship-it: docs → test → review → commit-push-pr

📋 /docs
  ✅ done

📋 /test
  ✅ done

📋 /review
  ✅ done

📋 commit-commands:commit-push-pr
  ✅ commit + push + PR
  PR: https://github.com/org/repo/pull/123
```

## Notes

- Halts immediately on any step failure.
- `commit-commands:commit-push-pr` is published by Anthropic in the
  `commit-commands` plugin. If it isn't installed, fall back to our `/commit` +
  `/push` + `/pr` chain.
- `/pr` retains its CodeRabbit-acknowledgment behavior — `/ship-it -pr` (or any
  path that uses our `/pr`) will post the `.tmp/coderabbit-ignored.json` summary
  to the PR.
- Each invoked command handles its own validation (main/master checks, existing PR, etc.).
