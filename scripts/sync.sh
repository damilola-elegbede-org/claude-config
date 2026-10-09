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

# mods_exclude_names — echoes the manifest's sync.mods_exclude, one name per
# line (nothing without a manifest). Fails, the reason as its output, on a
# value that is not an array of mod names or that names a local-* mod.
mods_exclude_names() {
    [ "$HAVE_MANIFEST" = "true" ] || return 0
    jq -r '(.sync.mods_exclude // []) as $x
        | if ($x | type) != "array" then error("mods_exclude must be an array of mod names")
          else $x[] | if type == "string" and test("^[A-Za-z0-9_-][A-Za-z0-9_.-]*$") and (startswith("local-") | not)
            then . else error("invalid mods_exclude entry: \(tojson)") end end' "$MANIFEST" 2>&1
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
# Each entry is a path relative to $SOURCE_DIR, deployed to the same relative
# path under ~/.claude/. Scripts that only run as hooks live in hooks/ (the
# Claude Code docs' convention); statusline, CLI helpers, and LaunchAgent
# programs stay at the top level. To add a new hook script: add its path here
# and wire it into settings.json. Both sync_files() and the dry-run preview
# read from this single source of truth.
#
# NOTE: space-delimited. Filenames MUST NOT contain spaces — the loops
# below rely on unquoted word-splitting to iterate this list. If a hook
# script ever needs a space in its name, switch this to a newline-delimited
# heredoc and iterate with `while read`.
RUNTIME_HOOK_SCRIPTS="statusline.sh hooks/exit_hook.sh hooks/session_start_version_check.sh claude-speak.sh voice-rx.sh hooks/session_registry.sh hooks/gate.sh resume_sessions.sh restart_on_update.sh papercut.sh archive-papercuts.sh"

# Non-script runtime data deployed next to the hooks (copied as-is, validated as
# JSON instead of `bash -n`, never made executable). gate.sh reads its rules from
# the same directory it is deployed to. Same space-delimited rule as above.
RUNTIME_HOOK_DATA="hooks/gate-rules.json"
# Phase 4 (rules, lifecycle events, workflow helpers). .sh only: this list is bash -n'd.
RUNTIME_HOOK_SCRIPTS="$RUNTIME_HOOK_SCRIPTS hooks/jev/registry.sh hooks/jev/rules-events-lib.sh hooks/jev/executive-lint.sh hooks/jev/file-org-guard.sh hooks/jev/pr-draft-guard.sh hooks/jev/pr-landing-gate.sh hooks/jev/pr-land-status.sh hooks/jev/retry-counter.sh hooks/jev/papercut-grep.sh hooks/jev/papercut-nudge.sh hooks/jev/papercut-dedupe.sh hooks/jev/memory-dup-guard.sh hooks/jev/stopfailure-hint.sh hooks/jev/session-start-project.sh hooks/jev/session-end-memory.sh hooks/jev/notification-urgency.sh hooks/jev/postcompact-log.sh hooks/jev/failure-classify.sh hooks/jev/session-check.sh hooks/jev/link-lint.sh hooks/jev/link-validate.sh hooks/jev/audit-digest.sh"
# Jev decision gates (Phase 2).
RUNTIME_HOOK_SCRIPTS="$RUNTIME_HOOK_SCRIPTS hooks/jev-gate.sh hooks/jev-gate-lib.sh hooks/jev-ask-channel.sh"
# Jev context/cost hooks (Phase 3, A1-A9) + their shared lib.
RUNTIME_HOOK_SCRIPTS="$RUNTIME_HOOK_SCRIPTS hooks/jev/ctx-lib.sh hooks/jev/a1-read-trim.sh hooks/jev/a2-search-rank.sh hooks/jev/a3-bash-trim.sh hooks/jev/a4-task-boundary.sh hooks/jev/a5-compact-reinject.sh hooks/jev/a6-agent-router.sh hooks/jev/a7-a8-prompt-context.sh hooks/jev/a9-skill-router.sh"
RUNTIME_HOOK_DATA="$RUNTIME_HOOK_DATA hooks/jev/rules.d/context.json hooks/jev/rules.d/skills.json"

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

# papercuts.md is runtime data, not configuration.  It deliberately does not
# exist in system-configs/.claude, so none of the scoped rsync --delete calls
# can own it.  Initialising it still shares papercut.sh's directory lock: an
# append that races the first /sync must not be replaced by the header.
initialize_papercut_log() {
    papercut_log="$TARGET_DIR/papercuts.md"
    papercut_lock="$TARGET_DIR/.papercuts.md.papercut.lock"
    PAPERCUT_LOCK_STALE_SECONDS="${PAPERCUT_LOCK_STALE_SECONDS:-300}"
    PAPERCUT_LOCK_ATTEMPTS="${PAPERCUT_LOCK_ATTEMPTS:-3000}"
    papercut_tmp=''
    papercut_lock_held=0

    [ -e "$papercut_log" ] || [ -L "$papercut_log" ] && return 0

    papercut_lock_directory_mtime() {
        /usr/bin/perl -e 'my @stat = stat $ARGV[0]; exit 1 unless @stat; print "$stat[9]\n"' "$1"
    }

    papercut_lock_is_reclaimable() {
        papercut_now="$(date -u +%s)"
        if [ ! -f "$papercut_lock/owner" ]; then
            papercut_mtime="$(papercut_lock_directory_mtime "$papercut_lock")" || return 1
            [ "$((papercut_now - papercut_mtime))" -ge "$PAPERCUT_LOCK_STALE_SECONDS" ]
            return
        fi
        papercut_pid=''; papercut_acquired=''
        if ! { read -r papercut_pid && read -r papercut_acquired; } 2>/dev/null <"$papercut_lock/owner"; then
            papercut_invalid_owner=1
        else
            case "${papercut_pid:-}:${papercut_acquired:-}" in
                *[!0-9:]*|:*|*:) papercut_invalid_owner=1 ;;
                *) papercut_invalid_owner=0 ;;
            esac
        fi
        if [ "$papercut_invalid_owner" -eq 1 ]; then
            papercut_mtime="$(papercut_lock_directory_mtime "$papercut_lock")" || return 1
            [ "$((papercut_now - papercut_mtime))" -ge "$PAPERCUT_LOCK_STALE_SECONDS" ]
            return
        fi
        if ! kill -0 "$papercut_pid" 2>/dev/null; then
            return 0
        fi
        # An old acquisition time alone cannot expire a live owner: macOS can sleep
        # longer than the stale bound. Compare the PID's actual start time instead,
        # so only a PID recycled after this lock was acquired is reclaimable.
        papercut_etime="$(ps -o etime= -p "$papercut_pid" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
        [ -n "$papercut_etime" ] || return 1
        papercut_elapsed="$(/usr/bin/perl -e '
            my $etime = shift;
            if ($etime =~ /^(?:(\d+)-)?(\d+):(\d\d):(\d\d)$/) {
              print (($1 // 0) * 86400 + $2 * 3600 + $3 * 60 + $4), qq{\n};
            } elsif ($etime =~ /^(\d+):(\d\d)$/) {
              print ($1 * 60 + $2), qq{\n};
            } else {
              exit 1;
            }
          ' "$papercut_etime")" || return 1
        papercut_process_started=$((papercut_now - papercut_elapsed))
        [ "$papercut_process_started" -gt "$((papercut_acquired + 2))" ]
    }

    papercut_reclaim_marker_is_stale() {
        papercut_now="$(date -u +%s)"
        papercut_mtime="$(papercut_lock_directory_mtime "$papercut_lock.reclaiming")" || return 1
        [ "$((papercut_now - papercut_mtime))" -ge 60 ]
    }

    for papercut_attempt in $(seq 1 "$PAPERCUT_LOCK_ATTEMPTS"); do
        if mkdir "$papercut_lock" 2>/dev/null; then
            papercut_lock_held=1
            printf '%s\n%s\n' "$$" "$(date -u +%s)" >"$papercut_lock/owner"
            break
        fi
        if papercut_lock_is_reclaimable; then
            { read -r papercut_pid && read -r papercut_acquired; } 2>/dev/null <"$papercut_lock/owner" || true
            case "${papercut_pid:-}:${papercut_acquired:-}" in
                *[!0-9:]*|:*|*:)
                    reclaim_marker="$papercut_lock.reclaiming"
                    if [ -d "$reclaim_marker" ] && papercut_reclaim_marker_is_stale; then
                        rmdir "$reclaim_marker" 2>/dev/null || true
                        continue
                    fi
                    if mkdir "$reclaim_marker" 2>/dev/null; then
                        if papercut_lock_is_reclaimable; then
                            rm -rf "$papercut_lock"
                        fi
                        rmdir "$reclaim_marker" 2>/dev/null || true
                    fi
                    ;;
                *)
                    if papercut_lock_is_reclaimable; then
                        reclaim_marker="$papercut_lock.reclaiming"
                        if [ -d "$reclaim_marker" ] && papercut_reclaim_marker_is_stale; then
                            rmdir "$reclaim_marker" 2>/dev/null || true
                            continue
                        fi
                        if mkdir "$reclaim_marker" 2>/dev/null; then
                            # Re-read the CURRENT owner inside the gate: another waiter may
                            # have reclaimed and re-acquired since the cached read above.
                            papercut_pid=''; papercut_acquired=''
                            { read -r papercut_pid && read -r papercut_acquired; } 2>/dev/null <"$papercut_lock/owner" || true
                            case "${papercut_pid:-}:${papercut_acquired:-}" in
                                *[!0-9:]*|:*|*:)
                                    if papercut_lock_is_reclaimable; then
                                        rm -rf "$papercut_lock"
                                    fi
                                    ;;
                                *)
                                    if papercut_lock_is_reclaimable; then
                                        rm -rf "$papercut_lock"
                                    fi
                                    ;;
                            esac
                            rmdir "$reclaim_marker" 2>/dev/null || true
                        fi
                    fi
                    ;;
            esac
        fi
        sleep 0.01
    done
    if [ "$papercut_lock_held" -ne 1 ]; then
        print_error "Timed out waiting to initialise $papercut_log"
        return 1
    fi

    # Recheck inside the shared lock.  The helper may have created and
    # appended the log just before this process acquired the lock.
    if [ ! -e "$papercut_log" ] && [ ! -L "$papercut_log" ]; then
        papercut_tmp=$(mktemp "$TARGET_DIR/.papercuts.md.sync.XXXXXX") || return 1
        {
            printf '%s\n' '# Papercuts'
            printf '%s\n' 'A factual log of small tooling failures and their fixes.'
            printf '%s\n' 'Format: date (UTC) · source · symptom · fix · project/path'
            printf '%s\n' 'Append via ~/.claude/papercut.sh; never edit or reorder entries.'
        } >"$papercut_tmp"
        mv -f "$papercut_tmp" "$papercut_log"
        papercut_tmp=''
        echo "  ✅ Papercuts log initialised at ~/.claude/papercuts.md"
    fi

    rm -f "$papercut_lock/owner"
    rmdir "$papercut_lock" 2>/dev/null || true
    return 0
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
        # Detect stat format (GNU first: `stat -f` on Linux is file-system mode and succeeds) for portable mtime listing
        if stat -c '%Y %n' "$HOME" >/dev/null 2>&1; then
            STAT_OPT='-c'
            STAT_FMT='%Y %n'
        else
            STAT_OPT='-f'
            STAT_FMT='%m %N'
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

