#!/bin/sh
# Installs the LaunchAgents that power session resume-after-restart and
# monthly papercut archiving:
#   - com.damilola.claude-resume-sessions   (RunAtLoad: reopen open sessions)
#   - com.damilola.claude-restart-on-update (StartInterval: restart
#     tmux-hosted sessions when a newer Claude Code build has been fetched)
#   - com.damilola.claude-archive-papercuts (monthly: archive non-recurring
#     prior-month papercuts)
#
# Run this ONCE after `/sync` has deployed system-configs/.claude/*.sh to
# ~/.claude/ (this script depends on resume_sessions.sh and
# restart_on_update.sh already being there). Re-run it any time to reinstall
# after editing a template.
#
# Templates live in system-configs/.claude/launchagents/*.plist.template
# with the literal string __HOME__ standing in for $HOME (LaunchAgent plists
# cannot expand environment variables, so the substitution happens here,
# once, at install time).
#
# This does not run through sync.sh: LaunchAgents live in
# ~/Library/LaunchAgents, outside sync.sh's ~/.claude/ scope, and loading
# one is a launchctl action, not a file copy.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE_DIR="$REPO_DIR/system-configs/.claude/launchagents"
TARGET_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$TARGET_DIR"
# launchd opens each plist's StandardOutPath/StandardErrorPath before the job
# runs, so the log directory has to exist before either agent is loaded.
mkdir -p -m 700 "$HOME/.claude/logs"

AGENTS="com.damilola.claude-resume-sessions com.damilola.claude-restart-on-update com.damilola.claude-archive-papercuts"

for agent in $AGENTS; do
    template="$TEMPLATE_DIR/$agent.plist.template"
    target="$TARGET_DIR/$agent.plist"

    if [ ! -f "$template" ]; then
        echo "ERROR: missing template $template" >&2
        exit 1
    fi

    sed "s|__HOME__|$HOME|g" "$template" > "$target"
    echo "Wrote $target"

    if launchctl list 2>/dev/null | grep -q "$agent"; then
        launchctl unload "$target" 2>/dev/null || true
    fi
    launchctl load "$target"
    echo "Loaded $agent"
done

echo ""
echo "Installed. Verify with:"
echo "  launchctl list | grep com.damilola.claude-"
echo ""
echo "com.damilola.claude-resume-sessions runs now (RunAtLoad also fires on"
echo "install) and again at every login. com.damilola.claude-restart-on-update"
echo "polls every 30 minutes (see the plist's StartInterval to change that)."
