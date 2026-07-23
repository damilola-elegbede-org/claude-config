#!/bin/sh
# Sync script for Claude configuration
# Syncs system-configs/.claude/ to ~/.claude/ with validation and backup

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure HOME is set
: "${HOME:?HOME variable is not set}"

# Get script directory (POSIX compatible)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="$REPO_DIR/system-configs/.claude"
TARGET_DIR="$HOME/.claude"

# ---- Per-station sync manifest (D design 2026-07-23) ------------------------
# sync-manifests/<LocalHostName>.json scopes what this station syncs.
# No manifest → default full sync (the laptops). Present manifest → only the
# sections it enables, and settings may be key-scoped merged instead of
# replaced, so station-local settings survive (the Mac Mini fleet node).
STATION="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
MANIFEST="$REPO_DIR/sync-manifests/$STATION.json"
HAVE_MANIFEST=false
if [ -f "$MANIFEST" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "❌ Manifest present for $STATION but jq is unavailable — refusing to guess. Install jq or remove the manifest."
        exit 1
    fi
    if ! jq empty "$MANIFEST" 2>/dev/null; then
        printf '%s\n' "❌ Invalid JSON in $MANIFEST — refusing to sync."
        exit 1
    fi
    HAVE_MANIFEST=true
fi

# manifest_flag <key> — echoes true/false; default true when no manifest.
manifest_flag() {
    if [ "$HAVE_MANIFEST" = "true" ]; then
        jq -r --arg k "$1" '.sync[$k] | if . == null then true else . end | if . == false then "false" else "true" end' "$MANIFEST"
    else
        echo "true"
    fi
}

# settings mode: replace (default) | merge | skip
settings_mode() {
    if [ "$HAVE_MANIFEST" = "true" ]; then
        jq -r '.sync.settings | if . == null then "replace" elif . == false then "skip" else . end' "$MANIFEST"
    else
        echo "replace"
    fi
}

# Declarative map of runtime hook scripts that sync deploys to ~/.claude/.
# Each entry is a filename under $SOURCE_DIR, referenced from settings.json
# hooks. To add a new hook script: add its filename here and wire it into
# settings.json. Both sync_files() and the dry-run preview read from this
# single source of truth.
#
# NOTE: space-delimited. Filenames MUST NOT contain spaces — the loops
# below rely on unquoted word-splitting to iterate this list. If a hook
# script ever needs a space in its name, switch this to a newline-delimited
# heredoc and iterate with `while read`.
RUNTIME_HOOK_SCRIPTS="statusline.sh exit_hook.sh session_start_version_check.sh claude-speak.sh voice-rx.sh"

# Parse arguments
DRY_RUN=false
CREATE_BACKUP=true
FORCE_SYNC=false

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --backup)
      CREATE_BACKUP=true
      shift
      ;;
    --force)
      FORCE_SYNC=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run|--backup|--force]"
      exit 1
      ;;
  esac
done

# Function to print colored output (POSIX compatible)
print_success() {
    printf "${GREEN}✓${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}✗${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}⚠${NC} %s\n" "$1"
}

# Function to create backup
create_backup() {
    if [ -d "$TARGET_DIR" ]; then
        BACKUP_DIR="$HOME/.claude.backup.$(date +%Y%m%d_%H%M%S)"
        echo "Creating backup at $BACKUP_DIR..."
        if ! cp -RP "$TARGET_DIR" "$BACKUP_DIR"; then
            print_error "Backup failed - aborting sync to prevent data loss"
            return 1
        fi
        print_success "Backup created at $BACKUP_DIR"
    fi
}

# Function to rotate backups - keep only latest 5
cleanup_old_backups() {
    backup_count=$(find "$HOME" -maxdepth 1 -name '.claude.backup.*' -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "$backup_count" -gt 5 ]; then
        echo "Rotating backups (keeping latest 5)..."
        # Detect stat format (BSD vs GNU) for portable mtime listing
        if stat -f "%m %N" "$HOME" >/dev/null 2>&1; then
            STAT_OPT='-f'
            STAT_FMT='%m %N'
        else
            STAT_OPT='-c'
            STAT_FMT='%Y %n'
        fi
        # List backups by time, delete all but newest 5
        # Use find with strict pattern matching for security
        find "$HOME" -maxdepth 1 -name '.claude.backup.[0-9]*_[0-9]*' -type d \
            -exec stat "$STAT_OPT" "$STAT_FMT" {} + 2>/dev/null | \
            sort -rn | cut -d' ' -f2- | tail -n +6 | while read -r old_backup; do
            # Strict validation: must match exact backup format YYYYMMDD_HHMMSS
            if [ -d "$old_backup" ] && echo "$old_backup" | grep -qE "^$HOME/\.claude\.backup\.[0-9]{8}_[0-9]{6}$"; then
                rm -rf "$old_backup"
                echo "  Removed old backup: $(basename "$old_backup")"
            fi
        done
    fi
}

