#!/bin/bash
# Claude Code Session Registry Hook
#
# Tracks every live Claude Code session (id, display name, cwd) in one file
# per session under $HOME/.claude/session-registry/, so a boot-time script
# can reopen them after a restart. Registered via two SessionStart/SessionEnd
# hook calls (see settings.json): `session_registry.sh start` on every
# SessionStart (including resume/clear/compact -- NOT filtered to "startup",
# since a resumed session must re-register itself as open), and
# `session_registry.sh end` on SessionEnd.
#
# Design note: SessionEnd does NOT delete the entry. It only stamps
# ended_at/end_reason. A machine restart kills the process with SIGTERM,
# which does NOT fire SessionEnd (verified empirically) -- so entries from
# sessions that were still open at shutdown simply have no ended_at, and
# resume_sessions.sh treats "no ended_at" as "resume this one". A real
# SessionEnd (any reason) always means the user closed the session on
# purpose, so it is correctly skipped on the next resume pass.
#
# One file per session_id means no cross-session locking is needed -- each
# session only ever writes its own file.
#
# State dir : $HOME/.claude/session-registry/<session_id>.json
# Log file  : $HOME/.claude/logs/session_registry.log
#
# Failure policy: every error path exits 0 with no stdout. Session
# start/end MUST NEVER be blocked or broken by this hook.

MODE="${1:-}"

BASE_DIR="$HOME/.claude"
REGISTRY_DIR="$BASE_DIR/session-registry"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/session_registry.log"

mkdir -p -m 700 "$REGISTRY_DIR" "$LOG_DIR" 2>/dev/null || true

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
    log "SKIP jq not available"
    exit 0
fi

if [[ "$MODE" != "start" && "$MODE" != "end" ]]; then
    log "SKIP unknown mode '$MODE'"
    exit 0
fi

input=$(cat 2>/dev/null || echo "")
[[ -z "$input" ]] && exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$session_id" ]] && { log "SKIP no session_id in payload"; exit 0; }

entry_file="$REGISTRY_DIR/$session_id.json"

atomic_write() {
    local content="$1"
    local tmp
    tmp=$(mktemp "$REGISTRY_DIR/.tmp.XXXXXX" 2>/dev/null) || return 1
    printf '%s' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$entry_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

if [[ "$MODE" == "start" ]]; then
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    source_val=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)
    name=$(printf '%s' "$input" | jq -r '.session_title // empty' 2>/dev/null)
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Version this session actually launched with. Used by
    # restart_on_update.sh to tell whether a tmux-hosted session is behind
    # the latest fetched build. Bounded lookup so a slow/hung `claude
    # --version` never delays session start.
    version=""
    if command -v claude >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            raw=$(timeout 2 claude --version 2>/dev/null)
        elif command -v gtimeout >/dev/null 2>&1; then
            raw=$(gtimeout 2 claude --version 2>/dev/null)
        else
            raw=$(claude --version 2>/dev/null)
        fi
        version=$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi

    # Only sessions living in our managed tmux session ("claude-sessions",
    # created by resume_sessions.sh) are eligible for the update-triggered
    # restart in restart_on_update.sh -- we can safely send keystrokes into
    # a tmux pane we manage, but never into an ad hoc terminal/iTerm window
    # opened outside that session, where there's no safe way to signal it.
    tmux_target=""
    if [[ -n "$TMUX" ]] && command -v tmux >/dev/null 2>&1; then
        current_tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)
        if [[ "$current_tmux_session" == "claude-sessions" ]]; then
            tmux_target=$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null)
            # Tag the window with this session_id so restart_on_update.sh can
            # verify -- before respawning -- that the window still hosts THIS
            # session, not a different one that landed at the same
            # session:index after this window closed and the index was reused.
            if [[ -n "$tmux_target" ]]; then
                tmux set-window-option -t "$tmux_target" @claude_session_id "$session_id" 2>/dev/null || true
            fi
        fi
    fi

    content=$(jq -n \
        --arg id "$session_id" \
        --arg cwd "$cwd" \
        --arg source "$source_val" \
        --arg name "$name" \
        --arg now "$now" \
        --arg version "$version" \
        --arg tmux_target "$tmux_target" \
        '{
            session_id: $id,
            name: (if $name == "" then null else $name end),
            cwd: $cwd,
            source: $source,
            started_at: $now,
            version: (if $version == "" then null else $version end),
            tmux_target: (if $tmux_target == "" then null else $tmux_target end),
            ended_at: null,
            end_reason: null
        }')

    if atomic_write "$content"; then
        log "START id=$session_id source=$source_val name=${name:-<unnamed>} cwd=$cwd"
    else
        log "START_FAIL could not write $entry_file"
    fi
    exit 0
fi

# MODE == end
reason=$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null)
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

if [[ -f "$entry_file" ]]; then
    existing=$(cat "$entry_file" 2>/dev/null)
    content=$(printf '%s' "$existing" | jq \
        --arg reason "$reason" \
        --arg now "$now" \
        '.ended_at = $now | .end_reason = (if $reason == "" then null else $reason end)' 2>/dev/null)
    [[ -z "$content" ]] && content="$existing"
else
    # No start entry on record (e.g. registry hook added mid-session, or a
    # session predating this feature) -- write a minimal ended stub so it is
    # never mistaken for an open session.
    content=$(jq -n \
        --arg id "$session_id" \
        --arg reason "$reason" \
        --arg now "$now" \
        '{session_id: $id, name: null, cwd: null, source: null, started_at: null, ended_at: $now, end_reason: (if $reason == "" then null else $reason end)}')
fi

if atomic_write "$content"; then
    log "END id=$session_id reason=${reason:-<none>}"
else
    log "END_FAIL could not write $entry_file"
fi

exit 0
