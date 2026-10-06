#!/bin/sh
# Prepares the LaunchAgent that writes the Jev daily summary and runs the nightly audit at 06:30 local:
#   - com.damilola.jev-daily-report (scripts/jev-daily-summary.py, then scripts/jev-nightly-audit.py)
#
# By default this prints what it would do and changes nothing. Pass --write to render the plist into
# ~/Library/LaunchAgents. It never loads the agent: loading is a separate, explicit launchctl step that
# the output prints (the audit makes Jev calls, so starting it is a decision for the owner).
#
# The template lives in system-configs/.claude/launchagents/com.damilola.jev-daily-report.plist.template.
# LaunchAgent plists cannot expand environment variables, so the literal strings __HOME__ and __REPO__
# stand in for $HOME and this checkout and are substituted here, at install time. The scripts run from
# the checkout (not from ~/.claude); the Jev client they call is the one /sync deploys to
# ~/.claude/hooks/jev/jev-ask. Set JEV_REPO_DIR to point the agent at a different checkout.
#
# Usage: scripts/install-jev-daily-agent.sh [--write]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${JEV_REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
AGENT="com.damilola.jev-daily-report"
TEMPLATE="$REPO_DIR/system-configs/.claude/launchagents/$AGENT.plist.template"
TARGET_DIR="$HOME/Library/LaunchAgents"
TARGET="$TARGET_DIR/$AGENT.plist"

WRITE=0
case "${1:-}" in
    "") ;;
    --write) WRITE=1 ;;
    *)
        echo "usage: $0 [--write]" >&2
        exit 2
        ;;
esac

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: missing template $TEMPLATE" >&2
    exit 1
fi
for s in jev-daily-summary.py jev-nightly-audit.py; do
    if [ ! -f "$REPO_DIR/scripts/$s" ]; then
        echo "ERROR: missing $REPO_DIR/scripts/$s" >&2
        exit 1
    fi
done
case "$REPO_DIR" in
    */.claude/worktrees/*)
        echo "WARNING: $REPO_DIR is a worktree; the agent would stop working when it is removed." >&2
        echo "         Run this from the main checkout, or set JEV_REPO_DIR." >&2
        ;;
esac

echo "Agent:    $AGENT (daily at 06:30 local)"
echo "Template: $TEMPLATE"
echo "Runs:     python3 scripts/jev-daily-summary.py; python3 scripts/jev-nightly-audit.py  (in $REPO_DIR)"
echo "Output:   $HOME/.tmp/reports/jev-daily-<date>.md  (log: $HOME/.claude/logs/jev_daily_report.launchd.log)"
echo "Target:   $TARGET"

if [ "$WRITE" -eq 0 ]; then
    echo ""
    echo "Dry run: nothing written. Re-run with --write to render the plist."
    exit 0
fi

mkdir -p "$TARGET_DIR"
# launchd opens StandardOutPath/StandardErrorPath before the job runs, so the directory must exist.
mkdir -p "$HOME/.claude/logs"
# The values land inside XML text, so escape & < > " first, then escape \, | and & for the sed replacement.
sed_val() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' | sed -e 's/[\\|&]/\\&/g'
}
HOME_ESC="$(sed_val "$HOME")"
REPO_ESC="$(sed_val "$REPO_DIR")"
sed -e "s|__HOME__|$HOME_ESC|g" -e "s|__REPO__|$REPO_ESC|g" "$TEMPLATE" > "$TARGET"
echo "Wrote $TARGET"
echo ""
echo "Not loaded. To start it (a separate, explicit step):"
echo "  launchctl load \"$TARGET\""
echo "To stop it:"
echo "  launchctl unload \"$TARGET\""
echo "Check:"
echo "  launchctl list | grep $AGENT"
