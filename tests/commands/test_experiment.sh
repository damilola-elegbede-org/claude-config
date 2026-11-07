#!/bin/bash
# Tests for /experiment: SKILL.md shape, and the scripts' verdicts, lock, gate screen, timeouts, resume and blind judge.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SK="$ROOT/system-configs/.claude/skills/experiment"
S="$SK/scripts"
T=$(mktemp -d "${TMPDIR:-/tmp}/exp-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
export EXPERIMENTS_DIR="$T/exps"
export EXPERIMENT_GATE="$ROOT/system-configs/.claude/hooks/gate.sh"
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ ($2)}"; }
eq() { [ "$2" = "$3" ] && ok || bad "$1" "expected '$3', got '$2'"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1" "missing '$3' in: ${2:0:300}" ;; esac; }

# mk <slug> <protocol-overrides-json> <plan-json> -> a filled experiment dir (not locked)
mk() {
  local d
  d=$(bash "$S/new.sh" "$1")
  jq --argjson o "$2" '. + {question:"Does the treatment pass?", hypothesis:"The treatment passes every run.",
    prediction:"treatment passes 3/3", if_false:"treatment fails at least once"} + $o' "$d/protocol.json" >"$d/p.x" && mv "$d/p.x" "$d/protocol.json"
  printf '%s' "$3" >"$d/plan.json"
  printf '%s' "$d"
}
PLAN3='{"reps":3,"timeout_s":20,"seed":7,"conditions":[{"name":"treatment","cmd":"true","observe":null},{"name":"baseline","cmd":"false","observe":null},{"name":"negative-control","cmd":"false","observe":null}]}'

echo "== SKILL.md =="
F="$SK/SKILL.md"
[ -f "$F" ] && ok || bad "SKILL.md exists"
grep -q '^# /experiment' "$F" && ok || bad "H1 starts with # /experiment (pr-checks.yml)"
for s in "## Usage" "## Description" "## Expected Output" "## Behavior"; do grep -qF "$s" "$F" && ok || bad "SKILL.md has $s"; done
grep -q '^name: experiment$' "$F" && ok || bad "frontmatter name"
grep -q '^description: .*not sure' "$F" && ok || bad "description carries the proactive trigger phrases"
! grep -q 'disable-model-invocation' "$F" && ok || bad "model-invocable (never disable-model-invocation)"
for r in protocol designs safety judge; do [ -f "$SK/references/$r.md" ] && ok || bad "references/$r.md exists"; done
for x in new.sh lock.sh run.sh score.py; do [ -x "$S/$x" ] && ok || bad "$x is executable"; done
A="$ROOT/system-configs/.claude/agents/experiment-runner.md"
grep -q 'SYSTEM BOUNDARY' "$A" && ok || bad "runner agent has SYSTEM BOUNDARY"
! grep -q '^tools:.*Agent' "$A" && ok || bad "runner agent has no Agent tool"

echo "== scaffold + validation =="
D=$(bash "$S/new.sh" scaffold)
for p in protocol.json plan.json work home runs; do [ -e "$D/$p" ] && ok || bad "new.sh made $p"; done
out=$(bash "$S/lock.sh" "$D" 2>&1); code=$?
eq "template text cannot be locked" "$code" "3"
has "template refusal names the field" "$out" "still the template text"
eq "bad slug refused" "$(bash "$S/new.sh" 'Bad Slug' >/dev/null 2>&1; echo $?)" "64"
D=$(mk badref '{"pass_rule":{"type":"rate","condition":"nope","op":">=","value":1}}' "$PLAN3")
has "pass rule naming an unknown condition is invalid" "$(python3 "$S/score.py" --validate "$D" 2>&1)" "pass_rule.condition must name"
D=$(mk noctl '{"controls":[]}' "$PLAN3")
has "an experiment without a control is invalid" "$(python3 "$S/score.py" --validate "$D" 2>&1)" "add a negative control"

