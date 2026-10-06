#!/usr/bin/env bash
# Hermetic tests for scripts/jev-daily-summary.py, scripts/jev-nightly-audit.py and the LaunchAgent
# installer. Temp HOME, fixture decision log and transcripts, a stub jev-ask (and the real client in
# JEV_MOCK mode for one egress check). No network and no real Jev calls.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUMMARY="$REPO_ROOT/scripts/jev-daily-summary.py"
AUDIT="$REPO_ROOT/scripts/jev-nightly-audit.py"
INSTALL="$REPO_ROOT/scripts/install-jev-daily-agent.sh"
JSRC="$REPO_ROOT/system-configs/.claude/hooks/jev"

if ! command -v python3 >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: python3 is required for the Jev daily tests" >&2
    exit 1
  fi
  echo "SKIP: python3 not installed (would FAIL in CI)" >&2
  exit 0
fi

for v in $(env | sed -n 's/^\(JEV_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done

T="$(mktemp -d /tmp/claude-config-jev-daily.XXXXXX)"
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
has() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1" "missing [$3] in [${2:0:600}]"; fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1" "unexpected [$3] present"; fi; }

export HOME="$T/home"
mkdir -p "$HOME/.claude" "$T/out"

# --- fixture decision log: Denver day 2026-10-04 is 06:00Z .. 06:00Z next day (MDT, UTC-6) -------------
LOG="$T/decisions.jsonl"
cat >"$LOG" <<'EOF'
{"ts":"2026-10-04T05:59:59Z","gate":"G1-rm","mode":"regex","outcome":"deny","src":"hook:gate.sh","target":"rm -rf before-the-day"}
{"ts":"2026-10-04T06:00:00Z","gate":"A6-agent-router","outcome":"ok","src":"client","wall_ms":100,"cost_usd":0.001,"origin":"live"}
{"ts":"2026-10-04T12:00:00Z","gate":"A6-agent-router","outcome":"ok","src":"client","wall_ms":200,"cost_usd":0.002,"origin":"live"}
{"ts":"2026-10-04T12:00:01Z","gate":"A6-agent-router","outcome":"ok","src":"client","wall_ms":300,"cost_usd":0.003}
{"ts":"2026-10-04T12:00:02Z","gate":"A6-agent-router","outcome":"unavailable","src":"client","wall_ms":900,"cost_usd":0,"origin":"test"}
{"ts":"2026-10-04T13:00:00Z","gate":"G1-irreversible-local","mode":"enforce","outcome":"hit-enforce","src":"hook:jev-gate","tool":"Bash","action_sha":"aaa","session_id":"sess-1","origin":"live"}
{"ts":"2026-10-04T13:00:00Z","gate":"G1-irreversible-local","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","action_sha":"aaa","session_id":"sess-1","origin":"live","action":"rm -rf ./data | cat"}
{"ts":"2026-10-04T14:00:00Z","gate":"G4-prod","mode":"enforce","outcome":"hit-enforce","src":"hook:jev-gate","tool":"Bash","action_sha":"bbb","origin":"live"}
{"ts":"2026-10-04T15:00:00Z","gate":"G1-rm","mode":"regex","outcome":"deny","src":"hook:gate.sh","target":"rm -rf /tmp/x"}
{"ts":"2026-10-04T16:00:00Z","gate":"G3-publish","mode":"shadow","outcome":"would-deny-shadow","src":"hook:jev-gate","origin":"replay"}
{"ts":"2026-10-04T16:00:01Z","gate":"G3-publish","mode":"shadow","outcome":"would-deny-shadow","src":"hook:jev-gate","origin":"replay"}
{"ts":"2026-10-04T16:00:02Z","gate":"G5-comms","mode":"shadow","outcome":"would-deny-shadow","src":"hook:jev-gate"}
{"ts":"2026-10-04T17:00:00Z","gate":"G1-rm","mode":"regex","outcome":"retry-after-deny","src":"hook:gate.sh","origin":"live"}
not json at all
{"ts":"2026-10-05T05:59:59Z","gate":"A6-agent-router","outcome":"ok","src":"client","wall_ms":400,"cost_usd":0.004,"origin":"live"}
{"ts":"2026-10-05T06:00:00Z","gate":"A6-agent-router","outcome":"ok","src":"client","wall_ms":999,"cost_usd":9,"origin":"live"}
EOF