# jq def shared by merge_settings' merge path and its no-live-file init path:
# strips any hook entry whose command matches a hooks_silence_command_contains
# substring (content-matched, not event-matched — a future sound hook is
# caught wherever it's added, and a future non-sound hook on an otherwise-
# silenced event still syncs), then drops matcher blocks and event keys left
# empty by the filter.
JQ_SILENCE_HOOKS_DEF=$(cat <<'JQ'
def silence_hooks(patterns):
    if (patterns | length) == 0 then . else
        to_entries
        | map(.value |= (
            map(.hooks |= map(select(((.command // "") as $c | patterns | any(. as $p | $c | contains($p))) | not)))
            | map(select((.hooks | length) > 0))
          ))
        | map(select((.value | length) > 0))
        | from_entries
    end;
JQ
)

# Key-scoped settings merge: live settings.json keeps every key it has, except
# the manifest's settings_owned_keys, where the repo wins — including deletion
# (repo dropped an owned key → it is removed live). "hooks" is an owned key
# like any other, except its value is passed through silence_hooks() first,
# so a station can be denylisted off sound-producing hooks specifically,
# rather than off whole hook events. Falls back to replace-from-repo (still
# filtered — a missing/invalid live file must not bypass the denylist) when
# there is no live settings.json to merge into.
merge_settings() {
    live="$TARGET_DIR/settings.json"
    src="$SOURCE_DIR/settings.json"
    silence=$(jq -c '.sync.hooks_silence_command_contains // []' "$MANIFEST")
    if [ ! -f "$live" ] || ! jq empty "$live" 2>/dev/null; then
        init=$(jq --argjson silence "$silence" "$JQ_SILENCE_HOOKS_DEF"'
            if has("hooks") then .hooks |= silence_hooks($silence) else . end
        ' "$src") || return 1
        [ -n "$init" ] || return 1
        printf '%s\n' "$init" > "$live"
        return 0
    fi
    owned=$(jq -c '.sync.settings_owned_keys // []' "$MANIFEST")
    merged=$(jq --argjson owned "$owned" --argjson silence "$silence" --slurpfile repo "$src" "$JQ_SILENCE_HOOKS_DEF"'
        reduce $owned[] as $k (.;
            if $k == "hooks" then
                if ($repo[0] | has("hooks")) then .hooks = ($repo[0].hooks | silence_hooks($silence)) else del(.hooks) end
            elif ($repo[0] | has($k)) then .[$k] = $repo[0][$k]
            else del(.[$k]) end)
    ' "$live") || return 1
    [ -n "$merged" ] || return 1
    printf '%s\n' "$merged" > "$live"
    return 0
}

# Install the plugins settings.json enables. enabledPlugins only declares
# on/off; Claude Code never installs from it, so a fresh machine would carry
# "enabled" plugins that were never fetched. Best-effort and idempotent: a
# failed install warns and never fails the sync. Updates after install are
# Claude Code's background auto-update, not this function: on by default only
# for claude-plugins-official, so settings.json's extraKnownMarketplaces sets
# autoUpdate for the other three.
sync_plugins() {
    if ! command -v claude >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        print_warning "claude or jq not found — plugin install skipped"
        return 0
    fi
    if ! enabled=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$SOURCE_DIR/settings.json"); then
        print_warning "could not read enabledPlugins from settings.json — plugin install skipped"
        return 0
    fi
    # Each inventory gates only its own loop: an unreadable list must not
    # read as "nothing installed" and trigger a re-add or re-install of everything.
    # "<marketplace name> <github repo>" — the name is what follows @ in enabledPlugins.
    if mkt_json=$(claude plugin marketplace list --json 2>/dev/null) \
        && marketplaces=$(printf '%s\n' "$mkt_json" | jq -r '.[].name'); then
        for entry in \
            "claude-plugins-official anthropics/claude-plugins-official" \
            "knowledge-work-plugins anthropics/knowledge-work-plugins" \
            "anthropic-agent-skills anthropics/skills" \
            "claude-community anthropics/claude-plugins-community"; do
            mkt_name=${entry% *}
            mkt_repo=${entry#* }
            if printf '%s\n' "$marketplaces" | grep -Fxq "$mkt_name"; then
                continue
            fi
            if claude plugin marketplace add "$mkt_repo" >/dev/null 2>&1; then
                echo "  ✅ marketplace added: $mkt_name"
            else
                print_warning "could not add marketplace $mkt_name ($mkt_repo) — its plugins will not install"
            fi
        done
    else
        print_warning "marketplace inventory unavailable — marketplace adds skipped"
    fi
    # Only user-scope installs count: a project- or local-scope copy seen from the
    # current directory does not make the plugin available everywhere.
    if inst_json=$(claude plugin list --json 2>/dev/null) \
        && installed=$(printf '%s\n' "$inst_json" | jq -r '.[] | select(.scope == "user") | .id'); then
        while IFS= read -r plugin; do
            [ -n "$plugin" ] || continue
            if printf '%s\n' "$installed" | grep -Fxq "$plugin"; then
                continue
            fi
            if claude plugin install --scope user "$plugin" >/dev/null 2>&1; then
                echo "  ✅ plugin installed: $plugin"
            else
                print_warning "plugin install failed: $plugin (run: claude plugin install $plugin)"
            fi
        done <<EOF
$enabled
EOF
    else
        print_warning "plugin inventory unavailable — plugin installs skipped"
    fi
    # LSP plugins ship without their language servers; say so instead of letting
    # Claude report an executable-not-found load error later.
    while IFS= read -r plugin; do
        case "$plugin" in
            pyright-lsp@*) lsp_bin=pyright-langserver; lsp_pkg=pyright ;;
            typescript-lsp@*) lsp_bin=typescript-language-server; lsp_pkg="typescript-language-server typescript" ;;
            *) continue ;;
        esac
        if ! command -v "$lsp_bin" >/dev/null 2>&1; then
            print_warning "$plugin needs $lsp_bin on PATH (install: npm install -g $lsp_pkg)"
        fi
    done <<EOF
$enabled
EOF
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

# Deploy hooks/jev/ (Jev client: shim, node client, configs, session check).
# Unlike RUNTIME_HOOK_SCRIPTS this is a directory with a node dependency, so
# it gets its own step: validate, rsync (runtime state and node_modules are
# excluded, so --delete never touches them), then `npm ci --omit=dev` ONLY when
# package.json / package-lock.json changed or node_modules is missing.
# JEV_SYNC_SKIP_NPM=1 skips the install (tests run sync against a temp HOME).
# An install failure warns but does not fail sync: Jev degrades to regex and
# the SessionStart check says so.
sync_jev_hooks() {
    jev_src="$SOURCE_DIR/hooks/jev"
    jev_dst="$TARGET_DIR/hooks/jev"
    if [ ! -d "$jev_src" ]; then
        print_error "Jev hooks missing from source tree: hooks/jev"
        return 1
    fi
    for jev_script in jev-ask session-check.sh; do
        if [ ! -f "$jev_src/$jev_script" ]; then
            print_error "Jev hook script missing from source tree: hooks/jev/$jev_script"
            return 1
        fi
        jev_err=$(bash -n "$jev_src/$jev_script" 2>&1) || {
            print_error "Invalid shell script: hooks/jev/$jev_script"
            printf "    %s\n" "$jev_err"
            return 1
        }
    done
    if command -v python3 >/dev/null 2>&1; then
        jev_err=$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$jev_src/skill-catalog.py" 2>&1) || {
            print_error "Invalid Python: hooks/jev/skill-catalog.py"
            printf "    %s\n" "$jev_err"
            return 1
        }
    fi
    if command -v node >/dev/null 2>&1; then
        jev_err=$(node --check "$jev_src/client.mjs" 2>&1) || {
            print_error "Invalid JavaScript: hooks/jev/client.mjs"
            printf "    %s\n" "$jev_err"
            return 1
        }
    fi

    jev_install=false
    if [ ! -d "$jev_dst/node_modules" ] \
        || [ ! -f "$jev_dst/node_modules/.jev-installed" ] \
        || ! cmp -s "$jev_src/package.json" "$jev_dst/package.json" 2>/dev/null \
        || ! cmp -s "$jev_src/package-lock.json" "$jev_dst/package-lock.json" 2>/dev/null; then
        jev_install=true
    fi

    mkdir -p "$jev_dst"
    if ! jev_out=$(rsync -a --delete --exclude='node_modules' --exclude='jev.sock' --exclude='jev.sock.spawn' --exclude='mcp-classes.json' --exclude='mcp-classes.lock' "$jev_src/" "$jev_dst/" 2>&1); then
        print_error "Failed to sync hooks/jev"
        printf "    %s\n" "$jev_out"
        return 1
    fi
    chmod +x "$jev_dst/jev-ask" "$jev_dst/session-check.sh"

    if [ "$jev_install" = "true" ]; then
        if [ -n "${JEV_SYNC_SKIP_NPM:-}" ]; then
            echo "  ⏭  Jev deps: npm ci skipped (JEV_SYNC_SKIP_NPM)"
        elif ! command -v npm >/dev/null 2>&1; then
            print_warning "npm not found - Jev client has no SDK; checkpoints fall back to regex"
        elif ! command -v node >/dev/null 2>&1; then
            print_warning "node not found - Jev client cannot run; checkpoints fall back to regex"
        elif jev_node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null) \
            && jev_node_min=$(jq -r '.engines.node // ""' "$jev_src/package.json" 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p') \
            && [ "${jev_node_major:-0}" -lt "${jev_node_min:-22}" ]; then
            # npm treats engines as advisory (engine-strict is off by default): without this check a Node 20
            # workstation would install the SDK with warnings and then be reported as healthy.
            print_warning "Node ${jev_node_major} is older than the Node ${jev_node_min} the Jev SDK needs - skipping npm ci; Jev falls back to regex until Node >= ${jev_node_min}"
            # The manifests were just updated but node_modules was not: drop the marker so the next sync on a
            # new-enough Node reinstalls instead of trusting a stale install.
            rm -f "$jev_dst/node_modules/.jev-installed"
        elif jev_out=$(cd "$jev_dst" && npm ci --omit=dev --no-audit --no-fund --engine-strict 2>&1); then
            : >"$jev_dst/node_modules/.jev-installed"
            echo "  ✅ Jev deps: npm ci --omit=dev in ~/.claude/hooks/jev"
        else
            print_warning "npm ci failed in ~/.claude/hooks/jev - Jev falls back to regex until it succeeds"
            printf "    %s\n" "$jev_out"
        fi
    else
        echo "  ✅ Jev deps: unchanged (npm ci not needed)"
    fi

    # A running daemon holds the old client and SDK in memory; stop it so the
    # next call starts a fresh one. Harmless when none is running.
    if command -v node >/dev/null 2>&1; then
        "$jev_dst/jev-ask" --stop >/dev/null 2>&1 || true
    fi
    echo "  ✅ Jev hooks → ~/.claude/hooks/jev/"
    return 0
}

# Function to sync files
sync_files() {
    echo "🔄 Synchronizing files:"

    # Create target directories
    mkdir -p "$TARGET_DIR/agents"
    mkdir -p "$TARGET_DIR/skills"
    mkdir -p "$TARGET_DIR/output-styles"

    # This is intentionally the only operation that names papercuts.md.
    # The log and papercuts/ archive are otherwise outside every sync,
    # delete, backup-restore, and cleanup path in this script.
    if ! initialize_papercut_log; then
        return 1
    fi

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

    # Sync output styles if they exist.
    #
    # --exclude='local-*.md' is load-bearing, not cosmetic. --delete otherwise
    # destroys any style authored directly in ~/.claude/output-styles/ — which
    # is exactly how you'd A/B a candidate style against the deployed one, so
    # the flag was quietly deleting the only means of evaluating these files.
    # Anything named local-*.md is yours: never synced from here, never removed.
    if [ "$(manifest_flag output_styles)" != "true" ]; then
        echo "  ⏭  Output styles: skipped by $STATION manifest"
    elif [ -d "$SOURCE_DIR/output-styles" ]; then
        rsync_output=""
        if rsync_output=$(rsync -a --delete --exclude='local-*.md' "$SOURCE_DIR/output-styles/" "$TARGET_DIR/output-styles/" 2>&1); then
            STYLE_COUNT=$(find "$SOURCE_DIR/output-styles" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✅ Output styles: $STYLE_COUNT files → ~/.claude/output-styles/"
        else
            print_warning "Failed to sync output styles: $rsync_output"
        fi
    fi

    # Sync rules (*.md only). --exclude='local-*.md' keeps a rule authored
    # directly in ~/.claude/rules/ alive through --delete, as for output styles.
    if [ "$(manifest_flag rules)" != "true" ]; then
        echo "  ⏭  Rules: skipped by $STATION manifest"
    elif [ -d "$SOURCE_DIR/rules" ]; then
        mkdir -p "$TARGET_DIR/rules"
        rsync_output=""
        if rsync_output=$(rsync -a --delete --exclude='local-*.md' --include='*/' --include='*.md' --exclude='*' "$SOURCE_DIR/rules/" "$TARGET_DIR/rules/" 2>&1); then
            RULE_COUNT=$(find "$SOURCE_DIR/rules" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  ✅ Rules: $RULE_COUNT files → ~/.claude/rules/"
        else
            echo "  ❌ Failed to sync rules"
            printf "    %s\n" "$rsync_output"
            return 1
        fi
    fi

    # Sync mods: plugin folders of function hooks (glassbox, ...), loaded by
    # every session because settings.json's env sets CLAUDE_CODE_PLUGIN_DIRS
    # to ~/.claude/mods. A mod's tests stay in the repo; the type files and
    # tsconfig.json the engine lays into a loaded mod are its own, so --delete
    # leaves them be. A local-* folder is yours, as for output styles and rules.
    if [ "$(manifest_flag mods)" != "true" ]; then
        echo "  ⏭  Mods: skipped by $STATION manifest"
    elif [ -d "$SOURCE_DIR/mods" ]; then
        mkdir -p "$TARGET_DIR/mods"
        # A manifest's mods_exclude names mods a station never gets: the fleet
        # node keeps screen-only mods off its headless sessions. Each is left
        # out of the copy, and removed if an earlier sync put it there (--delete
        # spares excluded paths). Names are checked first, so the unquoted list
        # below can neither glob nor split a name, and a local-* name (yours,
        # never synced) is refused so the removal below can never reach it.
        # Any failure stops the sync (its exit status is checked: set -e is
        # off inside sync_files).
        if ! MODS_EXCLUDE=$(mods_exclude_names); then
            echo "  ❌ Mods: $MODS_EXCLUDE ($MANIFEST)"
            return 1
        fi
        mods_exclude_file=$(mktemp "${TMPDIR:-/tmp}/claude-sync-mods.XXXXXX")
        for mod in $MODS_EXCLUDE; do
            printf '/%s/\n' "$mod" >>"$mods_exclude_file"
        done
        rsync_output=""
        if rsync_output=$(rsync -a --delete --exclude='local-*' --exclude='/*/tests/' --exclude='/*/.claude-plugin/types/' --exclude='/*/tsconfig.json' --exclude-from="$mods_exclude_file" "$SOURCE_DIR/mods/" "$TARGET_DIR/mods/" 2>&1); then
            rm -f "$mods_exclude_file"
            MOD_COUNT=$(find "$SOURCE_DIR/mods" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
            for mod in $MODS_EXCLUDE; do
                if [ -d "$SOURCE_DIR/mods/$mod" ]; then
                    MOD_COUNT=$((MOD_COUNT - 1))
                fi
                if [ -d "$TARGET_DIR/mods/$mod" ]; then
                    if ! rm -rf "${TARGET_DIR:?}/mods/$mod" 2>/dev/null || [ -e "$TARGET_DIR/mods/$mod" ]; then
                        echo "  ❌ Mods: could not remove $mod, excluded on $STATION but still in ~/.claude/mods/"
                        return 1
                    fi
                    echo "  🧹 Mods: removed $mod (excluded on $STATION)"
                fi
            done
            if [ -n "$MODS_EXCLUDE" ]; then
                echo "  ✅ Mods: $MOD_COUNT mods → ~/.claude/mods/ (excluded on $STATION: $(echo $MODS_EXCLUDE))"
            else
                echo "  ✅ Mods: $MOD_COUNT mods → ~/.claude/mods/"
            fi
        else
            rm -f "$mods_exclude_file"
            echo "  ❌ Failed to sync mods"
            printf "    %s\n" "$rsync_output"
            return 1
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
                cp "$SOURCE_DIR/settings.json" "$TARGET_DIR/"
                sync_plugins ;;
        esac
    fi

    # Sync each tracked hook script: validate syntax, copy, make executable.
    if [ "$(manifest_flag hook_scripts)" != "true" ]; then
        echo "  ⏭  Hook scripts: skipped by $STATION manifest"
        RUNTIME_HOOK_SCRIPTS=""
        RUNTIME_HOOK_DATA=""
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
        mkdir -p "$TARGET_DIR/$(dirname "$script")"
        cp "$src" "$TARGET_DIR/$script"
        chmod +x "$TARGET_DIR/$script"
        # A script that moved into a subdirectory (e.g. hooks/) leaves its
        # old top-level copy behind in ~/.claude/; remove it so a stale copy
        # can't be run by an old settings path.
        case "$script" in
            */*) rm -f "$TARGET_DIR/$(basename "$script")" ;;
        esac
    done

    # Hook data files (e.g. gate-rules.json): same fail-fast rule as the scripts,
    # validated as JSON, copied without the executable bit.
    for datafile in $RUNTIME_HOOK_DATA; do
        src="$SOURCE_DIR/$datafile"
        if [ ! -f "$src" ]; then
            print_error "Tracked hook data file missing from source tree: $datafile"
            print_error "RUNTIME_HOOK_DATA lists '$datafile' but it is not present in $SOURCE_DIR"
            return 1
        fi
        if ! command -v jq >/dev/null 2>&1; then
            print_error "jq not available — required to validate hook data file: $datafile"
            return 1
        fi
        validation_errors=$(jq empty "$src" 2>&1) || {
            print_error "Invalid JSON hook data file: $datafile"
            printf "    %s\n" "$validation_errors"
            return 1
        }
        mkdir -p "$TARGET_DIR/$(dirname "$datafile")"
        cp "$src" "$TARGET_DIR/$datafile"
    done
    if [ "$(manifest_flag hook_scripts)" = "true" ]; then
        sync_jev_hooks || return 1
    fi

    # Build synced settings summary line from the same map. Every entry
    # is guaranteed to exist at this point (the loop above would have
    # returned on any missing script), so no `-f` guard is needed.
    synced_settings="settings.json"
    for script in $RUNTIME_HOOK_SCRIPTS $RUNTIME_HOOK_DATA; do
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

# Prerequisites: everything sync and the runtime hooks need, checked BEFORE anything is written
# (including by --dry-run). Missing tools and a Node older than the Jev SDK's engines.node are
# hard failures; a missing gateway key is a warning (Jev degrades to regex, and fleet stations
# without a key must still sync). JEV_SYNC_SKIP_NPM=1 (tests) skips the node/npm checks.
check_prerequisites() {
    prereq_fail=0
    echo "🔎 Prerequisites:"
    for prereq_tool in jq rsync; do
        if command -v "$prereq_tool" >/dev/null 2>&1; then
            echo "  ✅ $prereq_tool"
        else
            print_error "$prereq_tool not found (brew install $prereq_tool)"
            prereq_fail=1
        fi
    done

    if [ "$(manifest_flag hook_scripts)" = "true" ]; then
        if [ -z "${JEV_SYNC_SKIP_NPM:-}" ]; then
            prereq_node_min=22
            if command -v jq >/dev/null 2>&1 && [ -f "$SOURCE_DIR/hooks/jev/package.json" ]; then
                prereq_node_min=$(jq -r '.engines.node // ""' "$SOURCE_DIR/hooks/jev/package.json" 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p')
                prereq_node_min=${prereq_node_min:-22}
            fi
            if ! command -v node >/dev/null 2>&1; then
                print_error "node not found - the Jev client needs Node >= $prereq_node_min (brew install node)"
                prereq_fail=1
            elif prereq_node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null) \
                && [ "${prereq_node_major:-0}" -lt "$prereq_node_min" ]; then
                print_error "Node $prereq_node_major is older than the Node $prereq_node_min the Jev SDK needs (brew upgrade node)"
                prereq_fail=1
            else
                echo "  ✅ node $(node -p 'process.versions.node' 2>/dev/null) (needs >= $prereq_node_min)"
            fi
            if command -v npm >/dev/null 2>&1; then
                echo "  ✅ npm"
            else
                print_error "npm not found - needed for npm ci in ~/.claude/hooks/jev"
                prereq_fail=1
            fi
        fi

        # Same lookup order as hooks/jev/client.mjs resolveKey(): environment first, then an export line in ~/.zshrc.
        if [ -n "${AI_GATEWAY_API_KEY:-}${VERCEL_AI_GATEWAY_TOKEN:-}${VERCEL_AI_GATEWAY_KEY:-}" ] \
            || grep -Eqs '^[[:space:]]*export[[:space:]]+(VERCEL_AI_GATEWAY_TOKEN|VERCEL_AI_GATEWAY_KEY|AI_GATEWAY_API_KEY)=[^[:space:]#]' "${JEV_ZSHRC:-$HOME/.zshrc}"; then
            echo "  ✅ Jev gateway key"
        else
            print_warning "no Jev gateway key (export VERCEL_AI_GATEWAY_TOKEN in ~/.zshrc or set AI_GATEWAY_API_KEY) - Jev checkpoints will fall back to regex"
        fi
    fi

    # Vendored higgsfield-* skills drive the `higgsfield` CLI. Only checked when
    # this station syncs skills and the source tree actually ships them.
    # HIGGSFIELD_SYNC_SKIP_CHECK=1 skips (tests run sync against a temp HOME).
    if [ -z "${HIGGSFIELD_SYNC_SKIP_CHECK:-}" ] && [ "$(manifest_flag skills)" = "true" ] \
        && ls -d "$SOURCE_DIR"/skills/higgsfield-* >/dev/null 2>&1; then
        if command -v higgsfield >/dev/null 2>&1; then
            echo "  ✅ higgsfield $(higgsfield --version 2>/dev/null | cut -d' ' -f2)"
            # account status needs a stored login AND a selected workspace; it also needs
            # the network, so a failure here warns instead of blocking the sync.
            if higgsfield account status >/dev/null 2>&1; then
                echo "  ✅ higgsfield signed in with a workspace"
            else
                print_warning "higgsfield not ready (run: higgsfield auth login, then higgsfield workspace list / workspace set <id>) - or offline; the higgsfield-* skills cannot generate until fixed"
            fi
        elif [ "$HAVE_MANIFEST" = "true" ]; then
            # manifest stations (the fleet node) are scoped on purpose: warn so a merge never blocks their sync
            print_warning "higgsfield not found on $STATION - the higgsfield-* skills cannot run there (npm i -g @higgsfield/cli, then higgsfield auth login)"
        else
            print_error "higgsfield not found - the higgsfield-* skills need the CLI (npm i -g @higgsfield/cli, then higgsfield auth login)"
            prereq_fail=1
        fi
        # python3 runs the skill scripts; the rest are only brandkit's export stages.
        # the brandkit scripts call str.removeprefix/removesuffix, which need Python 3.9
        if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
            echo "  ✅ python3 $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])') (needs >= 3.9)"
        elif [ "$HAVE_MANIFEST" = "true" ]; then
            print_warning "python3 >= 3.9 not found on $STATION - the higgsfield-brandkit and higgsfield-websites scripts cannot run there (brew install python)"
        else
            print_error "python3 >= 3.9 not found - the higgsfield-brandkit and higgsfield-websites scripts need it (brew install python)"
            prereq_fail=1
        fi
        hf_missing=""
        for hf_tool in rsvg-convert soffice pdftoppm pdffonts fc-match fc-cache; do
            command -v "$hf_tool" >/dev/null 2>&1 || hf_missing="$hf_missing $hf_tool"
        done
        command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || hf_missing="$hf_missing magick"
        if [ -n "$hf_missing" ]; then
            print_warning "higgsfield-brandkit export tools missing:$hf_missing (brew install imagemagick librsvg poppler fontconfig; brew install --cask libreoffice)"
        fi
    fi

    if [ "$prereq_fail" -ne 0 ]; then
        echo ""
        echo "❌ Prerequisites missing — nothing was synced. Install the items above and run sync again."
        return 1
    fi
    echo ""
    return 0
}

# Main execution
main() {
    start_time=$(date +%s)

    if ! check_prerequisites; then
        return 1
    fi

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
        if [ "$(manifest_flag rules)" = "true" ] && [ -d "$SOURCE_DIR/rules" ]; then
            echo "  - $(find "$SOURCE_DIR/rules" -name "*.md" 2>/dev/null | wc -l | tr -d ' ') rule files → ~/.claude/rules/ (--delete; local-*.md kept)"
        fi
        if [ "$(manifest_flag mods)" = "true" ] && [ -d "$SOURCE_DIR/mods" ]; then
            if ! preview_exclude=$(mods_exclude_names); then
                echo "  - mods ⚠️  $preview_exclude (real sync would fail)"
            else
                preview_mods=$(find "$SOURCE_DIR/mods" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
                for mod in $preview_exclude; do
                    if [ -d "$SOURCE_DIR/mods/$mod" ]; then
                        preview_mods=$((preview_mods - 1))
                    fi
                done
                if [ -n "$preview_exclude" ]; then
                    echo "  - $preview_mods mods → ~/.claude/mods/ (--delete; local-* kept; excluded on $STATION: $(echo $preview_exclude))"
                else
                    echo "  - $preview_mods mods → ~/.claude/mods/ (--delete; local-* kept)"
                fi
            fi
        fi
        SETTINGS_MODE=$(settings_mode)
        echo "  - settings.json → ~/.claude/settings.json (mode: $SETTINGS_MODE)"
        if [ "$SETTINGS_MODE" = "merge" ] && [ -f "$TARGET_DIR/settings.json" ] && command -v jq >/dev/null 2>&1; then
            owned=$(jq -c '.sync.settings_owned_keys // []' "$MANIFEST")
            silence=$(jq -c '.sync.hooks_silence_command_contains // []' "$MANIFEST")
            # "hooks" is compared separately below (its live value is filtered,
            # so a naive raw comparison against unfiltered repo hooks would
            # falsely report a change whenever a silenced entry exists at all).
            changed=$(jq -r --argjson owned "$owned" --slurpfile repo "$SOURCE_DIR/settings.json" '
                [ ($owned - ["hooks"])[] as $k | select((.[$k] // null) != ($repo[0][$k] // null)) | $k ] | join(", ")
            ' "$TARGET_DIR/settings.json" 2>/dev/null || echo "?")
            if [ -n "$changed" ]; then
                echo "      owned keys that would change: $changed"
            else
                echo "      owned keys already in sync"
            fi
            if echo "$owned" | jq -e 'index("hooks") != null' >/dev/null 2>&1; then
                hook_diff=$(jq -r --argjson silence "$silence" --slurpfile repo "$SOURCE_DIR/settings.json" "$JQ_SILENCE_HOOKS_DEF"'
                    (($repo[0].hooks // {}) | silence_hooks($silence)) as $filtered
                    | if $filtered == (.hooks // {}) then "in_sync" else "changed" end
                ' "$TARGET_DIR/settings.json" 2>/dev/null || echo "?")
                case "$hook_diff" in
                    in_sync) echo "      hooks (after silencing): already in sync" ;;
                    changed) echo "      hooks (after silencing): would change" ;;
                    *) echo "      hooks (after silencing): could not compare" ;;
                esac
                silenced_events=$(jq -r --argjson silence "$silence" "$JQ_SILENCE_HOOKS_DEF"'
                    (.hooks // {}) as $before
                    | ($before | silence_hooks($silence)) as $after
                    | [ $before | keys[] as $k | select(($after | has($k)) | not) | $k ] | join(", ")
                ' "$SOURCE_DIR/settings.json" 2>/dev/null || echo "")
                if [ -n "$silenced_events" ]; then
                    echo "      hook events silenced by content, never synced to $STATION: $silenced_events"
                fi
            fi
        fi
        for script in $RUNTIME_HOOK_SCRIPTS $RUNTIME_HOOK_DATA; do
            if [ -f "$SOURCE_DIR/$script" ]; then
                echo "  - $script → ~/.claude/$script"
            else
                echo "  - $script ⚠️  MISSING from source tree (real sync would fail)"
            fi
        done
        echo "  - hooks/jev/ → ~/.claude/hooks/jev/ (npm ci --omit=dev only when package.json changed)"
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
