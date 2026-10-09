---
name: land
description: Follow a pull request through to mergeable - CI green, every review thread resolved, no conflicts, review bots answered. Use right after a PR is created or pushed, whenever a PR must be "ready to merge", and whenever the landing gate names a PR that is not mergeable yet.
argument-hint: "<pr-url> [--status]"
metadata:
  category: workflow
---

# /land

## Usage

```bash
/land https://github.com/<owner>/<repo>/pull/<n>           # remediate until mergeable or bounded out
/land https://github.com/<owner>/<repo>/pull/<n> --status  # one verdict, no changes
```

## Description

A PR is done when GitHub would let D click Merge, not when it is created. Every PR here runs CI and
gets reviewed by CodeRabbit and Codex; any of those can leave the PR unmergeable after it opens. This
skill owns the follow-up: it reads the PR's real state, fixes what blocks it with the existing skills,
waits for what is still running, and reports "ready to merge" only when the state says so.

The verdict comes from `~/.claude/hooks/jev/pr-land-status.sh`, the same script the `pr-landing-gate`
Stop hook uses, so this skill and the gate cannot disagree about what "mergeable" means. It checks
CI conclusions directly because repos without required status checks report red CI as `UNSTABLE`,
which GitHub still lets you merge.

## Workflow

Work from a checkout of the PR's branch (the worktree that created it), because fixes are commits
on that branch.

1. Read the verdict:
   `~/.claude/hooks/jev/pr-land-status.sh <url>` prints one JSON line with `verdict`
   (`ready | merged | closed | pending | blocked | error`), `blockers[]` (each with a `fix`),
   `pending[]` and `notes[]`.
2. Act on it:
   - `ready`, `merged` or `closed`: go to step 4.
   - `pending` (checks running, mergeability computing, or a review bot that has not answered the
     current head yet): wait with `~/.claude/hooks/jev/pr-land-status.sh <url> --wait 540`, run with a
     Bash timeout of 600000 ms, then read the new verdict. Waiting is not a remediation round, but
     it is bounded: after 4 waits in a row on the same head with no change in what is pending, a
     check that never finishes needs D, so go to step 3.
   - `blocked`: fix every blocker with the skill its `fix` names, then return to step 1.

     | Blocker              | Fix                                                                                |
     | -------------------- | ---------------------------------------------------------------------------------- |
     | `failing-checks`     | `/fix-ci`, then `/commit` and `/push`                                              |
     | `unresolved-threads` | `/resolve-comments <pr-number>`: reply with the fix commit and resolve each thread |
     | `changes-requested`  | `/resolve-comments <pr-number>`                                                    |
     | `conflicts`          | `/rebase`, then `/push --force` (force-with-lease)                                 |
     | `behind-base`        | `/rebase`, then `/push --force` (force-with-lease)                                 |
     | `draft`              | `gh pr ready <url>`                                                                |
     | `blocked-other`      | needs D (usually a required human approval): go to step 3                          |

     A push starts a new head: CI and the review bots run again, so the next verdict is usually
     `pending`. That is expected; wait it out.

3. Bound the loop. After 3 remediation rounds for the same blocker kind, after 4 unchanged
   waits, or immediately for `blocked-other` or a blocker only D can clear, record the stop so the gate releases this head:
   `~/.claude/hooks/jev/pr-land-status.sh <url> --bounded-out "<the remaining blocker>"`.
   A later push makes a new head, and the gate tracks that head afresh.
4. Report with the PR link and the final verdict, one row per PR:
   - ready: "ready to merge", with CI and thread counts from the verdict as evidence.
   - bounded out: "NOT mergeable", the remaining blocker, what was tried, and the one action D can
     take (link the exact page). Never call a bounded-out PR ready.
   - `error` (gh offline or unauthenticated): say the state is unknown and give the command to retry.

## Expected Output

Illustrative; the URL, counts and blocker are examples.

```text
User: /land https://github.com/acme/widget/pull/42

pr-land-status: blocked (failing-checks: test -> /fix-ci; unresolved-threads: 2 -> /resolve-comments)
Round 1: /fix-ci fixed the test failure; /resolve-comments fixed, replied with the commit and resolved both threads; pushed.
pr-land-status: pending (checks-running: test; awaiting-review: chatgpt-codex-connector) -> waiting
pr-land-status: ready (CLEAN, checks green, 0 unresolved threads)

| PR | Verdict | Evidence |
| -- | ------- | -------- |
| https://github.com/acme/widget/pull/42 | ready to merge | test SUCCESS, 0 unresolved threads, Codex reviewed the head |
```

## Notes

- Review threads must be resolved, not just answered: the repos require conversation resolution,
  and an unresolved thread blocks Merge.
- A review bot only counts as awaited when it has reviewed or commented on this repo's recent PRs,
  and only for `review_grace_min` minutes after the head commit (rule config `pr-landing-gate` in
  `hooks/jev/rules.d/rules-events.json`). After that the verdict carries a note instead of waiting.
- Do not merge. Merging stays with D or the orchestrator.
