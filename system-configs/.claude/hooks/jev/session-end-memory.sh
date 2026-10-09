#!/bin/bash
# SessionEnd — did D correct Claude in a way worth saving as a memory? Regex
# pre-filter over D's own messages (correction cues), then ONE Jev boolean (rule
# session-end-memory, default SHADOW) over just those messages. Candidates are
# appended to ~/.claude/memory-candidates.md for D to review; nothing is written to
# memory itself. In shadow the Jev answer is only logged; the candidate file gets a
# line only in enforce mode.
#
# SessionEnd shares a 1.5s budget unless the settings entry raises `timeout`; this
# hook fails open (exit 0, no output) on any problem. Interactive sessions only.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
MODE=$(re_mode session-end-memory shadow)
[ "$MODE" = off ] && exit 0
[ "$(re_scope)" = interactive ] || exit 0
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
[ -f "$TRANSCRIPT" ] || exit 0
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)

CORR=$(python3 - "$TRANSCRIPT" <<'PYEOF' 2>/dev/null
import json, re, sys
CUE = re.compile(r"(^|\W)(no[,.! ]|don'?t|do not|stop |not what|wrong|i said|i told you|actually|instead|never |always |that'?s not|shouldn'?t|should not|please don'?t|why did you)", re.I)
out = []
try:
    for line in open(sys.argv[1]):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "user":
            continue
        c = (e.get("message") or {}).get("content")
        if isinstance(c, list):
            c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
        if not isinstance(c, str):
            continue
        c = c.strip()
        if not c or c.startswith("<") or len(c) > 1200:
            continue
        if CUE.search(c):
            out.append(c[:400].replace("\n", " "))
except OSError:
    pass
for c in out[-12:]:
    print(c)
PYEOF
)
[ -n "$CORR" ] || exit 0

STATE=$(jq -nc --arg msgs "$CORR" '{user_messages_with_correction_cues:($msgs|split("\n"))}')
Q='{"memory_worthy":{"type":"boolean","instructions":"Do these messages from D contain a correction or standing preference about how Claude should behave that is general enough to save as a memory for future sessions (not a one-off task instruction)?","criteria":{"true":"D corrected Claude or stated a durable preference, rule or constraint","false":"only task-specific instructions or incidental wording"}}}'
RESP=$(re_jev_req session-end-memory "$STATE" "$Q" 1000 | re_jev_call 2>/dev/null) || exit 0
P=$(jq -r '.answers.memory_worthy.probability // empty' <<<"$RESP" 2>/dev/null)
[ -n "$P" ] || exit 0
re_log session-end-memory "p=$P" "mode=$MODE"
[ "$MODE" = enforce ] || exit 0
awk -v p="$P" -v t="$(re_cfg session-end-memory threshold 0.8)" 'BEGIN{exit !(p+0>=t+0)}' || exit 0

CAND_FILE="${MEMORY_CANDIDATES_FILE:-$RE_CLAUDE_DIR/memory-candidates.md}"
mkdir -p "$(dirname "$CAND_FILE")" 2>/dev/null || exit 0
[ -f "$CAND_FILE" ] || printf '%s\n' '# Memory candidates' 'Corrections from D that may deserve a memory entry. Review, then save or discard; never auto-written to memory.' 'Format: date (UTC) · session · cwd · quote · p' >"$CAND_FILE"
QUOTE=$(printf '%s\n' "$CORR" | tail -1 | cut -c1-200 | tr '·' '.')
printf '%s · %s · %s · "%s" · p=%s\n' "$(date -u +%F)" "${SID:0:8}" "$(basename "$CWD")" "$QUOTE" "$P" >>"$CAND_FILE"
# The session is ending, so nothing can be drawn now: leave a note for the next SessionStart (session-start-project.sh) to flash.
mkdir -p "$RE_STATE_DIR" 2>/dev/null && jq -nc --arg q "$QUOTE" --arg p "$P" --arg f "$CAND_FILE" --argjson ts "$(date +%s)" \
  '{ts:$ts,quote:$q,p:$p,file:$f}' >"$RE_STATE_DIR/last-memory-candidate.json" 2>/dev/null
exit 0
