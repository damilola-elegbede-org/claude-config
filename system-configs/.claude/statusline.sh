#!/bin/bash
# Claude Code StatusLine Configuration
# Shows: model | git_branch | directory | output_mode | version | context_window_%
# Per-terminal version tracking: Each terminal shows ✨ when IT first sees a new version
#
# FALLBACK BEHAVIOR:
# - When Claude Code passes empty/invalid JSON: shows "Claude" model, current dir, "default" style
# - When Claude Code passes valid JSON: uses provided data with smart defaults
# - Invalid/unknown versions default to 1.0.100
# - Always maintains per-terminal version tracking and git branch detection
#
# HOW IT WORKS:
# - Uses stable terminal identifier (grandparent PID + pwd hash)
# - Terminal files store VERSION:FLAG format (e.g., "1.0.102:1")
# - FLAG=1 means show stars, FLAG=0 means don't show stars
# - Shows ✨ when FLAG=1 in the terminal's tracking file
# - New terminals create file with FLAG=1
# - Version changes update file with FLAG=1
# - Same version keeps existing flag
# - No interference between different terminal windows
# - Auto-cleanup of tracking files after 7 days
#
# STAR LOGIC:
# - File format: VERSION:FLAG (e.g., "1.0.102:1")
# - New terminal: creates file with VERSION:1 (show stars)
# - Version change: updates file with NEW_VERSION:1 (show stars)
# - Same version: reads existing flag from file
# - Unknown/invalid version: defaults to 1.0.100:1
#
# TEST MODE:
# - Pass --test flag to use .tmp/terminal_versions/ instead of ~/.claude/terminal_versions/
# - This isolates test logs from production logs

# Star expiry window (in seconds). Default: 6 hours.
STAR_EXPIRY_SECS=${STAR_EXPIRY_SECS:-21600}

# Parse command-line arguments
TEST_MODE=0
if [[ "$1" == "--test" ]]; then
    TEST_MODE=1
    shift  # Remove --test from arguments
fi

# Read Claude session data from stdin
input=$(cat)

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for statusline.sh\n' >&2
  exit 0
fi

# Check if input is empty or invalid JSON and set fallback values
if [[ -z "$input" ]] || ! echo "$input" | jq . >/dev/null 2>&1; then
  # No data or invalid JSON from Claude Code - use sensible defaults
  model_name="Claude"
  current_dir=$(basename "$PWD")
  output_style="default"
  version="unknown"
  context_pct="--"
  session_name=""
