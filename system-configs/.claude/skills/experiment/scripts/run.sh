#!/bin/bash
# run.sh <dir>                              run every condition x rep in plan.json, append rows to runs.jsonl
# run.sh <dir> --record <cond> <rep> <json> [note]   append one observation made by hand (ask-d steps, judgment)
#
# Refuses, before anything runs, when:
#   - the experiment is not locked, or protocol.json / plan.json changed since lock.sh
#   - protocol side_effects is not "sandbox" (an ask-d experiment's gated step is run by the main session itself,
#     where the gates see it, and recorded with --record)
#   - the regex gate (gate.sh) would stop any condition's cmd or observe command. Commands run here are
#     subprocesses the PreToolUse gates never see, so each one is screened through gate.sh first; anything it
#     would stop is refused, never run. EXPERIMENT_GATE overrides the gate path (tests); a missing gate refuses.
#
# Every run: cwd <dir>/work; HOME stays real unless the condition says "home": "sandbox" (then <dir>/home); env
# EXPERIMENT_DIR, EXPERIMENT_WORK, EXPERIMENT_HOME, EXPERIMENT_CONDITION, EXPERIMENT_REP; a timeout_s kill;
# stdout/stderr kept in full under runs/. Order is shuffled per rep with plan.seed, so no condition always runs
# first. Re-running skips condition/rep pairs already recorded, so an interrupted run resumes.
#
# Row: {condition, rep, exit, secs, timed_out, value, out_tail, err_tail, started, source}
#   value: observe null -> exit == 0; "judge" -> null (a blind judge fills it); a command -> its stdout as JSON,
#   else as a string. The observe command sees RUN_OUT, RUN_ERR (file paths) and RUN_EXIT.
set -uo pipefail

dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: run.sh <experiment-dir> [--record <cond> <rep> <json> [note]]" >&2; exit 64; }
dir="$(cd "$dir" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/score.py" --check-lock "$dir" || exit 65
plan="$dir/plan.json"
rows="$dir/runs.jsonl"
touch "$rows"

has_row() { jq -e --arg c "$1" --argjson r "$2" 'select(.condition == $c and .rep == $r)' "$rows" >/dev/null 2>&1; }

if [ "${2:-}" = "--record" ]; then
  cond="${3:-}" rep="${4:-}" val="${5:-}" note="${6:-}"
  jq -e --arg c "$cond" '.conditions[] | select(.name == $c)' "$plan" >/dev/null 2>&1 || { echo "unknown condition: $cond" >&2; exit 64; }
  case "$rep" in "" | *[!0-9]*) echo "rep must be a positive integer" >&2; exit 64 ;; esac
  # jq . (not jq -e): a literal false or null is valid JSON and a valid observation
  [ -n "$val" ] && printf '%s' "$val" | jq . >/dev/null 2>&1 || { echo "value must be JSON (true, false, a number, a quoted string)" >&2; exit 64; }
  if has_row "$cond" "$rep"; then echo "refused: $cond rep $rep is already recorded" >&2; exit 65; fi
  jq -nc --arg c "$cond" --argjson r "$rep" --argjson v "$val" --arg n "$note" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{condition:$c, rep:$r, value:$v, note:$n, started:$t, source:"manual"}' >>"$rows"
  echo "recorded $cond rep $rep = $val"
  exit 0
fi

side=$(jq -r '.side_effects' "$dir/protocol.json")
if [ "$side" != "sandbox" ]; then
  echo "refused: side_effects is $side, not sandbox. Run the gated step yourself in the main session (the gates see it there), then record it with: run.sh $dir --record <cond> <rep> <json>" >&2
  exit 65
fi

gate="${EXPERIMENT_GATE:-$HOME/.claude/hooks/gate.sh}"
[ -f "$gate" ] || { echo "refused: no regex gate at $gate to screen commands; set EXPERIMENT_GATE" >&2; exit 65; }
gate_home="$dir/.gatehome"
mkdir -p "$gate_home"
screen() { # cmd -> 0 when the regex gate would let it run
  local out
  out=$(jq -nc --arg c "$1" --arg w "$dir/work" '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w, session_id:"experiment-screen", transcript_path:""}' |
    env -u CLAUDE_JOB_DIR -u BARECLAUDE_AGENT_SLUG HOME="$gate_home" bash "$gate" 2>/dev/null)
  ! printf '%s' "$out" | grep -q '"permissionDecision":"\(deny\|ask\)"'
}
refused=0
while IFS=$'\t' read -r name kind text; do
  if ! screen "$text"; then
    echo "refused: the regex gate would stop $name's $kind command: $text" >&2
    refused=1
  fi
