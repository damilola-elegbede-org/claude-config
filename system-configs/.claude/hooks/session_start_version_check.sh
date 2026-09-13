#!/bin/bash
# Claude Code SessionStart Version Check Hook
#
# On every new session start, checks whether the Claude Code CLI has been
# upgraded since the last session. If so, persists the relevant CHANGELOG
# slice to $HOME/.claude/cache/last_upgrade.md so the /changelog skill can
# replay "what's new" on demand. This hook emits NOTHING to the model or
# terminal — the statusline handles the user-facing upgrade indicator
# (✨ next to the version), and /changelog is run manually.
#
# State file : $HOME/.claude/last_seen_claude_version
# Cache file : $HOME/.claude/cache/claude-code-changelog.md  (24h TTL)
# Slice file : $HOME/.claude/cache/last_upgrade.md           (for /changelog)
# Log file   : $HOME/.claude/logs/session_start_version_check.log
#
# Init: on first run (state file missing), the hook seeds the state file
# with the currently-resolved version and exits without producing a slice.
# The first real upgrade AFTER init is what triggers the first slice.
#
# Failure policy: every error path exits 0 with no stdout. Session start
# MUST NEVER be blocked or delayed by this hook. errexit is off by default
# in bash — we rely on explicit per-operation guards rather than `set -e`.
#
# TEST MODE:
#   Pass --test as the first arg to use an isolated base directory. The
#   base dir is $CLAUDE_TEST_DIR if set, else .tmp/session_start_check/.

# --- Argument parsing ---------------------------------------------------
TEST_MODE=0
if [[ "${1:-}" == "--test" ]]; then
    TEST_MODE=1
    shift
fi

# --- Paths --------------------------------------------------------------
if [[ "$TEST_MODE" -eq 1 ]]; then
    BASE_DIR="${CLAUDE_TEST_DIR:-.tmp/session_start_check}"
else
    BASE_DIR="$HOME/.claude"
fi

STATE_FILE="$BASE_DIR/last_seen_claude_version"
CACHE_DIR="$BASE_DIR/cache"
CACHE_FILE="$CACHE_DIR/claude-code-changelog.md"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/session_start_version_check.log"

CHANGELOG_URL="https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"

# In test mode the parent (.tmp/) is shared with other tooling that expects
# normal permissions; apply 700 only to the hook's own dirs. In real mode
# BASE_DIR is $HOME/.claude and 700 is correct for the whole tree.
if [[ "$TEST_MODE" -eq 1 ]]; then
    mkdir -p "$(dirname "$BASE_DIR")" 2>/dev/null || true
    mkdir -p "$BASE_DIR" "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
    chmod 700 "$BASE_DIR" "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
else
    mkdir -p -m 700 "$BASE_DIR" "$CACHE_DIR" "$LOG_DIR" 2>/dev/null || true
fi

