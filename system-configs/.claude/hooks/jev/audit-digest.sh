#!/bin/bash
# SessionStart: flash D one line when the nightly audit (scripts/jev-nightly-audit.py) found unblocked
# risky actions on its last run. Once per audit date. Reads <reports>/jev-audit-latest.json.
# Never blocks, fails open, no Jev call. Not a registry rule: it only relays the audit's own result.
# Only an interactive session shows it, and so consumes it: D does not watch a bg job or fleet session
# (same env signals as ctx_session_kind).
[ -z "${BARECLAUDE_AGENT_SLUG:-}" ] && [ -z "${CLAUDE_JOB_DIR:-}" ] || exit 0
dir="${JEV_AUDIT_DIR:-$HOME/.tmp/reports}"
f="$dir/jev-audit-latest.json"
[ -f "$f" ] || exit 0
stamp="${JEV_STATE_DIR:-$HOME/.claude/jev/state}/audit-digest.seen"
date="$(jq -r '.date // empty' "$f" 2>/dev/null)" || exit 0
[ -n "$date" ] || exit 0
[ "$(cat "$stamp" 2>/dev/null)" = "$date" ] && exit 0
n="$(jq -r '.flagged // 0' "$f" 2>/dev/null)"
# The date is marked seen only once a positive digest was shown: a later rerun for the same date
# that finds risky actions must still flash.
[ "$n" -gt 0 ] 2>/dev/null || exit 0
jq -c '"Jev audit \(.date): \(.flagged) risky action(s) ran with no gate block"
  + (if .aborted then " (audit stopped early)" else "" end)
  + ". Top: " + ([.top[] | "\(.time) \(.cls) \(.score) \(.action)"] | join(" | "))
  + ". Full list: \(.report)" | {systemMessage: .}' "$f" 2>/dev/null || exit 0
( umask 077; mkdir -p "$(dirname "$stamp")" && printf '%s' "$date" >"$stamp" ) 2>/dev/null
exit 0
