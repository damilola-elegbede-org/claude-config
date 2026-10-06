#!/bin/bash
# Stop — lint the final reply against the Executive output style.
#
# Regex checks (mode "executive-lint", default ENFORCE) for INTERACTIVE main-agent
# sessions. Background jobs (CLAUDE_JOB_DIR) are linted in SHADOW only: every rule is
# logged as would-block and nothing ever blocks. Fleet (BARECLAUDE_AGENT_SLUG) and
# subagents (agent_id on stdin; SubagentStop is a different event) are skipped:
#   1. line 1 is one bold sentence starting with a tag: FYI|DECISION|APPROVAL|INPUT|ACTION|BLOCKED
#   2. DECISION|APPROVAL|ACTION|BLOCKED carry the meta line (Confidence/Reversible/Deadline)
#   3. at most max_lines lines (default 60)
#   4. no bare Linear IDs (ENG-1234) outside a markdown link / code
# A violation blocks with a reason. stop_hook_active is respected: never blocks twice
# in a row (the harness also overrides after 8 consecutive blocks).
#
# Jev checks, all SHADOW (one jev-ask call, three questions; logged, never block):
#   executive-tag-correctness  choice: which tag fits D's next move?
#   executive-unsourced-claims score : actionable claims without sources
#   executive-scope-creep      boolean: git diff --stat vs the first user prompt

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
SESSION_SCOPE=$(re_scope)
case "$SESSION_SCOPE" in interactive | bgjob) ;; *) exit 0 ;; esac
[ -z "$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null)" ] || exit 0

MSG=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$MSG" ] || exit 0
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)
TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)

LINT_MODE=$(re_mode executive-lint enforce)
MAX_LINES=$(re_cfg executive-lint max_lines 60)
case "$MAX_LINES" in '' | *[!0-9]*) MAX_LINES=60 ;; esac

