---
name: codex-review
description: Run the Codex reviewer locally before a PR opens, fix what it finds, and re-run until no P0/P1 findings remain (max 3 rounds). Use before pushing or opening a PR, or when D says "pre-review", "run codex review", or "catch Codex comments before the PR".
argument-hint: "[target_branch] [--auto]"
metadata:
  category: workflow
---

# /codex-review

## Usage

```bash
/codex-review               # Review branch + uncommitted changes vs main, triage interactively
/codex-review develop       # Review against develop
/codex-review --auto        # Apply recommended fixes without the triage dialog
```

## Description

Codex reviews every PR on GitHub, and each round of its comments costs a fix-push-re-review
cycle. The same reviewer ships in the Codex CLI as `codex review`, signed in with D's existing
ChatGPT login, so running it before the PR opens lets most of those comments get fixed while
the branch is still local. It reduces review rounds; it does not eliminate them, because the
reviewer is not deterministic and GitHub's run can still surface something the local run did not.

`codex review --base <branch>` diffs from the merge-base to the working tree, so it covers
commits on the branch plus staged and unstaged changes. That means this skill can run before
anything is committed. Untracked files are not in that diff, so Step 3 marks them intent-to-add
for the duration of the review; otherwise a brand-new file would be hashed as reviewed without
the reviewer ever seeing it.

GitHub's Codex reads the repository and its `AGENTS.md`, nothing else. A local run under
`~/.codex` also loads D's personal skills (linked from `~/.claude/skills`), the global
`~/.codex/AGENTS.md`, hooks and memories, which steer it away from what GitHub will flag. The
review therefore runs under a dedicated Codex home, `~/.codex-review`, holding only its own login
and a minimal config. That home needs its own login rather than a copy of `~/.codex/auth.json`:
two homes refreshing one copied token can invalidate each other's session.

The run also passes `references/focus.md` as developer instructions. It lists the defect classes
that make up most GitHub Codex findings in these repositories, largest first, and asks every
finding to end with a `Files the fix must change:` line. Triage only lets a fix edit files the
finding names, so that line is what lets a wiring fix reach a registry or manifest outside the
flagged file. `codex review --base` refuses a custom prompt argument, so the focus goes through
the `developer_instructions` config key instead.

Findings go through `/resolve-comments --local`, the same triage path `/review` uses, so the
validation rules, the untrusted-input rules, and the skipped-issue record all apply unchanged.

## Execution

### Step 1: Preflight

Codex is optional on any machine this config syncs to. A missing or signed-out CLI skips the
review with a warning; it never blocks a ship.

```text
RUN: cd "$(git rev-parse --show-toplevel)"
     (from a subdirectory, `git ls-files --others` lists only that subtree, so untracked files
      elsewhere would miss both the review and the cache hash)
RUN: mkdir -p .tmp/codex-review   (first, so every WRITE_STATE below has a directory to write to)

Two runs in one worktree would share the review index, round logs and triage files, and one
could parse or cache the other's findings, so a lock admits one run at a time. `mkdir` is
atomic, so a failed `mkdir` means another run holds the lock.

RUN: mkdir .tmp/codex-review/run.lock
IF: it succeeds
  WRITE: this process's PID to run.lock/pid
IF: it fails AND the PID in run.lock/pid is still running
  OUTPUT: "Another Codex review is running in this worktree. Wait for it to finish, then re-run."
  END (busy, without WRITE_STATE: the running review owns state.json)
     (busy is not a pass: a caller that proceeded would publish before that review reports)
IF: it fails AND that PID is gone (a crashed run left the lock)
  OUTPUT: "A crashed Codex review left .tmp/codex-review/run.lock. Remove it and re-run."
  END (busy)
     (reclaiming automatically races: two runs can each remove the other's fresh lock, so a
      stale lock is cleared by hand once)
Only the run whose `mkdir` succeeded owns the lock. Every END after this point, success or
failure, removes .tmp/codex-review/run.lock first. The two busy ENDs above never remove it: that
run does not own the lock, and removing it would let a third run start beside the active one.

RUN: command -v codex
IF: not found
  OUTPUT: "⚠️ codex CLI not installed — skipping the local Codex review."
  WRITE_STATE: status = "skipped"
  END (success)

SET: review_home = ~/.codex-review
RUN: mkdir -p {review_home}
RUN: CODEX_HOME={review_home} codex login status
IF: exit code == 0 AND output starts with "Logged in"
  WRITE: {review_home}/config.toml, replacing it every run so it cannot drift:
           approval_policy = "never"
           sandbox_mode = "read-only"
           [features]
           memories = false
           hooks = false
         (no model key: the CLI default is the closest available match to GitHub's reviewer,
          whose model is not published)
  SET: codex_cmd = CODEX_HOME={review_home} codex
ELSE
  RUN: codex login status
  IF: exit code != 0 OR output does not start with "Logged in"
    OUTPUT: "⚠️ codex CLI not signed in — skipping the local Codex review. Run
             `CODEX_HOME=~/.codex-review codex login` to enable it."
    WRITE_STATE: status = "skipped"
    END (success)
  SET: codex_cmd = codex -c 'sandbox_mode="read-only"' -c 'approval_policy="never"'
       (a review copies the home's sandbox setting, and ~/.codex may allow writes; the review
        must never modify the worktree it is reviewing)
  OUTPUT: "⚠️ Reviewing under ~/.codex, whose personal skills and AGENTS.md GitHub's Codex never
           sees, so findings may differ from GitHub's. Run `CODEX_HOME=~/.codex-review codex login`
           once for a GitHub-like review."

SET: focus_file = the `references/focus.md` file next to this SKILL.md
SET: focus_arg = -c "developer_instructions=<focus_file contents as one JSON string>"
     (JSON string escaping is valid TOML basic-string syntax; build it with
      python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' {focus_file})

PARSE: $ARGUMENTS for target_branch and --auto
IF: no target_branch
  SET: target_branch = main (or master if the repo has no main)

RUN: git merge-base {target_branch} HEAD
IF: it fails
  OUTPUT: "No merge-base with {target_branch} — skipping the local Codex review."
  WRITE_STATE: status = "skipped"
  END (success)

RUN: git diff --quiet {merge_base} -- ':!.tmp' AND no untracked files outside .tmp/
     (`git ls-files --others --exclude-standard -- ':!.tmp'` is empty)
IF: there is nothing to review
  OUTPUT: "No changes against {target_branch} — nothing to review."
  END (success)
```