echo "== SUPPORTED / REFUTED / INCONCLUSIVE =="
D=$(mk sup '{}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null && ok || bad "lock a valid experiment"
has "run.sh runs 9" "$(bash "$S/run.sh" "$D" 2>&1)" "ran 9"
eq "9 rows" "$(wc -l <"$D/runs.jsonl" | tr -d ' ')" "9"
out=$(python3 "$S/score.py" "$D"); code=$?
eq "SUPPORTED exits 0" "$code" "0"
has "table shows the verdict" "$out" "Verdict: SUPPORTED"
has "table shows the interval" "$out" "| treatment | 3 | 0 | 3 | 1.00 |"
eq "verdict.json written" "$(jq -r .verdict "$D/verdict.json")" "SUPPORTED"
has "resume skips recorded runs" "$(bash "$S/run.sh" "$D" 2>&1)" "ran 0, skipped 9"
eq "conditions are interleaved, not run in plan order" "$(jq -r 'select(.rep==1) | .condition' "$D/runs.jsonl" | paste -sd, -)" \
  "$(python3 -c "import random; r=random.Random(7*1000003+1); b=['treatment','baseline','negative-control']; r.shuffle(b); print(','.join(b))")"

D=$(mk ref '{"pass_rule":{"type":"rate","condition":"baseline","op":">=","value":1}}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
python3 "$S/score.py" "$D" >/dev/null; eq "REFUTED exits 1" "$?" "1"

D=$(mk ctl '{}' "$(jq -c '.conditions[2].cmd = "true"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
out=$(python3 "$S/score.py" "$D"); code=$?
eq "a negative control that passes is INCONCLUSIVE" "$code" "2"
has "and says the test cannot discriminate" "$out" "cannot tell the hypothesis apart"

D=$(mk slow '{}' "$(jq -c '.timeout_s = 1 | .reps = 1 | .conditions[0].cmd = "sleep 5"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
eq "timeout recorded" "$(jq -r 'select(.condition=="treatment") | .timed_out' "$D/runs.jsonl")" "true"
python3 "$S/score.py" "$D" >/dev/null; eq "a timed-out run leaves the experiment INCONCLUSIVE" "$?" "2"

echo "== observe, mean, compare =="
PLANM='{"reps":2,"timeout_s":20,"seed":1,"conditions":[{"name":"treatment","cmd":"echo 12","observe":"cat \"$RUN_OUT\""},{"name":"baseline","cmd":"echo 10","observe":"cat \"$RUN_OUT\""},{"name":"negative-control","cmd":"echo 0","observe":"cat \"$RUN_OUT\""}]}'
D=$(mk cmp '{"pass_rule":{"type":"compare","stat":"mean","a":"treatment","b":"baseline","op":">","margin":1}}' "$PLANM")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
eq "observe stdout parsed as JSON" "$(jq -r 'select(.condition=="treatment") | .value' "$D/runs.jsonl" | head -1)" "12"
eq "a numeric value is stored as a number" "$(jq -r 'select(.condition=="treatment") | .value | type' "$D/runs.jsonl" | head -1)" "number"
python3 "$S/score.py" "$D" >/dev/null; eq "compare mean 12 > 10 + margin 1 SUPPORTED" "$?" "0"
D=$(mk cmp2 '{"pass_rule":{"type":"compare","stat":"mean","a":"treatment","b":"baseline","op":">","margin":5}}' "$PLANM")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
python3 "$S/score.py" "$D" >/dev/null; eq "compare mean 12 > 10 + margin 5 REFUTED" "$?" "1"
D=$(mk mean '{"pass_rule":{"type":"mean","condition":"treatment","op":"==","value":12}}' "$PLANM")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
python3 "$S/score.py" "$D" >/dev/null; eq "mean == 12 SUPPORTED" "$?" "0"

echo "== the lock holds =="
D=$(mk lk '{}' "$PLAN3")
out=$(bash "$S/run.sh" "$D" 2>&1); code=$?
eq "an unlocked experiment does not run" "$code" "65"
has "and says lock first" "$out" "not locked"
bash "$S/lock.sh" "$D" >/dev/null
jq '.pass_rule.value = 0' "$D/protocol.json" >"$D/x" && mv "$D/x" "$D/protocol.json"
has "a protocol edited after lock does not run" "$(bash "$S/run.sh" "$D" 2>&1)" "changed after lock.sh"
python3 "$S/score.py" "$D" >/dev/null 2>&1; eq "and does not score" "$?" "3"
D=$(mk relock '{}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
bash "$S/lock.sh" "$D" >/dev/null 2>&1; eq "re-locking after runs is refused" "$?" "65"
D=$(mk refuse '{"side_effects":"refuse"}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null 2>&1; eq "side_effects refuse cannot be locked" "$?" "65"

echo "== safety: sandbox only, gate screen =="
D=$(mk askd '{"side_effects":"ask-d"}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null
out=$(bash "$S/run.sh" "$D" 2>&1); code=$?
eq "an ask-d experiment never runs through run.sh" "$code" "65"
has "and says to run the gated step in the main session" "$out" "main session"
for c in treatment baseline negative-control; do for r in 1 2 3; do
  v=false; [ "$c" = treatment ] && v=true
  bash "$S/run.sh" "$D" --record "$c" "$r" "$v" "by hand" >/dev/null || bad "record $c $r"
done; done
python3 "$S/score.py" "$D" >/dev/null; eq "recorded observations score SUPPORTED" "$?" "0"
bash "$S/run.sh" "$D" --record treatment 1 true >/dev/null 2>&1; eq "a recorded pair cannot be overwritten" "$?" "65"
bash "$S/run.sh" "$D" --record treatment 4 'not json' >/dev/null 2>&1; eq "a non-JSON value is refused" "$?" "64"

D=$(mk gated '{}' "$(jq -c '.conditions[0].cmd = "git push origin --delete old-feature"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null
out=$(bash "$S/run.sh" "$D" 2>&1); code=$?
eq "a command the regex gate stops is refused" "$code" "65"
has "and named" "$out" "regex gate would stop treatment"
eq "nothing ran" "$(wc -c <"$D/runs.jsonl" | tr -d ' ')" "0"
D=$(mk gated2 '{}' "$(jq -c '.conditions[0].observe = "git push origin --delete x"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null
has "an observe command is screened too" "$(bash "$S/run.sh" "$D" 2>&1)" "treatment's observe command"
D=$(mk nogate '{}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null
has "a missing gate refuses" "$(EXPERIMENT_GATE="$T/none.sh" bash "$S/run.sh" "$D" 2>&1)" "no regex gate"
D=$(mk sbhome '{}' "$(jq -c '.reps = 1 | .conditions[0].home = "sandbox" | .conditions[0].cmd = "test \"$HOME\" = \"$EXPERIMENT_HOME\" && test \"$(pwd -P)\" = \"$(cd \"$EXPERIMENT_WORK\" && pwd -P)\""' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
eq "home sandbox gives the run the fake HOME, and it runs in work/" "$(jq -r 'select(.condition=="treatment") | .value' "$D/runs.jsonl")" "true"

echo "== blind judge =="
PLANJ='{"reps":2,"timeout_s":20,"seed":3,"conditions":[{"name":"treatment","cmd":"echo good","observe":"judge"},{"name":"baseline","cmd":"echo bad","observe":"judge"},{"name":"negative-control","cmd":"echo bad","observe":"judge"}]}'
D=$(mk judge '{}' "$PLANJ")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
python3 "$S/score.py" "$D" >/dev/null; eq "unjudged outputs are INCONCLUSIVE" "$?" "2"
python3 "$S/score.py" --export-blind "$D" >/dev/null
eq "6 blind items" "$(wc -l <"$D/blind/items.jsonl" | tr -d ' ')" "6"
! grep -q 'treatment\|baseline\|negative' "$D/blind/items.jsonl" && ok || bad "blind items carry no condition names"
jq -c '{id, value: (.output | test("good"))}' "$D/blind/items.jsonl" >"$D/blind/judgments.jsonl"
python3 "$S/score.py" "$D" >/dev/null; eq "judgments merge back and score SUPPORTED" "$?" "0"

echo "== review regressions =="
[ -x "$S/supervise.py" ] && ok || bad "supervise.py is executable"
D=$(mk multiline '{}' "$(jq -c '.conditions[0].cmd = "true\ngit push origin --delete old-feature"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null
out=$(bash "$S/run.sh" "$D" 2>&1); code=$?
eq "a gated command on a second line is refused" "$code" "65"
eq "and nothing ran" "$(wc -c <"$D/runs.jsonl" | tr -d ' ')" "0"
D=$(mk orphan '{}' "$(jq -c '.reps = 1 | .timeout_s = 1 | .conditions[0].cmd = "(sleep 2; touch \"$EXPERIMENT_WORK/late\") & sleep 5"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
eq "a timed-out run is marked timed_out" "$(jq -r 'select(.condition=="treatment") | .timed_out' "$D/runs.jsonl")" "true"
sleep 3
[ ! -e "$D/work/late" ] && ok || bad "a timeout kills the run's background children"
D=$(mk obsfail '{}' "$(jq -c '.reps = 1 | .conditions[0].observe = "echo true; exit 7"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
eq "a failed observe records no value" "$(jq -c 'select(.condition=="treatment") | .value' "$D/runs.jsonl")" "null"
has "and says why" "$(jq -r 'select(.condition=="treatment") | .error' "$D/runs.jsonl")" "observe exited 7"
python3 "$S/score.py" "$D" >/dev/null; eq "so the result is INCONCLUSIVE" "$?" "2"
D=$(mk recrange '{"side_effects":"ask-d"}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null
bash "$S/run.sh" "$D" --record treatment 0 true >/dev/null 2>&1; eq "--record refuses rep 0" "$?" "65"
bash "$S/run.sh" "$D" --record treatment 4 true >/dev/null 2>&1; eq "--record refuses a rep past plan.reps" "$?" "65"
D=$(mk extrarows '{}' "$PLAN3")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
for r in 4 5 6; do printf '{"condition":"negative-control","rep":%s,"value":true}\n' "$r" >>"$D/runs.jsonl"; done
printf '{"condition":"negative-control","rep":1,"value":true}\n' >>"$D/runs.jsonl"
python3 "$S/score.py" "$D" >/dev/null; eq "rows outside the plan and duplicates do not change the verdict" "$?" "0"
D=$(mk posonly '{"controls":[{"condition":"baseline","expect":"pass"}]}' "$PLAN3")
has "positive-only controls are invalid" "$(python3 "$S/score.py" --validate "$D" 2>&1)" "no negative control"
D=$(mk bigout '{}' "$(jq -c '.reps = 1 | .conditions[0].cmd = "head -c 30000 /dev/zero | tr \"\\\\0\" a" | .conditions[0].observe = "judge"' <<<"$PLAN3")")
bash "$S/lock.sh" "$D" >/dev/null; bash "$S/run.sh" "$D" >/dev/null 2>&1
python3 "$S/score.py" --export-blind "$D" >/dev/null
eq "a 30k output is exported whole" "$(jq -r '.output | length' "$D/blind/items.jsonl")" "30000"

echo
echo "experiment: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
