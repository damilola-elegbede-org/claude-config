#!/bin/bash
# Notification — play the Aurora alert tone, but only when the notification is
# urgent. Keeps the original guards: fleet (BARECLAUDE_AGENT_SLUG) and background
# jobs (CLAUDE_JOB_DIR) never play a sound.
#
# Urgency: regex on notification_type first (permission_prompt / elicitation_dialog
# are D-must-act; auth_success and *_completed are not). Anything else goes to one
# Jev boolean (rule notification-urgency, default SHADOW). Shadow = the sound
# policy is unchanged (always play, as before) and Jev's answer is only logged;
# enforce = silent when Jev says not urgent. Jev unavailable → play (fail open).
# NO_SOUND=1 (tests) skips afplay.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"

if [ -n "${BARECLAUDE_AGENT_SLUG:-}" ] || [ -n "${CLAUDE_JOB_DIR:-}" ]; then exit 0; fi

play() {
  re_log notification-urgency "$1" "${2:-}"
  [ -n "${NO_SOUND:-}" ] && exit 0
  afplay -v 1.0 '/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Modern/Aurora.m4r' 2>/dev/null &
  exit 0
}

re_need_jq || play play-nojq
INPUT=$(cat)
MODE=$(re_mode notification-urgency shadow)
[ "$MODE" = off ] && play play-off
TYPE=$(jq -r '.notification_type // empty' <<<"$INPUT" 2>/dev/null)
MSG=$(jq -r '.message // empty' <<<"$INPUT" 2>/dev/null)

case "$TYPE" in
  permission_prompt | elicitation_dialog | elicitation_url_dialog | agent_needs_input) play play-urgent-regex "$TYPE" ;;
  auth_success | elicitation_complete | elicitation_response | agent_completed)
    if [ "$MODE" = enforce ]; then
      re_log notification-urgency silent-regex "$TYPE"
      exit 0
    fi
    play play-shadow-nonurgent-regex "$TYPE"
    ;;
esac

STATE=$(jq -nc --arg t "$TYPE" --arg m "${MSG:0:400}" '{notification_type:$t,message:$m}')
Q='{"urgent":{"type":"boolean","instructions":"Does this Claude Code notification need D to act within minutes (a blocked prompt, a question, a failure), as opposed to an informational or idle ping?","criteria":{"true":"Claude is blocked on D or something failed","false":"informational, idle, or already handled"}}}'
RESP=$(re_jev_req notification-urgency "$STATE" "$Q" 800 | re_jev_call 2>/dev/null) || play play-jev-unavailable
P=$(jq -r '.answers.urgent.probability // empty' <<<"$RESP" 2>/dev/null)
[ -n "$P" ] || play play-no-answer
re_log notification-urgency "jev p=$P" "mode=$MODE type=$TYPE"
if [ "$MODE" = enforce ] && ! awk -v p="$P" -v t="$(re_cfg notification-urgency threshold 0.5)" 'BEGIN{exit !(p+0>=t+0)}'; then
  exit 0
fi
play play "p=$P"