else
  # Valid JSON input - extract all fields in a single jq call to reduce process overhead
  jq_output=$(printf '%s' "$input" | jq -r --arg pwd "$PWD" '[
    (.model.display_name // "Claude"),
    (.workspace.current_dir // .cwd // $pwd),
    (.output_style.name // "default"),
    (.version // "unknown"),
    ((.context_window.used_percentage // "") | tostring),
    (.session_name // "")
  ] | @tsv')
  IFS=$'\t' read -r model_name raw_dir output_style version context_pct session_name <<< "$jq_output"
  current_dir=$(basename "$raw_dir")
fi

# Validate & normalize context percentage
if [[ -z "$context_pct" ]] || ! [[ "$context_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  context_pct="--"
fi

# Color threshold logic for context window percentage
if [[ "$context_pct" == "--" ]]; then
  ctx_color='\033[90m'; ctx_display="--"
else
  ctx_int=${context_pct%.*}
  [[ -n "$ctx_int" ]] || ctx_int="0"
  ctx_display="${ctx_int}%"
  if [[ $ctx_int -ge 90 ]]; then ctx_color='\033[31m'        # Red
  elif [[ $ctx_int -ge 80 ]]; then ctx_color='\033[38;5;208m' # Orange
  elif [[ $ctx_int -ge 65 ]]; then ctx_color='\033[33m'       # Yellow
  else ctx_color='\033[32m'; fi                                # Green
fi

# Get git branch (fallback if git command fails)
git_branch=$(git branch --show-current 2>/dev/null || echo "")
[[ -n "$git_branch" ]] || git_branch="no-git"

# Get terminal identifier based on grandparent PID only

# Get grandparent PID - required for terminal identification
if ! ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' '); then
    printf 'Error: Unable to get parent PID for statusline\n' >&2
    exit 1
fi

if ! gppid=$(ps -o ppid= -p $ppid 2>/dev/null | tr -d ' '); then
    printf 'Error: Unable to get grandparent PID for statusline\n' >&2
    exit 1
fi

# Use grandparent PID (terminal emulator) for stability across directories
raw_id="terminal_${gppid}"
terminal_id="$(printf '%s' "$raw_id" | tr '/\n' '_' | tr -cd 'A-Za-z0-9._-')"

[[ -n "$terminal_id" ]] || terminal_id="fallback_$$"

# Version tracking files
if [[ "$TEST_MODE" -eq 1 ]]; then
    # Test mode: use test directory specified by environment variable or default
    if [[ -n "${CLAUDE_TEST_DIR:-}" ]]; then
        version_dir="${CLAUDE_TEST_DIR}"
        terminal_versions_dir="${version_dir}/terminal_versions"
    else
        version_dir=".tmp"
        terminal_versions_dir="$version_dir/terminal_versions"
    fi
else
    # Production mode: use ~/.claude/terminal_versions/
    version_dir="$HOME/.claude"
    terminal_versions_dir="$version_dir/terminal_versions"
fi
terminal_version_file="$terminal_versions_dir/${terminal_id}"

# Handle unknown/invalid version - use default 1.0.100
if [[ "$version" == "unknown" ]] || [[ -z "$version" ]]; then
    version="1.0.100"
fi

# Extract semantic version (e.g., "1.0.102" from "1.0.102:uuid:uuid")
semantic_version="${version%%:*}"

# Validate semantic version format - use default if invalid
if [[ ! "$semantic_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    semantic_version="1.0.100"
    version="1.0.100"  # Also update display version
fi

version_display="$version"

# Create terminal versions directory if needed
mkdir -p -m 700 "$terminal_versions_dir" 2>/dev/null || true

# Logging functionality for debugging
log_file="$terminal_versions_dir/events.log"

# Function to rotate log file when it exceeds 10MB
rotate_log_file() {
    local file_path="$1"

    if [[ ! -f "$file_path" ]]; then
        return 0
    fi

    # Get file size - works on both macOS and Linux
    local file_size
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        file_size=$(stat -f %z "$file_path" 2>/dev/null || echo "0")
    else
        # Linux
        file_size=$(stat -c %s "$file_path" 2>/dev/null || echo "0")
    fi

    # Check if file exceeds 10MB (10485760 bytes)
    if [[ $file_size -gt 10485760 ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local rotated_file="${file_path%.*}_${timestamp}.log"

        # Move current log to rotated file
        mv "$file_path" "$rotated_file" 2>/dev/null || return 1

        # Compress the rotated file in background
        (gzip "$rotated_file" 2>/dev/null || true) &

        # Create new empty log file with proper permissions
        touch "$file_path" 2>/dev/null || true
        chmod 600 "$file_path" 2>/dev/null || true

        # Log the rotation event to the new file
        local rotation_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        printf '[%s] [STATUSLINE] [LOG_ROTATE] PID:%s Rotated log to %s (size: %s bytes)\n' \
            "$rotation_timestamp" "$$" "$rotated_file.gz" "$file_size" >> "$file_path" 2>/dev/null || true
    fi
}

log_event() {
    local event_type="$1"
    local details="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Check for log rotation before writing
    rotate_log_file "$log_file"

    printf '[%s] [STATUSLINE] [%s] PID:%s TERM:%s VER:%s %s\n' \
        "$timestamp" "$event_type" "$$" "$terminal_id" "$semantic_version" "$details" >> "$log_file" 2>/dev/null || true
}

# Function to expire stale stars (files >6 hours old with flag=1)
expire_stale_stars() {
    local file_path="$1"

    if [[ ! -f "$file_path" ]]; then
        return 0
    fi

    # Get file modification time - works on both macOS and Linux
    local mod_time
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        mod_time=$(stat -f %m "$file_path" 2>/dev/null || echo "0")
    else
        # Linux
        mod_time=$(stat -c %Y "$file_path" 2>/dev/null || echo "0")
    fi

    local current_time=$(date +%s)
    local age_seconds=$((current_time - mod_time))
    local age_minutes=$((age_seconds / 60))

    # Check if file age exceeds configured expiry window
    if [[ $age_seconds -gt ${STAR_EXPIRY_SECS} ]]; then
        # Read current content
        local stored_content=$(cat "$file_path" 2>/dev/null || echo "")

        # Parse VERSION:FLAG format
        if [[ "$stored_content" =~ ^([^:]+):([01])$ ]]; then
            local stored_version="${BASH_REMATCH[1]}"
            local stored_flag="${BASH_REMATCH[2]}"

            # If flag=1, reset it to flag=0
            if [[ "$stored_flag" == "1" ]]; then
                local tmp_file="$(mktemp "$terminal_versions_dir/.tmp.XXXXXX" 2>/dev/null || printf '%s' "$terminal_versions_dir/.tmp.$$")"
                umask 077
                printf '%s:0' "$stored_version" > "$tmp_file" 2>/dev/null || true
                chmod 600 "$tmp_file" 2>/dev/null || true
                mv -f "$tmp_file" "$file_path" 2>/dev/null || true
                log_event "STAR_EXPIRED" "File age ${age_minutes} minutes, reset flag from 1 to 0 for version $stored_version"
            fi
        fi
    fi
}

# Per-Terminal Version Tracking: Store VERSION:FLAG format
# Only show stars if this is a new Claude session (file doesn't exist)
show_stars=false

if [[ ! -f "$terminal_version_file" ]]; then
    # New Claude session - create file with VERSION:1 (show stars)
    tmp_file="$(mktemp "$terminal_versions_dir/.tmp.XXXXXX" 2>/dev/null || printf '%s' "$terminal_versions_dir/.tmp.$$")"
    umask 077
    printf '%s:1' "$semantic_version" > "$tmp_file" 2>/dev/null || true
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$terminal_version_file" 2>/dev/null || true
    show_stars=true
    log_event "CREATE" "New terminal session, created file with flag=1 (show stars) from PWD: $PWD"
else
    # Check for stale stars before processing the file
    expire_stale_stars "$terminal_version_file"
    # File exists - read and parse the content
    stored_content=$(cat "$terminal_version_file" 2>/dev/null || echo "")

    # Parse VERSION:FLAG format
    if [[ "$stored_content" =~ ^([^:]+):([01])$ ]]; then
        stored_version="${BASH_REMATCH[1]}"
        stored_flag="${BASH_REMATCH[2]}"
    else
        # Old format or corrupted - treat as version only
        stored_version="$stored_content"
        stored_flag="0"
    fi

    # Check if version changed
    if [[ "$stored_version" != "$semantic_version" ]]; then
        # Version changed - update file with new VERSION:1 (show stars for new version)
        tmp_file="$(mktemp "$terminal_versions_dir/.tmp.XXXXXX" 2>/dev/null || printf '%s' "$terminal_versions_dir/.tmp.$$")"
        umask 077
        printf '%s:1' "$semantic_version" > "$tmp_file" 2>/dev/null || true
        chmod 600 "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$terminal_version_file" 2>/dev/null || true
        show_stars=true  # Show stars for new version
        log_event "UPDATE" "Version changed from $stored_version (flag=$stored_flag) to $semantic_version, set flag=1 (show stars) from PWD: $PWD"
    else
        # Same version - use stored flag
        if [[ "$stored_flag" == "1" ]]; then
            show_stars=true
            log_event "READ" "Same version, flag=$stored_flag (show stars) from PWD: $PWD"
        else
            show_stars=false
            log_event "READ" "Same version, flag=$stored_flag (no stars) from PWD: $PWD"
        fi
    fi
fi

# Set version display based on star status (persistent for the session)
if [[ "$show_stars" == "true" ]]; then
    version_display="$version ✨"
fi

# Comprehensive cleanup function for log rotation and file maintenance
perform_cleanup() {
    local versions_dir="$1"

    if [[ ! -d "$versions_dir" ]]; then
        return 0
    fi

    # Skip cleanup if we've done it recently (within last hour) to improve performance
    local cleanup_marker="$versions_dir/.last_cleanup"
    if [[ -f "$cleanup_marker" ]]; then
        local current_time=$(date +%s)
        local marker_time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            marker_time=$(stat -f %m "$cleanup_marker" 2>/dev/null || echo "0")
        else
            # Linux
            marker_time=$(stat -c %Y "$cleanup_marker" 2>/dev/null || echo "0")
        fi

        # If marker is less than 1 hour old, skip cleanup
        if [[ $((current_time - marker_time)) -lt 3600 ]]; then
            return 0
        fi
    fi

    # Update cleanup marker
    touch "$cleanup_marker" 2>/dev/null || true

    # 30-day cleanup: Remove old terminal_* files (but not events.log)
    find -P "$versions_dir" -type f -name "terminal_*" -mtime +30 -delete 2>/dev/null || true

    # 30-day cleanup: Remove old rotated events_*.log* files (but NEVER the main events.log)
    find -P "$versions_dir" -type f -name "events_*.log*" -mtime +30 -delete 2>/dev/null || true

    # Also clean up any temporary files that might be left behind
    find -P "$versions_dir" -type f -name ".tmp.*" -mtime +1 -delete 2>/dev/null || true

    # Log cleanup activity
    if [[ -f "$versions_dir/events.log" ]]; then
        local cleanup_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        printf '[%s] [STATUSLINE] [CLEANUP] PID:%s Performed 30-day cleanup in %s\n' \
            "$cleanup_timestamp" "$$" "$versions_dir" >> "$versions_dir/events.log" 2>/dev/null || true
    fi
}

# Perform cleanup with new 30-day retention policy
perform_cleanup "$terminal_versions_dir"

# Clean up legacy files from old implementations
rm -f "$version_dir/acknowledged_version" "$version_dir/notified_session" 2>/dev/null || true

# Reset any previous formatting first
printf '\033[0m'

# Session name: leading magenta segment, shown only when the session has a name
if [[ -n "$session_name" ]]; then
  printf '\033[35m%s\033[0m \033[90m•\033[0m ' "$session_name"
fi

# Output with colors
# Model: red | Branch: orange | Dir: cyan | Style: yellow | Version: green (with ✨ if new) | Context: dynamic color
# Using • (bullet) as separator
printf '\033[31m%s\033[0m \033[90m•\033[0m \033[38;5;208m%s\033[0m \033[90m•\033[0m \033[36m%s\033[0m \033[90m•\033[0m \033[33m%s\033[0m \033[90m•\033[0m \033[32m%s\033[0m \033[90m•\033[0m '"${ctx_color}"'%s\033[0m\n' \
  "$model_name" \
  "$git_branch" \
  "$current_dir" \
  "$output_style" \
  "$version_display" \
  "$ctx_display"
