#!/usr/bin/env bash
# CI-safe guard for the Jev replay regression check (scripts/jev-replay.py --check). No network and no
# model calls: it works on temp copies of the committed questions, thresholds, labels and results file and
# proves the guard fails when a threshold or question changes WITHOUT an updated results file, passes once
# the results file is refreshed offline (--rescore), and fails when a threshold change moves a rule's block
# rate more than 5 points. Also smoke-tests the replay pipeline end to end on the deterministic mock backend.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPLAY="$REPO_ROOT/scripts/jev-replay.py"
JSRC="$REPO_ROOT/system-configs/.claude/hooks/jev"
FIX="$REPO_ROOT/tests/fixtures"

for tool in python3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    if [[ -n "${CI:-}" ]]; then
      echo "FAIL: $tool is required for the replay check tests" >&2
      exit 1
    fi
    echo "SKIP: $tool not installed (would FAIL in CI)" >&2
    exit 0
  fi
done

T="$(mktemp -d /tmp/claude-config-jev-replay.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASSES=0
FAILS=0
ok() { PASSES=$((PASSES + 1)); }
bad() {
  FAILS=$((FAILS + 1))
  printf 'FAIL: %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2" >&2
}
eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1" "missing [$3] in [${2:0:400}]"; fi; }

# fresh: temp copies of the four inputs the check reads
fresh() {
  rm -rf "${T:?}/w"
  mkdir -p "$T/w"
  cp "$JSRC/gate-questions.json" "$T/w/questions.json"
  cp "$JSRC/rules.d/gates.json" "$T/w/rules.json"
  cp "$FIX/jev-replay-labels.jsonl" "$T/w/labels.jsonl"
  cp "$FIX/jev-replay-results.json" "$T/w/results.json"
}
# run <replay args...>: sets RC, OUT (stdout) and ERR (stderr) against the temp copies
run() {
  OUT=$(python3 "$REPLAY" "$@" --questions "$T/w/questions.json" --rules "$T/w/rules.json" \
    --labels "$T/w/labels.jsonl" --results "$T/w/results.json" 2>"$T/w/stderr")
  RC=$?
  ERR=$(cat "$T/w/stderr")
}
edit_json() { # file jq-filter
  jq "$2" "$1" >"$1.new" && mv "$1.new" "$1"
}

echo "== the committed state is consistent"
python3 "$REPLAY" --check >"$T/repo.out" 2>"$T/repo.err"
eq "--check passes on the committed results file" "0" "$?"
has "the drift table is printed" "$(cat "$T/repo.out")" "| rule | n | baseline block rate"
has "the OK line names the fingerprints" "$(cat "$T/repo.out")" "OK: results file is current"

echo "== a question change without a fresh live run fails"
fresh
edit_json "$T/w/questions.json" '.choice_questions.risk_class.instructions += " (edited)"'
run --check
eq "edited question: --check fails" "1" "$RC"
has "names the fingerprint mismatch" "$ERR" "fingerprint mismatch"
has "tells the author to re-run live" "$ERR" "--write-results"
run --rescore
eq "--rescore refuses to paper over a question change" "1" "$RC"

fresh
edit_json "$T/w/questions.json" '.gates["G1-irreversible-local"].label += " x"'
run --check
eq "edited gate label: --check fails" "1" "$RC"

fresh
edit_json "$T/w/questions.json" '.note = "reworded, no effect on the questions" | .version = 99'
run --check
eq "note/version edits do not need a live run" "0" "$RC"

echo "== the labelled set is guarded too"
fresh
echo '{"id":"extra","kind":"bash","state":{"command":"ls"},"labels":{}}' >>"$T/w/labels.jsonl"
run --check
eq "changed labels: --check fails" "1" "$RC"
has "names the labelled set" "$ERR" "labelled set changed"

echo "== a threshold change without an updated results file fails"
fresh
edit_json "$T/w/rules.json" '.["G1-irreversible-local"].threshold = 0.81'
run --check
eq "edited threshold: --check fails" "1" "$RC"
has "names the threshold" "$ERR" "G1-irreversible-local: recorded 0.8 vs now 0.81"
has "points at --rescore" "$ERR" "--rescore"
run --rescore
eq "--rescore succeeds offline" "0" "$RC"
run --check
eq "after --rescore the check passes (a small shift is fine)" "0" "$RC"
eq "the results file records the new threshold" "0.81" "$(jq -r '.thresholds["G1-irreversible-local"]' "$T/w/results.json")"
eq "the accepted baseline is kept, not silently replaced" "$(jq -c '.baseline' "$FIX/jev-replay-results.json")" "$(jq -c '.baseline' "$T/w/results.json")"

echo "== a threshold change that moves a block rate more than 5 points fails"
fresh
edit_json "$T/w/rules.json" '.["approval-detector"].threshold = 0.51'
run --rescore
eq "--rescore still rewrites (it warns)" "0" "$RC"
has "--rescore warns about the shift" "$OUT" "WARNING: shift above 5 points"
run --check
eq "check fails on a drifted block rate" "1" "$RC"
has "names the rule" "$ERR" "approval-detector"
has "says how much" "$ERR" "more than 5 points"
has "table marks the rule NO" "$OUT" "| NO |"

echo "== missing results file fails"
fresh
rm -f "$T/w/results.json"
run --check
eq "no results file: --check fails" "1" "$(if [[ "$RC" -ne 0 ]]; then echo 1; else echo 0; fi)"

echo "== the replay pipeline runs offline on the mock backend"
MOCK_OUT=$(python3 "$REPLAY" --backend mock --no-history --out "$T/mock-report.md" 2>"$T/mock.err")
eq "mock replay exits 0" "0" "$?"
has "mock replay reports class accuracy" "$MOCK_OUT" "Class accuracy:"
has "mock replay prints deny-class threshold curves" "$MOCK_OUT" "Deny-class threshold curves"

printf 'Jev replay check: %d passed, %d failed\n' "$PASSES" "$FAILS"
[[ "$FAILS" -eq 0 ]]
