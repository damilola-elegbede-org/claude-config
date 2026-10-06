---
name: goal-status
description: Report progress on the session's /goal — the condition D set with /goal or Claude set via ProposeGoal — as a headline, progress bar, criteria table with evidence, the goal check's latest reason, and check history. Use when D types /goal-status, or asks "how's the goal going", "goal status", "are we there yet", "what's left on the goal". Read-only; never sets, clears, or works toward the goal. Not for Notion or Linear goals.
argument-hint: "[--all]"
metadata:
  category: workflow
---

# /goal-status

## Usage

```bash
/goal-status          # the current session's goal
/goal-status --all    # every goal in this project's recent sessions, one table
```

## Description

`/goal <condition>` attaches a Stop hook: after each turn a separate check decides whether the
condition holds, and Claude keeps working until it does. Bare `/goal` prints one line. This skill
turns the same data into a status report D can read at a glance.

The goal check only answers met / not met, so there is nothing to fill a bar with. The skill
splits the condition into 3–7 checkable criteria **once per goal**, pins that split, and verifies
each criterion with fresh evidence on every call. The bar is criteria verified / total, and the
total never changes while the goal stands.

Trap worth knowing: `/goal status` (with a space) does not show status — `/goal` takes
`[<condition> | clear]`, so it sets a goal whose condition is "status". Use `/goal-status`.

## Data

`scripts/goal_status.py` (next to this file) reads the session transcript, located through
`$CLAUDE_CODE_SESSION_ID` under `$CLAUDE_CONFIG_DIR` (default `~/.claude`). Run it with Bash:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/goal_status.py" report          # current session
python3 "${CLAUDE_SKILL_DIR}/scripts/goal_status.py" report --all    # project-wide
```

If `${CLAUDE_SKILL_DIR}` isn't set, use the directory holding this SKILL.md.

Each goal in the JSON has: `condition`, `origin` (typed /goal or proposed by Claude), `set_at`,
`state` (`active`, `paused`, `achieved`, `impossible`, `cleared`, `replaced`), `checks[]`
(`at`, `met`, `reason`), `check_count`, `last_reason`, `duration_ms`, `tokens`, `paused`.
`tokens` exists only once a goal is achieved or impossible.

## Procedure

1. Run `report` (or `report --all` when asked). On an `error`, show it in one line and stop.
2. **No goals:** one line — "No goal set this session. Set one with `/goal <condition>`." Stop.
   **`--all`:** go straight to the `--all` layout; no pinning, verification or bar.
3. Take the last goal in the list. For `active` or `paused`, pin criteria. Both `criteria`
   commands default to the current session's latest goal, so never pass the condition text:
   - `criteria get`. If it returns criteria, use them.
   - If `null`, split the condition into 3–7 criteria. Each one is a single fact a read-only
     command or file read can confirm ("CI green on PR #276", not "work is done"). Order them so
     dependencies come later. Save through stdin so quotes in the text cannot break the shell:

     ```bash
     python3 "${CLAUDE_SKILL_DIR}/scripts/goal_status.py" criteria set --json - <<'JSON'
     [{"id": 1, "text": "..."}, {"id": 2, "text": "..."}, {"id": 3, "text": "..."}]
     JSON
     ```

     Never re-split a pinned goal; the script refuses anyway.

4. Verify each criterion now, read-only: `git`, `gh … view/checks/list`, `ls`, `rg`, running the
   project's tests only if they are fast and side-effect free. Status words, not emoji:
   - `met` — evidence confirms it
   - `NOT MET` — evidence contradicts it
   - `waiting` — depends on an earlier criterion that is not met
   - `unverified` — no read-only way to check; never counts toward the bar
5. Render the bar with `bar <met> <total>`.
6. Render the report (layouts under Expected Output). Every evidence cell is a command and its result or a
   `file:line`.

## Rules

- **The goal check wins.** If its last reason says not met but every criterion is `met`, the
  headline still says not met, and a ⚠️ line names the disagreement and quotes the reason.
- **Read-only.** Never run `/goal`, `/goal clear`, or ProposeGoal, and never fix a failing
  criterion — report it. This turn ends normally and the goal check runs again after it.
- Keep it to one screen. Truncate quoted reasons to ~200 characters.

## Expected Output

### Active or paused

Illustrative example; the goal, numbers and evidence are made up.

```text
**FYI · Goal 4 of 6 criteria met; CI is the blocker.**

Goal: "PR #276 merged with CI green and docs updated"
Set 42 min ago by typed /goal · 7 checks so far

Progress  ████████████████░░░░░░░░  4/6  67%

| # | Criterion          | Status  | Evidence                      |
|---|--------------------|---------|-------------------------------|
| 1 | Branch pushed      | met     | `git status -sb` → up to date |
| 5 | CI green           | NOT MET | `gh pr checks 276` → lint red |
| 6 | PR merged          | waiting | depends on 5                  |

Last check (7 of 7): "CI lint job still failing on PR #276."

Check history  ✗ ✗ ✗ ✗ ✗ ✗ ✗   (7 checks, 0 met)

**Next:** Claude fixes criterion 5; the goal check runs again after that turn.
```

- Headline tag: `FYI` while progressing; `ACTION` when paused (state the pause message and that D
  sends a message or runs `/goal clear`), or when every criterion is `unverified` or `NOT MET`
  with no path forward Claude can take.
- Check history shows the last 20 checks oldest→newest, `✗` not met, `✓` met.

### Finished goals

| State        | Headline                                    | Body                                       |
| ------------ | ------------------------------------------- | ------------------------------------------ |
| `achieved`   | `FYI · Goal met in N checks (duration).`    | condition, tokens, the goal check's reason |
| `impossible` | `🔴 Goal judged impossible after N checks.` | reason quoted, one suggested reworded goal |
| `cleared`    | `FYI · Goal cleared early after N checks.`  | condition, last reason before the clear    |
| `replaced`   | shown only under `--all`                    |                                            |

No criteria verification for finished goals; the bar appears only if criteria were pinned.

### --all

One table, newest first, at most 15 rows:

| Set | Session | State | Checks | Duration | Goal |
| --- | ------- | ----- | ------ | -------- | ---- |

`Session` is the first 8 characters of the id. `Goal` is truncated to ~60 characters. Below the
table, one line counts goals by state.
