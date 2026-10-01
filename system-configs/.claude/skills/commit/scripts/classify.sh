#!/bin/bash
# classify.sh — optional change classifier for /commit and /branch.
#
#   classify.sh commit                  # staged diff (else working-tree diff vs HEAD)
#   classify.sh branch "<description>"  # branch-type hint for the description
#
# stdout: one JSON object. Always present: helper, mode, deterministic_type (regex on
# the changed paths: test|docs|ci|null). In ENFORCE mode also the Jev answers:
#   commit: type (conventional type), type_p, mixed (bool), mixed_p
#   branch: type (feature|fix|hotfix|enhancement|experiment), type_p, mixed, mixed_p
# "mixed" = the working changes mix unrelated concerns (offer to split into commits).
# Rules workflow-commit-type, workflow-commit-mixed, workflow-branch-type — default
# SHADOW: Jev is called and logged, the answers are withheld. Advisory only: the
# skill's own message rules decide. Fails open (prints mode "unavailable", exit 0).

# shellcheck source-path=SCRIPTDIR source=../../../hooks/jev/rules-events-lib.sh
. "$(dirname "$0")/../../../hooks/jev/rules-events-lib.sh" 2>/dev/null || { echo '{"helper":"classify","mode":"unavailable"}'; exit 0; }
re_need_jq || { echo '{"helper":"classify","mode":"unavailable"}'; exit 0; }

KIND="${1:-commit}"
DESC="${2:-}"

if [ "$KIND" = branch ]; then
  TYPE_RULE=workflow-branch-type
else
  TYPE_RULE=workflow-commit-type
fi
TYPE_MODE=$(re_mode "$TYPE_RULE" shadow)
MIX_MODE=$(re_mode workflow-commit-mixed shadow)
if [ "$TYPE_MODE" = off ] && [ "$MIX_MODE" = off ]; then
  echo '{"helper":"classify","mode":"off"}'
  exit 0
fi

DIFF_ARGS=(--cached)
[ -n "$(git diff --cached --name-only 2>/dev/null | head -1)" ] || DIFF_ARGS=(HEAD)
FILES=$(git diff "${DIFF_ARGS[@]}" --name-only 2>/dev/null | head -80)
STAT=$(git diff "${DIFF_ARGS[@]}" --stat 2>/dev/null | tail -60 | cut -c1-200)
DIFFHEAD=$(git diff "${DIFF_ARGS[@]}" 2>/dev/null | head -c 6000)

DET=null
if [ -n "$FILES" ]; then
  if ! printf '%s\n' "$FILES" | grep -qvE '(^|/)(tests?|__tests__)/|\.(test|spec)\.'; then
    DET='"test"'
  elif ! printf '%s\n' "$FILES" | grep -qvE '\.(md|rst|txt)$|^docs/'; then
    DET='"docs"'
  elif ! printf '%s\n' "$FILES" | grep -qvE '^\.github/'; then
    DET='"ci"'
  fi
fi

Q='{}'
if [ "$KIND" = branch ]; then
  [ "$TYPE_MODE" != off ] && Q=$(jq -c '. + {type:{type:"choice",instructions:"Which branch type fits this description?",criteria:{feature:"new capability",fix:"bug fix",hotfix:"urgent production fix",enhancement:"improvement, refactor or optimisation of existing behaviour",experiment:"prototype, spike or proof of concept"}}}' <<<"$Q")
else
  [ "$TYPE_MODE" != off ] && Q=$(jq -c '. + {type:{type:"choice",instructions:"Which conventional-commit type fits these changes?",criteria:{feat:"new capability",fix:"bug fix",docs:"documentation only",style:"formatting only",refactor:"restructure without behaviour change",test:"tests only",chore:"maintenance, config, dependencies",perf:"performance improvement",ci:"CI pipeline changes"}}}' <<<"$Q")
fi
if [ "$MIX_MODE" != off ] && [ -n "$FILES" ]; then
  Q=$(jq -c '. + {mixed:{type:"boolean",instructions:"Do these changes mix unrelated concerns that belong in separate commits?",criteria:{"true":"two or more unrelated purposes in one change set","false":"one coherent purpose"}}}' <<<"$Q")
fi

OUT=$(jq -nc --arg k "$KIND" --argjson d "$DET" '{helper:"classify",kind:$k,deterministic_type:$d}')
if [ "$Q" = '{}' ]; then
  jq -c --arg m shadow '. + {mode:$m}' <<<"$OUT"
  exit 0
fi
STATE=$(jq -nc --arg desc "$DESC" --arg files "$FILES" --arg stat "$STAT" --arg diff "$DIFFHEAD" \
  '{description:$desc,changed_files:($files|split("\n")),diff_stat:$stat,diff_start:$diff}')
if ! RESP=$(re_jev_req "$TYPE_RULE" "$STATE" "$Q" 2000 | re_jev_call 2>/dev/null) || [ -z "$RESP" ]; then
  jq -c '. + {mode:"unavailable"}' <<<"$OUT"
  exit 0
fi
JT=$(jq -r '.answers.type.choice // empty' <<<"$RESP" 2>/dev/null)
JTP=$(jq -r --arg c "$JT" '.answers.type.probabilities[$c] // empty' <<<"$RESP" 2>/dev/null)
JM=$(jq -r '.answers.mixed.probability // empty' <<<"$RESP" 2>/dev/null)
re_log "$TYPE_RULE" "type=$JT p=$JTP mixed_p=$JM" "kind=$KIND type_mode=$TYPE_MODE mix_mode=$MIX_MODE"

RES="$OUT"
if [ "$TYPE_MODE" = enforce ] && [ -n "$JT" ]; then
  RES=$(jq -c --arg t "$JT" --arg p "${JTP:-0}" '. + {type:$t,type_p:($p|tonumber)}' <<<"$RES")
fi
if [ "$MIX_MODE" = enforce ] && [ -n "$JM" ]; then
  RES=$(jq -c --arg p "$JM" --arg th "$(re_cfg workflow-commit-mixed threshold 0.8)" '. + {mixed:(($p|tonumber) >= ($th|tonumber)),mixed_p:($p|tonumber)}' <<<"$RES")
fi
if [ "$TYPE_MODE" = enforce ] || [ "$MIX_MODE" = enforce ]; then
  jq -c '. + {mode:"enforce"}' <<<"$RES"
else
  jq -c '. + {mode:"shadow"}' <<<"$RES"
fi
exit 0
