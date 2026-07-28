---
name: restart-claude
description: Update the Claude Code CLI to the latest version and restart every running claude session (background sessions, tmux panes, the daemon, pre-warmed spares) so they pick up the new binary and the current settings.json. Use this whenever the user says anything like "restart all my claude sessions", "get everything on the latest claude", "my sessions are on an old version", "restart claude everywhere", "reload my settings across sessions", "update claude and restart it", or asks why a session still behaves like an older version after an update. Also use it after editing ~/.claude/settings.json when the user wants running sessions to actually pick the change up — settings are read at startup, so a restart is the only way. Reach for this even when the user only vaguely gestures at "refreshing" or "cycling" their claude sessions.
argument-hint: "[--include-fresh]"
metadata:
  category: specialized
---

# /restart-claude

## Usage

```bash
/restart-claude                  # update the CLI, restart everything running an older build
/restart-claude --include-fresh  # also restart processes already on the latest build
```

Underlying script — run the plan first, then execute:

```bash
python3 ~/.claude/skills/restart-claude/scripts/restart_claude.py --plan
python3 ~/.claude/skills/restart-claude/scripts/restart_claude.py --execute
python3 ~/.claude/skills/restart-claude/scripts/restart_claude.py --execute --include-fresh
python3 ~/.claude/skills/restart-claude/scripts/restart_claude.py --execute --no-update
```

## Description

A running claude process is pinned to the binary it exec'd and the settings it read at
startup. `claude update` swaps in a new build for *future* launches; it does nothing for
sessions already running. That's how a fleet drifts — the CLI reports 2.1.220 while live
sessions still serve 2.1.219 and 2.1.201.

So the job is: update, then replace each stale process, without losing the user's work.

Five different things run claude, and each needs a different move:

| Kind | How to spot it | Restart move |
|---|---|---|
| Background session | `claude agents --json`, `kind: background` | `claude stop <id>`, then `claude --resume <sessionId> --bg --reply-on-resume` from its cwd |
| tmux pane hosting a live session | pane's claude pid appears in `claude agents --json` | `respawn-pane` running `claude --resume <sessionId>` — resumed **in place**, so it stays interactive in that pane |
| tmux pane running a TUI (`claude agents`) | pane's process tree contains a claude binary | `tmux respawn-pane -k` replaying the same argv |
| Daemon supervisor | `claude daemon run` | kill it — but it owns every background session, so this goes last |
| Pre-warmed spare | `--bg-spare` / `bg-pty-host`, not serving a session | kill it; the daemon makes fresh ones on demand |

`claude agents --json` is the authoritative source for real sessions — it gives `sessionId`,
`cwd`, `name` and busy/idle status. Don't reconstruct that from `ps`; you'll misclassify
subagents and spares. Use `ps` only for the things that aren't sessions (daemon, spares,
panes). Interactive entries come back in a slimmer shape than background ones (no short
`id`, no `state`), so normalise before indexing or one open interactive session breaks the
whole run.

Identifying *which build* a process runs is the subtle part. The launcher may be a wrapper
script that hard-links the newest build into `ClaudeCode.app` (so macOS privacy grants
attach to a stable bundle id), which means the running binary's path can contain no version
at all and the launcher path resolves to itself. Compare **inodes** against `versions/*`
rather than matching paths, and take "latest" as the newest entry in `versions/`. Match
processes on argv[0], not the whole command line — otherwise a wrapper shell like
`zsh -lc 'claude agents'` looks like claude and pollutes the list.

Note `/Applications/Claude.app` is the separate desktop app. It has nothing to do with the
CLI, and its helpers must not be killed.

### Where staleness actually comes from

Background sessions don't run the binary that launched them — the daemon hands each new
session a **pre-warmed spare**, so the session inherits the spare pool's version. That's why
background sessions are usually already current while tmux panes, which exec the launcher
directly and then sit for weeks, are the ones that drift. It also means a stale daemon
quietly poisons every session it starts, so spares are killed *before* any session restarts,
and a stale daemon is replaced last.