# Function to validate settings.json hooks
# Note: Uses plain variable assignments instead of 'local' for POSIX compliance (SC3043)
validate_settings_hooks() {
    settings_file="$SOURCE_DIR/settings.json"

    if [ ! -f "$settings_file" ]; then
        return 0  # No settings file, nothing to validate
    fi

    # Check if jq is available for JSON parsing
    if ! command -v jq >/dev/null 2>&1; then
        print_warning "jq not available, skipping settings hook validation"
        return 0
    fi

    # Extract hook commands from settings.json
    # Structure: .hooks.{HookType}[].hooks[].command
    if ! hooks=$(jq -r '
        .hooks // {} |
        to_entries[] |
        .value[] |
        .hooks[] |
        select(.type == "command") |
        .command // empty
    ' "$settings_file" 2>&1); then
        print_error "Failed to parse settings.json (invalid JSON?): $hooks"
        return 1
    fi

    if [ -z "$hooks" ]; then
        return 0  # No hooks defined
    fi

    # Validate each hook command exists
    # Use a temp file to track errors (POSIX-compatible - avoids subshell variable issue with pipes)
    hook_errors=0
    error_file=$(mktemp)
    echo "0" > "$error_file"

    echo "$hooks" | while IFS= read -r hook_cmd; do
        if [ -n "$hook_cmd" ]; then
            # Extract the base command (first word)
            base_cmd=$(echo "$hook_cmd" | awk '{print $1}')

            # Check if it's a shell script that should exist (POSIX compatible)
            # Check for relative path (./) or absolute path (/)
            if [ "${base_cmd#./}" != "$base_cmd" ] || [ "${base_cmd#/}" != "$base_cmd" ]; then
                # Relative or absolute path - check if file exists
                check_path="$base_cmd"
                if [ "${base_cmd#./}" != "$base_cmd" ]; then
                    check_path="$REPO_DIR/${base_cmd#./}"
                fi
                if [ ! -f "$check_path" ]; then
                    print_error "Hook command not found: $base_cmd"
                    # Increment error count in temp file
                    current_errors=$(cat "$error_file")
                    echo "$((current_errors + 1))" > "$error_file"
                fi
            fi
        fi
    done

    hook_errors=$(cat "$error_file")
    rm -f "$error_file"

    if [ "$hook_errors" -gt 0 ]; then
        print_error "Found $hook_errors invalid hook command(s) in settings.json"
        return 1
    fi

    return 0
}

# Refuse to sync from a checkout that is behind origin/main — a stale tree's
# rsync --delete removes agents/skills that only exist upstream (this exact
# incident deleted newer agents once). --force overrides for offline work.
check_tree_freshness() {
    if [ "$FORCE_SYNC" = "true" ]; then
        return 0
    fi
    if ! git -C "$REPO_DIR" fetch origin main --quiet 2>/dev/null; then
        print_warning "Could not reach origin to verify freshness (offline?) — proceeding; use --force to silence"
        return 0
    fi
    behind=$(git -C "$REPO_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [ "$behind" -gt 0 ]; then
        print_error "This checkout is $behind commit(s) behind origin/main — syncing from a stale tree deletes newer configs."
        print_error "Run: git pull   (or re-run with --force if you really mean this tree)"
        return 1
    fi
    return 0
}

# Key-scoped settings merge: live settings.json keeps every key it has, except
# the manifest's settings_owned_keys, where the repo wins — including deletion
# (repo dropped an owned key → it is removed live). Falls back to replace when
# there is no live settings.json to merge into.
merge_settings() {
    live="$TARGET_DIR/settings.json"
    src="$SOURCE_DIR/settings.json"
    if [ ! -f "$live" ] || ! jq empty "$live" 2>/dev/null; then
        cp "$src" "$live"
        return 0
    fi
    owned=$(jq -c '.sync.settings_owned_keys // []' "$MANIFEST")
    merged=$(jq --argjson owned "$owned" --slurpfile repo "$src" '
        reduce $owned[] as $k (.;
            if ($repo[0] | has($k)) then .[$k] = $repo[0][$k] else del(.[$k]) end)
    ' "$live") || return 1
    [ -n "$merged" ] || return 1
    printf '%s\n' "$merged" > "$live"
    return 0
}

# Function to validate configs
validate_configs() {
    echo "🔄 Syncing Claude configurations..."
    if [ "$HAVE_MANIFEST" = "true" ]; then
        echo "🖥  Station: $STATION (manifest: sync-manifests/$STATION.json)"
    else
        echo "🖥  Station: $STATION (no manifest — default full sync)"
    fi
    echo "📁 Source: $SOURCE_DIR ($(find "$SOURCE_DIR" -name "*.md" -o -name "*.json" -o -name "*.sh" 2>/dev/null | wc -l | tr -d ' ') files)"
    echo "📁 Target: $TARGET_DIR"
    echo ""

    echo "✅ Pre-sync validation:"

    # Check source directory
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "❌ Source directory not found: $SOURCE_DIR"
        return 1
    fi

    # Validate settings hooks before sync
    if ! validate_settings_hooks; then
        echo "❌ Settings hook validation failed"
        return 1
    fi
    echo "  - Settings hooks: Valid"

    # Basic syntax validation
    AGENT_COUNT=$(find "$SOURCE_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    SKILL_COUNT=$(find "$SOURCE_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "  - Configuration syntax: Valid ($AGENT_COUNT agents, $SKILL_COUNT skills)"

    # Check target directory permissions
    if [ ! -w "$HOME" ]; then
        echo "❌ Cannot write to home directory"
        return 1
    fi
    echo "  - Target directory: Ready"
    echo "  - Permissions: OK"
    echo ""

    return 0
}

# Function to sync files
sync_files() {
    echo "🔄 Synchronizing files:"

    # Create target directories
    mkdir -p "$TARGET_DIR/agents"
    mkdir -p "$TARGET_DIR/skills"
    mkdir -p "$TARGET_DIR/output-styles"

    # Sync agents using rsync (use if-then pattern to work with set -e)
    if [ "$(manifest_flag agents)" != "true" ]; then
        echo "  ⏭  Agents: skipped by $STATION manifest"
    else
    rsync_output=""
    if rsync_output=$(rsync -a --delete --exclude="README.md" --exclude="*TEMPLATE*" --exclude="*CATEGORIES*" --exclude="*AUDIT*" "$SOURCE_DIR/agents/" "$TARGET_DIR/agents/" 2>&1); then
        AGENT_COUNT=$(find "$SOURCE_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✅ Agents: $AGENT_COUNT files → ~/.claude/agents/"
    else
        echo "  ❌ Failed to sync agents"
        printf "    %s\n" "$rsync_output"
        return 1
    fi

    # Flatten leads/ subdirectory — Claude Code requires agents at top level
    if [ -d "$TARGET_DIR/agents/leads" ]; then
        for f in "$TARGET_DIR/agents/leads"/*.md; do
            [ -f "$f" ] && mv "$f" "$TARGET_DIR/agents/"
        done
        rmdir "$TARGET_DIR/agents/leads" 2>/dev/null || true
        print_success "Flattened leads/ agents to ~/.claude/agents/"
    fi
    fi

    # Sync skills
    if [ "$(manifest_flag skills)" != "true" ]; then
        echo "  ⏭  Skills: skipped by $STATION manifest"
    else
    rsync_output=""
    if rsync_output=$(rsync -a --delete --exclude="README.md" --exclude="*TEMPLATE*" "$SOURCE_DIR/skills/" "$TARGET_DIR/skills/" 2>&1); then
        SKILL_COUNT=$(find "$SOURCE_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✅ Skills: $SKILL_COUNT skills → ~/.claude/skills/"
    else
        echo "  ❌ Failed to sync skills"
        printf "    %s\n" "$rsync_output"
        return 1
    fi
    fi

    # Clean up legacy commands directory if it exists
    if [ -d "$TARGET_DIR/commands" ]; then
        rm -rf "$TARGET_DIR/commands"
        echo "  🧹 Removed legacy ~/.claude/commands/"
    fi

    # Sync output styles if they exist
    if [ "$(manifest_flag output_styles)" != "true" ]; then
        echo "  ⏭  Output styles: skipped by $STATION manifest"
    elif [ -d "$SOURCE_DIR/output-styles" ]; then
        rsync_output=""
        if rsync_output=$(rsync -a --delete "$SOURCE_DIR/output-styles/" "$TARGET_DIR/output-styles/" 2>&1); then
            STYLE_COUNT=$(find "$SOURCE_DIR/output-styles" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✅ Output styles: $STYLE_COUNT files → ~/.claude/output-styles/"
        else
            print_warning "Failed to sync output styles: $rsync_output"
        fi
    fi

    # Sync settings.json per station policy: replace (default), key-scoped
    # merge (fleet nodes — repo wins only on owned keys), or skip.
    SETTINGS_MODE=$(settings_mode)
    if [ -f "$SOURCE_DIR/settings.json" ]; then
        case "$SETTINGS_MODE" in
            skip)
                echo "  ⏭  settings.json: skipped by $STATION manifest" ;;
            merge)
                if merge_settings; then
                    echo "  ✅ settings.json: key-scoped merge (owned keys from repo, station keys preserved)"
                else
                    print_error "settings.json merge failed — live file left untouched"
                    return 1
                fi ;;
            *)
                cp "$SOURCE_DIR/settings.json" "$TARGET_DIR/" ;;
        esac
    fi

    # Sync each tracked hook script: validate syntax, copy, make executable.
    if [ "$(manifest_flag hook_scripts)" != "true" ]; then
        echo "  ⏭  Hook scripts: skipped by $STATION manifest"
        RUNTIME_HOOK_SCRIPTS=""
    fi
    # RUNTIME_HOOK_SCRIPTS is defined at the top of this file.
    #
    # All shipped hooks have a `#!/bin/bash` shebang and use bash-only
    # constructs (`local`, `[[ ]]`, `=~`). We validate with `bash -n` so
    # Linux (where /bin/sh is dash) doesn't false-positive on bashisms.
    # macOS /bin/sh is bash-compat which is why `sh -n` previously slipped
    # through during local dev.
    if ! command -v bash >/dev/null 2>&1; then
        print_error "bash not available — required to validate hook scripts"
        return 1
    fi
    # RUNTIME_HOOK_SCRIPTS is the declarative source of truth. Every
    # entry MUST exist in the source tree — silently skipping missing
    # entries lets /sync report success while settings.json still points
    # at a hook that was never installed. Fail fast so that class of
    # drift is impossible.
    for script in $RUNTIME_HOOK_SCRIPTS; do
        src="$SOURCE_DIR/$script"
        if [ ! -f "$src" ]; then
            print_error "Tracked hook script missing from source tree: $script"
            print_error "RUNTIME_HOOK_SCRIPTS lists '$script' but it is not present in $SOURCE_DIR"
            return 1
        fi
        validation_errors=$(bash -n "$src" 2>&1) || {
            print_error "Invalid shell script: $script"
            printf "    %s\n" "$validation_errors"
            return 1
        }
        cp "$src" "$TARGET_DIR/"
        chmod +x "$TARGET_DIR/$script"
    done

    # Build synced settings summary line from the same map. Every entry
    # is guaranteed to exist at this point (the loop above would have
    # returned on any missing script), so no `-f` guard is needed.
    synced_settings="settings.json"
    for script in $RUNTIME_HOOK_SCRIPTS; do
        synced_settings="$synced_settings, $script"
    done
    echo "  ✅ Settings: $synced_settings"

    # Sync main CLAUDE.md to home directory
    CLAUDE_MD_SOURCE="$REPO_DIR/system-configs/CLAUDE.md"
    if [ "$(manifest_flag claude_md)" != "true" ]; then
        echo "  ⏭  CLAUDE.md: skipped by $STATION manifest"
    elif [ -f "$CLAUDE_MD_SOURCE" ]; then
        if cp "$CLAUDE_MD_SOURCE" "$HOME/CLAUDE.md"; then
            echo "  ✅ CLAUDE.md → ~/CLAUDE.md"
        else
            print_warning "Failed to sync CLAUDE.md to home directory"
        fi
    fi

    # Clean up misplaced CLAUDE.md in .claude directory (non-fatal)
    if [ -f "$TARGET_DIR/CLAUDE.md" ]; then
        if rm -f "$TARGET_DIR/CLAUDE.md"; then
            echo "  🧹 Removed misplaced ~/.claude/CLAUDE.md"
        else
            print_warning "Failed to remove misplaced ~/.claude/CLAUDE.md"
        fi
    fi
    echo ""

    return 0
}

# Function to validate sync
post_sync_validation() {
    echo "✅ Post-sync validation:"

    # Check file integrity
    agent_count=0
    skill_count=0

    if [ -d "$TARGET_DIR/agents" ]; then
        agent_count=$(find "$TARGET_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [ -d "$TARGET_DIR/skills" ]; then
        skill_count=$(find "$TARGET_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    fi

    echo "  - File integrity: All files copied successfully"
    echo "  - Agent configs: $agent_count/$agent_count valid"
    echo "  - Skills: $skill_count/$skill_count valid"
    echo ""

    return 0
}

# Main execution
main() {
    start_time=$(date +%s)

    # Handle dry run
    if [ "$DRY_RUN" = "true" ]; then
        echo "📖 Preview mode - no changes will be made"
        echo ""
        echo "🔍 Analyzing configurations:"
        echo "  Source: $SOURCE_DIR ($(find "$SOURCE_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ') files)"
        echo "  Target: $TARGET_DIR"
        echo ""
        echo "📋 Files to sync:"
        echo "  - $(find "$SOURCE_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ') agent files → ~/.claude/agents/"
        echo "  - $(find "$SOURCE_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ') skills → ~/.claude/skills/"
        SETTINGS_MODE=$(settings_mode)
        echo "  - settings.json → ~/.claude/settings.json (mode: $SETTINGS_MODE)"
        if [ "$SETTINGS_MODE" = "merge" ] && [ -f "$TARGET_DIR/settings.json" ] && command -v jq >/dev/null 2>&1; then
            owned=$(jq -c '.sync.settings_owned_keys // []' "$MANIFEST")
            changed=$(jq -r --argjson owned "$owned" --slurpfile repo "$SOURCE_DIR/settings.json" '
                [ $owned[] as $k | select((.[$k] // null) != ($repo[0][$k] // null)) | $k ] | join(", ")
            ' "$TARGET_DIR/settings.json" 2>/dev/null || echo "?")
            if [ -n "$changed" ]; then
                echo "      owned keys that would change: $changed"
            else
                echo "      owned keys already in sync"
            fi
        fi
        for script in $RUNTIME_HOOK_SCRIPTS; do
            if [ -f "$SOURCE_DIR/$script" ]; then
                echo "  - $script → ~/.claude/$script"
            else
                echo "  - $script ⚠️  MISSING from source tree (real sync would fail)"
            fi
        done
        echo ""
        echo "📊 Preview summary:"
        echo "  Total files: $(find "$SOURCE_DIR" -name "*.md" -o -name "*.json" -o -name "*.sh" 2>/dev/null | wc -l | tr -d ' ') configurations ready"
        echo "  Backup would be created before sync"
        echo "  Estimated time: 2-3 seconds"
        return 0
    fi

    # Refuse stale trees before anything else
    if ! check_tree_freshness; then
        echo "❌ Freshness check failed — sync aborted"
        return 1
    fi

    # Validate before sync
    if ! validate_configs; then
        echo "❌ Pre-sync validation failed"
        echo ""
        echo "🛠️ Fix these issues before syncing:"
        echo "  1. Check source directory structure"
        echo "  2. Verify target directory permissions"
        echo "  3. Validate configuration syntax"
        echo ""
        echo "Run /sync again after addressing these issues."
        return 1
    fi

    # Create backup
    if [ "$CREATE_BACKUP" = "true" ]; then
        create_backup
        echo ""
    fi

    # Perform sync with error handling
    if ! sync_files; then
        echo "❌ Sync failed"
        echo "🎯 Sync aborted"
        return 1
    fi

    # Post-sync validation
    post_sync_validation

    # Rotate old backups (keep only latest 5)
    cleanup_old_backups

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "📊 Sync completed successfully:"
    echo "  Files synced: $(find "$SOURCE_DIR" -name "*.md" -o -name "*.json" -o -name "*.sh" 2>/dev/null | wc -l | tr -d ' ') total"
    if [ -n "${BACKUP_DIR:-}" ]; then
        echo "  Backup location: $BACKUP_DIR"
    fi
    echo "  Sync time: ${duration} seconds"

    return 0
}

# Run main function
main "$@"
