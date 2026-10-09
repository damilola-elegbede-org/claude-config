#!/bin/bash
# SessionStart: flash D one line when the nightly audit (scripts/jev-nightly-audit.py) found unblocked
# risky actions on its last run. Once per audit date. Reads <reports>/jev-audit-latest.json.
# Never blocks, fails open, no Jev call. Not a registry rule: it only relays the audit's own result.
dir="${JEV_AUDIT_DIR:-$HOME/.tmp/reports}"
f="$dir/jev-audit-latest.json"
[ -f "$f" ] || exit 0
stamp="${JEV_STATE_DIR:-$HOME/.claude/jev/state}/audit-digest.seen"
date="$(jq -r '.date // empty' "$f" 2>/dev/null)" || exit 0
[ -n "$date" ] || exit 0
[ "$(cat "$stamp" 2>/dev/null)" = "$date" ] && exit 0
n="$(jq -r '.flagged // 0' "$f" 2>/dev/null)"
if [ "$n" -gt 0 ] 2>/dev/null; then
  jq -c '"Jev audit \(.date): \(.flagged) risky action(s) ran with no gate block"
    + (if .aborted then " (audit stopped early)" else "" end)
    + ". Top: " + ([.top[] | "\(.time) \(.cls) \(.score) \(.action)"] | join(" | "))
    + ". Full list: \(.report)" | {systemMessage: .}' "$f" 2>/dev/null || exit 0
fi
( umask 077; mkdir -p "$(dirname "$stamp")" && printf '%s' "$date" >"$stamp" ) 2>/dev/null
exit 0
