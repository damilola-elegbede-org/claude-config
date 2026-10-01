#!/bin/bash
# PreToolUse(Write) — before a NEW memory file is written, ask Jev (boolean, rule
# memory-dup-guard, default SHADOW) whether it duplicates an entry already in
# MEMORY.md. Never denies. Shadow = log only; enforce = additionalContext naming
# the most similar existing entry (local token overlap) and telling Claude to update
# it instead. Covers Write to */memory/*.md except MEMORY.md; an existing target is
# an update, not a new memory, and is skipped.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
FILE=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null)
case "$FILE" in */memory/*.md) ;; *) exit 0 ;; esac
[ "$(basename "$FILE")" = MEMORY.md ] && exit 0
[ -e "$FILE" ] && exit 0
MODE=$(re_mode memory-dup-guard shadow)
[ "$MODE" = off ] && exit 0
# Egress: a memory written inside an excluded (work) tree never leaves the machine, whatever the session cwd.
# shellcheck source-path=SCRIPTDIR source=ctx-lib.sh
. "$(dirname "$0")/ctx-lib.sh" || exit 0
ctx_path_excluded "$FILE" && exit 0
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$CWD" ] && ctx_path_excluded "$CWD" && exit 0

INDEX="$(dirname "$FILE")/MEMORY.md"
[ -f "$INDEX" ] || exit 0
CONTENT=$(jq -r '.tool_input.content // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$CONTENT" ] || exit 0

NEW_NAME=$(printf '%s\n' "$CONTENT" | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d '"')
NEW_DESC=$(printf '%s\n' "$CONTENT" | sed -n 's/^description:[[:space:]]*//p' | head -1 | tr -d '"')
BODY=$(printf '%s\n' "$CONTENT" | awk 'BEGIN{n=0} /^---[[:space:]]*$/ {n++; next} n>=2 {print}' | head -c 800)

# Local similarity: best-overlapping index line (also names the candidate in the nudge).
BEST=$(printf '%s\n%s' "$NEW_NAME $NEW_DESC" "$BODY" | RE_INDEX="$INDEX" python3 -c '
import os, re, sys
new = sys.stdin.read().lower()
nw = {w for w in re.findall(r"[a-z0-9]{4,}", new)}
best, bl = 0.0, ""
for ln in open(os.environ["RE_INDEX"], encoding="utf-8", errors="replace"):
    if not ln.startswith("- ["):
        continue
    w = {x for x in re.findall(r"[a-z0-9]{4,}", ln.lower())}
    if not w or not nw:
        continue
    j = len(w & nw) / len(w | nw)
    if j > best:
        best, bl = j, ln.strip()
m = re.search(r"\]\(([^)]+)\)", bl)
print("%.2f\t%s\t%s" % (best, m.group(1) if m else "", bl[:200]))
' 2>/dev/null)
BEST_FILE=$(printf '%s' "$BEST" | cut -f2)

STATE=$(jq -nc --arg name "$NEW_NAME" --arg desc "$NEW_DESC" --arg body "$BODY" \
  --arg index "$(grep '^- \[' "$INDEX" | cut -c1-300 | head -150)" \
  '{new_memory:{name:$name,description:$desc,body_start:$body},existing_index_lines:($index|split("\n"))}')
Q='{"duplicate":{"type":"boolean","instructions":"Does the new memory restate a fact or rule that an existing index line already records, so it should update that entry instead?","criteria":{"true":"an existing entry already covers the same fact or rule","false":"this is new information"}}}'
RESP=$(re_jev_req memory-dup-guard "$STATE" "$Q" 1200 | re_jev_call 2>/dev/null) || exit 0
P=$(jq -r '.answers.duplicate.probability // empty' <<<"$RESP" 2>/dev/null)
[ -n "$P" ] || exit 0
re_log memory-dup-guard "p=$P" "mode=$MODE name=$NEW_NAME"
[ "$MODE" = enforce ] || exit 0
awk -v p="$P" -v t="$(re_cfg memory-dup-guard threshold 0.9)" 'BEGIN{exit !(p+0>=t+0)}' || exit 0
re_ctx PreToolUse "Possible duplicate memory: ${NEW_NAME:-the new entry} may restate an existing one${BEST_FILE:+ (closest index entry: ${BEST_FILE})}. Check MEMORY.md and update that file instead of creating a new one, unless this is genuinely new."
exit 0
