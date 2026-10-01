#!/bin/bash
# Stop — CLAUDE.md "Papercuts": "When friction costs time, append one factual line
# as soon as you hit it". Asks Jev (boolean, rule papercut-nudge, default SHADOW)
# whether tooling friction cost time this turn. Regex pre-filter first: Jev is only
# called when the turn had at least one failed tool call or the reply mentions
# friction. Shadow = log only. Enforce = Stop additionalContext reminding Claude to
# log it via papercut-dedupe.sh (never twice in a row: stop_hook_active respected).
# Interactive main-agent sessions only.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
MODE=$(re_mode papercut-nudge shadow)
[ "$MODE" = off ] && exit 0
[ "$(re_scope)" = interactive ] || exit 0
[ -z "$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null)" ] || exit 0
[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" = true ] && exit 0

MSG=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null)
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)

# This turn = everything after the last real user message in the transcript.
TURN=$(python3 - "$TRANSCRIPT" <<'PYEOF' 2>/dev/null
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except (OSError, ValueError, IndexError):
    print("0\t")
    sys.exit(0)

def is_prompt(e):
    if e.get("type") != "user":
        return False
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        return bool(c.strip()) and not c.lstrip().startswith("<")
    return any(isinstance(b, dict) and b.get("type") == "text" and not b.get("text", "").lstrip().startswith("<") for b in c or [])

start = 0
for i, e in enumerate(rows):
    if is_prompt(e):
        start = i
errs = []
for e in rows[start:]:
    c = (e.get("message") or {}).get("content")
    if isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                t = b.get("content")
                if isinstance(t, list):
                    t = " ".join(x.get("text", "") for x in t if isinstance(x, dict))
                errs.append(str(t or "")[:160].replace("\n", " "))
print(str(len(errs)) + "\t" + " | ".join(errs[:5]))
PYEOF
)
NERR=$(printf '%s' "$TURN" | cut -f1)
ERRS=$(printf '%s' "$TURN" | cut -f2-)
case "$NERR" in '' | *[!0-9]*) NERR=0 ;; esac

if [ "$NERR" -eq 0 ] && ! printf '%s' "$MSG" | grep -qiE 'workaround|work-around|timed out|hung|retried|retries|kept failing|mysterious|silently|no-op|ENOENT|ECONN|EACCES'; then
  exit 0
fi

STATE=$(jq -nc --arg reply "${MSG:0:1500}" --argjson n "$NERR" --arg errs "$ERRS" \
  '{last_reply:$reply,failed_tool_calls_this_turn:$n,failed_call_snippets:$errs}')
Q='{"friction":{"type":"boolean","instructions":"Did tooling friction (failed commands, workarounds, retries, mysterious errors) cost real time this turn, such that a future session would benefit from a one-line papercut note?","criteria":{"true":"a tool or environment problem cost real time and has a reusable fix or workaround","false":"no tooling friction, or it was trivial and one-off"}}}'
RESP=$(re_jev_req papercut-nudge "$STATE" "$Q" 1200 | re_jev_call 2>/dev/null) || exit 0
P=$(jq -r '.answers.friction.probability // empty' <<<"$RESP" 2>/dev/null)
[ -n "$P" ] || exit 0
re_log papercut-nudge "p=$P" "mode=$MODE failed_calls=$NERR"
[ "$MODE" = enforce ] || exit 0
awk -v p="$P" -v t="$(re_cfg papercut-nudge threshold 0.8)" 'BEGIN{exit !(p+0>=t+0)}' || exit 0
re_ctx Stop "Friction cost time this turn. Before finishing, log it once: ~/.claude/hooks/jev/papercut-dedupe.sh <source> \"<symptom>\" \"<fix>\" \"<project/path>\" (it skips duplicates and appends via papercut.sh). Do not edit the log by hand. If you already logged it, ignore this."
exit 0
