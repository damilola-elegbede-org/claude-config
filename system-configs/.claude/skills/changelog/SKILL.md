---
name: changelog
description: Replay the Claude Code CHANGELOG entries from the most recent CLI upgrade. Use when the user wants to revisit "what's new" after the session-start greeting has scrolled away, or asks things like "what changed in the last upgrade", "show me the changelog", "what did I just upgrade into".
argument-hint: "[--full|<version>]"
category: workflow
---

# /changelog

## Usage

```bash
/changelog              # Summarize the last upgrade's changelog slice
/changelog --full       # Show the raw CHANGELOG slice without summarization
/changelog <version>    # Show a specific version's section (e.g. /changelog 2.1.99)
```

## Description

Replays the Claude Code CHANGELOG entries captured the last time the CLI was
upgraded, so the user can revisit "what's new" on demand. Complementary to the
SessionStart version-check hook: the hook shows the greeting once at startup,
this skill lets the user ask for it again at any point in the session.

## Behavior

### Default (`/changelog`)

1. **Read the persisted slice** at `$HOME/.claude/cache/last_upgrade.md`.
   This file is written by `~/.claude/session_start_version_check.sh` whenever
   a real upgrade is detected. Format:

   ```text
   ---
   from: <prev version>
   to: <current version>
   detected_at: <timestamp>
   ---

   ## <current version>
   ... raw CHANGELOG entries ...
   ```

2. **If the file exists**, parse the YAML header (`from`, `to`, `detected_at`)
   and the body (the raw changelog slice), then present:

   - A one-line header: `Claude Code <from> → <to> (upgraded <detected_at>)`
   - A themed summary: **Features**, **Improvements**, **Fixes**. 5–8 bullets
     total. Prioritize user-facing changes over internal fixes — match the
     style the session-start greeting uses.
   - A one-line footer: `Reply '/changelog --full' to see the raw entries.`

3. **If the file does NOT exist**, no upgrade has been observed on this
   machine since the hook was installed. Report that plainly. Do not fabricate
   entries. Offer: "Run `claude --version` and I can look up that version's
   changelog section directly if you'd like."

### `--full` mode

Print the raw body of `$HOME/.claude/cache/last_upgrade.md` verbatim (strip the
YAML header, keep the changelog markdown). No summarization. Useful when the
user wants to see every bullet.

### Specific version (`/changelog 2.1.99`)

1. Skip `last_upgrade.md` entirely.
2. Read the cached full changelog at `$HOME/.claude/cache/claude-code-changelog.md`
   (maintained by the hook).
3. **Do not fetch.** This skill is read-only with respect to the cache —
   the hook owns network I/O so TLS hardening, sanity checks, and error
   handling live in one place. If the cache file does not exist, tell
   the user: *"The cached CHANGELOG is missing. Start a new Claude Code
   session to refresh it — the SessionStart hook will refetch — then
   re-run `/changelog <version>`."* Do not run `curl`. The hook refreshes
   the cache on session start when the file is more than 24h old, so
   "start a new session" is the user-visible refresh mechanism. The
   skill itself has no way to inspect the cache's age (Read gives
   contents, not mtime), so it must not make freshness claims.
4. Extract the section for the requested version. Scan `##` headings
   and pull the first semver found in each (so `## 2.1.99`,
   `## [2.1.99]`, and `## 2.1.99 (2026-04-10)` all match version
   `2.1.99` — matching the hook's own slicer). Take everything from the
   matching heading up to the next `##` heading and summarize it with
   the same Features/Improvements/Fixes structure as the default mode.
5. If the requested version is not present in the CHANGELOG, say so — do not
   invent content.

## Implementation notes for the model

- Use the **Read** tool for `~/.claude/cache/last_upgrade.md` and
  `~/.claude/cache/claude-code-changelog.md`. Both are plain text.
- **Never run `curl` or any other network fetch from this skill.** The
  SessionStart version-check hook owns the cache and all network I/O —
  TLS hardening, timeouts, content sanity checks, and error logging all
  live there. Duplicating fetch logic here would drift from the hook's
  hardening and split the attack surface across two places.
- Never write to `~/.claude/cache/last_upgrade.md` or
  `~/.claude/cache/claude-code-changelog.md`. This skill is strictly
  read-only with respect to hook state. The hook owns those files.
- When summarizing, group bullets by theme and cap at 8 bullets. If the slice
  contains many fixes, collapse similar ones into a single bullet
  (e.g. "Several `/resume` picker fixes" rather than listing each).
- Be faithful: only summarize entries that appear in the source. Do not
  extrapolate from version numbers.

## Expected Output

### Default mode — slice exists

```text
User: /changelog

Claude Code 2.1.100 → 2.1.101 (upgraded 2026-04-10 09:14:22 -0700)

Features
  - /team-onboarding generates a teammate ramp-up guide from local usage
  - OS CA certificate store trusted by default for enterprise TLS proxies

Improvements
  - Tool-not-available, rate-limit, and refusal errors now explain what
    happened and how to proceed
  - /context free-space accounting now matches the header percentage

Fixes
  - --resume/--continue no longer loses context on large sessions
  - Hardcoded 5-minute request timeout removed; API_TIMEOUT_MS is honored
  - permissions.deny now overrides PreToolUse hook "ask" decisions (security)

Reply '/changelog --full' to see the raw entries.
```

### Default mode — no upgrade recorded yet

```text
User: /changelog

No upgrade has been recorded on this machine yet. The session-start
version-check hook writes ~/.claude/cache/last_upgrade.md the first time
it sees a version change after install.

If you want a specific version's changelog, try /changelog <version>
(e.g. /changelog 2.1.101).
```

### Specific version mode

```text
User: /changelog 2.1.99

Claude Code 2.1.99 (from cached CHANGELOG)

Features
  - ...

(summarized from anthropics/claude-code CHANGELOG.md)
```

## Notes

- The cache and slice files live under `~/.claude/cache/` and are owned by
  `session_start_version_check.sh`.
- Slice is updated only when the hook detects a true upgrade (not on
  downgrades, not on equal-version boots).
- This skill does no network work on the default path — it is safe to run
  offline as long as an upgrade has been observed at least once.