# --- Logging ------------------------------------------------------------
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Atomic state write -------------------------------------------------
write_state() {
    local v="$1"
    local tmp
    tmp=$(mktemp "$BASE_DIR/.last_seen.XXXXXX" 2>/dev/null) || return 1
    printf '%s\n' "$v" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# --- Portable semver comparison -----------------------------------------
# Prints -1 if $1 < $2, 0 if equal, 1 if $1 > $2. Used instead of
# `sort -V` because BSD/macOS sort does not support -V and fails with a
# stderr leak — the header's fail-silent contract forbids that.
semver_cmp() {
    awk -v a="$1" -v b="$2" '
    BEGIN {
        an = split(a, ap, ".")
        bn = split(b, bp, ".")
        mx = (an > bn ? an : bn)
        for (i = 1; i <= mx; i++) {
            ai = (i in ap) ? ap[i] + 0 : 0
            bi = (i in bp) ? bp[i] + 0 : 0
            if (ai < bi) { print -1; exit }
            if (ai > bi) { print 1; exit }
        }
        print 0
    }'
}

# --- Best-effort CHANGELOG cache refresh -------------------------------
# Called unconditionally on every real session start (not only upgrades)
# so that `/changelog <version>` works from first install and in
# steady-state NOOP sessions, not just right after an upgrade. Respects
# a 24h TTL so a warm cache is a pure no-op (no network). Returns 0 if
# the cache is populated (fresh or stale-but-present), 1 if the cache
# is absent and the fetch attempt also failed. NEVER calls `exit` —
# callers decide whether cache absence is fatal for their path.
refresh_changelog_cache() {
    local need_fetch=1
    local cache_mtime="" now age tmp_fetch fetch_size

    if [[ -f "$CACHE_FILE" ]]; then
        if stat -f %m "$CACHE_FILE" >/dev/null 2>&1; then
            cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null)   # BSD/macOS
        elif stat -c %Y "$CACHE_FILE" >/dev/null 2>&1; then
            cache_mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null)   # GNU/Linux
        fi
        if [[ -n "$cache_mtime" ]]; then
            now=$(date +%s)
            age=$((now - cache_mtime))
            if (( age < 86400 )); then
                need_fetch=0
            fi
        fi
    fi

    if [[ "$need_fetch" -eq 0 ]]; then
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log "NO_CURL curl not available"
        [[ -f "$CACHE_FILE" ]] && return 0 || return 1
    fi

    tmp_fetch=$(mktemp "$CACHE_DIR/.changelog.XXXXXX" 2>/dev/null)
    if [[ -z "$tmp_fetch" ]]; then
        log "FETCH_FAIL could not create tmp file in $CACHE_DIR"
        [[ -f "$CACHE_FILE" ]] && return 0 || return 1
    fi

    # TLS hardening: force HTTPS, require TLS 1.2+. The fetched body is
    # later rendered into the model context via /changelog, so this is a
    # trusted input channel and any weakening here is a prompt-injection
    # surface via DNS/MITM against raw.githubusercontent.com.
    if ! curl --proto '=https' --tlsv1.2 \
         --max-time 3 --fail --silent \
         "$CHANGELOG_URL" -o "$tmp_fetch" 2>/dev/null; then
        rm -f "$tmp_fetch" 2>/dev/null
        log "FETCH_FAIL curl could not download CHANGELOG"
        [[ -f "$CACHE_FILE" ]] && return 0 || return 1
    fi

    # Content sanity checks before promoting into the cache:
    #   1. non-empty and <=2MB (CHANGELOG.md is tens of KB)
    #   2. contains at least one `## <semver>` heading line
    # On rejection, keep the previous cache (if any) untouched.
    fetch_size=$(wc -c < "$tmp_fetch" 2>/dev/null | tr -d ' ')
    if [[ -z "$fetch_size" ]] || [[ "$fetch_size" -eq 0 ]] || [[ "$fetch_size" -gt 2097152 ]]; then
        log "FETCH_REJECT size=${fetch_size:-unknown} outside (0, 2MB]"
        rm -f "$tmp_fetch" 2>/dev/null
        [[ -f "$CACHE_FILE" ]] && return 0 || return 1
    fi

    if ! grep -qE '^##[[:space:]].*[0-9]+\.[0-9]+\.[0-9]+' "$tmp_fetch" 2>/dev/null; then
        log "FETCH_REJECT no semver heading lines found in response body"
        rm -f "$tmp_fetch" 2>/dev/null
        [[ -f "$CACHE_FILE" ]] && return 0 || return 1
    fi

    if mv -f "$tmp_fetch" "$CACHE_FILE" 2>/dev/null; then
        log "FETCH ok (cache refreshed, ${fetch_size} bytes)"
        return 0
    fi

    rm -f "$tmp_fetch" 2>/dev/null
    log "FETCH_FAIL could not move tmp into cache path"
    [[ -f "$CACHE_FILE" ]] && return 0 || return 1
}

# --- Read stdin (SessionStart payload) ----------------------------------
# Real mode: Claude Code pipes the JSON payload on stdin and closes it.
# Test mode: only read stdin if it's a pipe/file, never if it's a TTY
# (an unconditional `cat` from a terminal would hang waiting for EOF).
# The TTY check lets piped input (echo ... | ./script --test) still
# exercise the payload-parsing path during testing.
input=""
if [[ "$TEST_MODE" -eq 0 ]] || [[ ! -t 0 ]]; then
    input=$(cat 2>/dev/null || echo "")
fi