echo "== daily summary"
OUT=$(python3 -I "$SUMMARY" --date 2026-10-04 --log "$LOG" --out "$T/out")
eq "prints the report path" "$T/out/jev-daily-2026-10-04.md" "$OUT"
R=$(cat "$T/out/jev-daily-2026-10-04.md")
has "title" "$R" "# Jev daily summary 2026-10-04"
has "Denver boundaries: 06:00Z in, 05:59:59Z next day in, 06:00Z next day out (6 client rows)" "$R" "| Calls (client rows) | 5 |"
has "unavailable count and percent" "$R" "| Unavailable | 1 (20.0%) |"
has "p50 / p95 wall_ms" "$R" "| wall_ms p50 / p95 | 300 ms / 900 ms |"
has "total cost" "$R" '| Total cost | $0.0100 |'
lacks "the row after the day is not counted" "$R" "999"
lacks "the row before the day is not counted" "$R" "before-the-day"
has "block with logged action" "$R" "| G1-irreversible-local | deny | live | rm -rf ./data \\| cat |"
lacks "hit-enforce plus deny for one call counts once" "$R" "| G1-irreversible-local | hit-enforce"
has "hit-enforce without a deny still counts, action not logged" "$R" "| G4-prod | hit-enforce | live | (action not logged, sha bbb) |"
has "regex deny shows its target" "$R" "| G1-rm | deny | unknown | rm -rf /tmp/x |"
has "shadow per rule, most first" "$R" "| G3-publish | 2 |"
has "shadow single" "$R" "| G5-comms | 1 |"
has "bypass" "$R" "1 retries after a deny: G1-rm x1."
has "origin live" "$R" "| live | 3 | 0 (0.0%) | 200 ms / 400 ms |"
has "origin test" "$R" "| test | 1 | 1 (100.0%) |"
has "origin replay shadow count" "$R" "| replay | 0 | 0 (n/a) | n/a / n/a | \$0.0000 | 0 | 2 | 0 |"
has "rows without an origin are unknown" "$R" "| unknown | 1 |"
eq "origin order live before unknown" "| live" "$(printf '%s\n' "$R" | grep -m1 '^| live\|^| unknown' | cut -c1-6)"

echo "== empty day and bad input"
E=$(python3 -I "$SUMMARY" --date 2026-01-01 --log "$LOG" --stdout)
has "empty day renders" "$E" "| Calls (client rows) | 0 |"
has "empty day says no rows" "$E" "No rows."
python3 -I "$SUMMARY" --date nonsense --log "$LOG" --out "$T/out" >/dev/null 2>&1
eq "bad date exits 2" "2" "$?"
python3 -I "$SUMMARY" --date 2026-10-04 --log "$T/missing.jsonl" --out "$T/out2" >/dev/null 2>&1
eq "missing log is an empty report, exit 0" "0" "$?"

