#!/usr/bin/env bash
# Hermetic tests for the opt-in /ask-jev skill (skills/ask-jev/scripts/rank-files.sh). Temp HOME, the
# request-validating jev-ask stub (and, for the redaction check, the real client in JEV_MOCK mode), no
# network. Covers: prefilter, batches of at most 20, request shape, ranking, fail-open, egress, redaction.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/system-configs/.claude/skills/ask-jev"
RANK="$SKILL/scripts/rank-files.sh"
JSRC="$REPO_ROOT/system-configs/.claude/hooks/jev"
STUB="$REPO_ROOT/tests/mocks/jev-ask-stub.sh"

if ! command -v jq >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq is required for the ask-jev tests" >&2
    exit 1
  fi
  echo "SKIP: jq not installed (would FAIL in CI)" >&2
  exit 0
fi

# Nothing from the caller's environment may leak in.
for v in $(env | sed -n 's/^\(JEV_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
unset AI_GATEWAY_API_KEY VERCEL_AI_GATEWAY_TOKEN VERCEL_AI_GATEWAY_KEY BARECLAUDE_AGENT_SLUG CLAUDE_JOB_DIR

T="$(mktemp -d /tmp/claude-config-ask-jev.XXXXXX)"
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
has() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1" "missing [$3] in [${2:0:300}]"; fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1" "unexpected [$3] present"; fi; }

# --- static: the skill's shape -----------------------------------------------------------------------
[[ -x "$RANK" ]] && ok || bad "rank-files.sh is executable"
eq "SKILL.md H1 is # /ask-jev" "# /ask-jev" "$(grep -m1 '^# ' "$SKILL/SKILL.md")"
eq "SKILL.md frontmatter name" "ask-jev" "$(sed -n 's/^name: //p' "$SKILL/SKILL.md" | head -1)"
has "description steers 'where is X / which files handle Y'" "$(sed -n 's/^description: //p' "$SKILL/SKILL.md")" "where is X"
has "description names the before-reading trigger" "$(sed -n 's/^description: //p' "$SKILL/SKILL.md")" "first"
eq "the rule ships registered" "enforce" "$(jq -r '.rules["ask-jev-rank"].mode' "$JSRC/rules.d/skills.json")"
eq "batch size is capped at 20 in config" "20" "$(jq -r '.rules["ask-jev-rank"].batch_size' "$JSRC/rules.d/skills.json")"

# --- a deployed-style HOME ---------------------------------------------------------------------------
export HOME="$T/home"
J="$HOME/.claude/hooks/jev"
mkdir -p "$J/rules.d" "$HOME/.claude"
cp "$JSRC/ctx-lib.sh" "$JSRC/registry.sh" "$JSRC/jev-config.json" "$J/"
cp "$JSRC/rules.d/skills.json" "$J/rules.d/"
cp "$STUB" "$J/jev-ask"
chmod +x "$J/jev-ask"
export JEV_STUB_LOG="$T/stub.log"

P="$T/proj"
mkdir -p "$P/src" "$P/docs"
printf 'export const retryPolicy = 3;\n// retry with backoff\n' >"$P/src/retry-policy.ts"
printf 'function call() {\n  // retry on 503\n  retry();\n  retry();\n}\n' >"$P/src/client.ts"
printf 'one retry note\n' >"$P/docs/notes.md"
printf 'nothing relevant here\n' >"$P/docs/other.txt"
printf 'RETRY_SECRET=abc\n' >"$P/.env"
printf 'retry\000\001\002binary' >"$P/src/blob.bin"
printf '{"answers":{"f1":{"type":"boolean","probability":0.2},"f2":{"type":"boolean","probability":0.95},"f3":{"type":"boolean","probability":0.5}},"model":"mock","latency_ms":1,"cost_usd":0}' >"$T/fix3.json"

echo "== prefilter and ranking"
: >"$JEV_STUB_LOG"
OUT=$(cd "$P" && JEV_MOCK="$T/fix3.json" "$RANK" "where is retry handled" . 2>"$T/err")
RC=$?
ERR=$(cat "$T/err")
eq "exit 0" "0" "$RC"
eq "ranked by Jev probability, best first" "0.95	./src/client.ts
0.50	./docs/notes.md
0.20	./src/retry-policy.ts" "$OUT"
eq "one Jev call for three files" "1" "$(grep -c . "$JEV_STUB_LOG")"
REQ="$(head -1 "$JEV_STUB_LOG")"
eq "rule id" "ask-jev-rank" "$(jq -r .rule <<<"$REQ")"
eq "boolean question per file" "f1,f2,f3" "$(jq -r '[.questions | to_entries[] | select(.value.type == "boolean") | .key] | join(",")' <<<"$REQ")"
eq "query rides in state" "where is retry handled" "$(jq -r .state.query <<<"$REQ")"
eq "state has no untrusted key (files travel in the untrusted field)" "false" "$(jq -r '.state | has("untrusted")' <<<"$REQ")"
has "a file is sent as its path plus first lines" "$(jq -r '.untrusted.f1' <<<"$REQ")" "path: ./src/retry-policy.ts"
has "file content is sent" "$(jq -r '.untrusted.f1' <<<"$REQ")" "retryPolicy"
eq "cwd is passed so the client can refuse an excluded tree" "$P" "$(jq -r .cwd <<<"$REQ" | sed 's#^/private##')"
lacks "the secret-named .env is never sent" "$(cat "$JEV_STUB_LOG")" "RETRY_SECRET"
lacks "a binary file is never sent" "$(cat "$JEV_STUB_LOG")" "blob.bin"
lacks "a keyword-less file is not sent" "$(cat "$JEV_STUB_LOG")" "nothing relevant here"

