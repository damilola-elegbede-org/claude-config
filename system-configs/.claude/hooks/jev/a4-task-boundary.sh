#!/bin/bash
# A4 - Stop: when the session is heavy and the task just finished, suggest /clear or /compact.
#
# Pipeline (cheapest first, so most turns cost nothing):
#   1. interactive sessions only (rule scope), never when stop_hook_active (no loops)
#   2. estimate context size = bytes of the transcript since the last compaction boundary / 4;
#      below `min_est_tokens` (150k) -> stop here, no Jev call
#   3. at most one nudge per `cooldown_s` per session
#   4. ONE Jev choice over the last assistant message + transcript tail:
#      task_completed | in_progress | switched
#   5. choice in `suggest_on` with probability >= threshold -> a user-visible systemMessage
#      (Stop has no additionalContext channel; the audience is D, not Claude)
# NEVER blocks the stop. Shadow mode only logs the verdict. Fail OPEN on any error.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

# a4_est_tokens <transcript>: bytes since the last compact boundary, /4.
a4_est_tokens() {
  local f="$1" ln bytes
  ln="$(grep -n -E '"subtype":"compact_boundary"|"isCompactSummary":true' "$f" 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -n "$ln" ]; then
    bytes="$(tail -n +"$ln" "$f" | wc -c | tr -d ' ')"
  else
    bytes="$(wc -c <"$f" | tr -d ' ')"
  fi
  echo $((bytes / 4))
}

# a4_tail <transcript>: last ~6 text turns, each cut to 400 chars, as JSON array of "role: text".
a4_tail() {
  tail -c 600000 "$1" 2>/dev/null | jq -R -n -c '
    [ inputs | fromjson? | select(.type == "user" or .type == "assistant")
      | select((.isMeta // false) | not)
      | .type as $r | .message.content as $c
      | (if ($c | type) == "string" then $c else ([$c[]? | select(.type == "text") | .text] | join("\n")) end)
      | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "") | gsub("^\\s+|\\s+$"; "")
      | select(length > 0) | "\($r): \(.[0:400])" ] | .[-6:]' 2>/dev/null
}

main() {
  ctx_bootstrap A4-task-boundary || return 0
  [ "$(ctx_in .stop_hook_active)" != "true" ] || return 0
  local tp sid last est min cool stamp state tailj
  tp="$(ctx_in .transcript_path)"
  [ -n "$tp" ] && [ -r "$tp" ] || return 0
  est="$(a4_est_tokens "$tp")"
  min="$(ctx_cfg min_est_tokens 150000)"
  [ "$est" -ge "$min" ] || return 0

  sid="$(ctx_in .session_id | tr -dc 'A-Za-z0-9_-')"
  [ -n "$sid" ] || sid=nosession
  cool="$(ctx_cfg cooldown_s 1800)"
  stamp="${JEV_STATE_DIR}/${sid}.a4"
  if [ -f "$stamp" ] && find "$stamp" -mmin "-$((cool / 60))" 2>/dev/null | grep -q .; then
    return 0
  fi

  last="$(ctx_in .last_assistant_message | cut -c1-3000)"
  tailj="$(a4_tail "$tp")"
  [ -n "$tailj" ] || tailj='[]'
  state="$(jq -cn --arg last "$last" --argjson tail "$tailj" '{last_assistant_message: $last, transcript_tail: $tail}')"
  jq -n --arg rule "$RULE" --argjson state "$state" '
    {rule: $rule, state: $state, timeout_ms: 1500,
     questions: {phase: {type: "choice",
       instructions: "Judging from state.last_assistant_message and state.transcript_tail, which phase is the session in right now?",
       criteria: {task_completed: "the requested task is finished and reported; nothing further is pending from the assistant",
                  in_progress: "work is mid-way, a step remains, a question is open, or the assistant is waiting on the user",
                  switched: "the user moved on to a different, unrelated task and the earlier one is done or dropped"}}}}' >"${WORK}/req.json"
  ctx_jev "${WORK}/req.json" || return 0

  jq -c --argjson est "$est" \
    '(.answers.phase // {}) as $a | {phase: $a.choice, p: (($a.probabilities // {})[$a.choice // ""] // null), est_tokens: $est}' \
    "${WORK}/jev-out.json" >"${WORK}/detail.json" 2>/dev/null
  ctx_log verdict "${WORK}/detail.json"

  if jq -e --argjson thr "$RULE_THRESHOLD" --argjson on "$(printf '%s' "$RULE_JSON" | jq -c '.suggest_on // ["task_completed"]')" \
    '(.answers.phase // {}) as $a | ($on | index($a.choice // "")) != null and ((($a.probabilities // {})[$a.choice] // 0) >= $thr)' \
    "${WORK}/jev-out.json" >/dev/null 2>&1; then
    [ "$RULE_MODE" = "enforce" ] || return 0
    (
      umask 077
      mkdir -p "$JEV_STATE_DIR" && : >"$stamp"
    ) 2>/dev/null
    jq -cn --argjson est "$est" '{systemMessage: "Jev: this task looks finished and the session context is about \($est / 1000 | floor)k tokens (estimated from transcript size). Every later turn re-reads it. Consider /clear (start fresh) or /compact (keep a summary)."}'
  fi
}

main
exit 0