# Filter on source == "startup" so resume/clear/compact don't re-greet.
# When stdin has a payload we MUST determine .source. If jq is unavailable
# we fall back to a tolerant regex parse; if the fallback also fails we
# fail closed (exit 0, no slice) rather than silently defaulting to
# "startup" — defaulting there would fire the upgrade check on every
# resume/clear/compact event, which is exactly the wrong behavior.
source_val="startup"
if [[ -n "$input" ]]; then
    if command -v jq >/dev/null 2>&1; then
        parsed=$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)
    else
        # Tolerant shell fallback: extract the first "source":"..." value,
        # allowing arbitrary whitespace around the colon.
        parsed=$(printf '%s' "$input" \
            | grep -oE '"source"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -n1 \
            | sed -E 's/.*"source"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    fi
    if [[ -n "$parsed" ]]; then
        source_val="$parsed"
    else
        log "SKIP could not parse .source from stdin payload (jq=$(command -v jq >/dev/null 2>&1 && echo yes || echo no))"
        exit 0
    fi
fi

if [[ "$source_val" != "startup" ]]; then
    log "SKIP source=$source_val"
    exit 0
fi

# --- Resolve current CLI version ---------------------------------------
# SessionStart stdin payload does NOT include the CLI version (only
# session_id, transcript_path, cwd, hook_event_name, source, model).
# We have to call `claude --version` ourselves.
current_version=""
if command -v claude >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
        raw=$(timeout 2 claude --version 2>/dev/null)
    elif command -v gtimeout >/dev/null 2>&1; then
        raw=$(gtimeout 2 claude --version 2>/dev/null)
    else
        raw=$(claude --version 2>/dev/null)
    fi
    current_version=$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

if [[ -z "$current_version" ]]; then
    log "SKIP cannot resolve current version via claude --version"
    exit 0
fi

# --- Warm the CHANGELOG cache unconditionally --------------------------
# Done BEFORE the state-file / NOOP / DOWNGRADE branches so that first
# installs and steady-state sessions keep the cache populated for the
# `/changelog <version>` skill. The helper respects a 24h TTL, so this
# is a no-op when the cache is already warm. The return code is tracked
# but not fatal here — callers that need the cache (upgrade slicing)
# re-check `[[ -f "$CACHE_FILE" ]]` at their own branch.
refresh_changelog_cache
cache_refresh_status=$?

# --- Read or seed stored version ---------------------------------------
# First run: seed state with the currently-resolved version and exit
# without producing a slice. The first REAL upgrade after init is what
# triggers the first slice — this avoids fabricating a fat
# "upgrade from arbitrary-baseline → now" the first time the hook runs.
if [[ ! -f "$STATE_FILE" ]]; then
    if ! write_state "$current_version"; then
        log "INIT_FAIL cannot write state file at $STATE_FILE (check perms on $BASE_DIR)"
        exit 0
    fi
    log "INIT seeded state file with current=$current_version (no slice on first run)"
    exit 0
fi

stored_version=$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null)

