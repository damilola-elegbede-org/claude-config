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
META_MODE=$(re_mode executive-lint-meta "$LINT_MODE")
BARE_MODE=$(re_mode executive-lint-bare-id "$LINT_MODE")
# Tag problems on replies this short are logged (tagshort) but never block, unless the reply asks D a question
# (a "?" means D has a move to make, so it needs its INPUT/DECISION tag).
TAG_MIN_CHARS=0
[ "$SESSION_SCOPE" = bgjob ] && TAG_MIN_CHARS=$(re_cfg executive-lint bgjob_tag_min_chars 500)
case "$TAG_MIN_CHARS" in '' | *[!0-9]*) TAG_MIN_CHARS=0 ;; esac
# Where a bare ticket ID should link; the block message quotes it so the agent never invents a slug-less URL.
LINEAR_URL=$(re_cfg executive-lint linear_issue_url "${RE_LINEAR_URL:-https://linear.app/bareclaude/issue}")
MAX_LINES=$(re_cfg executive-lint max_lines 60)
case "$MAX_LINES" in '' | *[!0-9]*) MAX_LINES=60 ;; esac

# --- regex checks -------------------------------------------------------------
LINT=$(printf '%s' "$MSG" | RE_MAX_LINES="$MAX_LINES" RE_LINEAR="${RE_LINEAR_PREFIXES:-ENG|OPS}" RE_TAG_MIN="$TAG_MIN_CHARS" RE_LINEAR_URL="$LINEAR_URL" python3 -c '
import os, re, sys
msg = sys.stdin.read()
lines = msg.rstrip("\n").split("\n")
TAGS = "FYI|DECISION|APPROVAL|INPUT|ACTION|BLOCKED"
problems = []
first = next((l for l in lines if l.strip()), "")
m = re.match(r"^\*\*(" + TAGS + r")(?=[\s*:·—-]|$)", first.strip())
tag = m.group(1) if m else ""
if not m or first.count("**") < 2:
    code = "tag" if (len(msg) > int(os.environ.get("RE_TAG_MIN", "0")) or "?" in msg) else "tagshort"
    problems.append(code + "\tline 1 must be one bold sentence starting with a tag (" + TAGS.replace("|", "/") + "), e.g. **ACTION · conclusion.** (DECISION/APPROVAL/ACTION/BLOCKED also need line 2 to be exactly: Confidence **high/medium/low** (basis) · Reversible **yes/no** · Deadline **when**)")
if tag in ("DECISION", "APPROVAL", "ACTION", "BLOCKED"):
    head = "\n".join(lines[:6])
    if not (re.search(r"Confidence\b", head) and re.search(r"Reversible\b", head) and re.search(r"Deadline\b", head)):
        problems.append("meta\t" + tag + " needs the meta line right after line 1: Confidence **high/medium/low** (basis) · Reversible **yes/no** · Deadline **when**")
limit = int(os.environ.get("RE_MAX_LINES", "60"))
if len(lines) > limit:
    problems.append("len\treply is %d lines; a brief fits on one screen (max %d) — cut it, or move the bulk into an artifact/file" % (len(lines), limit))
body = re.sub(r"```.*?```", " ", msg, flags=re.S)
body = re.sub(r"`[^`\n]*`", " ", body)
body = re.sub(r"\[[^\]]*\]\([^)]*\)", " ", body)
body = re.sub(r"https?://\S+", " ", body)
bare = sorted(set(re.findall(r"(?<![\w/.-])(?:" + os.environ.get("RE_LINEAR", "ENG|OPS") + r")-\d+\b", body)))
if bare:
    problems.append("bare\tbare Linear ID(s) " + ", ".join(bare) + " — every ticket reference is a full clickable link, including in line 1: [ID](" + os.environ.get("RE_LINEAR_URL", "") + "/ID)")
print(tag)
for p in problems:
    print(p)
' 2>/dev/null)
TAG=$(printf '%s\n' "$LINT" | head -1)
PROBLEMS=$(printf '%s\n' "$LINT" | tail -n +2)

# --- Jev shadow checks (never affect the verdict unless a rule is set to enforce) --
EXTRA=""
SCOPE_FLASH=""
TAG_MODE=$(re_mode executive-tag-correctness shadow)
SRC_MODE=$(re_mode executive-unsourced-claims shadow)
SCOPE_MODE=$(re_mode executive-scope-creep shadow)
# A background job's Jev model checks (tag-correctness, unsourced, scope) never block: forced to
# shadow. The regex lint modes (executive-lint, -meta, -bare-id) are honored per scope from the registry.
if [ "$SESSION_SCOPE" = bgjob ]; then
  for m in TAG_MODE SRC_MODE SCOPE_MODE; do
    [ "${!m}" = enforce ] && printf -v "$m" shadow
  done
  [ "$LINT_MODE$META_MODE$BARE_MODE$TAG_MODE$SRC_MODE$SCOPE_MODE" = offoffoffoffoffoff ] && exit 0
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
    # Long replies keep their head and tail: the tag is at the top and the Next line at the bottom.
    REPLY_J="$MSG"
    if [ "${#MSG}" -gt 3500 ]; then REPLY_J="${MSG:0:1200}"$'\n[... middle omitted ...]\n'"${MSG: -2200}"; fi
    STATE=$(jq -nc --arg reply "$REPLY_J" --arg prompt "$FIRST_PROMPT" --arg diff "$DIFFSTAT" \
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
          EXTRA="${EXTRA}tag ${TAG} looks wrong: D's next move reads as ${JTAG}. Retag line 1; DECISION, APPROVAL and ACTION also need the meta line (Confidence · Reversible · Deadline), and a DECISION, APPROVAL or INPUT goes to D through AskUserQuestion"$'\n'
        fi
      fi
      # Jev's score answer carries a probability per level, not a level: P(level>=2) = p["2"] + p["3"].
      JSRC=$(jq -r '.answers.unsourced.probabilities // empty | ((."2" // 0) + (."3" // 0))' <<<"$RESP" 2>/dev/null)
      if [ -n "$JSRC" ]; then
        re_log executive-unsourced-claims "p=$JSRC" ""
        if [ "$SRC_MODE" = enforce ] && \
          awk -v p="$JSRC" -v t="$(re_cfg executive-unsourced-claims threshold 0.92)" 'BEGIN{exit !(p+0>=t+0)}'; then
          EXTRA="${EXTRA}claims D may act on lack sources — add file:line / command output / URL, or mark untested or inference"$'\n'
        fi
      fi
      JSC=$(jq -r '.answers.scope.probability // empty' <<<"$RESP" 2>/dev/null)
      if [ -n "$JSC" ]; then
        re_log executive-scope-creep "p=$JSC" ""
        if [ "$SCOPE_MODE" = enforce ] && awk -v p="$JSC" -v t="$(re_cfg executive-scope-creep threshold 0.9)" 'BEGIN{exit !(p+0>=t+0)}'; then
          EXTRA="${EXTRA}the diff looks wider than the request (CLAUDE.md Changes: touch only what the request implies)"$'\n'
        fi
        # Advisory flash: never blocks, any mode but off, any scope (incl. bgjob), at most once per session.
        if awk -v p="$JSC" -v t="$(re_cfg executive-scope-creep flash_threshold 0.95)" 'BEGIN{exit !(p+0>=t+0)}'; then
          FLASH_MARK="$(re_session_dir "$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)")/scope-flash"
          if [ ! -e "$FLASH_MARK" ]; then
            mkdir -p "$(dirname "$FLASH_MARK")" 2>/dev/null && : >"$FLASH_MARK" 2>/dev/null
            SCOPE_FLASH="Jev: the changes so far look wider than what you asked for (scope check p=${JSC}). Advisory only; nothing was blocked."
            re_log executive-scope-creep flash "p=$JSC"
          fi
        fi
      fi
    fi
  fi
fi

# One would-block row per shadowed check (the old code logged only the first problem, hiding meta/bare).
BLOCKING=""
BLOCKCODES=""
while IFS=$'\t' read -r code text; do
  [ -n "$code" ] || continue
  case "$code" in
    tag) mode=$LINT_MODE ;;
    len) mode=$LINT_MODE ;;
    meta) mode=$META_MODE ;;
    bare) mode=$BARE_MODE ;;
    *) mode=shadow ;; # tagshort: short replies are never blocked
  esac
  case "$mode" in
    enforce)
      BLOCKING="${BLOCKING}${text}"$'\n'
      BLOCKCODES="${BLOCKCODES:+$BLOCKCODES,}$code"
      ;;
    shadow) re_log "executive-lint-$code" shadow-would-block "$text" ;;
  esac
