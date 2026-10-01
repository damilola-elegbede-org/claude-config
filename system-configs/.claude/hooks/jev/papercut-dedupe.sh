#!/bin/bash
# papercut-dedupe.sh SOURCE SYMPTOM FIX PROJECT/PATH
#
# Drop-in wrapper for ~/.claude/papercut.sh that refuses to log the same papercut
# twice (CLAUDE.md "Papercuts": "never log the same papercut twice").
#   1. Deterministic: the normalized symptom already appears in the live log or the
#      archive → print "duplicate", append nothing, exit 0.
#   2. Jev boolean "restates an existing entry?" against the most similar log lines
#      (rule papercut-dedupe, default SHADOW: logged; only in enforce mode and at or
#      above the threshold does it skip the append).
# Jev unavailable → append (fail open). Never edits the log itself: appends go
# through papercut.sh, the only sanctioned writer.
# Env: PAPERCUT_LOG (log path), PAPERCUT_SH (writer path).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
WRITER="${PAPERCUT_SH:-$HERE/../../papercut.sh}"
[ -x "$WRITER" ] || WRITER="$RE_CLAUDE_DIR/papercut.sh"
LOG="${PAPERCUT_LOG:-$RE_CLAUDE_DIR/papercuts.md}"

if [ "$#" -ne 4 ]; then
  exec "$WRITER" "$@" # let papercut.sh print its own usage error
fi
SYMPTOM="$2"

if ! re_need_jq; then
  exec "$WRITER" "$@"
fi
MODE=$(re_mode papercut-dedupe shadow)

# 1. deterministic exact-symptom check
NORM=$(printf '%s' "$SYMPTOM" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
FILES=("$LOG")
for f in "$(dirname "$LOG")"/papercuts/archive/*.md; do [ -f "$f" ] && FILES+=("$f"); done
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  if tr '[:upper:]' '[:lower:]' <"$f" | tr -s '[:space:]' ' ' | grep -qF -- "$NORM"; then
    re_log papercut-dedupe duplicate-exact ""
    echo "duplicate: this symptom is already in the papercut log; nothing appended"
    exit 0
  fi
done

# 2. Jev near-duplicate check against the most similar entries
if [ "$MODE" != off ] && [ -f "$LOG" ]; then
  CANDS=$(printf '%s' "$NORM" | RE_LOG_FILE="$LOG" python3 -c '
import os, re, sys
norm = sys.stdin.read()
words = {w for w in re.findall(r"[a-z0-9_.-]{4,}", norm)}
rows = []
for ln in open(os.environ["RE_LOG_FILE"], encoding="utf-8", errors="replace").read().splitlines():
    if not re.match(r"^\d{4}-\d{2}-\d{2} · ", ln):
        continue
    s = sum(1 for w in words if w in ln.lower())
    if s:
        rows.append((s, ln[:300]))
rows.sort(key=lambda t: -t[0])
print("\n".join(l for _, l in rows[:12]))
' 2>/dev/null)
  if [ -n "$CANDS" ]; then
    STATE=$(jq -nc --arg cand "$SYMPTOM" --arg fix "$3" --arg existing "$CANDS" \
      '{candidate:{symptom:$cand,fix:$fix},existing_entries:($existing|split("\n"))}')
    Q='{"duplicate":{"type":"boolean","instructions":"Does the candidate papercut describe the same underlying problem as any existing entry, even if worded differently?","criteria":{"true":"an existing entry records the same symptom and cause","false":"no existing entry covers this"}}}'
    if RESP=$(re_jev_req papercut-dedupe "$STATE" "$Q" 1500 | re_jev_call 2>/dev/null) && [ -n "$RESP" ]; then
      P=$(jq -r '.answers.duplicate.probability // empty' <<<"$RESP" 2>/dev/null)
      if [ -n "$P" ]; then
        re_log papercut-dedupe "jev p=$P" "mode=$MODE"
        if [ "$MODE" = enforce ] && awk -v p="$P" -v t="$(re_cfg papercut-dedupe threshold 0.9)" 'BEGIN{exit !(p+0>=t+0)}'; then
          echo "duplicate: an existing entry already covers this (Jev p=$P); nothing appended"
          exit 0
        fi
      fi
    fi
  fi
fi

exec "$WRITER" "$@"