echo "== --top and usage"
OUT=$(cd "$P" && JEV_MOCK="$T/fix3.json" "$RANK" --top 2 "where is retry handled" . 2>/dev/null)
eq "--top 2 prints two lines" "2" "$(grep -c . <<<"$OUT")"
OUT=$(cd "$P" && "$RANK" 2>&1)
RC=$?
eq "no query is a usage error (2)" "2" "$RC"
OUT=$(cd "$P" && "$RANK" "retry" "$P/nope-*.xyz" 2>&1)
RC=$?
eq "no matching file exits 1" "1" "$RC"

echo "== quoted globs are expanded"
OUT=$(cd "$P" && JEV_MOCK="$T/fix3.json" "$RANK" "retry" "src/*.ts" 2>/dev/null)
has "glob matched the .ts files" "$OUT" "src/client.ts"
lacks "glob did not match docs" "$OUT" "notes.md"

echo "== batches of at most 20"
BIG="$T/big"
mkdir -p "$BIG"
for i in $(seq 1 45); do printf 'retry handler %s\n' "$i" >"$BIG/f$i.ts"; done
jq -nc '{answers: ([range(1; 21) | {key: "f\(.)", value: {type: "boolean", probability: 0.5}}] | from_entries), model: "mock", latency_ms: 1, cost_usd: 0}' >"$T/fix20.json"
: >"$JEV_STUB_LOG"
OUT=$(cd "$BIG" && JEV_MOCK="$T/fix20.json" "$RANK" "retry handler" . 2>/dev/null)
eq "45 files make 3 calls" "3" "$(grep -c . "$JEV_STUB_LOG")"
eq "no batch exceeds 20 files" "true" "$(jq -s 'all(.[]; (.questions | length) <= 20)' "$JEV_STUB_LOG")"
eq "first two batches are full" "20,20,5" "$(jq -s -r 'map(.questions | length) | join(",")' "$JEV_STUB_LOG")"
eq "every file is printed once" "45" "$(grep -c . <<<"$OUT")"

echo "== max_files bounds the prefilter"
printf '%s' '{"rules":{"ask-jev-rank":{"max_files":4}}}' >"$J/jev-rules.json"
: >"$JEV_STUB_LOG"
OUT=$(cd "$BIG" && JEV_MOCK="$T/fix20.json" "$RANK" "retry handler" . 2>/dev/null)
eq "max_files 4 prints 4 files" "4" "$(grep -c . <<<"$OUT")"
eq "and makes one call" "1" "$(grep -c . "$JEV_STUB_LOG")"
rm -f "$J/jev-rules.json"

echo "== fail open: Jev unavailable"
: >"$JEV_STUB_LOG"
OUT=$(cd "$P" && JEV_MOCK=unavailable "$RANK" "where is retry handled" . 2>"$T/err")
RC=$?
ERR=$(cat "$T/err")
eq "exit 0" "0" "$RC"
eq "prefilter order with - as the probability (path hit first, then more content hits)" "-	./src/retry-policy.ts
-	./src/client.ts
-	./docs/notes.md" "$OUT"
has "one-line note on stderr" "$ERR" "Jev unavailable or refused"
eq "the note is one line" "1" "$(grep -c . <<<"$ERR")"

echo "== fail open: kill switch, rule off, no client"
touch "$HOME/.claude/jev.off"
: >"$JEV_STUB_LOG"
OUT=$(cd "$P" && JEV_MOCK="$T/fix3.json" "$RANK" "where is retry handled" . 2>"$T/err")
eq "kill switch: no Jev call" "0" "$(grep -c . "$JEV_STUB_LOG")"
eq "kill switch: prefilter order" "-	./src/retry-policy.ts" "$(head -1 <<<"$OUT")"
has "kill switch: says so" "$(cat "$T/err")" "kill switch"
rm -f "$HOME/.claude/jev.off"

