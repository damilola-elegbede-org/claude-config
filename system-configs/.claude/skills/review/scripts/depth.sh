#!/bin/bash
# depth.sh — optional review-depth hint for /review (branch-delta mode).
#
# stdout: {"helper":"depth","mode":...,"depth":"single|deep","floor":"single|deep",
#          "reason":"...","risk_level":0-3 (enforce only)}
#
# The deterministic FLOOR comes from changed paths (auth, secrets, payments,
# migrations, CI workflows, settings, hooks, sync, infra → deep). Jev (score "risk",
# rule workflow-review-depth, default SHADOW) can only RAISE depth above the floor,
# and only in enforce mode: level >= 2 → deep. Depth is never lowered below the
# floor, and this helper never approves, skips, or shortens a review — it only picks
# single vs deep. Fails open: on any problem the answer is the floor.

# shellcheck source-path=SCRIPTDIR source=../../../hooks/jev/rules-events-lib.sh
. "$(dirname "$0")/../../../hooks/jev/rules-events-lib.sh" 2>/dev/null || { echo '{"helper":"depth","mode":"unavailable","depth":"single","floor":"single","reason":"no lib"}'; exit 0; }
re_need_jq || { echo '{"helper":"depth","mode":"unavailable","depth":"single","floor":"single","reason":"no jq"}'; exit 0; }

BASE=$(git merge-base main HEAD 2>/dev/null || git merge-base master HEAD 2>/dev/null || echo HEAD)
FILES=$( { git diff --name-only "$BASE"..HEAD 2>/dev/null; git diff --name-only 2>/dev/null; } | sort -u | head -300)

FLOOR=single
REASON="no sensitive paths"
HIT=$(printf '%s\n' "$FILES" | grep -iE '(^|/)(auth|security|secrets?|crypt|payments?|billing|stripe|migrations?|infra)(/|[._-]|$)|\.github/workflows/|settings\.json$|(^|/)hooks/|sync\.sh$|Dockerfile|\.env' | head -3 | tr '\n' ' ')
if [ -n "$HIT" ]; then
  FLOOR=deep
  REASON="sensitive paths changed: ${HIT}"
fi
[ "$(printf '%s\n' "$FILES" | grep -c .)" -gt 40 ] && { FLOOR=deep; REASON="more than 40 files changed"; }

MODE=$(re_mode workflow-review-depth shadow)
BASEOUT=$(jq -nc --arg f "$FLOOR" --arg r "$REASON" '{helper:"depth",depth:$f,floor:$f,reason:$r}')
if [ "$MODE" = off ] || [ -z "$FILES" ]; then
  jq -c --arg m "$MODE" '. + {mode:$m}' <<<"$BASEOUT"
  exit 0
fi

STAT=$(git diff --stat "$BASE" 2>/dev/null | tail -60 | cut -c1-200)
DIFFHEAD=$(git diff "$BASE" 2>/dev/null | head -c 8000)
STATE=$(jq -nc --arg stat "$STAT" --arg diff "$DIFFHEAD" '{diff_stat:$stat,diff_start:$diff}')
Q='{"risk":{"type":"score","instructions":"How risky is this change set to merge without a thorough review?","criteria":["trivial: docs, comments, formatting, renames","ordinary logic change with tests","touches auth, data, payments, shell execution, infrastructure or permissions","security-critical or hard to reverse"]}}'
if ! RESP=$(re_jev_req workflow-review-depth "$STATE" "$Q" 2000 | re_jev_call 2>/dev/null) || [ -z "$RESP" ]; then
  jq -c '. + {mode:"unavailable"}' <<<"$BASEOUT"
  exit 0
fi
# Jev's score answer carries a probability per level, not a level: take the most likely level.
LVL=$(jq -r '.answers.risk.probabilities // empty | to_entries | max_by(.value) | .key' <<<"$RESP" 2>/dev/null)
re_log workflow-review-depth "level=$LVL floor=$FLOOR" "mode=$MODE"
if [ "$MODE" = enforce ] && [ -n "$LVL" ]; then
  DEPTH="$FLOOR"
  [ "$LVL" -ge 2 ] 2>/dev/null && DEPTH=deep
  jq -c --arg d "$DEPTH" --argjson l "$LVL" '. + {mode:"enforce",depth:$d,risk_level:$l}' <<<"$BASEOUT"
else
  jq -c '. + {mode:"shadow"}' <<<"$BASEOUT"
fi
exit 0
