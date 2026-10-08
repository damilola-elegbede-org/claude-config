---
name: ship-it
description: Orchestrate development workflows with composable flags. Use when shipping code through docs, test, commit, review, push, and PR stages.
argument-hint: "[-d] [-t] [-v] [-c] [-r] [-x] [-p] [-pr] [--dry-run]"
metadata:
  category: orchestration
---

# /ship-it

## Usage

```bash
/ship-it                    # Full: docs → test → review → codex-review → commit-push-pr
/ship-it -c -p              # Quick: delegate commit+push to commit-commands:commit-push-pr (no PR)
/ship-it -t -c -p           # Test first, then commit+push
/ship-it -r -c -p           # Review gate, then commit+push
/ship-it -x -c -p           # Local Codex review loop, then commit+push
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

| Flag               | What it enables                                                                                                                 |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `-d`               | Run `/docs` first                                                                                                               |
| `-t`               | Run `/test` first                                                                                                               |
| `-v`               | Run `/verify` first (gates must be green to proceed)                                                                            |
| `-r`               | Run `/review` first                                                                                                             |
| `-x`               | Run `/codex-review` first (also runs automatically whenever `-pr` is set)                                                      |
| `-c -p -pr`        | Commit + push + PR (delegated to `commit-commands:commit-push-pr`)                                                              |
| `-c -p` (no `-pr`) | Commit + push only (`commit-commands:commit-push-pr` without the PR step is not available, so fall back to `/commit` + `/push`) |
| `-c` alone         | Run `/commit` only                                                                                                              |
| `-p` alone         | Run `/push` only                                                                                                                |
| `-pr` alone        | Create PR via `/pr` (preserves `--draft`, CodeRabbit acknowledgment)                                                            |
| Other combinations | Any other partial combination (e.g., `-c -pr` without `-p`) is rejected with an error.                                          |
| `--dry-run`        | Print the plan, don't execute                                                                                                   |

## Execution

Parse flags from `$ARGUMENTS`. With no flags, enable every step.

Run enabled steps in this fixed order; halt immediately on failure.

**Pre-commit gate.** Before any step that commits, pushes, or opens a PR, the project's gates
must have been run in this invocation. Only `-v` satisfies that: `/test` runs the test suite but
not lint, typecheck, or build, and `/review` reads code and runs no gates at all. A green `-t`
with a red typecheck is exactly the state this gate exists to catch.

```text
IF: any of -c / -p / -pr is set AND -v did not run and pass
  RUN: /verify --report-only
  IF: any gate failed
    OUTPUT: "Refusing to ship with N failing gate(s): {names}. Fix them and re-run."
    HALT
  IF: no gates detected
    OUTPUT: "No verification gates detected — shipping unchecked."
    CONTINUE (this is a warning, not a failure; a project with no gates is allowed to exist)
```

**What this gate is, honestly.** It is a convention this skill follows, not a control that
enforces itself. Nothing stops an agent from calling `/commit` directly and skipping it entirely —
bare `/commit` carries no gate of its own. Treat it as the default path being the safe one, not as
a guarantee. Making it a guarantee needs a `PreToolUse` hook on `git commit` that checks for a
fresh verify result; that is a larger change than this skill.

There is deliberately no bypass flag. `/commit` and `/push` already carry a standing rule against
skipping hooks, and a settings hook blocks that string in any bash command outright, so a skip
flag here would reopen the hole those guards close — and documenting it would put the blocked
string into the example output. To ship a red branch, fix the gate or run `/push` directly and own
that choice.

1. **`-d`**: Invoke `/docs`. Skip if no doc-relevant changes detected.
2. **`-t`**: Invoke `/test`.
3. **`-v`**: Invoke `/verify`. Halt if it ends with gates still failing.
4. **`-r`**: Invoke `/review`. If issues found, hand off to `/resolve-comments` per its own flow.
5. **`-x`, or `-pr` set**: Invoke `/codex-review {target_branch}`. Codex reviews every PR on
   GitHub, so any path that opens a PR runs the same reviewer locally first and fixes its findings
   while the branch is still local. Halt if it ends `blocked`; a `skipped` result (no CLI, not
   signed in) is a warning and the ship continues. If it changed any file, run
   `/verify --report-only` again after it and halt on any failing gate, whether verification ran
   through `-v` or through the pre-commit gate. Gates that passed before the fixes say nothing about
   the code being shipped. If tracked changes remain uncommitted after it
   (`git status --porcelain --untracked-files=no`) and `-c` is not set, halt: `/push` would
   publish the code without the fixes that verification just checked.
   **Skip this step when step 6 will take the `-pr`-only path** (`/pr` without `-c`/`-p`): `/pr`
   runs `/codex-review` itself and then pushes committed fixes or refuses uncommitted ones. Running
   it here first would cache the diff as passed, `/pr`'s run would skip, and those safeguards
   would never fire, so the PR could open without the fixes.
6. **Commit + push + PR** (after any of -d/-t/-v/-r/-x have run): pick the right path
   based on which of `-c`, `-p`, `-pr` are set (in the no-flag default, all
   three are set, so this step runs `commit-commands:commit-push-pr`):
   - All three of `-c -p -pr` set (including the no-flag default):
     - **Check** that `commit-commands:commit-push-pr` is available (the
       Anthropic-published `commit-commands` plugin installs it).
     - **If `/codex-review` recorded skipped findings this run** (records with
       `"source": "codex"` in `.tmp/coderabbit-ignored.json`): skip the plugin and
       invoke our `/commit` → `/push` → `/pr`, because only `/pr` posts those
       acknowledgments to the PR.
     - **If available:** one tool call to `commit-commands:commit-push-pr`.
       No TaskCreate ceremony, no orchestration.
     - **If not available:** output `commit-commands:commit-push-pr not
       installed, falling back to local skills` and invoke our `/commit` →
       `/push` → `/pr` in sequence.
   - `-c -p` without `-pr`: `commit-commands:commit-push-pr` always creates a
     PR, so for "commit + push only" invoke our `/commit` followed by `/push`.
   - `-pr` alone or alongside only `-d`/`-t`/`-r`/`-x` (not `-c`/`-p`): invoke our
     `/pr` so the CodeRabbit comment integration (via
     `.tmp/coderabbit-ignored.json`) and flags like `--draft` work.
   - `-c` alone: invoke our `/commit`.
   - `-p` alone: invoke our `/push`.
   - Other partial combinations (e.g., `-c -pr` without `-p`): reject with a
     clear error before doing any work.

Why delegate to `commit-commands:commit-push-pr` for the common case: it does
status + commit + push + `gh pr create` in a single message with parallel tool
calls (its frontmatter pre-injects `git status`, `git diff HEAD`, and the
current branch — no extra round-trips).

## Dry-run

When `--dry-run` is set, print the enabled steps and which path will run for
the commit/push/pr triplet. Don't execute anything.

## Expected Output

```text
🚀 ship-it: docs → test → review → codex-review → commit-push-pr

📋 /docs
  ✅ done

📋 /test
  ✅ done

📋 /review
  ✅ done

📋 /codex-review
  ✅ clean (round 2)

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
