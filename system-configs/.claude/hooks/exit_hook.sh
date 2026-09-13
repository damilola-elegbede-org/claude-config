#!/bin/bash
# Claude Code Exit Hook
# Updates terminal version files when a Claude session ends
# Compares current version with stored version:
# - If newer: writes NEW_VERSION:1 (statusline will show stars)
# - If same: preserves existing flag (only 6-hour timer changes flag to 0)
# Terminal ID is based on grandparent PID only, so tracking persists across directories
#
# TEST MODE:
# - Pass --test flag to use .tmp/terminal_versions/ instead of ~/.claude/terminal_versions/
# - This isolates test logs from production logs

# Parse command-line arguments
TEST_MODE=0
if [[ "$1" == "--test" ]]; then
    TEST_MODE=1
    shift  # Remove --test from arguments
fi

# Get terminal identifier based on grandparent PID only
# Get grandparent PID - required for terminal identification
if ! ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' '); then
    # Silently exit if we can't get parent PID
    exit 0
fi

if ! gppid=$(ps -o ppid= -p $ppid 2>/dev/null | tr -d ' '); then
    # Silently exit if we can't get grandparent PID
    exit 0
fi

# Use grandparent PID (terminal emulator) for stability across directories
raw_id="terminal_${gppid}"
terminal_id="$(printf '%s' "$raw_id" | tr '/\n' '_' | tr -cd 'A-Za-z0-9._-')"

[[ -n "$terminal_id" ]] || terminal_id="fallback_$$"

# Version tracking files
if [[ "$TEST_MODE" -eq 1 ]]; then
    # Test mode: use test directory specified by environment variable or default
    if [[ -n "${CLAUDE_TEST_DIR:-}" ]]; then
        terminal_versions_dir="${CLAUDE_TEST_DIR}/terminal_versions"
    else
        terminal_versions_dir=".tmp/terminal_versions"
    fi
else
    # Production mode: use ~/.claude/terminal_versions/
    version_dir="$HOME/.claude"
    terminal_versions_dir="$version_dir/terminal_versions"
fi
terminal_version_file="$terminal_versions_dir/${terminal_id}"

# Robust version detection: Try stdin JSON first, then claude --version
# Read any input from stdin (if provided by SessionEnd hook)
input=$(cat 2>/dev/null || echo "")
current_version=""

# Try to extract version from JSON input if available
if [[ -n "$input" ]] && command -v jq >/dev/null 2>&1; then
    current_version=$(echo "$input" | jq -r '.version // empty' 2>/dev/null)
fi

# If no version from JSON, try claude --version
if [[ -z "$current_version" ]]; then
    current_version=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

# If still no version, use default
if [[ -z "$current_version" ]]; then
    current_version="1.0.100"
fi

# Extract semantic version (e.g., "1.0.102" from "1.0.102:uuid:uuid")
semantic_version="${current_version%%:*}"

# Validate semantic version format - use default if invalid
if [[ ! "$semantic_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    semantic_version="1.0.100"
fi

# Create terminal versions directory if needed
mkdir -p -m 700 "$terminal_versions_dir" 2>/dev/null || true

# Logging functionality for debugging
log_file="$terminal_versions_dir/events.log"
log_event() {
    local event_type="$1"
    local details="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [EXIT_HOOK] [%s] PID:%s TERM:%s VER:%s %s\n' \
        "$timestamp" "$event_type" "$$" "$terminal_id" "$semantic_version" "$details" >> "$log_file" 2>/dev/null || true
}

# Function to compare semantic versions
# Returns 0 if v1 > v2, 1 if v1 = v2, 2 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    IFS='.' read -r -a v1_parts <<< "$v1"
    IFS='.' read -r -a v2_parts <<< "$v2"

    for i in {0..2}; do
        v1_part="${v1_parts[i]:-0}"
        v2_part="${v2_parts[i]:-0}"

        if (( v1_part > v2_part )); then
            return 0  # v1 is newer
        elif (( v1_part < v2_part )); then
            return 2  # v1 is older
        fi
    done

    return 1  # versions are equal
}

# Check if terminal version file exists and compare versions
if [[ -f "$terminal_version_file" ]]; then
    # Read current content
    stored_content=$(cat "$terminal_version_file" 2>/dev/null || echo "")

    # Parse VERSION:FLAG format
    if [[ "$stored_content" =~ ^([^:]+):([01])$ ]]; then
        stored_version="${BASH_REMATCH[1]}"
        stored_flag="${BASH_REMATCH[2]}"
    else
        # Old format or corrupted - treat as version only, preserve flag as 0
        stored_version="$stored_content"
        stored_flag="0"
    fi

    # Compare versions
    compare_versions "$semantic_version" "$stored_version"
    comparison_result=$?

    if [[ $comparison_result -eq 0 ]]; then
        # Current version is newer - write NEW_VERSION:1 (only upgrade changes flag)
        tmp_file="$(mktemp "$terminal_versions_dir/.tmp.XXXXXX" 2>/dev/null || printf '%s' "$terminal_versions_dir/.tmp.$$")"
        umask 077
        printf '%s:1' "$semantic_version" > "$tmp_file" 2>/dev/null || true
        chmod 600 "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$terminal_version_file" 2>/dev/null || true
        log_event "UPDATE" "Version upgraded from $stored_version to $semantic_version, set flag=1 (will show stars next time) from PWD: $PWD"
    else
        # Same version - preserve existing flag, only update version
        tmp_file="$(mktemp "$terminal_versions_dir/.tmp.XXXXXX" 2>/dev/null || printf '%s' "$terminal_versions_dir/.tmp.$$")"
        umask 077
        printf '%s:%s' "$semantic_version" "$stored_flag" > "$tmp_file" 2>/dev/null || true
        chmod 600 "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$terminal_version_file" 2>/dev/null || true
        log_event "VERSION_UPDATE" "Same version $semantic_version, preserved flag=$stored_flag (flag only changes via timer) from PWD: $PWD"
    fi
else
    # No existing file - just log the event, don't create file
    log_event "NO_FILE" "No version file for terminal_$terminal_id, skipping exit hook"
fi

exit 0
