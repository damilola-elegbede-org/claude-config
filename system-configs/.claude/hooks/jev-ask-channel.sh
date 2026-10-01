#!/bin/bash
# shellcheck shell=bash disable=SC2154
# jev-ask-channel.sh - Stop hook for G16 (ask channel). Blocks the stop when the final message
# ends by asking D to decide something in prose instead of via AskUserQuestion.
#
# Shadow-first (rule G16-ask-channel ships mode "shadow": log only). A quality hook: Jev
# unavailable -> no-op. Skips subagents, bg jobs, fleet (they end with `needs input:` instead),
# exempt agents, and any stop that is already a continuation (stop_hook_active) so it can never loop.
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=jev-gate-lib.sh
. "$HOOK_DIR/jev-gate-lib.sh" || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0
jev_gates_off && exit 0 # gate.off (master) or jev.off; regular files only (mkdir is not a kill switch)
JEV_HOOK_NAME=jev-ask-channel

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

TOOL="Stop"
IFS=$'\t' read -r ACTIVE SESSION AGENT_ID CWD < <(
  printf '%s' "$INPUT" | jq -r 'def nz: if . == null or . == "" then "-" else . end; [((.stop_hook_active // false) | tostring), (.session_id | nz), (.agent_id | nz), (.cwd | nz)] | @tsv' 2>/dev/null
)
jev_init_context
RULES=$(jev_rules_json)

# Never re-block a continuation: the harness overrides after 8 blocks and we must not loop.
if [ "${ACTIVE:-false}" = "true" ]; then
  jev_log G16-ask-channel skip-stop-hook-active "" ""
  exit 0
fi
[ "${AGENT_ID:--}" = "-" ] || exit 0 # subagent

RULE=$(jev_resolve_rules "$RULES" G16-ask-channel)
[ -n "$RULE" ] || exit 0 # off, or out of scope (interactive only by default: bg/fleet use `needs input:`)
MODE=$(printf '%s' "$RULE" | cut -f2)
THR=$(printf '%s' "$RULE" | cut -f3)

if jev_is_exempt "$RULES"; then
  jev_log G16-ask-channel allow-exempt-agent "$MODE" ""
  exit 0
fi

MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')
[ -n "$MSG" ] || exit 0
# A `needs input:` hand-off is the sanctioned channel in headless contexts.
if printf '%s' "$MSG" | grep -qiE '^[[:space:]]*(\*\*)?needs input:'; then
  jev_log G16-ask-channel skip-needs-input "$MODE" ""
  exit 0
fi

# Prefilter: only the ending matters, and it must look like a question or a hand-back to D.
ENDING="$MSG"
[ "${#MSG}" -gt 900 ] && ENDING="${MSG: -900}"
if ! printf '%s' "$ENDING" | grep -qiE '\?|let me know|your call|up to you|tell me (which|if|whether|how)|which (one|do you|would you)|do you want|want me to|should i|need your (decision|call|input)|waiting on you|how would you like'; then
  exit 0
fi

ENDING=$(printf '%s' "$ENDING" | jev_redact)
STATE=$(jq -nc --arg tail "$ENDING" --arg ctx "$JEV_CTX" '{tool:"Stop", context:$ctx, final_message_tail:$tail}')
ACTION_SHA=$(jev_sha "$ENDING")
Q=$(jev_bool_questions '["G16-ask-channel"]')
REQ=$(jev_build_request "G16-ask-channel" "$STATE" '{}' "$Q")
RESP=$(jev_call "$REQ") || { jev_log G16-ask-channel unavailable "$MODE" ""; exit 0; }
jev_note "$RESP"
P=$(jev_prob "$RESP" G16-ask-channel)

if [ -n "$P" ] && jev_ge "$P" "$THR"; then
  if [ "$MODE" = "enforce" ]; then
    jev_log G16-ask-channel block "$MODE" "$P"
    jq -nc '{decision:"block", reason:"Jev gate [G16-ask-channel]: your last message ends by asking D to decide in prose. D wants every decision through AskUserQuestion. Re-send it as one AskUserQuestion call (headline, context, ONE ask, 2-4 options, exactly one recommended). Do not repeat the prose question."}'
  else
    jev_log G16-ask-channel would-block-shadow "$MODE" "$P"
  fi
else
  jev_log G16-ask-channel pass "$MODE" "$P"
fi
exit 0
