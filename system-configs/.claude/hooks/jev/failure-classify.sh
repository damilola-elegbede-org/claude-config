#!/bin/bash
# failure-classify.sh ci|verify — classify a failure log BEFORE spending retries.
# Used by /fix-ci (ci) and /verify (verify).
#
#   ci     → flaky | infra | real
#   verify → assertion | env | flaky
#
# stdin : the failing log (tail is enough; the Jev client redacts secrets again)
# stdout: {"helper":"failure-classify","kind":...,"class":...,"source":"regex|jev|none",
#          "steer":"one-line instruction","mode":...}
# Regex table first (source regex, always on). Only when it has no verdict does Jev
# (choice, rules workflow-ci-class / workflow-verify-class, default SHADOW) run; its
# answer is used only in enforce mode. Unclassified → class "unknown" and the skill
# proceeds exactly as before. Fails open (exit 0).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
KIND="${1:-ci}"
re_need_jq || { echo '{"helper":"failure-classify","class":"unknown","source":"none","mode":"unavailable"}'; exit 0; }

LOG=$(cat | tail -c 8000)
RULE="workflow-${KIND}-class"
MODE=$(re_mode "$RULE" shadow)

CLASS=unknown
SOURCE=none
INFRA='runner has received a shutdown|lost communication with the server|No space left on device|rate limit exceeded|Could not resolve host|ENOTFOUND|ECONNRESET|socket hang up|50[234] (Bad Gateway|Service|Gateway)|pull access denied|error pulling image|The operation was canceled|Unable to download|TLS handshake timeout'
FLAKY='flaky|Retrying \(|retry [0-9]+/[0-9]+|Test timeout of [0-9]+ms exceeded|Timeout - Async callback|ETXTBSY|EADDRINUSE|Target closed|browser has disconnected'
ENVRX='command not found|No such file or directory|ENOENT|Cannot find module .[^./]|ModuleNotFoundError|not installed|Permission denied|EACCES|ECONNREFUSED|executable file not found'
ASSERT='AssertionError|expected .{1,80} (received|to (equal|be|have|match))|Assertion failed|error TS[0-9]+|SyntaxError|\bFAIL\b|Failed tests|ESLint|lint error'

if [ "$KIND" = ci ]; then
  if printf '%s' "$LOG" | grep -qiE "$INFRA"; then CLASS=infra; SOURCE=regex
  elif printf '%s' "$LOG" | grep -qiE "$FLAKY"; then CLASS=flaky; SOURCE=regex
  elif printf '%s' "$LOG" | grep -qE "$ASSERT"; then CLASS=real; SOURCE=regex
  fi
else
  if printf '%s' "$LOG" | grep -qE "$ENVRX"; then CLASS="env"; SOURCE=regex
  elif printf '%s' "$LOG" | grep -qiE "$FLAKY"; then CLASS=flaky; SOURCE=regex
  elif printf '%s' "$LOG" | grep -qE "$ASSERT"; then CLASS=assertion; SOURCE=regex
  fi
fi

if [ "$CLASS" = unknown ] && [ "$MODE" != off ] && [ -n "$LOG" ]; then
  if [ "$KIND" = ci ]; then
    Q='{"class":{"type":"choice","instructions":"Classify this CI failure log.","criteria":{"flaky":"nondeterministic: timing, race, ordering, intermittent test","infra":"runner, network, registry, cache or rate-limit problem unrelated to the code","real":"deterministic failure caused by the code, tests or config under test"}}}'
  else
    Q='{"class":{"type":"choice","instructions":"Classify this failing verification gate output.","criteria":{"assertion":"a test, type check or lint rule failed because of the code","env":"missing binary, dependency, permission, service or other environment problem","flaky":"nondeterministic: timing, race, ordering, intermittent"}}}'
  fi
  STATE=$(jq -nc --arg log "$LOG" '{failure_log_tail:$log}')
  if RESP=$(re_jev_req "$RULE" "$STATE" "$Q" 2000 | re_jev_call 2>/dev/null) && [ -n "$RESP" ]; then
    JC=$(jq -r '.answers.class.choice // empty' <<<"$RESP" 2>/dev/null)
    JP=$(jq -r --arg c "$JC" '.answers.class.probabilities[$c] // empty' <<<"$RESP" 2>/dev/null)
    re_log "$RULE" "jev=$JC p=$JP" "mode=$MODE"
    if [ "$MODE" = enforce ] && [ -n "$JC" ] && awk -v p="${JP:-0}" -v t="$(re_cfg "$RULE" threshold 0.7)" 'BEGIN{exit !(p+0>=t+0)}'; then
      CLASS="$JC"
      SOURCE=jev
    fi
  fi
fi

case "$KIND:$CLASS" in
  ci:infra) STEER="Infrastructure, not code: re-run the failed jobs once (gh run rerun <run-id> --failed) before diagnosing; if it fails the same way again, diagnose." ;;
  ci:flaky) STEER="Looks nondeterministic: re-run once; if the same job fails again, treat it as real and diagnose." ;;
  ci:real) STEER="Deterministic failure: diagnose and fix; a plain re-run will not help." ;;
  verify:assertion) STEER="Code failure: fix the cause at file:line; each fix attempt counts toward the 3." ;;
  verify:env) STEER="Environment, not code: do not edit code or tests. Fix the environment once and re-run; if it cannot be fixed, report the gate as unavailable, never as a pass." ;;
  verify:flaky) STEER="Looks nondeterministic: re-run once unchanged; if it passes, report it as flaky rather than changing code; if it fails again, treat it as an assertion failure." ;;
  *) STEER="" ;;
esac
jq -nc --arg k "$KIND" --arg c "$CLASS" --arg s "$SOURCE" --arg st "$STEER" --arg m "$MODE" \
  '{helper:"failure-classify",kind:$k,class:$c,source:$s,steer:$st,mode:$m}'
exit 0
