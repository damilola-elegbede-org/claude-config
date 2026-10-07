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
anything is committed.

Findings go through `/resolve-comments --local`, the same triage path `/review` uses, so the
validation rules, the untrusted-input rules, and the skipped-issue record all apply unchanged.

## Execution

### Step 1: Preflight

Codex is optional on any machine this config syncs to. A missing or signed-out CLI skips the
review with a warning; it never blocks a ship.

```text
RUN: command -v codex
IF: not found
  OUTPUT: "⚠️ codex CLI not installed — skipping the local Codex review."
  WRITE_STATE: status = "skipped"
  END (success)

RUN: codex login status
IF: exit code != 0 OR output does not start with "Logged in"
  OUTPUT: "⚠️ codex CLI not signed in — skipping the local Codex review. Run `codex login` to enable it."
  WRITE_STATE: status = "skipped"
  END (success)

RUN: mkdir -p .tmp/codex-review

PARSE: $ARGUMENTS for target_branch and --auto
IF: no target_branch
  SET: target_branch = main (or master if the repo has no main)

RUN: git merge-base {target_branch} HEAD
IF: it fails
  OUTPUT: "No merge-base with {target_branch} — skipping the local Codex review."
  WRITE_STATE: status = "skipped"
  END (success)

RUN: git diff --quiet {merge_base} AND no untracked files (git status --porcelain)
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
SET: diff_hash = sha256 of (`git diff {merge_base}` output
                            + for each `git ls-files --others --exclude-standard` path: path and
                              `git hash-object` of its contents)
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
  RUN: codex review --base {target_branch} > .tmp/codex-review/round-{round}.log 2>&1
  IF: exit code != 0
    OUTPUT: "⚠️ codex review failed (exit {code}); see .tmp/codex-review/round-{round}.log. Skipping."
    WRITE_STATE: status = "skipped"
    END (success)

  PARSE: findings from the LAST "Full review comments:" block in the log
    (the log prints the block more than once; the last copy is the final answer)
    Each finding starts with a line:  - [P<n>] <title> — <absolute path>:<start>-<end>
    followed by indented body lines up to the next "- [P" line or end of block.
    Strip the repository root from the path so it is repo-relative.
    Drop exact duplicates (same badge, title, and location); the block can repeat entries.
  IF: no "Full review comments:" block AND the log reports no findings
    SET: findings = []

  IF: findings is empty
    OUTPUT: "✅ Codex review clean (round {round})."
    WRITE_STATE: status = "clean"
    END (success)

  WRITE: .tmp/review-local.json   (schema below; overwrites any earlier review output,
                                   which /review's own run has already consumed)
  COPY: .tmp/coderabbit-ignored.json → .tmp/codex-review/ignored-before.json (if it exists)
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
      "suggestion": "<body text>"
    }
  ]
}
```

### Step 4: Gate and record

After the loop, the last round's findings decide the outcome. When round 3 applied fixes, nothing
reviewed them, so that content must not be cached as passed. A P0 or P1 that D skipped during
triage is a decision, not a failure; `/resolve-comments` has already recorded it in
`.tmp/coderabbit-ignored.json`.

```text
SET: open_blockers = last-round P0/P1 findings that were neither fixed nor recorded as skipped
IF: open_blockers is empty AND the loop ended on round 3 with fixes applied
  WRITE_STATE: status = "unverified"
  OUTPUT: "⚠️ Codex review: round-3 fixes were not re-reviewed; GitHub's Codex review will be the first to see them."
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
