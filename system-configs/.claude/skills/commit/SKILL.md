---
name: commit
description: Create git commits with intelligent message generation. Use when changes are ready to commit.
argument-hint: "[--amend]"
metadata:
  category: workflow
  triggers:
    - 'cmd:\bgit\b(\s+-[A-Za-z]\s+\S+|\s+--\S+)*\s+commit\b'
---

# /commit

## Usage

```bash
/commit                         # Analyze changes and create commit
/commit --amend                 # Amend last commit with staged changes
```

## Description

Creates a git commit with a generated message in conventional commit format that matches the repository's
existing style.

This command does not use `--no-verify`: hooks are the project's quality gates, so a failing hook is reported
and fixed, not bypassed.

## Behavior

### Default mode

1. **Read the changes.** `git status`, `git diff --cached`, `git diff HEAD`, and `git log --oneline -10` for the
   repository's message style.
2. **Keep the commit clean.** Stage files by name, never `git add -A` or `git add .`, because a blanket add
   picks up files nobody reviewed. Leave out temporary and generated files: `.tmp/`, `*.log`, `.DS_Store`,
   build output (`dist/`, `build/`, `target/`, `out/`), `node_modules/`, `.env.local`, IDE folders. If one of
   those is already staged, ask through `AskUserQuestion` whether to unstage it (recommended) or commit as-is.
3. **Classify.** Always run `${HOME}/.claude/skills/commit/scripts/classify.sh commit` before writing the
   message (it logs the Jev call even when it withholds the answer). Only when its `mode` is `enforce`, use
   `type` as the default conventional type and, if `mixed` is true, offer to split the commit; otherwise ignore
   the output (`deterministic_type` is a path-based guess).
4. **Write the message.**

   ```text
   <type>(<scope>): <subject>

   <body>

   Generated with Claude Code
   Co-Authored-By: Claude <noreply@anthropic.com>
   ```

   Types: feat, fix, docs, style, refactor, test, chore, perf, ci. Subject under 72 characters. Add a body
   when the change needs explaining, in the tense and style the repository already uses.

5. **Commit.** Run `git commit` and let the pre-commit hooks run. If a hook fails, report each error with its
   file and line, stop, fix the cause, and commit again. The failed commit never happened, so the retry is a
   new commit, not an amend.
6. **Report** the commit hash and subject from `git log -1 --oneline`.

With nothing to commit, say the working tree is clean and stop.

### Amend mode (`--amend`)

Amending rewrites history, so it is allowed only when both hold: the last commit was authored by the current
user, and it has not been pushed. If either fails, refuse and say which one.

## Expected Output

Illustrative; the files and hash are examples.

```text
Changes: 3 files (src/auth/login.ts, tests/auth.test.ts, README.md)

feat(auth): implement JWT token refresh mechanism

Commit created: a1b2c3d
```
