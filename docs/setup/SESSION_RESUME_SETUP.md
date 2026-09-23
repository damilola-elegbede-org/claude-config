# Session Resume After Restart

Automatically reopens every Claude Code session that was still open when the
machine last restarted, and (optionally, and by design destructively) keeps
long-running sessions on the newest fetched build.

## How it works

- **`hooks/session_registry.sh`** (SessionStart/SessionEnd hooks, already wired in
  `settings.json`) tracks every session's id, name, cwd, launch version, and
  tmux location in one file per session under `~/.claude/session-registry/`.
  A clean session end stamps `ended_at`; a machine restart kills the process
  with SIGTERM, which never fires SessionEnd, so those entries are left
  looking "still open" — exactly the signal the resume script needs.
- **`resume_sessions.sh`** runs `claude update`, then reopens every "still
  open" session as a window in one tmux session named `claude-sessions`
  (`tmux attach -t claude-sessions` to see them all). Idempotent — safe to
  re-run.
- **`restart_on_update.sh`** polls for a newer fetched build and, if found,
  force-restarts any `claude-sessions`-hosted window onto it via
  `tmux respawn-window -k`. **This ends whatever that session was doing
  mid-turn** — an explicit, confirmed tradeoff, not a bug. It only ever
  touches windows inside the managed `claude-sessions` tmux session; an ad
  hoc terminal or iTerm2 window is never touched, because there's no safe
  way to signal it.

## Install (one-time, after `/sync`)

```bash
/sync                                          # deploys the *.sh hook scripts
./scripts/install-session-resume-agents.sh     # installs + loads the LaunchAgents
```

This installs three LaunchAgents:

| Label                                   | Trigger                        | Does                                                        |
| --------------------------------------- | ------------------------------ | ----------------------------------------------------------- |
| `com.damilola.claude-resume-sessions`   | login (`RunAtLoad`)            | `claude update`, then reopen every open session in tmux     |
| `com.damilola.claude-restart-on-update` | every 30 min (`StartInterval`) | restart `claude-sessions`-hosted windows onto a newer build |
| `com.damilola.claude-archive-papercuts` | monthly (first day, 03:17 local time) | archive prior-month papercuts that are not recurring |

## Verify

```bash
launchctl list | grep com.damilola.claude-
tail -f ~/.claude/logs/resume_sessions.log
tail -f ~/.claude/logs/restart_on_update.log
tail -f ~/.claude/logs/archive_papercuts.launchd.log
tmux attach -t claude-sessions
```

## Manage

```bash
# Disable auto-restart-on-update but keep boot resume:
launchctl unload ~/Library/LaunchAgents/com.damilola.claude-restart-on-update.plist

# Disable everything:
# These unload jobs only; they do not modify papercuts.md or its archive.
launchctl unload ~/Library/LaunchAgents/com.damilola.claude-resume-sessions.plist
launchctl unload ~/Library/LaunchAgents/com.damilola.claude-restart-on-update.plist
launchctl unload ~/Library/LaunchAgents/com.damilola.claude-archive-papercuts.plist

# Re-enable:
./scripts/install-session-resume-agents.sh

# Tune the restart-check interval: edit StartInterval (seconds) in
# system-configs/.claude/launchagents/com.damilola.claude-restart-on-update.plist.template,
# then re-run the install script.
```

## Known limits

- Only sessions running inside the `claude-sessions` tmux session are
  eligible for update-triggered restart. Sessions in a plain terminal tab,
  iTerm2 window, or another tmux session are resumed at boot but never
  force-restarted mid-life.
- A session's display name is captured at `SessionStart` (from `-n`/`--name`,
  or whatever the CLI reports as `session_title` on resume). A `/rename`
  mid-session isn't reflected back into the registry file until that
  session's next start/resume — cosmetic only, since resume/restart both key
  off `session_id`, not the display name.
