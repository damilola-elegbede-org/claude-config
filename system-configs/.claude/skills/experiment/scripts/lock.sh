#!/bin/bash
# lock.sh <dir> -> validates protocol.json + plan.json and seals them before any run (pre-registration).
#
# Writes <dir>/lock.json {sha256, locked_at, side_effects}. run.sh and score.py refuse an experiment whose files no
# longer match the lock, so the hypothesis, prediction and pass rule cannot move after the data is in. Re-locking is
# allowed only while runs.jsonl is empty: once a run is recorded, a changed protocol is a new experiment (new.sh).
set -euo pipefail

dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: lock.sh <experiment-dir>" >&2; exit 64; }
here="$(cd "$(dirname "$0")" && pwd)"

if [ -s "$dir/runs.jsonl" ]; then
  echo "refused: $dir already has recorded runs; a changed protocol is a new experiment (new.sh)" >&2
  exit 65
fi
python3 "$here/score.py" --validate "$dir"
side=$(jq -r '.side_effects' "$dir/protocol.json")
if [ "$side" = "refuse" ]; then
  echo "refused: protocol.json says side_effects=refuse; this experiment must not run" >&2
  exit 65
fi

sha=$(python3 "$here/score.py" --hash "$dir")
jq -n --arg s "$sha" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg side "$side" \
  '{sha256: $s, locked_at: $t, side_effects: $side}' >"$dir/lock.json"
echo "locked $dir ($side) sha256=${sha:0:12}"