done <<<"$PROBLEMS"
ALL=$(printf '%s%s' "$BLOCKING" "${EXTRA:+$'\n'$EXTRA}" | sed '/^$/d')
# A bgjob blocks only on regex-lint problems; Jev model extras are shadow-only there (forced above).
if [ -z "$ALL" ] || { [ "$SESSION_SCOPE" = bgjob ] && [ -z "$BLOCKING" ]; }; then
  [ -n "$SCOPE_FLASH" ] && jq -nc --arg m "$SCOPE_FLASH" '{systemMessage:$m}'
  exit 0
fi
# D sees every Jev action: systemMessage is the user-visible channel (the model only gets `reason`).
WHAT="${BLOCKCODES:-jev model check}"
if [ "$ACTIVE" = true ]; then
  re_log executive-lint allow-stop-hook-active "$(printf '%s' "$ALL" | head -1)"
  jq -nc --arg m "Jev: executive-lint let a reply through after one retry, still off-style ($WHAT)${SCOPE_FLASH:+ | $SCOPE_FLASH}" '{systemMessage:$m}'
  exit 0
fi
re_log executive-lint block "$(printf '%s' "$ALL" | head -1)"
REASON="Executive style violations in your last reply (output style Executive; fix and send the corrected reply):"$'\n'"$(printf '%s' "$ALL" | sed 's/^/- /')"
jq -nc --arg r "$REASON" --arg m "Jev: executive-lint blocked a reply and asked for a rewrite ($WHAT)${SCOPE_FLASH:+ | $SCOPE_FLASH}" '{decision:"block",reason:$r,systemMessage:$m}'
exit 0