# --- regex checks -------------------------------------------------------------
LINT=$(printf '%s' "$MSG" | RE_MAX_LINES="$MAX_LINES" RE_LINEAR="${RE_LINEAR_PREFIXES:-ENG|OPS}" python3 -c '
import os, re, sys
msg = sys.stdin.read()
lines = msg.rstrip("\n").split("\n")
TAGS = "FYI|DECISION|APPROVAL|INPUT|ACTION|BLOCKED"
problems = []
first = next((l for l in lines if l.strip()), "")
m = re.match(r"^\*\*(" + TAGS + r")(?=[\s*:·—-]|$)", first.strip())
tag = m.group(1) if m else ""
if not m or first.count("**") < 2:
    problems.append("line 1 must be one bold sentence starting with a tag (" + TAGS.replace("|", "/") + "), e.g. **ACTION · conclusion.**")
if tag in ("DECISION", "APPROVAL", "ACTION", "BLOCKED"):
    head = "\n".join(lines[:6])
    if not (re.search(r"Confidence\b", head) and re.search(r"Reversible\b", head) and re.search(r"Deadline\b", head)):
        problems.append(tag + " needs the meta line right after line 1: Confidence **high/medium/low** (basis) · Reversible **yes/no** · Deadline **when**")
limit = int(os.environ.get("RE_MAX_LINES", "60"))
if len(lines) > limit:
    problems.append("reply is %d lines; a brief fits on one screen (max %d) — cut it, or move the bulk into an artifact/file" % (len(lines), limit))
body = re.sub(r"```.*?```", " ", msg, flags=re.S)
body = re.sub(r"`[^`\n]*`", " ", body)
body = re.sub(r"\[[^\]]*\]\([^)]*\)", " ", body)
body = re.sub(r"https?://\S+", " ", body)
bare = sorted(set(re.findall(r"(?<![\w/.-])(?:" + os.environ.get("RE_LINEAR", "ENG|OPS") + r")-\d+\b", body)))
if bare:
    problems.append("bare Linear ID(s) " + ", ".join(bare) + " — every ticket reference is a full clickable link [ID](url)")
print(tag)
for p in problems:
    print(p)
' 2>/dev/null)
TAG=$(printf '%s\n' "$LINT" | head -1)
PROBLEMS=$(printf '%s\n' "$LINT" | tail -n +2)

# --- Jev shadow checks (never affect the verdict unless a rule is set to enforce) --
EXTRA=""
TAG_MODE=$(re_mode executive-tag-correctness shadow)
SRC_MODE=$(re_mode executive-unsourced-claims shadow)
SCOPE_MODE=$(re_mode executive-scope-creep shadow)
# A background job's report is read by D, never re-prompted: nothing blocks there. Whatever the
# registry says, every rule runs in shadow (logged as would-block) and the hook exits 0.
if [ "$SESSION_SCOPE" = bgjob ]; then
  for m in LINT_MODE TAG_MODE SRC_MODE SCOPE_MODE; do
    [ "${!m}" = enforce ] && printf -v "$m" shadow
  done
  [ "$LINT_MODE$TAG_MODE$SRC_MODE$SCOPE_MODE" = offoffoffoff ] && exit 0
fi
if [ "$ACTIVE" != true ] && [ -n "$TAG" ] && { [ "$TAG_MODE" != off ] || [ "$SRC_MODE" != off ] || [ "$SCOPE_MODE" != off ]; }; then
  FIRST_PROMPT=""
  if [ -f "$TRANSCRIPT" ]; then
    FIRST_PROMPT=$(python3 - "$TRANSCRIPT" <<'PYEOF' 2>/dev/null
import json, sys
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
    if isinstance(c, str) and c.strip() and not c.lstrip().startswith("<"):
        print(c.strip()[:1500])
        break
PYEOF
)
  fi
  DIFFSTAT=""
  if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    DIFFSTAT=$(git -C "$CWD" diff --stat HEAD 2>/dev/null | tail -40 | cut -c1-200)
  fi
  Q='{}'
  [ "$TAG_MODE" != off ] && Q=$(jq -c '. + {tag:{type:"choice",instructions:"Which tag names the single next move D must make after reading this reply?",criteria:{FYI:"D only reads; nothing is needed from D",DECISION:"D must choose between options",APPROVAL:"D must say yes or no to a plan",INPUT:"D must answer a question",ACTION:"D must do the one step only D can do: run a command, merge, upload, grant access, pay"}}}' <<<"$Q")
  [ "$SRC_MODE" != off ] && Q=$(jq -c '. + {unsourced:{type:"score",instructions:"How many factual claims D could act on in this reply lack a source (file:line, command output, URL, quote) and are not marked untested or inference?",criteria:["none: every actionable claim is sourced or marked untested/inference","one or two minor claims lack a source","several actionable claims lack a source","the key claims D would act on are bare assertions"]}}' <<<"$Q")
  if [ "$SCOPE_MODE" != off ] && [ -n "$DIFFSTAT" ] && [ -n "$FIRST_PROMPT" ]; then
    Q=$(jq -c '. + {scope:{type:"boolean",instructions:"Does the diff stat show changes beyond what the first user prompt asked for (refactors, adjacent files, extra features)?",criteria:{"true":"files or areas changed that the prompt did not imply","false":"every changed file is implied by the prompt"}}}' <<<"$Q")
  fi
  if [ "$Q" != '{}' ]; then
    STATE=$(jq -nc --arg reply "${MSG:0:3500}" --arg prompt "$FIRST_PROMPT" --arg diff "$DIFFSTAT" \
      '{reply:$reply,first_user_prompt:$prompt,diff_stat:$diff}')
    if RESP=$(re_jev_req executive-lint "$STATE" "$Q" 1500 | re_jev_call 2>/dev/null) && [ -n "$RESP" ]; then
      ACT_TAG="$TAG"
      [ "$ACT_TAG" = BLOCKED ] && ACT_TAG=ACTION
      JTAG=$(jq -r '.answers.tag.choice // empty' <<<"$RESP" 2>/dev/null)
      JP=$(jq -r --arg c "$JTAG" '.answers.tag.probabilities[$c] // empty' <<<"$RESP" 2>/dev/null)
      if [ -n "$JTAG" ]; then
        re_log executive-tag-correctness "$([ "$JTAG" = "$ACT_TAG" ] && echo agree || echo mismatch)" "actual=$ACT_TAG jev=$JTAG p=$JP"
        if [ "$TAG_MODE" = enforce ] && [ "$JTAG" != "$ACT_TAG" ] && \
          awk -v p="${JP:-0}" -v t="$(re_cfg executive-tag-correctness threshold 0.9)" 'BEGIN{exit !(p+0>=t+0)}'; then
          EXTRA="${EXTRA}tag ${TAG} looks wrong: D's next move reads as ${JTAG}"$'\n'
        fi
      fi
      # Jev's score answer carries a probability per level, not a level: P(level>=2) = p["2"] + p["3"].
      JSRC=$(jq -r '.answers.unsourced.probabilities // empty | ((."2" // 0) + (."3" // 0))' <<<"$RESP" 2>/dev/null)
      if [ -n "$JSRC" ]; then
        re_log executive-unsourced-claims "p=$JSRC" ""
        if [ "$SRC_MODE" = enforce ] && \
          awk -v p="$JSRC" -v t="$(re_cfg executive-unsourced-claims threshold 0.85)" 'BEGIN{exit !(p+0>=t+0)}'; then
          EXTRA="${EXTRA}claims D may act on lack sources — add file:line / command output / URL, or mark untested or inference"$'\n'
        fi
      fi
      JSC=$(jq -r '.answers.scope.probability // empty' <<<"$RESP" 2>/dev/null)
      if [ -n "$JSC" ]; then
        re_log executive-scope-creep "p=$JSC" ""
        if [ "$SCOPE_MODE" = enforce ] && awk -v p="$JSC" -v t="$(re_cfg executive-scope-creep threshold 0.9)" 'BEGIN{exit !(p+0>=t+0)}'; then
          EXTRA="${EXTRA}the diff looks wider than the request (CLAUDE.md Changes: touch only what the request implies)"$'\n'
        fi
      fi
    fi
  fi
fi

if [ -n "$PROBLEMS" ] && [ "$LINT_MODE" = shadow ]; then
  re_log executive-lint shadow-would-block "$(printf '%s' "$PROBLEMS" | head -1)"
fi
BLOCKING=""
[ "$LINT_MODE" = enforce ] && BLOCKING="$PROBLEMS"
ALL=$(printf '%s%s' "$BLOCKING" "${EXTRA:+$'\n'$EXTRA}" | sed '/^$/d')
[ -n "$ALL" ] || exit 0

[ "$SESSION_SCOPE" = bgjob ] && exit 0
if [ "$ACTIVE" = true ]; then
  re_log executive-lint allow-stop-hook-active "$(printf '%s' "$ALL" | head -1)"
  exit 0
fi
re_log executive-lint block "$(printf '%s' "$ALL" | head -1)"
REASON="Executive style violations in your last reply (output style Executive; fix and send the corrected reply, do not mention this check):"$'\n'"$(printf '%s' "$ALL" | sed 's/^/- /')"
re_block "$REASON"
exit 0