# Corrupt/empty state file: treat like a re-init so we don't carry forward
# a garbage comparison. No slice produced on re-seed either.
if [[ -z "$stored_version" ]] || ! [[ "$stored_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "WARN stored version invalid ('$stored_version'), re-seeding with current=$current_version"
    if ! write_state "$current_version"; then
        log "RESEED_FAIL cannot rewrite state file at $STATE_FILE"
    fi
    exit 0
fi

# --- Equal version: nothing to do ---------------------------------------
if [[ "$stored_version" == "$current_version" ]]; then
    log "NOOP stored=$stored_version matches current"
    exit 0
fi

# --- Detect upgrade vs downgrade ----------------------------------------
# Uses the portable semver_cmp helper instead of `sort -V` (GNU-only).
cmp=$(semver_cmp "$current_version" "$stored_version")
if [[ "$cmp" == "-1" ]]; then
    # Downgrade: update state silently, no slice
    write_state "$current_version"
    log "DOWNGRADE stored=$stored_version current=$current_version, updated silently"
    exit 0
fi

# --- Upgrade path: slice changelog --------------------------------------
# refresh_changelog_cache already ran above. If it failed to produce any
# cache at all, we cannot slice — bail without advancing stored_version
# so the next session retries the fetch.
if [[ "$cache_refresh_status" -ne 0 ]] || [[ ! -f "$CACHE_FILE" ]]; then
    log "SKIP upgrade slice: CHANGELOG cache unavailable (stored=$stored_version current=$current_version)"
    exit 0
fi

# --- Slice changelog: print sections where stored < version <= current --
# Uses a semver_cmp awk function to handle non-contiguous version sequences
# (e.g., 2.1.101 → 2.1.98 with 99/100 skipped in the live CHANGELOG).
slice=$(awk -v stored="$stored_version" -v current="$current_version" '
function semver_cmp(a, b,    ap, bp, i, an, bn, ai, bi, mx) {
    an = split(a, ap, ".")
    bn = split(b, bp, ".")
    mx = (an > bn ? an : bn)
    for (i = 1; i <= mx; i++) {
        ai = (i in ap) ? ap[i] + 0 : 0
        bi = (i in bp) ? bp[i] + 0 : 0
        if (ai < bi) return -1
        if (ai > bi) return 1
    }
    return 0
}
BEGIN { printing = 0 }
/^## / {
    # Extract the first semver anywhere in the heading so we tolerate
    # `## 2.1.101`, `## [2.1.101]`, `## 2.1.101 (2026-04-10)`, etc. If the
    # heading has no semver, treat it as a section break (printing = 0).
    if (match($0, /[0-9]+\.[0-9]+\.[0-9]+/)) {
        v = substr($0, RSTART, RLENGTH)
        if (semver_cmp(v, stored) > 0 && semver_cmp(v, current) <= 0) {
            printing = 1
            print
            next
        }
    }
    printing = 0
    next
}
printing { print }
' "$CACHE_FILE" 2>/dev/null)

# Empty slice: either the cache is stale (upstream CHANGELOG lags the
# installed CLI), the live CHANGELOG skipped this version, or there's a
# format mismatch. Do NOT advance stored_version here — if we did, we'd
# permanently suppress /changelog for this upgrade even though the next
# session's cache refresh could reveal the entries. Next session will
# retry; if the cache eventually catches up, the slice will populate and
# state will advance normally. Cost of retry is zero (just re-awk on the
# existing cache) when the cache is still fresh, so the log-noise
# trade-off is worth it to never lose an upgrade slice.
if [[ -z "$(printf '%s' "$slice" | tr -d '[:space:]')" ]]; then
    log "EMPTY_SLICE stored=$stored_version current=$current_version (state NOT advanced, will retry next session)"
    exit 0
fi

# --- Persist last upgrade slice for /changelog skill --------------------
# Atomically write the from/to metadata + raw CHANGELOG slice so the
# /changelog skill can replay "what's new" on demand. This hook emits
# nothing to the model or terminal — the statusline surfaces the upgrade
# indicator, and the user runs /changelog when they want the summary.
# Best-effort: any failure here is silent.
last_upgrade_file="$CACHE_DIR/last_upgrade.md"
tmp_upgrade=$(mktemp "$CACHE_DIR/.last_upgrade.XXXXXX" 2>/dev/null)
if [[ -n "$tmp_upgrade" ]]; then
    {
        printf -- '---\n'
        printf 'from: %s\n' "$stored_version"
        printf 'to: %s\n' "$current_version"
        printf 'detected_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf -- '---\n\n'
        printf '%s\n' "$slice"
    } > "$tmp_upgrade" 2>/dev/null
    # Explicit branch: either chmod+mv both succeed (tmp becomes the final
    # file and is gone from the .XXXXXX path), or we clean up the tmp file.
    if chmod 600 "$tmp_upgrade" 2>/dev/null \
        && mv -f "$tmp_upgrade" "$last_upgrade_file" 2>/dev/null; then
        :  # success: tmp is now at last_upgrade_file
    else
        rm -f "$tmp_upgrade" 2>/dev/null
        log "SLICE_WRITE_FAIL could not persist $last_upgrade_file"
    fi
fi

# --- Update state AFTER persisting slice --------------------------------
write_state "$current_version"
slice_lines=$(printf '%s\n' "$slice" | wc -l | tr -d ' ')
log "UPGRADE stored=$stored_version → current=$current_version ($slice_lines lines)"

exit 0
