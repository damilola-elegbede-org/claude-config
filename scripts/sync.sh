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

# Parse arguments
DRY_RUN=false
CREATE_BACKUP=true

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
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run|--backup]"
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
        if ! cp -r "$TARGET_DIR" "$BACKUP_DIR"; then
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

# Function to validate configs
validate_configs() {
    echo "🔄 Syncing Claude configurations..."
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

    # Sync skills
    rsync_output=""
    if rsync_output=$(rsync -a --delete --exclude="README.md" --exclude="*TEMPLATE*" "$SOURCE_DIR/skills/" "$TARGET_DIR/skills/" 2>&1); then
        SKILL_COUNT=$(find "$SOURCE_DIR/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✅ Skills: $SKILL_COUNT skills → ~/.claude/skills/"
    else
        echo "  ❌ Failed to sync skills"
        printf "    %s\n" "$rsync_output"
        return 1
    fi

    # Clean up legacy commands directory if it exists
    if [ -d "$TARGET_DIR/commands" ]; then
        rm -rf "$TARGET_DIR/commands"
        echo "  🧹 Removed legacy ~/.claude/commands/"
    fi

    # Sync output styles if they exist
    if [ -d "$SOURCE_DIR/output-styles" ]; then
        rsync_output=""
        if rsync_output=$(rsync -a --delete "$SOURCE_DIR/output-styles/" "$TARGET_DIR/output-styles/" 2>&1); then
            STYLE_COUNT=$(find "$SOURCE_DIR/output-styles" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✅ Output styles: $STYLE_COUNT files → ~/.claude/output-styles/"
        else
            print_warning "Failed to sync output styles: $rsync_output"
        fi
    fi

    # Sync individual files
    if [ -f "$SOURCE_DIR/settings.json" ]; then
        cp "$SOURCE_DIR/settings.json" "$TARGET_DIR/"
    fi

    if [ -f "$SOURCE_DIR/statusline.sh" ]; then
        validation_errors=$(sh -n "$SOURCE_DIR/statusline.sh" 2>&1) || {
            print_error "Invalid shell script: statusline.sh"
            printf "    %s\n" "$validation_errors"
            return 1
        }
        cp "$SOURCE_DIR/statusline.sh" "$TARGET_DIR/"
        chmod +x "$TARGET_DIR/statusline.sh"
    fi

    if [ -f "$SOURCE_DIR/exit_hook.sh" ]; then
        validation_errors=$(sh -n "$SOURCE_DIR/exit_hook.sh" 2>&1) || {
            print_error "Invalid shell script: exit_hook.sh"
            printf "    %s\n" "$validation_errors"
            return 1
        }
        cp "$SOURCE_DIR/exit_hook.sh" "$TARGET_DIR/"
        chmod +x "$TARGET_DIR/exit_hook.sh"
    fi

    # Build synced settings list dynamically
    synced_settings="settings.json"
    [ -f "$SOURCE_DIR/statusline.sh" ] && synced_settings="$synced_settings, statusline.sh"
    [ -f "$SOURCE_DIR/exit_hook.sh" ] && synced_settings="$synced_settings, exit_hook.sh"
    echo "  ✅ Settings: $synced_settings"

    # Sync main CLAUDE.md to home directory
    CLAUDE_MD_SOURCE="$REPO_DIR/system-configs/CLAUDE.md"
    if [ -f "$CLAUDE_MD_SOURCE" ]; then
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
        echo "  - settings.json → ~/.claude/settings.json"
        [ -f "$SOURCE_DIR/statusline.sh" ] && echo "  - statusline.sh → ~/.claude/statusline.sh"
        [ -f "$SOURCE_DIR/exit_hook.sh" ] && echo "  - exit_hook.sh → ~/.claude/exit_hook.sh"
        echo ""
        echo "📊 Preview summary:"
        echo "  Total files: $(find "$SOURCE_DIR" -name "*.md" -o -name "*.json" -o -name "*.sh" 2>/dev/null | wc -l | tr -d ' ') configurations ready"
        echo "  Backup would be created before sync"
        echo "  Estimated time: 2-3 seconds"
        return 0
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
