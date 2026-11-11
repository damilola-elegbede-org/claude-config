#!/bin/bash
# idle-helper-stop.sh — the lead does not end its turn while a finished helper is still alive.
#
#   Stop: with agent teams on, a named helper (Agent call with a name) becomes a teammate that stays
#     alive and addressable after it reports, until the lead stops it. Read the lead's own team file,
#     ~/.claude/teams/session-<first 8 of session_id>/config.json, and block the stop while any member
#     other than the lead has isActive == false (idle: finished and still listed). A stopped helper
#     (TaskStop, or a shutdown_request) is removed from members, so "listed" means "alive".
#     Helpers with isActive == true are still working and never block: the lead ends its turn and is
#     re-invoked when they report. The reason tells the lead to TaskStop each idle helper
#     (task_id = its name) or say why it is kept.
#
# Never loops: a stop-hook continuation (stop_hook_active true) is always allowed, the lead having
# been told once. Fails OPEN on everything else: no session id, no team file, unreadable or malformed
# JSON, no members, jq missing. Local file read only, no network, only this session's team dir.
# Not exempt for Clara: this is hygiene, not a decision gate, and ENG-3103 came from her session.
# Mode/scope come from the shared rule registry (rules.d/rules-events.json "idle-helper-stop").

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

RULE=idle-helper-stop
INPUT=$(cat)
MODE=$(re_mode "$RULE" enforce)
[ "$MODE" = off ] && exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = true ] && exit 0
[ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" ] || exit 0 # subagent

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
case "$SID" in '' | *[!A-Za-z0-9_-]*) exit 0 ;; esac # also rules out path traversal
CFG="$RE_CLAUDE_DIR/teams/session-${SID:0:8}/config.json"
[ -r "$CFG" ] || exit 0

NAMES=$(jq -r '[(.members // [])[]? | select(type == "object")
  | select(.isActive == false and .name != null and .name != "team-lead" and .agentType != "team-lead")
  | .name | tostring] | join(", ")' "$CFG" 2>/dev/null) || exit 0
[ -n "$NAMES" ] || exit 0

if [ "$MODE" = shadow ]; then
  re_log "$RULE" shadow-would-block "$NAMES"
  exit 0
fi
re_log "$RULE" block "$NAMES"
re_block "Idle helpers [idle-helper-stop]: these helpers have finished and are still alive: $NAMES.
Stop each one now with TaskStop (task_id = the helper's name), or say why it is kept running, then finish."
exit 0
