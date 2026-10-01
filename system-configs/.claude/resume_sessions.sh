#!/bin/bash
# Claude Code Session Resume Script
#
# Run at login (via a LaunchAgent, see docs/setup/SESSION_RESUME_SETUP.md) to
# reopen every Claude Code session that was still open when the machine last
# restarted. Reads the per-session files session_registry.sh writes to
# $HOME/.claude/session-registry/*.json: an entry with no ended_at is
# treated as "was open, resume it" (a machine restart kills sessions with
# SIGTERM, which never fires SessionEnd -- see session_registry.sh for the
# empirical basis).
#
# All resumed sessions land in one tmux session named "claude-sessions", one
# window per Claude session, titled "<display name>-<short id>" (or just the
# short id). Idempotent: re-running skips any session that already has a
# window in "claude-sessions", that started after the current boot (so it is
# still running somewhere), or that is running as `claude --resume <id>`.
#
# Runs `claude update` once, synchronously, before reopening anything, so
# every resumed session launches on the newest fetched build (the stable
# wrapper at ~/.local/bin/claude promotes the newest build in
# ~/.local/share/claude/versions/ at each launch -- see that script's
# comments). Bounded by a timeout so a slow/offline network can't hang
# login indefinitely; on timeout, sessions still resume on whatever build
# is already current.
#
# Log file: $HOME/.claude/logs/resume_sessions.log

BASE_DIR="$HOME/.claude"
REGISTRY_DIR="$BASE_DIR/session-registry"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/resume_sessions.log"
TMUX_SESSION="claude-sessions"
CLAUDE_BIN="$HOME/.local/bin/claude"

mkdir -p -m 700 "$LOG_DIR" 2>/dev/null || true

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
    log "ABORT jq not available"
    exit 0
fi
if ! command -v tmux >/dev/null 2>&1; then
    log "ABORT tmux not available"
    exit 0
fi
if [[ ! -x "$CLAUDE_BIN" ]]; then
    log "ABORT $CLAUDE_BIN not found or not executable"
    exit 0
fi
if [[ ! -d "$REGISTRY_DIR" ]]; then
    log "NOOP no session registry at $REGISTRY_DIR"
    exit 0
fi

# --- Fetch the latest build before reopening anything ----------------------
if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$CLAUDE_BIN" update >>"$LOG_FILE" 2>&1
    update_status=$?
elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 60 "$CLAUDE_BIN" update >>"$LOG_FILE" 2>&1
    update_status=$?
else
    log "SKIP_UPDATE no timeout or gtimeout available, refusing to run unbounded"
    update_status=-1
fi
log "UPDATE_CHECK exit=$update_status"

# --- Ensure the shared tmux session exists ----------------------------------
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION" -n placeholder 2>/dev/null
    log "CREATED tmux session $TMUX_SESSION"
fi

existing_windows=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null)

# Boot time as epoch seconds ("{ sec = 1788297973, usec = ... } ..." on macOS).
boot_epoch=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*[^u]sec = ([0-9]+).*/\1/')
[[ "$boot_epoch" =~ ^[0-9]+$ ]] || boot_epoch=""

resumed=0
skipped=0

for entry_file in "$REGISTRY_DIR"/*.json; do
    [[ -e "$entry_file" ]] || continue

    ended_at=$(jq -r '.ended_at // empty' "$entry_file" 2>/dev/null)
    [[ -n "$ended_at" ]] && continue  # was closed on purpose, don't resurrect

    session_id=$(jq -r '.session_id // empty' "$entry_file" 2>/dev/null)
    [[ -z "$session_id" ]] && continue

    cwd=$(jq -r '.cwd // empty' "$entry_file" 2>/dev/null)
    name=$(jq -r '.name // empty' "$entry_file" 2>/dev/null)
    short_id="${session_id:0:8}"
    # Display names aren't unique, so the short id is always part of the
    # window name -- two sessions titled the same never shadow each other.
    window_name="${name:+${name}-}${short_id}"

    if printf '%s\n' "$existing_windows" | grep -qxF "$window_name"; then
        skipped=$((skipped + 1))
        continue
    fi

    # An open entry that started after the current boot is not a restart
    # casualty: it is still running (or died this boot). This also covers a
    # session launched as plain `claude`, whose command line never carries
    # the session id the pgrep check below looks for.
    started_at=$(jq -r '.started_at // empty' "$entry_file" 2>/dev/null)
    if [[ -n "$started_at" && -n "$boot_epoch" ]]; then
        started_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$started_at" '+%s' 2>/dev/null)
        if [[ -n "$started_epoch" && "$started_epoch" -ge "$boot_epoch" ]]; then
            skipped=$((skipped + 1))
            log "SKIP started after boot id=$session_id name=$window_name"
            continue
        fi
    fi

    # A session can still be live outside the managed tmux session (e.g. a
    # terminal window open from before this script's tmux session existed,
    # or before a machine restart the registry didn't catch). Re-running
    # this script -- including via RunAtLoad on install/reinstall -- must
    # not spawn a second `claude --resume` client for the same session_id.
    if pgrep -f "claude --resume $session_id" >/dev/null 2>&1; then
        skipped=$((skipped + 1))
        log "SKIP already running outside tmux id=$session_id name=$window_name"
        continue
    fi

    if [[ -n "$cwd" && -d "$cwd" ]]; then
        tmux new-window -d -t "$TMUX_SESSION" -n "$window_name" -c "$cwd" \
            "$CLAUDE_BIN --resume $session_id" 2>>"$LOG_FILE"
    else
        tmux new-window -d -t "$TMUX_SESSION" -n "$window_name" \
            "$CLAUDE_BIN --resume $session_id" 2>>"$LOG_FILE"
    fi

    if [[ $? -eq 0 ]]; then
        resumed=$((resumed + 1))
        log "RESUMED id=$session_id name=$window_name cwd=${cwd:-<unset>}"
    else
        log "RESUME_FAIL id=$session_id name=$window_name"
    fi
done

# Drop the placeholder window created when the tmux session didn't exist
# yet, once real windows exist alongside it.
if tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "placeholder" \
    && [[ "$(tmux list-windows -t "$TMUX_SESSION" 2>/dev/null | wc -l | tr -d ' ')" -gt 1 ]]; then
    tmux kill-window -t "$TMUX_SESSION:placeholder" 2>/dev/null
fi

log "DONE resumed=$resumed skipped=$skipped"
exit 0