done < <(jq -r '.conditions[] | [.name, "cmd", .cmd], (select(.observe != null and .observe != "judge") | [.name, "observe", .observe]) | @tsv' "$plan")
[ "$refused" = 0 ] || { echo "nothing ran. Take a gated step to D, or redesign it to stay inside $dir" >&2; exit 65; }

timeout_s=$(jq -r '.timeout_s // 120' "$plan")
seed=$(jq -r '.seed // 1' "$plan")
order=$(python3 - "$plan" "$seed" <<'PY'
import json, random, sys
plan = json.load(open(sys.argv[1]))
names = [c["name"] for c in plan["conditions"]]
for rep in range(1, plan["reps"] + 1):
    rng = random.Random(int(sys.argv[2]) * 1000003 + rep)
    batch = names[:]
    rng.shuffle(batch)
    for n in batch:
        print(f"{rep}\t{n}")
PY
)

ran=0 skipped=0
while IFS=$'\t' read -r rep name; do
  [ -n "$name" ] || continue
  if has_row "$name" "$rep"; then skipped=$((skipped + 1)); continue; fi
  cmd=$(jq -r --arg c "$name" '.conditions[] | select(.name == $c) | .cmd' "$plan")
  obs=$(jq -r --arg c "$name" '.conditions[] | select(.name == $c) | .observe // ""' "$plan")
  homemode=$(jq -r --arg c "$name" '.conditions[] | select(.name == $c) | .home // "real"' "$plan")
  run_home="$HOME"
  [ "$homemode" = "sandbox" ] && run_home="$dir/home"
  out="$dir/runs/$name-$rep.out" err="$dir/runs/$name-$rep.err"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t0=$(python3 -c 'import time; print(time.time())')
  (cd "$dir/work" && env HOME="$run_home" EXPERIMENT_DIR="$dir" EXPERIMENT_WORK="$dir/work" EXPERIMENT_HOME="$dir/home" \
    EXPERIMENT_CONDITION="$name" EXPERIMENT_REP="$rep" \
    perl -e 'alarm shift; exec @ARGV or exit 127' "$timeout_s" bash -c "$cmd") >"$out" 2>"$err" </dev/null
  code=$?
  t1=$(python3 -c 'import time; print(time.time())')
  timed_out=false
  [ "$code" = 142 ] && timed_out=true
  if [ -z "$obs" ]; then
    val=$([ "$code" = 0 ] && echo true || echo false)
  elif [ "$obs" = "judge" ]; then
    val=null
  else
    ov=$(cd "$dir/work" && env HOME="$run_home" RUN_OUT="$out" RUN_ERR="$err" RUN_EXIT="$code" EXPERIMENT_DIR="$dir" \
      EXPERIMENT_CONDITION="$name" EXPERIMENT_REP="$rep" perl -e 'alarm shift; exec @ARGV or exit 127' 60 bash -c "$obs" 2>/dev/null </dev/null)
    ov=$(printf '%s' "$ov" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$ov" ] && printf '%s' "$ov" | jq -c . >/dev/null 2>&1 && [ "$(printf '%s' "$ov" | jq -s 'length')" = 1 ]; then val=$(printf '%s' "$ov" | jq -c .); else val=$(jq -Rn --arg s "$ov" '$s'); fi
  fi
  jq -nc --arg c "$name" --argjson r "$rep" --argjson e "$code" --argjson s "$(python3 -c "print(round($t1 - $t0, 3))")" \
    --argjson to "$timed_out" --argjson v "$val" --arg ot "$(tail -c 500 "$out")" --arg et "$(tail -c 500 "$err")" \
    --arg t "$started" \
    '{condition:$c, rep:$r, exit:$e, secs:$s, timed_out:$to, value:$v, out_tail:$ot, err_tail:$et, started:$t, source:"run.sh"}' >>"$rows"
  ran=$((ran + 1))
done <<<"$order"
echo "ran $ran, skipped $skipped already recorded; rows in $rows"
