#!/bin/bash
# pick_target.sh — optional click-target picker for /webapp-testing.
#
#   pick_target.sh "<goal, e.g. click the Save button>" < candidates.tsv
#
# stdin : one candidate per line, "selector<TAB>visible text or role" (for example
#         the output of examples/element_discovery.py reshaped to two columns).
# stdout: {"helper":"pick_target","mode":...,"selector":"<css or text= selector>","p":0.0-1.0,"source":"regex|jev"}
#         or the same with selector "" when nothing is chosen.
#
# Regex first: a candidate whose text equals a quoted/last word of the goal wins.
# Jev (choice, rule workflow-click-target, default SHADOW) only breaks ties; page text
# is untrusted, so candidates travel in the request's `untrusted` field and the model
# sees them only by option index. Its pick is returned only in enforce mode. Fails open.

# shellcheck source-path=SCRIPTDIR source=../../../hooks/jev/rules-events-lib.sh
. "$(dirname "$0")/../../../hooks/jev/rules-events-lib.sh" 2>/dev/null || { echo '{"helper":"pick_target","mode":"unavailable","selector":""}'; exit 0; }
re_need_jq || { echo '{"helper":"pick_target","mode":"unavailable","selector":""}'; exit 0; }

case "${1:-}" in -h | --help)
  sed -n '2,15s/^# \{0,1\}//p' "$0"
  exit 0
  ;;
esac
GOAL="${1:-}"
CANDS=$(head -60)
MODE=$(re_mode workflow-click-target shadow)
out() { jq -nc --arg m "$MODE" --arg s "$1" --arg src "$2" --arg p "${3:-0}" '{helper:"pick_target",mode:$m,selector:$s,source:$src,p:($p|tonumber)}'; }
[ -n "$GOAL" ] && [ -n "$CANDS" ] && [ "$MODE" != off ] || { out "" none; exit 0; }

# 1. exact text match against the goal's quoted phrase (or its last word)
PHRASE=$(printf '%s' "$GOAL" | sed -n "s/.*[\"']\\([^\"']*\\)[\"'].*/\\1/p")
[ -n "$PHRASE" ] || PHRASE=$(printf '%s' "$GOAL" | awk '{print $NF}')
EXACT=$(printf '%s\n' "$CANDS" | awk -F'\t' -v p="$(printf '%s' "$PHRASE" | tr '[:upper:]' '[:lower:]')" 'tolower($2)==p {print $1}')
if [ "$(printf '%s\n' "$EXACT" | grep -c .)" -eq 1 ]; then
  re_log workflow-click-target regex-exact ""
  out "$EXACT" regex 1
  exit 0
fi

# 2. Jev choice over the candidates, by index
N=$(printf '%s\n' "$CANDS" | grep -c .)
CRIT=$(jq -nc --argjson n "$N" '[range(0;$n)] | map({key:("c"+tostring),value:null}) | from_entries')
Q=$(jq -nc --argjson c "$CRIT" '{target:{type:"choice",instructions:"Which candidate element (see untrusted.candidates, by index) best achieves the goal?",criteria:$c}}')
STATE=$(jq -nc --arg g "$GOAL" '{goal:$g}')
UNTRUSTED=$(printf '%s\n' "$CANDS" | jq -Rsc 'split("\n") | map(select(length>0)) | to_entries | map({key:("c"+(.key|tostring)),value:.value}) | from_entries | {candidates:.}')
REQ=$(jq -nc --argjson s "$STATE" --argjson q "$Q" --argjson u "$UNTRUSTED" '{rule:"workflow-click-target",state:$s,questions:$q,untrusted:$u,timeout_ms:1500}')
RESP=$(printf '%s' "$REQ" | re_jev_call 2>/dev/null) || { out "" none; exit 0; }
CH=$(jq -r '.answers.target.choice // empty' <<<"$RESP" 2>/dev/null)
P=$(jq -r --arg c "$CH" '.answers.target.probabilities[$c] // 0' <<<"$RESP" 2>/dev/null)
re_log workflow-click-target "pick=$CH p=$P" "mode=$MODE"
# CH comes from the model: accept only c<digits> within range (no arithmetic on arbitrary
# text) and only at or above the rule threshold; otherwise return no selector so the skill
# falls back to its own judgement.
if [ "$MODE" = enforce ] && [[ "$CH" =~ ^c([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -lt "$N" ] \
  && awk -v p="$P" -v t="$(re_cfg workflow-click-target threshold 0.7)" 'BEGIN{exit !(p+0>=t+0)}'; then
  IDX=$((10#${BASH_REMATCH[1]}))
  SEL=$(printf '%s\n' "$CANDS" | sed -n "$((IDX + 1))p" | cut -f1)
  out "$SEL" jev "$P"
else
  out "" none
fi
exit 0
