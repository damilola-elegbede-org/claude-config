#!/usr/bin/env bash
# Hermetic coverage for the /papercuts skill's analysis script: window,
# attribution with repo evidence, root-cause clusters, and archive reads.
# Runs offline against a fixture log; never reads the caller's real log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/system-configs/.claude/skills/papercuts/scripts/papercuts.py"
FIXTURE="$ROOT/tests/fixtures/papercuts/papercuts-2026-10-17.txt"
TEST_DIR="$(mktemp -d /tmp/claude-config-papercuts-skill.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Only these sibling repos exist, so attribution can't depend on the runner's ~/dev.
for repo in bareclaude pipedream-automation alocubano.boulderfest damilola.tech claude-config; do
    mkdir -p "$TEST_DIR/dev/$repo"
done
mkdir -p "$TEST_DIR/archive"

PASS=0
FAIL=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name: expected [$expected], got [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

run() {
    python3 "$SCRIPT" report --offline --repo "$ROOT" --repos-dir "$TEST_DIR/dev" \
        --archive-dir "$TEST_DIR/archive" --today 2026-10-17 "$@"
}

q() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"; }

echo "papercuts skill: 7-day window on the 2026-10-17 fixture"
run --log "$FIXTURE" --days 7 >"$TEST_DIR/out.json"
OUT="$TEST_DIR/out.json"
check "window entries" "10" "$(q "$OUT" "d['totals']['window']")"
check "window ids" "28 29 30 31 32 33 34 35 36 37" \
    "$(q "$OUT" "' '.join(e['id'].split(':')[1] for e in d['entries'])")"
check "ours" "31 32 33 35 36" \
    "$(q "$OUT" "' '.join(e['id'].split(':')[1] for e in d['entries'] if e['owner']=='ours')")"
check "ours carry file:line evidence" "5" \
    "$(q "$OUT" "sum(1 for e in d['entries'] if e['owner']=='ours' and ':' in e['evidence'].split('→')[-1])")"
check "bareclaude flakes" "other:bareclaude other:bareclaude other:bareclaude" \
    "$(q "$OUT" "' '.join(e['owner'] for e in d['entries'][:3])")"
check "sandbox is external" "external" "$(q "$OUT" "d['entries'][-1]['owner']")"

cluster() { q "$OUT" "' '.join(i.split(':')[1] for c in d['clusters'] if c['key']=='$1' for i in c['entries'])"; }
check "gate-matches-text" "7 11 14 23 31" "$(cluster gate-matches-text)"
check "approval-not-taking" "22 32 33" "$(cluster approval-not-taking)"
check "whole-file-formatter" "5 10 36" "$(cluster whole-file-formatter)"
check "ours clusters lead" "ours" "$(q "$OUT" "d['clusters'][0]['owner']")"

echo "papercuts skill: archive months are read"
head -4 "$FIXTURE" >"$TEST_DIR/live.md"
sed -n '1,4p;5,10p' "$FIXTURE" >"$TEST_DIR/archive/2026-09.md"
run --log "$TEST_DIR/live.md" --days 30 >"$OUT"
check "archive entries counted" "6" "$(q "$OUT" "d['totals']['log']")"
check "archive ids" "archive/2026-09.md:5" "$(q "$OUT" "d['entries'][0]['id']")"

echo "papercuts skill: a line in both an archive and the live log counts once"
sed -n '1,5p' "$FIXTURE" >"$TEST_DIR/live.md"
run --log "$TEST_DIR/live.md" --days 30 >"$OUT"
check "duplicate counted once" "6" "$(q "$OUT" "d['totals']['log']")"

echo "papercuts skill: cluster scope and this-repo attribution"
rm -f "$TEST_DIR/archive/2026-09.md"
{
    head -4 "$FIXTURE"
    echo "2026-10-15 · claude · unit test flakes under load, green on rerun · rerun · damilola.tech/tests"
    echo "2026-10-16 · claude · infra test flakes again, green on rerun · rerun · bareclaude/tests"
    echo "2026-10-16 · claude · session notes went missing · none · claude-config/docs"
} >"$TEST_DIR/live.md"
run --log "$TEST_DIR/live.md" --days 7 --repos-dir "$TEST_DIR/empty" >"$OUT"
check "this repo without a sibling dir" "ours-unverified" "$(q "$OUT" "d['entries'][-1]['owner']")"
run --log "$TEST_DIR/live.md" --days 7 >"$OUT"
check "flaky-ci ignores other repos" "[]" \
    "$(q "$OUT" "[c['entries'] for c in d['clusters'] if c['key']=='flaky-ci']")"

echo "papercuts skill: missing log is an error, not an empty report"
if run --log "$TEST_DIR/nope.md" >"$OUT"; then
    check "missing log exits non-zero" "1" "0"
else
    check "missing log exits non-zero" "1" "1"
fi

echo "papercuts skill: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