echo "== nightly audit fixtures"
PROJ="$T/projects"
mkdir -p "$PROJ/-p1" "$PROJ/-p2"
GOODCWD="$HOME/repos/demo"
BADCWD="$HOME/work/secret-repo"
mkdir -p "$GOODCWD" "$BADCWD"
cat >"$HOME/.claude-config-test.json" <<EOF
{"exclude_paths": ["~/work", "~/Visa"]}
EOF
export JEV_CONFIG="$HOME/.claude-config-test.json"
ev() { # ts tool-json cwd session
  printf '{"type":"assistant","timestamp":"%s","cwd":"%s","sessionId":"%s","message":{"content":[{"type":"text","text":"PROSE-MUST-NOT-LEAK"},%s]}}\n' "$1" "$3" "$4" "$2"
}
{
  ev 2026-10-04T13:00:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./data | cat"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:05:00Z '{"type":"tool_use","name":"Bash","input":{"command":"curl -H \"Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123\" https://x.example/deploy --prod"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:06:00Z '{"type":"tool_use","name":"Bash","input":{"command":"curl -H \"Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123\" https://x.example/deploy --prod"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:07:00Z '{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:08:00Z '{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/notes.md","content":"FILE-CONTENT-MUST-NOT-LEAK"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:09:00Z '{"type":"tool_use","name":"mcp__claude_ai_Gmail__send_message","input":{"body":"GMAIL-BODY-MUST-NOT-LEAK"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:10:00Z '{"type":"tool_use","name":"Bash","input":{"command":"cat ~/work/secret-repo/x.txt"}}' "$GOODCWD" sess-1
  ev 2026-10-04T13:11:00Z '{"type":"tool_use","name":"Bash","input":{"command":"echo from-excluded-cwd"}}' "$BADCWD" sess-2
  ev 2026-10-04T13:12:00Z '{"type":"tool_use","name":"Edit","input":{"file_path":"'"$HOME"'/Visa/a.ts"}}' "$GOODCWD" sess-2
  ev 2026-10-03T13:00:00Z '{"type":"tool_use","name":"Bash","input":{"command":"too early day"}}' "$GOODCWD" sess-1
  ev 2026-10-05T13:00:00Z '{"type":"tool_use","name":"Bash","input":{"command":"too late day"}}' "$GOODCWD" sess-1
  printf '{"type":"user","timestamp":"2026-10-04T13:01:00Z","cwd":"%s","message":{"content":[{"type":"tool_result","content":"TOOL-RESULT-MUST-NOT-LEAK"}]}}\n' "$GOODCWD"
} >"$PROJ/-p1/s1.jsonl"
ev 2026-10-04T14:00:00Z '{"type":"tool_use","name":"Bash","input":{"command":"git push origin main"}}' "$GOODCWD" sess-3 >"$PROJ/-p2/s3.jsonl"

# Stub client: records each request, answers by content, never touches the network.
STUB="$T/jev-ask-stub"
cat >"$STUB" <<'EOF'
#!/bin/bash
REQ=$(cat)
printf '%s\n' "$REQ" >>"$STUB_LOG"
printf '%s\n' "${JEV_ORIGIN:-}" >>"$STUB_ORIGIN_LOG"
[ -n "${STUB_UNAVAILABLE:-}" ] && exit 3
case "$REQ" in
  *"rm -rf"*) P='{"data_loss":0.9,"none":0.1}' ;;
  *"deploy --prod"*) P='{"prod_system":0.85,"reversible":0.15}' ;;
  *"blockme.md"*) P='{"irreversible":0.9,"none":0.1}' ;;
  *"git push origin main"*) P='{"irreversible":0.82,"reversible":0.18}' ;;
  *) P='{"none":0.9,"data_loss":0.05,"reversible":0.05}' ;;
esac
printf '{"answers":{"risk_class":{"type":"choice","choice":"x","probabilities":%s}},"model":"mock","latency_ms":1,"cost_usd":0}' "$P"
EOF
chmod +x "$STUB"
export STUB_LOG="$T/stub.log" STUB_ORIGIN_LOG="$T/stub-origin.log"
export JEV_ASK="$STUB"

