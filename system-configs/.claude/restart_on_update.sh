#!/bin/bash
# Claude Code Restart-on-Update Watcher
#
# Run periodically (via a LaunchAgent StartInterval, see
# docs/setup/SESSION_RESUME_SETUP.md) to force every tmux-hosted Claude Code
# session onto a newer build as soon as one is fetched -- an explicit,
# confirmed tradeoff: this ENDS whatever that session was doing mid-turn.
#
# Scope, deliberately narrow: only sessions running inside the
# "claude-sessions" tmux session (the one resume_sessions.sh creates) are
# touched. session_registry.sh only records a `tmux_target` for sessions it
# detects are running there, so there is no way to reach -- and no attempt
# to reach -- a session in an ad hoc terminal/iTerm window outside it.
#
# Mechanism: `tmux respawn-window -k` replaces the pane's process outright
# (equivalent to killing it and starting the replacement command), rather
# than sending an in-band `/exit` keystroke -- keystroke injection can be
# lost or land mid-permission-prompt; a hard respawn is deterministic. The
# replacement command is `claude --resume <id>`, which fires a fresh
# SessionStart that re-registers the entry with the new build version.
#
# Log file: $HOME/.claude/logs/restart_on_update.log

BASE_DIR="$HOME/.claude"
REGISTRY_DIR="$BASE_DIR/session-registry"
VERSIONS_DIR="$HOME/.local/share/claude/versions"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/restart_on_update.log"
TMUX_SESSION="claude-sessions"
CLAUDE_BIN="$HOME/.local/bin/claude"

mkdir -p -m 700 "$LOG_DIR" 2>/dev/null || true

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
    log "SKIP jq not available"
    exit 0
fi
if ! command -v tmux >/dev/null 2>&1; then
    log "SKIP tmux not available"
    exit 0
fi
if [[ ! -d "$REGISTRY_DIR" ]]; then
    exit 0
fi
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    exit 0
fi

# Portable semver comparison, used both to pick the newest build and to
# compare each session against it -- no `sort -V`, whose support varies
# across macOS releases.
version_lt() {
    awk -v a="$1" -v b="$2" '
    BEGIN {
        an = split(a, ap, ".")
        bn = split(b, bp, ".")
        mx = (an > bn ? an : bn)
        for (i = 1; i <= mx; i++) {
            ai = (i in ap) ? ap[i] + 0 : 0
            bi = (i in bp) ? bp[i] + 0 : 0
            if (ai < bi) { print "1"; exit }
            if (ai > bi) { print "0"; exit }
        }
        print "0"
    }'
}

latest_version=""
for build_path in "$VERSIONS_DIR"/*; do
    [[ -e "$build_path" ]] || continue
    candidate=$(basename "$build_path")
    [[ "$candidate" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    if [[ -z "$latest_version" || "$(version_lt "$latest_version" "$candidate")" == "1" ]]; then
        latest_version="$candidate"
    fi
done
if [[ -z "$latest_version" ]]; then
    log "SKIP no builds found in $VERSIONS_DIR"
    exit 0
fi

restarted=0

for entry_file in "$REGISTRY_DIR"/*.json; do
    [[ -e "$entry_file" ]] || continue

    ended_at=$(jq -r '.ended_at // empty' "$entry_file" 2>/dev/null)
    [[ -n "$ended_at" ]] && continue

    tmux_target=$(jq -r '.tmux_target // empty' "$entry_file" 2>/dev/null)
    [[ -z "$tmux_target" ]] && continue

    session_id=$(jq -r '.session_id // empty' "$entry_file" 2>/dev/null)
    version=$(jq -r '.version // empty' "$entry_file" 2>/dev/null)
    [[ -z "$session_id" || -z "$version" ]] && continue

    if ! tmux list-windows -t "$TMUX_SESSION" -F '#{session_name}:#{window_index}' 2>/dev/null \
        | grep -qxF "$tmux_target"; then
        log "SKIP stale tmux_target=$tmux_target id=$session_id (window gone)"
        continue
    fi

    # A window existing at tmux_target does not prove it still hosts THIS
    # session: if the original window closed without firing SessionEnd and
    # its index was later reused by an unrelated window (move/renumber), this
    # check alone would let the respawn below destroy that unrelated live
    # window. session_registry.sh tags the window with @claude_session_id at
    # start, so confirm that tag matches before respawning -- fail closed
    # (skip) on any mismatch or missing tag, including windows tagged before
    # this check existed.
    window_owner=$(tmux show-window-options -t "$tmux_target" -v @claude_session_id 2>/dev/null)
    if [[ "$window_owner" != "$session_id" ]]; then
        log "SKIP identity mismatch tmux_target=$tmux_target id=$session_id owner=${window_owner:-<none>}"
        continue
    fi

    is_older=$(version_lt "$version" "$latest_version")
    [[ "$is_older" != "1" ]] && continue

    tmux respawn-window -k -t "$tmux_target" "$CLAUDE_BIN --resume $session_id" 2>>"$LOG_FILE"
    if [[ $? -eq 0 ]]; then
        restarted=$((restarted + 1))
        log "RESTARTED id=$session_id target=$tmux_target from=$version to=$latest_version"
    else
        log "RESTART_FAIL id=$session_id target=$tmux_target"
    fi
done

[[ $restarted -gt 0 ]] && log "DONE restarted=$restarted onto version=$latest_version"

exit 0
