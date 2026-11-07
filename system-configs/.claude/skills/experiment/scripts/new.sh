#!/bin/bash
# new.sh <slug> -> scaffolds one experiment and prints its directory.
#
#   <dir>/protocol.json  sealed half: question, hypothesis, prediction, pass rule, controls (runners never read it)
#   <dir>/plan.json      runner half: conditions, reps, timeouts (all a runner needs)
#   <dir>/work/          scratch working directory every condition runs in
#   <dir>/home/          fake HOME a condition can opt into ("home": "sandbox")
#   <dir>/runs/          full stdout/stderr per run
#
# Experiments live under $EXPERIMENTS_DIR, else <repo>/.tmp/experiments, else ./.tmp/experiments.
set -euo pipefail

slug="${1:-}"
case "$slug" in
  "" | *[!a-z0-9-]*)
    echo "usage: new.sh <slug>   (lowercase letters, digits and hyphens)" >&2
    exit 64
    ;;
esac

if [ -n "${EXPERIMENTS_DIR:-}" ]; then
  base="$EXPERIMENTS_DIR"
elif top=$(git rev-parse --show-toplevel 2>/dev/null); then
  base="$top/.tmp/experiments"
else
  base="$PWD/.tmp/experiments"
fi

dir="$base/$(date +%Y%m%d-%H%M%S)-$slug"
[ ! -e "$dir" ] || { echo "already exists: $dir" >&2; exit 73; }
mkdir -p "$dir/work" "$dir/home" "$dir/runs"

jq -n --arg id "$(basename "$dir")" '{
  id: $id,
  question: "What do we need to know? One sentence.",
  hypothesis: "The claim being tested, stated so it can be false.",
  prediction: "What the runs will show if the hypothesis is true, in terms of the metric.",
  if_false: "What the runs will show if it is false.",
  pass_rule: {type: "rate", condition: "treatment", op: ">=", value: 1},
  controls: [{condition: "negative-control", expect: "fail"}],
  side_effects: "sandbox",
  notes: ""
}' >"$dir/protocol.json"

jq -n '{
  reps: 3,
  timeout_s: 120,
  seed: 1,
  conditions: [
    {name: "treatment", cmd: "true", observe: null, home: "real"},
    {name: "baseline", cmd: "true", observe: null, home: "real"},
    {name: "negative-control", cmd: "false", observe: null, home: "real"}
  ]
}' >"$dir/plan.json"

printf '%s\n' "$dir"