echo "== nightly audit: dry run"
: >"$STUB_LOG"
D=$(python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG" --out "$T/aout" --dry-run)
eq "dry run makes no Jev calls" "0" "$(grep -c . "$STUB_LOG")"
[[ -e "$T/aout" ]] && bad "dry run writes nothing" || ok
has "dry run lists a command" "$D" "Bash	ls -la"
has "dry run lists the Write path" "$D" "Write	/Users/x/notes.md"
has "dry run states the counts" "$D" "would send 5"
has "dry run counts excluded actions" "$D" "skipped (excluded paths) 3"
lacks "dry run redacts the bearer token" "$D" "abcdefghijklmnopqrstuvwxyz0123"
has "dry run shows the redaction marker" "$D" "Bearer [REDACTED]"
lacks "tool_result content is never read" "$D" "TOOL-RESULT-MUST-NOT-LEAK"
lacks "assistant prose is never read" "$D" "PROSE-MUST-NOT-LEAK"
lacks "file content is never read" "$D" "FILE-CONTENT-MUST-NOT-LEAK"
lacks "other tools (Gmail) are never read" "$D" "GMAIL-BODY-MUST-NOT-LEAK"
lacks "events outside the day are skipped" "$D" "too early day"
lacks "events after the day are skipped" "$D" "too late day"
lacks "excluded cwd skipped" "$D" "from-excluded-cwd"
lacks "a command naming an excluded path is skipped" "$D" "secret-repo"
lacks "an excluded Write/Edit path is skipped" "$D" "Visa/a.ts"

echo "== nightly audit: run"
: >"$STUB_LOG"
: >"$STUB_ORIGIN_LOG"
python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG" --out "$T/aout" >"$T/path.txt"
eq "writes the daily file" "$T/aout/jev-daily-2026-10-04.md" "$(cat "$T/path.txt")"
A=$(cat "$T/aout/jev-daily-2026-10-04.md")
eq "one Jev call per distinct action" "5" "$(grep -c . "$STUB_LOG")"
eq "every call has origin audit" "5" "$(grep -c '^audit$' "$STUB_ORIGIN_LOG")"
SENT=$(cat "$STUB_LOG")
lacks "the request never carries the bearer token" "$SENT" "abcdefghijklmnopqrstuvwxyz0123"
lacks "the request never carries tool_result text" "$SENT" "TOOL-RESULT-MUST-NOT-LEAK"
lacks "the request never carries file content" "$SENT" "FILE-CONTENT-MUST-NOT-LEAK"
has "rule is audit/risk-class" "$SENT" '"rule": "audit/risk-class"'
has "asks the shared risk_class choice question" "$SENT" '"risk_class": {"type": "choice"'
has "section heading" "$A" "## Nightly audit"
has "starts a daily file when none exists" "$A" "# Jev daily summary 2026-10-04"
has "deploy flagged" "$A" "prod_system | 0.85 | Bash | curl -H"
has "push to main flagged" "$A" "irreversible | 0.82 | Bash | git push origin main"
lacks "rm -rf was blocked by a gate (matched by logged action): not reported" "$A" "rm -rf ./data"
has "blocked count" "$A" "1 risky action(s) were blocked"
lacks "benign command not reported" "$A" "ls -la"
has "counts line" "$A" "actions extracted 9, skipped for excluded paths 3, distinct 5"

echo "== nightly audit: join by session and time when the gate row has no action text"
LOG2="$T/decisions2.jsonl"
cat >"$LOG2" <<'EOF'
{"ts":"2026-10-04T13:05:10Z","gate":"G4-prod","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","action_sha":"ccc","session_id":"sess-1"}
{"ts":"2026-10-04T13:06:10Z","gate":"G4-prod","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","action_sha":"ccd","session_id":"sess-1"}
{"ts":"2026-10-04T14:00:00Z","gate":"G4-prod","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","action_sha":"ddd","session_id":"other-session"}
EOF
S2=$(python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG2" --stdout)
lacks "deploy blocked by session+time join: not reported" "$S2" "deploy --prod"
has "same time, different session: still reported" "$S2" "git push origin main"

echo "== nightly audit: heredoc bodies, relative paths, per-occurrence blocks"
PROJ2="$T/projects2"
mkdir -p "$PROJ2/-q1"
{
  ev 2026-10-04T13:00:00Z '{"type":"tool_use","name":"Bash","input":{"command":"cat > private.conf <<EOF\nHEREDOC-BODY-MUST-NOT-LEAK\nEOF\nrm -rf ./after"}}' "$GOODCWD" sess-9
  ev 2026-10-04T13:01:00Z '{"type":"tool_use","name":"Bash","input":{"command":"cat ../../work/REL-EXCLUDED-MARK/x.txt"}}' "$GOODCWD" sess-9
  ev 2026-10-04T13:02:00Z '{"type":"tool_use","name":"Write","input":{"file_path":"/Users/x/blockme.md"}}' "$GOODCWD" sess-9
  ev 2026-10-04T13:03:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./twice"}}' "$GOODCWD" sess-9
  ev 2026-10-04T15:03:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./twice"}}' "$GOODCWD" sess-9
} >"$PROJ2/-q1/s9.jsonl"
D2=$(python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ2" --log "$LOG" --dry-run)
lacks "heredoc body is not listed" "$D2" "HEREDOC-BODY-MUST-NOT-LEAK"
has "heredoc command line is kept with a placeholder" "$D2" "cat > private.conf <<EOF [heredoc body omitted] rm -rf ./after"
lacks "a relative path into an excluded tree is skipped" "$D2" "REL-EXCLUDED-MARK"
has "relative-path skip is counted" "$D2" "skipped (excluded paths) 1"
LOG3="$T/decisions3.jsonl"
cat >"$LOG3" <<'EOF'
{"ts":"2026-10-04T13:02:00Z","gate":"G2-write","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Write","session_id":"sess-9","action":"Write /Users/x/blockme.md"}
{"ts":"2026-10-04T13:03:00Z","gate":"G1-rm","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","session_id":"sess-9","action":"rm -rf ./twice"}
EOF
: >"$STUB_LOG"
S3=$(python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ2" --log "$LOG3" --stdout)
lacks "heredoc body never reaches the client" "$(cat "$STUB_LOG")" "HEREDOC-BODY-MUST-NOT-LEAK"
lacks "Write block row with a tool prefix matches the path action" "$S3" "blockme.md"
has "a second, unblocked occurrence is still reported" "$S3" "rm -rf ./twice"
has "an unrelated unblocked action is still reported" "$S3" "rm -rf ./after"

echo "== nightly audit: idempotent, summary keeps the audit section"
python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG" --out "$T/aout" >/dev/null
eq "re-running the audit keeps one section" "1" "$(grep -c '^## Nightly audit' "$T/aout/jev-daily-2026-10-04.md")"
python3 -I "$SUMMARY" --date 2026-10-04 --log "$LOG" --out "$T/aout" >/dev/null
RS=$(cat "$T/aout/jev-daily-2026-10-04.md")
has "summary re-run keeps the audit section" "$RS" "## Nightly audit"
eq "summary section appears once" "1" "$(grep -c '^# Jev daily summary' "$T/aout/jev-daily-2026-10-04.md")"
has "audit goes after the summary" "$(grep -n '^## By origin\|^## Nightly audit' "$T/aout/jev-daily-2026-10-04.md" | cut -d: -f2 | tr '\n' ' ')" "## By origin ## Nightly audit"

echo "== nightly audit: max-calls and unavailable"
: >"$STUB_LOG"
M=$(python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG" --max-calls 2 --stdout)
eq "--max-calls caps the calls" "2" "$(grep -c . "$STUB_LOG")"
has "the rest is reported as not scored" "$M" "not scored 3"
: >"$STUB_LOG"
U=$(STUB_UNAVAILABLE=1 python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG" --stdout)
eq "stops after 5 unavailable calls in a row" "5" "$(grep -c . "$STUB_LOG")"
has "says it stopped early" "$U" "Stopped early"
has "unavailable counted" "$U" "unavailable 5"

echo "== nightly audit: unreadable config refuses to scan"
JEV_CONFIG="$T/nope.json" python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --dry-run >/dev/null 2>&1
MISSING_RC=$?
if [[ -f "$JSRC/jev-config.json" ]]; then
  # find_config falls back to the shipped config when the override is missing; only a corrupt file refuses
  echo '{ not json' >"$T/bad.json"
  JEV_CONFIG="$T/bad.json" python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --dry-run >/dev/null 2>&1
  eq "corrupt exclude config exits 1" "1" "$?"
else
  eq "missing config override with no shipped config exits 1" "1" "$MISSING_RC"
fi

echo "== nightly audit through the real client in JEV_MOCK mode"
if command -v node >/dev/null 2>&1 && [[ -x "$JSRC/jev-ask" ]]; then
  printf '{"answers":{"risk_class":{"type":"choice","choice":"data_loss","probabilities":{"data_loss":0.95,"none":0.05}}},"model":"mock","latency_ms":1,"cost_usd":0}' >"$T/fixture.json"
  mkdir -p "$T/state"
  RM=$(JEV_ASK="$JSRC/jev-ask" JEV_MOCK="$T/fixture.json" JEV_STATE_DIR="$T/state" JEV_RECORD="$T/record.json" JEV_RULES="$T/none.json" \
    python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ" --log "$LOG2" --stdout 2>&1)
  has "real client in mock mode answers" "$RM" "data_loss | 0.95"
  if [[ -f "$T/state/jev/decisions.jsonl" ]]; then
    has "client logged origin audit" "$(cat "$T/state/jev/decisions.jsonl")" '"origin":"audit"'
  else
    bad "client wrote its decision log" "missing $T/state/jev/decisions.jsonl"
  fi
  if [[ -f "$T/record.json" ]]; then
    lacks "client payload carries no bearer token" "$(cat "$T/record.json")" "abcdefghijklmnopqrstuvwxyz0123"
  else
    bad "client wrote its record file" "missing $T/record.json"
  fi
else
  echo "  (node or jev-ask missing: skipped)"
fi

echo "== nightly audit: one-to-one blocks, cwd, exact text, truncation"
PROJ4="$T/projects4"
mkdir -p "$PROJ4/-r1" "$HOME/repos/other"
OTHERCWD="$HOME/repos/other"
LONGCMD="rm -rf /tmp/$(printf 'a%.0s' $(seq 1 300))/end"
{
  ev 2026-10-04T13:00:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./dup"}}' "$GOODCWD" sess-20
  ev 2026-10-04T13:00:10Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./dup"}}' "$GOODCWD" sess-20
  ev 2026-10-04T13:10:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./samecwd"}}' "$GOODCWD" sess-21
  ev 2026-10-04T13:10:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf ./samecwd"}}' "$OTHERCWD" sess-21
  ev 2026-10-04T13:20:00Z '{"type":"tool_use","name":"Bash","input":{"command":"rm -rf database"}}' "$GOODCWD" sess-22
  ev 2026-10-04T13:30:00Z '{"type":"tool_use","name":"Bash","input":{"command":"'"$LONGCMD"'"}}' "$GOODCWD" sess-23
} >"$PROJ4/-r1/s.jsonl"
TRUNC="${LONGCMD:0:136} ... ${LONGCMD: -58}"
LOG4="$T/decisions4.jsonl"
cat >"$LOG4" <<EOF
{"ts":"2026-10-04T13:00:05Z","gate":"G1-rm","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","session_id":"sess-20","action":"rm -rf ./dup"}
{"ts":"2026-10-04T13:10:00Z","gate":"G1-rm","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","session_id":"sess-21","action":"rm -rf ./samecwd"}
{"ts":"2026-10-04T13:20:00Z","gate":"G1-rm","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","session_id":"sess-22","action":"rm -rf data"}
{"ts":"2026-10-04T13:30:00Z","gate":"G1-rm","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","session_id":"sess-23","action":"$TRUNC"}
EOF
: >"$STUB_LOG"
S4=$(python3 -I "$AUDIT" --date 2026-10-04 --projects "$PROJ4" --log "$LOG4" --stdout)
eq "same text in two cwds is scored separately (5 calls)" "5" "$(grep -c . "$STUB_LOG")"
eq "two identical commands, one deny: the second is reported" "1" "$(printf '%s\n' "$S4" | grep -c 'rm -rf ./dup')"
eq "same text in two cwds, one deny: exactly one reported" "1" "$(printf '%s\n' "$S4" | grep -c 'rm -rf ./samecwd')"
has "deny on a shorter prefix does not block the longer command" "$S4" "rm -rf database"
lacks "a gate-truncated logged action still matches the long command" "$S4" "aaaaaaaaaaaa"

echo "== daily summary: one blocked call, several gates"
LOG5="$T/decisions5.jsonl"
cat >"$LOG5" <<'EOF'
{"ts":"2026-10-04T13:00:00Z","gate":"G1","mode":"enforce","outcome":"hit-enforce","src":"hook:jev-gate","tool":"Bash","action_sha":"m1","session_id":"s-m"}
{"ts":"2026-10-04T13:00:00Z","gate":"G3","mode":"enforce","outcome":"hit-enforce","src":"hook:jev-gate","tool":"Bash","action_sha":"m1","session_id":"s-m"}
{"ts":"2026-10-04T13:00:00Z","gate":"G1,G3","mode":"enforce","outcome":"deny","src":"hook:jev-gate","tool":"Bash","action_sha":"m1","session_id":"s-m","action":"multi-rule-call"}
{"ts":"2026-10-04T14:00:00Z","gate":"G5","mode":"enforce","outcome":"hit-enforce","src":"hook:jev-gate","tool":"Bash","action_sha":"m2","session_id":"s-m"}
{"ts":"2026-10-04T14:00:00Z","gate":"G6","mode":"enforce","outcome":"hit-enforce","src":"hook:jev-gate","tool":"Bash","action_sha":"m2","session_id":"s-m"}
EOF
M5=$(python3 -I "$SUMMARY" --date 2026-10-04 --log "$LOG5" --stdout)
has "multi-gate deny is one event listing all gates" "$M5" "| G1,G3 | deny |"
lacks "its hit-enforce rows are not counted again" "$M5" "| G1 | hit-enforce"
has "hit-enforce rows without a deny merge into one event" "$M5" "| G5,G6 | hit-enforce |"
eq "two blocked calls in total" "2" "$(printf '%s\n' "$M5" | grep -c '| hit-enforce |\|| deny |')"

echo "== installer"
H="$T/ihome"
mkdir -p "$H"
DRY=$(HOME="$H" JEV_REPO_DIR="$REPO_ROOT" sh "$INSTALL")
has "dry run says it changes nothing" "$DRY" "nothing written"
[[ -e "$H/Library" ]] && bad "dry run creates nothing" || ok
WR=$(HOME="$H" JEV_REPO_DIR="$REPO_ROOT" sh "$INSTALL" --write)
PL="$H/Library/LaunchAgents/com.damilola.jev-daily-report.plist"
[[ -f "$PL" ]] && ok || bad "plist written"
has "tells the owner how to load" "$WR" "launchctl load"
has "says it did not load" "$WR" "Not loaded"
PLT=$(cat "$PL")
lacks "no __HOME__ left" "$PLT" "__HOME__"
lacks "no __REPO__ left" "$PLT" "__REPO__"
has "repo path is the WorkingDirectory" "$PLT" "<key>WorkingDirectory</key>"
has "repo path substituted" "$PLT" "<string>$REPO_ROOT</string>"
lacks "no cd in the shell command" "$PLT" "cd "
has "runs the summary then the audit" "$PLT" "jev-daily-summary.py; python3 scripts/jev-nightly-audit.py"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PL" >/dev/null 2>&1
  eq "plist is valid" "0" "$?"
fi
eq "06:30 schedule hour" "6" "$(python3 -I -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb'))['StartCalendarInterval']['Hour'])" "$PL")"
eq "06:30 schedule minute" "30" "$(python3 -I -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb'))['StartCalendarInterval']['Minute'])" "$PL")"
AH="$T/amp home"
AR="$T/a&b|c"
mkdir -p "$AH" "$AR/scripts" "$AR/system-configs/.claude/launchagents"
cp "$REPO_ROOT/system-configs/.claude/launchagents/com.damilola.jev-daily-report.plist.template" "$AR/system-configs/.claude/launchagents/"
: >"$AR/scripts/jev-daily-summary.py"
: >"$AR/scripts/jev-nightly-audit.py"
HOME="$AH" JEV_REPO_DIR="$AR" sh "$INSTALL" --write >/dev/null 2>&1
APL="$AH/Library/LaunchAgents/com.damilola.jev-daily-report.plist"
plkey() { python3 -I -c "import plistlib,sys;d=plistlib.load(open(sys.argv[1],'rb'));print(d[sys.argv[2]] if sys.argv[2]!='cmd' else d['ProgramArguments'][2])" "$1" "$2" 2>&1; }
eq "a path with & and | survives substitution" "$AR" "$(plkey "$APL" WorkingDirectory)"
HO="$T/hostile home"
HR="$T/h\"o\$(touch pwned)'s&r"
mkdir -p "$HO" "$HR/scripts" "$HR/system-configs/.claude/launchagents"
cp "$REPO_ROOT/system-configs/.claude/launchagents/com.damilola.jev-daily-report.plist.template" "$HR/system-configs/.claude/launchagents/"
: >"$HR/scripts/jev-daily-summary.py"
: >"$HR/scripts/jev-nightly-audit.py"
HOME="$HO" JEV_REPO_DIR="$HR" sh "$INSTALL" --write >/dev/null 2>&1
HPL="$HO/Library/LaunchAgents/com.damilola.jev-daily-report.plist"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$HPL" >/dev/null 2>&1
  eq "hostile-path plist is valid" "0" "$?"
fi
eq "hostile path is the exact WorkingDirectory" "$HR" "$(plkey "$HPL" WorkingDirectory)"
HCMD="$(plkey "$HPL" cmd)"
lacks "the shell command never contains the path" "$HCMD" "touch pwned"
(cd "$HR" && /bin/sh -c "$HCMD" >/dev/null 2>&1)
if [[ -e "$HR/pwned" || -e "$T/pwned" ]]; then bad "hostile path ran nothing" "pwned exists"; else ok; fi
HOME="$H" sh "$INSTALL" --bogus >/dev/null 2>&1
eq "unknown flag exits 2" "2" "$?"

echo ""
echo "Jev daily: $PASSES passed, $FAILS failed"
[[ "$FAILS" -eq 0 ]]
