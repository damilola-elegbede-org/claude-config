#!/bin/bash
# interview-stop.sh — after a confirmed /interview, the run ends when the done criteria are met.
#
#   Stop: while this session has an active contract (gate.sh interview-contract reads D's confirmed
#     playback from the transcript), block the stop and tell Claude to keep working. Released by:
#     a `needs input:` or `failed:` line (the run hands back to D; the contract stays active), or a
#     `result:` line Jev judges to meet the criteria (the contract closes, ending its grants).
#     Re-blocks on a stop-hook continuation, capped at max_blocks per contract, so a stuck run can
#     never trap the session.
#
# Mode/scope/exempt come from the shared rule registry (rules.d/rules-events.json "interview-stop").
# Fails OPEN on any error, including Jev being unavailable: one early stop costs less than trapping D.
# Test seams: JEV_MOCK (rules-events-lib.sh).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

RULE=interview-stop
INPUT=$(cat)
MODE=$(re_mode "$RULE" enforce)
[ "$MODE" = off ] && exit 0
if re_is_exempt_agent; then
  re_log "$RULE" allow-exempt-agent ""
  exit 0
fi
[ -z "$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')" ] || exit 0 # subagent

TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
[ -n "$TP" ] && [ -r "$TP" ] || exit 0
grep -q 'UNDERSTANDING PLAYBACK' "$TP" 2>/dev/null || exit 0
CONTRACT=$(bash "$(dirname "$0")/../gate.sh" interview-contract "$TP" 2>/dev/null) || exit 0
[ -n "$CONTRACT" ] || exit 0

ID=$(printf '%s' "$CONTRACT" | jq -r '.id' | tr -c 'A-Za-z0-9_-' '_')
DONE_WHEN=$(printf '%s' "$CONTRACT" | jq -r '.criteria')
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')

close() {
  mkdir -p "$RE_CLAUDE_DIR/interview-closed" 2>/dev/null
  : >"$RE_CLAUDE_DIR/interview-closed/$ID"
}

if printf '%s' "$MSG" | grep -qiE '^[[:space:]]*(\*\*)?(needs input|failed):'; then
  re_log "$RULE" released-hand-back ""
  exit 0
fi

CNT="$(re_session_dir "$SID")/interview/$ID.blocks"
MAX=$(re_cfg "$RULE" max_blocks 8)
case "$MAX" in '' | *[!0-9]*) MAX=8 ;; esac
N=$(cat "$CNT" 2>/dev/null || echo 0)

if printf '%s' "$MSG" | grep -qiE '^[[:space:]]*(\*\*)?result:'; then
  THR=$(re_cfg "$RULE" threshold 0.5)
  TAIL="$MSG"
  [ "${#MSG}" -gt 3500 ] && TAIL="${MSG: -3500}"
  STATE=$(jq -nc --arg d "$DONE_WHEN" --arg r "$TAIL" '{done_when:$d, final_message:$r}')
  Q='{"done":{"type":"boolean","instructions":"Does the final message show that every done_when criterion was met, with evidence?","criteria":{"true":"Each criterion is reported met.","false":"A criterion is unmet, unaddressed, or reported as still open."}}}'
  if ! RESP=$(re_jev_req "$RULE" "$STATE" "$Q" 3000 | re_jev_call 2>/dev/null) || [ -z "$RESP" ]; then
    re_log "$RULE" fail-open-jev-unavailable ""
    [ "$MODE" = shadow ] || close
    exit 0
  fi
  P=$(printf '%s' "$RESP" | jq -r '.answers.done.probability // empty')
  if [ -z "$P" ] || awk -v p="$P" -v t="$THR" 'BEGIN{exit !(p+0>=t+0)}'; then
    re_log "$RULE" released-done "$P"
    [ "$MODE" = shadow ] || close
    exit 0
  fi
fi

if [ "$N" -ge "$MAX" ]; then
  re_log "$RULE" released-cap "$MAX"
  [ "$MODE" = shadow ] && exit 0
  close
  jq -nc --arg d "$DONE_WHEN" --arg m "$MAX" '{systemMessage:("Interview run [interview-stop]: gave up after " + $m + " blocks; the run may be unfinished. Done when: " + $d)}'
  exit 0
fi

if [ "$MODE" = shadow ]; then
  re_log "$RULE" shadow-would-block ""
  exit 0
fi
mkdir -p "$(dirname "$CNT")" 2>/dev/null
echo $((N + 1)) >"$CNT"
re_log "$RULE" block "$N"
re_block "Interview run [interview-stop]: D confirmed this run, so it continues until it is done. Done when: $DONE_WHEN
Keep working. Finish with a line starting \`result:\` once every criterion is met, or \`needs input:\` naming the one action only D can take, or \`failed:\` with the reason."
exit 0
