#!/bin/bash
# SessionStart — two jobs, one hook.
#
# 1. Pending StopFailure hint: if stopfailure-hint.sh saved a known fix in the last
#    2 hours (same session id, or source=resume), inject it once as additionalContext
#    and mark it consumed. Deterministic, always on (rule stopfailure-hint).
# 2. Project memories: classify the project from cwd + git remote (regex map first;
#    Jev choice only when the map has no hit; rule session-project-memories, default
#    SHADOW) and inject the matching MEMORY.md one-liners. Shadow = log only.
#
# Interactive sessions only for job 2 (fleet and bg jobs carry their own context).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
SOURCE=$(jq -r '.source // empty' <<<"$INPUT" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

CTX=""

# --- 1. pending StopFailure hint ---------------------------------------------------
PEND="$RE_STATE_DIR/last-stopfailure.json"
if [ "$(re_mode stopfailure-hint enforce)" != off ] && [ -f "$PEND" ]; then
  TS=$(jq -r '.ts // 0' "$PEND" 2>/dev/null)
  PSID=$(jq -r '.session_id // empty' "$PEND" 2>/dev/null)
  NOW=$(date +%s)
  case "$TS" in '' | *[!0-9]*) TS=0 ;; esac
  if [ $((NOW - TS)) -le 7200 ] && { [ "$SOURCE" = resume ] || { [ -n "$SID" ] && [ "$SID" = "$PSID" ]; }; }; then
    H=$(jq -r '.hint // empty' "$PEND" 2>/dev/null)
    if [ -n "$H" ]; then
      CTX="Last turn of the previous session ended on an API error. ${H}"
      mv -f "$PEND" "$PEND.consumed" 2>/dev/null
      re_log stopfailure-hint injected "source=$SOURCE"
    fi
  fi
fi

# --- 2. project memories -----------------------------------------------------------
PROJ_MODE=$(re_mode session-project-memories shadow)
if [ "$PROJ_MODE" != off ] && [ "$(re_scope)" = interactive ]; then
  REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null | sed -E 's#(https?://)[^@/]*@#\1#' | cut -c1-200)
  HAY="$CWD $REMOTE"
  # project map: name|regex on cwd+remote|memory file stems (space separated, trailing * = prefix)
  MAP='alcbf|alocubano|alcbf-* vercel-project-pin-footgun libsql-remote-rejects-temp-tables
claude-config|claude-config|config-changes-via-claude-config claude-config-* claude-code-hooks-stdin-not-env claude-code-numeric-settings-must-be-numbers workflow-skills-are-model-invoked fleet-default-model-is-sonnet advisor-* executive-output-rules output-style-name-collisions
bareclaude|[Bb]are[Cc]laude|bareclaude-three-agents merge-policy-no-human-gate triage-records-agents-execute verify-ticket-premises-live hyperlink-linear-tickets job-app-tickets-close-on-delivery oriki-build-gates
damilola-tech|damilola\.tech|damilola-profile'
  PROJECT=""
  STEMS=""
  while IFS='|' read -r NAME RX FILES; do
    if printf '%s' "$HAY" | grep -qE "$RX"; then
      PROJECT="$NAME"
      STEMS="$FILES"
      break
    fi
  done <<<"$MAP"
  SRC=regex
  if [ -z "$PROJECT" ] && [ -n "$HAY" ]; then
    STATE=$(jq -nc --arg cwd "$(basename "$CWD")" --arg remote "$REMOTE" '{cwd_basename:$cwd,git_remote:$remote}')
    Q='{"project":{"type":"choice","instructions":"Which of D'"'"'s projects is this working directory?","criteria":{"alcbf":"ALCBF / alocubano boutique festival site","claude-config":"the Claude Code configuration repo","bareclaude":"the BareClaude agent fleet","damilola-tech":"damilola.tech personal site","other":"none of these"}}}'
    if RESP=$(re_jev_req session-project-memories "$STATE" "$Q" 1200 | re_jev_call 2>/dev/null) && [ -n "$RESP" ]; then
      JC=$(jq -r '.answers.project.choice // empty' <<<"$RESP" 2>/dev/null)
      JP=$(jq -r --arg c "$JC" '.answers.project.probabilities[$c] // empty' <<<"$RESP" 2>/dev/null)
      re_log session-project-memories "jev=$JC p=$JP" "mode=$PROJ_MODE"
      if [ "$PROJ_MODE" = enforce ] && awk -v p="${JP:-0}" -v t="$(re_cfg session-project-memories threshold 0.8)" 'BEGIN{exit !(p+0>=t+0)}'; then
        while IFS='|' read -r NAME _ FILES; do
          [ "$NAME" = "$JC" ] && { PROJECT="$NAME"; STEMS="$FILES"; SRC=jev; }
        done <<<"$MAP"
      fi
    fi
  fi
  if [ -n "$PROJECT" ]; then
    re_log session-project-memories "project=$PROJECT source=$SRC" "mode=$PROJ_MODE"
    if [ "$PROJ_MODE" = enforce ] && [ -f "$(re_memory_dir)/MEMORY.md" ]; then
      LINES=""
      read -r -a STEM_LIST <<<"$STEMS" # array, not word-splitting: prefix stems like alcbf-* must not glob
      for STEM in "${STEM_LIST[@]}"; do
        case "$STEM" in
          *'*') L=$(grep -E "\]\(${STEM%\*}[^)]*\.md\)" "$(re_memory_dir)/MEMORY.md" 2>/dev/null) ;;
          *) L=$(grep -F "](${STEM}.md)" "$(re_memory_dir)/MEMORY.md" 2>/dev/null) ;;
        esac
        [ -n "$L" ] && LINES="${LINES}${L}"$'\n'
      done
      LINES=$(printf '%s' "$LINES" | cut -c1-260 | head -12)
      [ -n "$LINES" ] && CTX="${CTX:+$CTX$'\n\n'}Memory entries relevant to this project (${PROJECT}):"$'\n'"${LINES}"
    fi
  fi
fi

[ -n "$CTX" ] || exit 0
re_ctx SessionStart "$CTX"
exit 0
