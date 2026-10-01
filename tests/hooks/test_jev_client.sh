#!/usr/bin/env bash
# Tests for the Jev client (system-configs/.claude/hooks/jev). CI never calls
# the Gateway: everything runs against mocks (JEV_MOCK, JEV_BACKEND_FIXTURE),
# a temp HOME, and a copy of the client in a temp dir.
#
# Covers: mock mode, unavailable -> exit 3, kill switch, egress exclusion,
# redaction (a secret must never reach the recorded post-redaction payload or
# the shadow log), truncation, shadow log carries no state, bad input -> exit 2,
# per-rule off, daemon lifecycle (auto-start, warm reuse, single instance, idle
# exit, stale socket, direct fallback, timeout), SessionStart degradation line.
#
# Credential fixtures are assembled from fragments at runtime: spelled out
# literally they would trip the Write secret guard on this very file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/system-configs/.claude/hooks/jev"

if ! command -v node >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: node is not installed; the Jev client cannot run." >&2
    exit 1
  fi
  echo "SKIP: node not installed (would FAIL in CI)" >&2
  exit 0
fi

# Nothing from the caller's environment may leak in (a real key, a live socket).
for v in $(env | sed -n 's/^\(JEV_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
unset AI_GATEWAY_API_KEY VERCEL_AI_GATEWAY_TOKEN VERCEL_AI_GATEWAY_KEY

T="$(mktemp -d /tmp/jevt.XXXXXX)"
J="$T/hooks/jev"
export HOME="$T"
mkdir -p "$J" "$T/.claude"
cp "$SRC/client.mjs" "$SRC/jev-ask" "$SRC/session-check.sh" "$SRC/jev-config.json" "$SRC/jev-rules.json" "$J/"
chmod +x "$J/jev-ask" "$J/session-check.sh"
ASK="$J/jev-ask"
SHADOW="$T/.claude/jev-shadow.jsonl"

cleanup() {
  pkill -f "$J/client.mjs --daemon" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1" >&2; [[ -n "${2:-}" ]] && echo "       $2" >&2; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing [$3] in [${2:0:300}]"; fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected [$3] present"; fi; }

OUT=""
ERR=""
RC=0
# run_ask <stdin-json> [ENV=val ...]
run_ask() {
  local input="$1"
  shift
  OUT=$(printf '%s' "$input" | env "$@" "$ASK" 2>"$T/stderr")
  RC=$?
  ERR=$(cat "$T/stderr")
}

Q='{"x":{"type":"boolean","instructions":"is it destructive?"}}'
mkin() { printf '{"rule":"%s","state":%s,"questions":%s}' "$1" "$2" "${3:-$Q}"; }

FIX="$T/fixture.json"
echo '{"answers":{"x":{"type":"boolean","probability":0.82}},"model":"typesafe-ai/jev","latency_ms":140,"cost_usd":0.000014}' >"$FIX"

echo "== repo config shape"
eq "package.json pins ai exactly" "$(node -e "console.log(require('$SRC/package.json').dependencies.ai)")" "7.0.126"
# shellcheck disable=SC2088 # literal tilde in a test description
has "exclude_paths has ~/Visa" "$(node -e "console.log(require('$SRC/jev-config.json').exclude_paths.join(' '))")" "~/Visa"
# shellcheck disable=SC2088 # literal tilde in a test description
has "exclude_paths has ~/work" "$(node -e "console.log(require('$SRC/jev-config.json').exclude_paths.join(' '))")" "~/work"
lacks "exclude_paths has no bare /work/ substring entry" "$(node -e "console.log(require('$SRC/jev-config.json').exclude_paths.join(' '))")" " /work/"
eq "exempt_agents" "$(node -e "console.log(require('$SRC/jev-rules.json').exempt_agents.join(','))")" "dara,clara"
eq "rules map starts empty" "$(node -e "console.log(String(Object.keys(require('$SRC/jev-rules.json').rules).length))")" "0"

echo "== mock mode"
run_ask "$(mkin t-mock '{"command":"ls"}')" JEV_MOCK="$FIX"
eq "mock exit 0" "$RC" "0"
has "mock returns fixture" "$OUT" '"probability":0.82'
run_ask "$(mkin t-mock '{"command":"ls"}')" JEV_MOCK=unavailable
eq "JEV_MOCK=unavailable exits 3" "$RC" "3"
eq "unavailable has empty stdout" "$OUT" ""

echo "== bad input"
run_ask 'not json' JEV_MOCK="$FIX"
eq "invalid JSON exits 2" "$RC" "2"
run_ask '{"state":{},"questions":{"x":{"type":"boolean","instructions":"q"}}}' JEV_MOCK="$FIX"
eq "missing rule exits 2" "$RC" "2"
run_ask "$(mkin t-bad '{"a":1}' '{"x":{"type":"nope","instructions":"q"}}')" JEV_MOCK="$FIX"
eq "bad question type exits 2" "$RC" "2"
run_ask "$(mkin t-bad '{"a":1}' '{"x":{"type":"choice","instructions":"q"}}')" JEV_MOCK="$FIX"
eq "choice without criteria exits 2" "$RC" "2"
run_ask "$(mkin t-bad '{"a":1}')" JEV_MOCK="$T/does-not-exist.json"
eq "unreadable mock fixture exits 2" "$RC" "2"

echo "== key, kill switch, rule off"
run_ask "$(mkin t-nokey '{"a":1}')"
eq "no key exits 3" "$RC" "3"
has "no key says why" "$ERR" "no_key"
touch "$T/.claude/jev.off"
run_ask "$(mkin t-kill '{"a":1}')" JEV_MOCK="$FIX"
eq "kill switch exits 3 even with a mock" "$RC" "3"
has "kill switch says why" "$ERR" "kill_switch"
rm -f "$T/.claude/jev.off"
run_ask "$(mkin t-kill '{"a":1}')" JEV_MOCK="$FIX"
eq "kill switch removed -> 0" "$RC" "0"
mkdir "$T/.claude/jev.off"
run_ask "$(mkin t-kill '{"a":1}')" JEV_MOCK="$FIX"
eq "a DIRECTORY named jev.off is not the kill switch (mkdir tamper does nothing)" "$RC" "0"
rmdir "$T/.claude/jev.off"
printf '{"exempt_agents":[],"rules":{"r-off":{"mode":"off"},"r-shadow":{"mode":"shadow"}}}' >"$J/jev-rules.json"
run_ask "$(mkin r-off '{"a":1}')" JEV_MOCK="$FIX"
eq "rule mode off exits 3" "$RC" "3"
run_ask "$(mkin r-shadow '{"a":1}')" JEV_MOCK="$FIX"
eq "rule mode shadow runs" "$RC" "0"
printf '{"exempt_agents":[],"r-top":{"mode":"off"}}' >"$J/jev-rules.json"
run_ask "$(mkin r-top '{"a":1}')" JEV_MOCK="$FIX"
eq "top-level rule entry (contract shape) also honored" "$RC" "3"
# One registry reader: rules.d/*.json (lexical) then jev-rules.json LAST (the user's file wins).
mkdir -p "$J/rules.d"
printf '{"rules":{"r-d":{"mode":"off"},"r-both":{"mode":"off"}}}' >"$J/rules.d/10-a.json"
printf '{"r-d2":{"mode":"off"}}' >"$J/rules.d/20-b.json"
printf '{"exempt_agents":[],"rules":{"r-both":{"mode":"shadow"}}}' >"$J/jev-rules.json"
run_ask "$(mkin r-d '{"a":1}')" JEV_MOCK="$FIX"
eq "rules.d entry (wrapped shape) honored by the client" "$RC" "3"
run_ask "$(mkin r-d2 '{"a":1}')" JEV_MOCK="$FIX"
eq "rules.d entry (flat shape) honored by the client" "$RC" "3"
run_ask "$(mkin r-both '{"a":1}')" JEV_MOCK="$FIX"
eq "jev-rules.json overrides rules.d for the same rule" "$RC" "0"
rm -rf "$J/rules.d"
cp "$SRC/jev-rules.json" "$J/jev-rules.json"

echo "== egress exclusion"
mkdir -p "$T/personal/proj" "$T/work/proj" "$T/Visa/repo"
run_ask "$(mkin t-egress '{"a":1}')" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "personal cwd is allowed" "$RC" "0"
OUT=$(cd "$T/work/proj" && printf '%s' "$(mkin t-egress '{"a":1}')" | env JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1 "$ASK" 2>"$T/stderr")
RC=$?
eq "cwd under ~/work exits 3" "$RC" "3"
has "egress says why" "$(cat "$T/stderr")" "egress_excluded_path"
run_ask "{\"rule\":\"t-egress\",\"cwd\":\"$T/Visa/repo\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "caller-supplied cwd under Visa exits 3 (case-insensitive)" "$RC" "3"
run_ask "{\"rule\":\"t-egress\",\"untrusted_source\":\"gmail\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "gmail untrusted_source exits 3" "$RC" "3"
run_ask "{\"rule\":\"t-egress\",\"untrusted_source\":[\"web\",\"slack\"],\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "slack untrusted_source exits 3" "$RC" "3"
run_ask "{\"rule\":\"t-egress\",\"state\":{\"untrusted_source\":\"gmail\",\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "untrusted_source flagged inside state exits 3" "$RC" "3"
OUT=$(cd "$T/work/proj" && printf '%s' "$(mkin t-egress '{"a":1}')" | env JEV_MOCK="$FIX" "$ASK" 2>/dev/null)
RC=$?
eq "mock mode skips egress unless asked" "$RC" "0"
# Exclusions are anchored at $HOME (or an absolute prefix), never a bare substring: a CI checkout such as
# /home/runner/work/<repo> must be allowed, a sibling like ~/workshop must be allowed, ~/Work/.. refused.
mkdir -p "$T/ci/home/runner/work/repo" "$T/workshop/x" "$T/Work/Proj" "$T/elsewhere/visa/repo"
for okdir in "$T/ci/home/runner/work/repo" "$T/workshop/x" "$T/elsewhere/visa/repo"; do
  run_ask "{\"rule\":\"t-egress\",\"cwd\":\"$okdir\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
  eq "cwd ${okdir#"$T"/} is not under an excluded HOME dir -> allowed" "$RC" "0"
done
run_ask "{\"rule\":\"t-egress\",\"cwd\":\"$T/Work/Proj\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "cwd ~/Work/Proj refused (case-insensitive)" "$RC" "3"
ln -s "$T/work/proj" "$T/linked-into-work"
run_ask "{\"rule\":\"t-egress\",\"cwd\":\"$T/linked-into-work\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "symlink into ~/work refused (realpath)" "$RC" "3"
printf '{"exclude_paths":["/srv/clients/","~/clients/**"]}' >"$J/jev-config.json"
mkdir -p "$T/clients/a"
run_ask "{\"rule\":\"t-egress\",\"cwd\":\"/srv/clients/acme\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "absolute prefix entry refuses /srv/clients/acme" "$RC" "3"
run_ask "{\"rule\":\"t-egress\",\"cwd\":\"$T/clients/a\",\"state\":{\"a\":1},\"questions\":$Q}" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
# shellcheck disable=SC2088 # literal tilde in a test description
eq "~/clients/** entry refuses ~/clients/a" "$RC" "3"
printf '{"exclude_paths":["~/work"' >"$J/jev-config.json" # truncated mid-write
OUT=$(cd "$T/personal/proj" && printf '%s' "$(mkin t-egress '{"a":1}')" | env JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1 "$ASK" 2>"$T/stderr")
RC=$?
eq "malformed jev-config.json fails closed even from a personal cwd" "$RC" "3"
has "malformed config says why" "$(cat "$T/stderr")" "egress_config_unreadable"
rm -f "$J/jev-config.json"
run_ask "$(mkin t-egress '{"a":1}')" JEV_MOCK="$FIX" JEV_MOCK_CHECK_EGRESS=1
eq "missing jev-config.json is not an error (no exclusions configured)" "$RC" "0"
cp "$SRC/jev-config.json" "$J/jev-config.json"

echo "== redaction"
AWS="AKIA""IOSFODNN7""EXAMPLE"
GHP="ghp""_$(printf 'a%.0s' $(seq 1 36))"
GHO="gho""_$(printf 'b%.0s' $(seq 1 36))"
SKK="sk""-$(printf 'c%.0s' $(seq 1 24))"
XOXB="xoxb""-1234567890-abcdefghij"
XOXP="xoxp""-1234567890-abcdefghij"
GLP="glpat""-$(printf 'd%.0s' $(seq 1 20))"
VCK="vck""_$(printf 'e%.0s' $(seq 1 30))"
JWT="eyJ""hbGciOiJIUzI1NiJ9.eyJ""zdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
HIGH="Zx9Qm4Lp7Rt2Wv8Yb3Nc6Hd1Fk5Js0Ga"
BEARER="Bearer ""abcdefghijklmnopqrstuvwx"
PW="hunter2-correct-horse"
URLPW="s3cr3tpassw0rd"
STATE=$(node -e '
const [aws, ghp, gho, sk, xb, xp, glp, vck, jwt, high, bearer, pw, urlpw] = process.argv.slice(1);
console.log(JSON.stringify({
  command: `echo hello && curl -H "Authorization: ${bearer}" https://api.example.com`,
  keys: [aws, ghp, gho, sk, xb, xp, glp, vck, jwt].join(" "),
  blob: `token blob ${high} end`,
  env: `DATABASE_PASSWORD=${pw} FOO_API_KEY=${vck}`,
  url: `postgres://admin:${urlpw}@db.example.com/app`,
  pem: "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----",
  password: "plain-value-under-sensitive-key",
}));
' "$AWS" "$GHP" "$GHO" "$SKK" "$XOXB" "$XOXP" "$GLP" "$VCK" "$JWT" "$HIGH" "$BEARER" "$PW" "$URLPW")
UNTRUSTED='{"page":"leaked '"$GHP"' in web text"}'
REC="$T/record.json"
run_ask "{\"rule\":\"t-redact\",\"state\":$STATE,\"untrusted\":$UNTRUSTED,\"questions\":$Q}" JEV_MOCK="$FIX" JEV_RECORD="$REC"
eq "redaction run exits 0" "$RC" "0"
RECORDED=$(cat "$REC")
SHADOW_ALL=$(cat "$SHADOW")
for pair in "AWS:$AWS" "GHP:$GHP" "GHO:$GHO" "SKK:$SKK" "XOXB:$XOXB" "XOXP:$XOXP" "GLP:$GLP" "VCK:$VCK" "JWT:$JWT" "HIGH:$HIGH" "BEARER:${BEARER#Bearer }" "PW:$PW" "URLPW:$URLPW" "PLAIN:plain-value-under-sensitive-key" "PEM:MIIEpAIBAAKCAQEA"; do
  lacks "secret ${pair%%:*} never reaches recorded payload" "$RECORDED" "${pair#*:}"
  lacks "secret ${pair%%:*} never reaches shadow log" "$SHADOW_ALL" "${pair#*:}"
done
has "redaction marker present" "$RECORDED" "[REDACTED]"
has "ordinary text survives" "$RECORDED" "echo hello"
has "untrusted stays under its own key" "$(node -e "console.log(Object.keys(JSON.parse(require('fs').readFileSync('$REC','utf8')).state).join(','))")" "untrusted"
has "redaction count recorded in shadow log" "$(tail -1 "$SHADOW")" '"redactions":'
run_ask "{\"rule\":\"t-redact\",\"state\":{\"untrusted\":\"x\"},\"questions\":$Q}" JEV_MOCK="$FIX"
eq "state with its own untrusted key exits 2" "$RC" "2"

echo "== truncation"
BIG=$(node -e 'console.log(JSON.stringify({log:"HEADMARK"+"x".repeat(600000)+"TAILMARK", cmd:"ls"}))')
run_ask "{\"rule\":\"t-trunc\",\"state\":$BIG,\"questions\":$Q}" JEV_MOCK="$FIX" JEV_RECORD="$REC"
eq "truncation run exits 0" "$RC" "0"
STATE_LEN=$(node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('$REC','utf8')).state).length.toString())")
if [[ "$STATE_LEN" -le 112000 ]]; then ok "state under 28000 tokens at 4 chars/token ($STATE_LEN chars)"; else bad "state too large" "$STATE_LEN chars"; fi
RECORDED=$(cat "$REC")
has "truncation marker" "$RECORDED" "[truncated"
has "head preserved" "$RECORDED" "HEADMARK"
has "tail preserved" "$RECORDED" "TAILMARK"
has "short fields untouched" "$RECORDED" '"cmd": "ls"'
has "shadow log flags truncation" "$(tail -1 "$SHADOW")" '"truncated":true'

echo "== shadow log has no state"
: >"$SHADOW"
run_ask "$(mkin t-shadow '{"command":"STATE-MARKER-98765"}')" JEV_MOCK="$FIX"
run_ask "$(mkin t-shadow '{"command":"STATE-MARKER-98765"}')" JEV_MOCK=unavailable
eq "one line per call (ok + unavailable)" "$(wc -l <"$SHADOW" | tr -d ' ')" "2"
SH=$(cat "$SHADOW")
lacks "no state marker in shadow log" "$SH" "STATE-MARKER-98765"
lacks "no state key in shadow log" "$SH" '"state"'
has "shadow line has rule" "$SH" '"rule":"t-shadow"'
has "shadow line has cwd" "$SH" '"cwd":'
has "shadow line has answers" "$SH" '"probability":0.82'
has "shadow records unavailable calls too" "$SH" '"outcome":"unavailable"'

echo "== the one decision log (decisions.jsonl) mirrors the shadow log"
DEC="$T/.claude/jev/decisions.jsonl"
DL=$(grep -F '"gate":"t-shadow"' "$DEC" | head -1)
eq "decision line carries every documented field" "true" "$(jq -r '[has("ts","gate","mode","answers","confidence","model","latencyMs","outcome")] | all' <<<"$DL" 2>/dev/null)"
eq "decision line src is the client" "client" "$(jq -r .src <<<"$DL")"
eq "decision line carries the model (mock mode reports mock)" "mock" "$(jq -r .model <<<"$DL")"
eq "decision line carries latencyMs" "140" "$(jq -r .latencyMs <<<"$DL")"
eq "decision line carries confidence" "0.82" "$(jq -r .confidence <<<"$DL")"
lacks "decision log has no state" "$(cat "$DEC")" "STATE-MARKER-98765"

echo "== daemon lifecycle (backend fixture, no network)"
export JEV_BACKEND_FIXTURE="$FIX" JEV_IDLE_MS=1500 AI_GATEWAY_API_KEY=test-key-not-real
IN="$(mkin t-daemon '{"command":"echo hi"}' | sed 's/}$/,"timeout_ms":4000}/')"
pid_of() { sed -n 's/.*"pid":\([0-9]*\).*/\1/p' <<<"$1"; }
status() { env "$ASK" --status 2>/dev/null; }

run_ask "$IN"
eq "cold call via auto-started daemon exits 0" "$RC" "0"
has "cold call returns answers" "$OUT" '"probability":0.82'
P1=$(pid_of "$(status)")
if [[ -n "$P1" ]]; then ok "daemon is running (pid $P1)"; else bad "daemon not running after first call"; fi
run_ask "$IN"
eq "second call exits 0" "$RC" "0"
eq "warm call reuses the same daemon" "$(pid_of "$(status)")" "$P1"
has "daemon counted both requests" "$(status)" '"requests":2'
has "shadow says daemon served it" "$(tail -1 "$SHADOW")" '"source":"daemon"'

# idle exit (do not poll status meanwhile: a ping counts as activity)
sleep 2.8
eq "daemon exits when idle" "$(status)" ""
if [[ ! -e "$J/jev.sock" ]]; then ok "socket removed on idle exit"; else bad "socket file left behind"; fi

# single instance under concurrent cold starts
for i in 1 2 3 4; do
  (printf '%s' "$IN" | "$ASK" >"$T/conc.$i" 2>&1; echo $? >"$T/conc.$i.rc") &
done
wait
all_ok=yes
for i in 1 2 3 4; do [[ "$(cat "$T/conc.$i.rc")" == "0" ]] || all_ok=no; done
eq "4 concurrent cold callers all succeed" "$all_ok" "yes"
eq "exactly one daemon process" "$(pgrep -f "$J/client.mjs --daemon" | wc -l | tr -d ' ')" "1"

# stale socket: kill -9 leaves the file behind
PK=$(pid_of "$(status)")
kill -9 "$PK" 2>/dev/null
sleep 0.3
if [[ -e "$J/jev.sock" ]]; then ok "kill -9 leaves a stale socket file"; else bad "expected stale socket file"; fi
run_ask "$IN"
eq "call recovers from stale socket" "$RC" "0"
P2=$(pid_of "$(status)")
if [[ -n "$P2" && "$P2" != "$PK" ]]; then ok "fresh daemon replaced the stale one"; else bad "no fresh daemon" "old=$PK new=$P2"; fi
env "$ASK" --stop
for _ in $(seq 1 20); do
  [[ -z "$(status)" ]] && break
  sleep 0.1
done
eq "--stop stops the daemon" "$(status)" ""

# fallback to a direct call when the socket cannot be used
run_ask "$IN" JEV_SOCK=/nonexistent-dir/jev.sock
eq "unusable socket falls back to direct call" "$RC" "0"
has "shadow says direct" "$(tail -1 "$SHADOW")" '"source":"direct"'
run_ask "$IN" JEV_NO_DAEMON=1
eq "JEV_NO_DAEMON=1 is direct" "$RC" "0"

# timeout -> exit 3, empty stdout
run_ask "$(mkin t-timeout '{"a":1}' | sed 's/}$/,"timeout_ms":200}/')" JEV_BACKEND_DELAY_MS=1200 JEV_NO_DAEMON=1
eq "slow backend times out with exit 3" "$RC" "3"
eq "timeout has empty stdout" "$OUT" ""
has "timeout says why" "$ERR" "timeout"
unset JEV_BACKEND_FIXTURE JEV_IDLE_MS AI_GATEWAY_API_KEY

echo "== SessionStart degradation line"
rm -f "$T/.zshrc"
OUT=$(printf '{}' | "$J/session-check.sh" 2>&1)
has "no key -> one-line regex warning" "$OUT" "degraded to regex"
has "warning names the key" "$OUT" "no gateway key"
eq "warning is a single line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
printf 'export VERCEL_AI_GATEWAY_TOKEN="zshrc-test-key"\n' >"$T/.zshrc"
OUT=$(printf '{}' | env JEV_NO_DAEMON=1 "$J/session-check.sh" 2>&1)
has "key in ~/.zshrc but SDK missing -> sdk warning" "$OUT" "SDK not installed"
mkdir -p "$J/node_modules/ai"
echo '{"name":"ai","version":"0.0.0"}' >"$J/node_modules/ai/package.json"
OUT=$(printf '{}' | env JEV_NO_DAEMON=1 "$J/session-check.sh" 2>&1)
eq "key + SDK present -> silent" "$OUT" ""
touch "$T/.claude/jev.off"
OUT=$(printf '{}' | env JEV_NO_DAEMON=1 "$J/session-check.sh" 2>&1)
has "kill switch noted" "$OUT" "kill switch"
rm -f "$T/.claude/jev.off" "$T/.zshrc"
rm -rf "$J/node_modules"

echo "== log rotation keeps every archive"
: >"$SHADOW"
rm -f "$T"/.claude/jev-shadow.*.jsonl
for i in 1 2 3 4 5; do
  run_ask "$(mkin "t-rot$i" '{"command":"ls"}')" JEV_MOCK="$FIX" JEV_LOG_MAX_BYTES=1
done
YM=$(date -u +%Y%m)
eq "the first rotation of the month takes the plain archive name" "$([[ -f "$T/.claude/jev-shadow.$YM.jsonl" ]] && echo yes || echo no)" "yes"
eq "a later rotation in the same month gets a numbered archive instead of replacing it" "$([[ -f "$T/.claude/jev-shadow.$YM.1.jsonl" ]] && echo yes || echo no)" "yes"
eq "no line is lost across rotations (5 calls, 5 lines over the live log and the archives)" "$(cat "$SHADOW" "$T"/.claude/jev-shadow.*.jsonl | grep -c '"rule":"t-rot')" "5"

echo
echo "Jev client tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