printf '%s' '{"rules":{"ask-jev-rank":{"mode":"off"}}}' >"$J/jev-rules.json"
OUT=$(cd "$P" && JEV_MOCK="$T/fix3.json" "$RANK" "where is retry handled" . 2>"$T/err")
eq "rule off: no Jev call" "0" "$(grep -c . "$JEV_STUB_LOG")"
has "rule off: says so" "$(cat "$T/err")" "is off"
rm -f "$J/jev-rules.json"

mv "$J/jev-ask" "$J/jev-ask.away"
OUT=$(cd "$P" && "$RANK" "where is retry handled" . 2>"$T/err")
RC=$?
eq "no client: still exit 0" "0" "$RC"
has "no client: prefilter order" "$OUT" "-	./src/retry-policy.ts"
mv "$J/jev-ask.away" "$J/jev-ask"

echo "== fail open: Jev dies mid-run (partial results are kept)"
cp "$J/jev-ask" "$T/jev-ask.real"
cat >"$J/jev-ask" <<EOF
#!/bin/bash
cat >/dev/null
n=\$(cat "$T/calls" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" >"$T/calls"
[ "\$n" -le 1 ] || exit 3
cat "$T/fix20.json"
EOF
chmod +x "$J/jev-ask"
rm -f "$T/calls"
OUT=$(cd "$BIG" && "$RANK" "retry handler" . 2>"$T/err")
eq "partial: all 45 files printed" "45" "$(grep -c . <<<"$OUT")"
eq "partial: 20 scored files first" "20" "$(grep -c '^0\.50' <<<"$OUT")"
eq "partial: the other 25 are unscored" "25" "$(grep -c '^-' <<<"$OUT")"
eq "partial: scored files come before unscored ones" "0.50" "$(head -1 <<<"$OUT" | cut -f1)"
has "partial: note says how far it got" "$(cat "$T/err")" "after 1 of 3 batches"
cp "$T/jev-ask.real" "$J/jev-ask"

echo "== fail open: bad answer"
printf '%s' 'not json' >"$T/garbage.json"
OUT=$(cd "$P" && JEV_MOCK="$T/garbage.json" "$RANK" "where is retry handled" . 2>/dev/null)
RC=$?
eq "garbage answer: exit 0" "0" "$RC"
has "garbage answer: prefilter order" "$OUT" "-	./src/retry-policy.ts"

echo "== egress: excluded trees never leave"
mkdir -p "$HOME/work/proj" "$HOME/ok"
printf 'retry in a work repo\n' >"$HOME/work/proj/retry.ts"
printf 'retry in an ordinary repo\n' >"$HOME/ok/retry.ts"
: >"$JEV_STUB_LOG"
OUT=$(cd "$HOME/ok" && JEV_MOCK="$T/fix3.json" "$RANK" "retry" "$HOME/work/proj" "$HOME/ok" 2>/dev/null)
lacks "an excluded path is dropped from the output" "$OUT" "/work/proj/retry.ts"
lacks "an excluded path is never sent" "$(cat "$JEV_STUB_LOG")" "work repo"
has "an ordinary path is kept" "$OUT" "/ok/retry.ts"

echo "== the real client redacts before anything leaves"
if command -v node >/dev/null 2>&1; then
  cp "$JSRC/client.mjs" "$JSRC/jev-ask" "$JSRC/jev-config.json" "$JSRC/jev-rules.json" "$J/"
  chmod +x "$J/jev-ask"
  # deliberately fake credentials that the client's redaction patterns cover
  printf 'retry config\naws_key = AKIAABCDEFGHIJKLMNOP\ntoken = ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" >"$P/src/creds-retry.ts"
  REC="$T/recorded.json"
  OUT=$(cd "$P" && JEV_MOCK="$T/fix3.json" JEV_RECORD="$REC" "$RANK" "retry" src/creds-retry.ts 2>/dev/null)
  lacks "the recorded payload has no AWS key" "$(cat "$REC" 2>/dev/null)" "AKIAABCDEFGHIJKLMNOP"
  lacks "the recorded payload has no GitHub token" "$(cat "$REC" 2>/dev/null)" "ghp_aaaa"
  has "the recorded payload still has the file's path" "$(cat "$REC" 2>/dev/null)" "creds-retry.ts"
  rm -f "$P/src/creds-retry.ts"
else
  echo "  (node missing: real-client redaction check skipped)"
fi

echo "== the decision log"
DL="$HOME/.claude/jev/decisions.jsonl"
LINE="$(grep -F '"gate":"ask-jev-rank"' "$DL" | head -1)"
eq "run is logged under the rule id" "ask-jev-rank" "$(jq -r .gate <<<"$LINE")"
eq "src names the skill" "skill:ask-jev" "$(jq -r .src <<<"$LINE")"
lacks "the log never records the query" "$(cat "$DL")" "where is retry handled"

printf 'ask-jev: %d passed, %d failed\n' "$PASSES" "$FAILS"
[[ "$FAILS" -eq 0 ]]