Practical consequence: a version-only pass often finds nothing to do for background
sessions. If the goal is a **settings.json** change, use `--include-fresh` — otherwise the
script correctly concludes nothing is stale and the edit never reaches running sessions.

## Execution

### Step 1: Show the plan

```text
RUN: restart_claude.py --plan
OUTPUT: the table of what would be cycled, including any busy sessions
```

### Step 2: Execute

```text
RUN: restart_claude.py --execute      (add --include-fresh for a settings-only change)
ORDER: update CLI → kill stale spares → restart background sessions →
       respawn tmux panes → hand daemon + this session to a detached helper
```

### Step 3: Verify and report

```text
RUN: restart_claude.py --plan
EXPECT: nothing left to restart
RELAY: the report table (also written to ~/.claude/restart-claude/last-run.md)
```

Two caveats when reading that verification: the detached helper may still be working (check
`~/.claude/restart-claude/finish-restart.log`), and this session's own restart can't be
observed from inside this session. If a relaunch failed, the report carries the exact
recovery command — surface it rather than reporting a bare failure count.

## Expected Output

```text
User: /restart-claude

updating CLI...
  Checking for updates to latest version... / Claude Code is up to date (2.1.220)
respawning pane 15:%3 (2.1.219 -> 2.1.220): agents
respawning pane 4:%21 (2.1.201 -> 2.1.220): --resume 0cdbfca1-82d5-46ea-91e5-4a04794b7eed

# restart-claude (2026-07-27 22:33:07)

Installed CLI: **2.1.220**

| what | id / pane | name | was | action |
|---|---|---|---|---|
| session | 6a496ffd | Linear Session | 2.1.219 | restarted -> b8831994 (on 2.1.220) |
| tmux pane | 15:%3 | claude agents | 2.1.219 | respawned |
| tmux pane | 4:%21 | claude | 2.1.201 | respawned |
| bg spare | 27938 | pre-warmed | 2.1.219 | killed |
| session (self) | 2c5fc6a9 | restart utility | 2.1.219 | restarting via detached helper |

## Notes
- Detached helper running: `~/.claude/restart-claude/finish-restart.sh`. This session is
  restarted by it, so this session's own output stops here.

report: /Users/daelegbe/.claude/restart-claude/last-run.md
```

## Notes

- **Busy sessions are restarted too** — deliberately, so one pass gets the whole fleet
  current. In-flight tool calls at kill time are lost; transcript history is not. Mention
  the busy sessions from the plan before executing so the interruption isn't a surprise.
- **A session with no transcript can't be resumed.** One that never exchanged a message has
  nothing on disk and `--resume` fails with "No conversation found", leaving an error where
  the session used to be. The script checks first and brings those back fresh, same name.
- **Restarting a background session mints a new session id.** Resuming into `--bg` carries
  the full history but issues a fresh id and drops the label, so `--name` is re-passed to
  keep sessions recognisable in `claude agents`. Give the user the old → new mapping from
  the report; otherwise they'll go looking for an id that no longer exists. Panes resumed in
  place keep their id.
- **This session is restarted last, by a detached helper.** The invoking session can't kill
  itself mid-script, and a stale daemon takes every background session down with it. Those
  steps run detached from `~/.claude/restart-claude/finish-restart.sh`, so the session
  running this skill stops mid-conversation and comes back under a new id. Say that *before*
  executing — otherwise it reads as a crash.
- **Interactive sessions outside tmux are left running.** There's no way to relaunch a
  terminal we don't control, so killing one would leave a dead window and no path back. The
  report prints the `/exit` + `claude --resume <id>` to run in that window.
- Panes are respawned behind a login shell, so the pane falls back to a prompt when claude
  later exits instead of the window disappearing.
