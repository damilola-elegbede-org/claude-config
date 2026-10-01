#!/bin/bash
# presort.sh — optional pre-sort for /process-linear step 3.
#
# stdin : JSON array of tickets [{"id":"ENG-1","title":"...","state":"Blocked"}, ...]
# stdout: {"helper":"presort","mode":"shadow|enforce|off|unavailable","results":[...]}
#         results (enforce mode only): [{"id","p_needs_d","hint":"likely-needs-d|likely-not-d"}]
#         sorted by p_needs_d descending.
#
# One Jev boolean per ticket ("needs D?") on title + state ONLY — no bodies, so it
# is cheap and sends nothing sensitive. It is a hint for reading order: step 3's
# classification (which reads the bodies) still decides every ticket's bucket.
# Rule workflow-linear-presort, default SHADOW: Jev is called and logged, results stay
# empty. Fails open: any problem prints an empty result and exits 0.

# shellcheck source-path=SCRIPTDIR source=../../../hooks/jev/rules-events-lib.sh
. "$(dirname "$0")/../../../hooks/jev/rules-events-lib.sh" 2>/dev/null || { echo '{"helper":"presort","mode":"unavailable","results":[]}'; exit 0; }

emit() { jq -nc --arg m "$1" --argjson r "${2:-[]}" '{helper:"presort",mode:$m,results:$r}'; }
re_need_jq || { echo '{"helper":"presort","mode":"unavailable","results":[]}'; exit 0; }

MODE=$(re_mode workflow-linear-presort shadow)
[ "$MODE" = off ] && { emit off; exit 0; }
TICKETS=$(cat)
jq -e 'type=="array"' >/dev/null 2>&1 <<<"$TICKETS" || { emit unavailable; exit 0; }
THRESH=$(re_cfg workflow-linear-presort threshold 0.5)

RESULTS='[]'
N=$(jq 'length' <<<"$TICKETS")
OFFSET=0
while [ "$OFFSET" -lt "$N" ]; do
  CHUNK=$(jq -c --argjson o "$OFFSET" '.[$o:$o+25] | map({id,title:(.title // "" | .[0:200]),state})' <<<"$TICKETS")
  Q=$(jq -c '[to_entries[] | {key:("t"+(.key|tostring)),value:{type:"boolean",instructions:("Does this Linear ticket genuinely need a decision only D can make (policy, irreversible, security, spend, ambiguous product call), as opposed to agent-executable work, a ticket blocked on another ticket, a shelved project, or a finished deliverable awaiting a rubber stamp? Ticket "+(.key|tostring)+" is in state_and_title.t"+(.key|tostring)),criteria:{"true":"only D can make this call","false":"an agent can execute or it is blocked elsewhere"}}}] | from_entries' <<<"$CHUNK")
  STATE=$(jq -c '{state_and_title:([to_entries[] | {key:("t"+(.key|tostring)),value:(.value.state + ": " + .value.title)}] | from_entries)}' <<<"$CHUNK")
  if RESP=$(re_jev_req workflow-linear-presort "$STATE" "$Q" 2500 | re_jev_call 2>/dev/null) && [ -n "$RESP" ]; then
    PART=$(jq -nc --argjson c "$CHUNK" --argjson th "$THRESH" --argjson r "$RESP" '[ $c | to_entries[] | . as $e | {id:$e.value.id, p_needs_d:($r.answers[("t"+($e.key|tostring))].probability // null)} | select(.p_needs_d != null) | . + {hint:(if .p_needs_d >= $th then "likely-needs-d" else "likely-not-d" end)}]' 2>/dev/null)
    [ -n "$PART" ] && RESULTS=$(jq -c --argjson p "$PART" '. + $p' <<<"$RESULTS")
  else
    emit unavailable
    exit 0
  fi
  OFFSET=$((OFFSET + 25))
done
re_log workflow-linear-presort "tickets=$N" "mode=$MODE"
if [ "$MODE" = enforce ]; then
  emit enforce "$(jq -c 'sort_by(-.p_needs_d)' <<<"$RESULTS")"
else
  emit "$MODE"
fi
exit 0