### Step 2: Skip if this exact diff already passed

`/ship-it` and `/pr` both call this skill, so one ship can reach it twice. The state file records
a hash of the reviewed content: the tracked diff plus every untracked file. Committing tracked
changes leaves the hash unchanged, so a review that ran before the commit still counts afterwards.
Committing a previously untracked file changes the hash and triggers one more review, which costs
time but never skips new content.

```text
SET: diff_hash = sha256 of (`git diff {merge_base} -- ':!.tmp'` output
                            + for each `git ls-files --others --exclude-standard -- ':!.tmp'`
                              path: path and `git hash-object` of its contents)
     (`.tmp/` holds this skill's own state, logs and index; in a repository that does not ignore
      it, including it would change the hash on every run and send the scratch files for review)
READ: .tmp/codex-review/state.json
IF: state.diff_hash == diff_hash AND state.status in (clean, acknowledged)
  OUTPUT: "Codex review already passed for this diff — skipping."
  END (success)
```

### Step 3: Review loop (max 3 rounds)

Three rounds is the repo's bound on retrying a failing step. Every round after the first
reviews the fixes from the previous round, and those fixes are where new findings usually come from.

```text
FOR round in 1..3:
  SET: new_files = `git ls-files --others --exclude-standard -- ':!.tmp'`
  SET: review_index = absolute path of .tmp/codex-review/index
  RUN: cp "$(git rev-parse --git-path index)" {review_index}
  RUN: GIT_INDEX_FILE={review_index} git add -N -- {each path in new_files}
       (intent-to-add in a private copy of the index: the files enter `git diff` with their full
        contents, and the live index is never written, so anything another session stages or
        commits during a review of several minutes is left intact)
  RUN: GIT_INDEX_FILE={review_index} {codex_cmd} review --base {target_branch} {focus_arg}
       > .tmp/codex-review/round-{round}.log 2>&1
  IF: exit code != 0
    OUTPUT: "⚠️ codex review failed (exit {code}); see .tmp/codex-review/round-{round}.log. Skipping."
    WRITE_STATE: status = "skipped"
    END (success)

  PARSE: findings from the LAST findings block in the log. The header depends on the count:
    "Review comment:" for exactly one finding, "Full review comments:" for two or more.
    (the log prints the block more than once; the last copy is the final answer)
    Each finding starts with a line:  - [P<n>] <title> — <absolute path>:<start>-<end>
    followed by indented body lines up to the next "- [P" line or end of block.
    Strip the repository root from the path so it is repo-relative.
    Drop exact duplicates (same badge, title, and location); the block can repeat entries.
  IF: no findings block AND the log's closing message says no issues were found
      (a clean review prints no header, only a summary such as "No actionable issues were found.")
    SET: findings = []
  IF: no findings block AND the closing message does not say that
    OUTPUT: "⚠️ Could not parse the Codex review output; see .tmp/codex-review/round-{round}.log."
    WRITE_STATE: status = "unverified"
    END (success)   (an unreadable result is never cached as clean)

  IF: findings is empty
    SET: last_round_clean = true
    BREAK   (Step 4 still checks blockers deferred in earlier rounds before recording clean)

  WRITE: .tmp/review-local.json   (schema below; overwrites any earlier review output,
                                   which /review's own run has already consumed)
  RUN: rm -f .tmp/codex-review/ignored-before.json   (a snapshot left by an earlier branch must
                                                     never merge into this one)
  COPY: .tmp/coderabbit-ignored.json → .tmp/codex-review/ignored-before.json (if it exists and
        its branch field equals the current branch; a file left by another branch in this
        worktree would otherwise post that branch's skips on this PR)
  INVOKE: /resolve-comments --local [--auto if this skill got --auto]
  MERGE: ignored-before.json records back into .tmp/coderabbit-ignored.json, dropping duplicates
         (same source, location, and description). File mode rewrites that file with only the
         current run's skips, and /pr must receive every skip from /review and every round.

  IF: no fixes were applied this round
    BREAK   (re-running on an unchanged diff would return the same findings)
  SET: diff_hash = recomputed as in Step 2
```

Severity mapping (Codex badge to the `/review` schema):

| Codex | `severity` |
| ----- | ---------- |
| P0    | CRITICAL   |
| P1    | HIGH       |
| P2    | MEDIUM     |
| P3    | LOW        |

`.tmp/review-local.json` written by this skill:

```json
{
  "schema_version": "1.0",
  "branch": "{current_branch}",
  "created_at": "{ISO timestamp}",
  "source": "codex",
  "summary": "Local codex review, round {round}: {count} findings",
  "walkthrough": [],
  "issues": [
    {
      "id": 1,
      "file": "path/relative/to/repo",
      "line": "<start line>",
      "severity": "HIGH",
      "type": "bugs",
      "description": "[P1] <title>",
      "suggestion": "<body text, including its Files the fix must change: line>"
    }
  ]
}
```

### Step 4: Gate and record

After the loop, the last round's findings decide the outcome. When round 3 applied fixes, nothing
reviewed them, so that content must not be cached as passed. A P0 or P1 that D skipped in the
triage dialog is a decision, not a failure; `/resolve-comments` has already recorded it in
`.tmp/coderabbit-ignored.json`. A P0 or P1 that triage skipped on its own, because validation
rejected the guidance or the fix reached outside the finding's files, was never decided by
anyone and stays a blocker. Such a blocker stays open even when a later round does not
report it again: the reviewer is not deterministic, so its silence is not a fix.

```text
SET: open_blockers = P0/P1 findings from any round that were neither fixed nor skipped by D in the
                    triage dialog (skip_category "user-skipped", "Skip all", or a declined
                    wider edit); automatic skips such as "out-of-scope-edit" or a validation
                    rejection count as open
IF: open_blockers is empty AND the loop ended on round 3 with fixes applied
  WRITE_STATE: status = "unverified"
  OUTPUT: "⚠️ Codex review: round-3 fixes were not re-reviewed; GitHub's Codex review will be the first to see them."
  END (success)
IF: open_blockers is empty AND last_round_clean AND nothing was skipped in any round
  WRITE_STATE: status = "clean"
  OUTPUT: "✅ Codex review clean (round {rounds})."
  END (success)
IF: open_blockers is empty
  WRITE_STATE: status = "acknowledged"
  OUTPUT: "Codex review: {fixed} fixed, {skipped} skipped across {rounds} round(s)."
  END (success)
ELSE
  WRITE_STATE: status = "blocked"
  OUTPUT: "Codex review still reports {n} P0/P1 finding(s) after {rounds} round(s):"
  OUTPUT: one line per blocker: "{file}:{line} — {description}"
  OUTPUT: "Logs: .tmp/codex-review/round-*.log"
  END (failure)   # /ship-it halts on this
```

`WRITE_STATE` writes `.tmp/codex-review/state.json`:

```json
{
  "diff_hash": "<sha256 from Step 2>",
  "target_branch": "main",
  "status": "clean|acknowledged|unverified|blocked|skipped",
  "rounds": 2,
  "updated_at": "{ISO timestamp}"
}
```

## Expected Output

Illustrative:

```text
Codex review vs main (round 1)...
Loaded 4 AI reviewer issues
[triage via /resolve-comments --local]
Fixed 3 issues, skipped 1
Codex review vs main (round 2)...
✅ Codex review clean (round 2).
```

## Notes

- Runtime grows with diff size: about 40 seconds for a two-file change and several minutes for a
  multi-file branch.
  Each round also draws on D's ChatGPT plan usage.
- The full log of every round stays in `.tmp/codex-review/` for debugging.
- This skill never pushes. When `/resolve-comments` commits fixes, the caller pushes them.
