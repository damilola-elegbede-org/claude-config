#!/bin/bash
# Live Jev smoke test. NOT run by CI or tests/test.sh: it calls the real Vercel
# AI Gateway (about $0.00001 per call) and needs the key the client resolves
# (env AI_GATEWAY_API_KEY / VERCEL_AI_GATEWAY_TOKEN, else the export line in
# ~/.zshrc). The key is never printed.
#
# It runs a temp COPY of hooks/jev (deps installed there with npm ci), so the
# repo checkout never gets a node_modules (markdownlint scans nested ones) and
# ~/.claude is never touched: shadow log and daemon socket live in the temp dir too.
#
# Measures, in wall-clock ms per `jev-ask` invocation:
#   direct  cold Node + SDK import + gateway call, no daemon (JEV_NO_DAEMON=1)
#   daemon  first call (spawns the daemon, which preloads the SDK)
#   warm    follow-up calls through the already-running daemon
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/system-configs/.claude/hooks/jev"
WARM_CALLS="${WARM_CALLS:-5}"

command -v node >/dev/null 2>&1 || { echo "smoke: node not found" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "smoke: perl not found (used for ms timing)" >&2; exit 1; }

TMP="$(mktemp -d /tmp/jevsmoke.XXXXXX)"
JEV_DIR="$TMP/jev"
ASK="$JEV_DIR/jev-ask"
cleanup() {
  [[ -x "$ASK" ]] && "$ASK" --stop >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$JEV_DIR"
cp "$SRC_DIR"/{client.mjs,jev-ask,session-check.sh,jev-config.json,jev-rules.json,package.json,package-lock.json} "$JEV_DIR/"
echo "smoke: npm ci --omit=dev in temp copy"
(cd "$JEV_DIR" && npm ci --omit=dev --no-audit --no-fund --silent) || { echo "smoke: npm ci failed" >&2; exit 1; }

export JEV_STATE_DIR="$TMP/state"
export JEV_SOCK="$TMP/jev.sock"

reason=$("$ASK" --check 2>/dev/null)
if [[ -n "$reason" ]]; then
  echo "smoke: Jev not ready: $reason (a key must be resolvable; see client.mjs)" >&2
  exit 1
fi

INPUT='{"rule":"smoke","timeout_ms":15000,"state":{"command":"git push --force origin main","cwd":"/repo"},"questions":{"destructive":{"type":"boolean","instructions":"Is this shell command irreversible or destructive?"},"category":{"type":"choice","instructions":"What kind of action is this?","criteria":{"read_only":null,"local_write":null,"remote_write":null}}}}'

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

# call <label> [ENV=val ...] -> prints one result line, sets LAST_OUT/LAST_RC
call() {
  local label="$1"
  shift
  local t0 t1
  t0=$(now_ms)
  LAST_OUT=$(printf '%s' "$INPUT" | env "$@" "$ASK" 2>"$TMP/err")
  LAST_RC=$?
  t1=$(now_ms)
  if [[ "$LAST_RC" -ne 0 ]]; then
    printf '%-14s FAILED exit=%s (%s)\n' "$label" "$LAST_RC" "$(tr -d '\n' <"$TMP/err")"
    return 1
  fi
  local gw p
  gw=$(node -e 'const r=JSON.parse(process.argv[1]);console.log(String(r.latency_ms))' "$LAST_OUT")
  p=$(node -e 'const r=JSON.parse(process.argv[1]);console.log(String(r.answers.destructive.probability))' "$LAST_OUT")
  printf '%-14s wall=%5sms  gateway=%5sms  destructive=%s\n' "$label" "$((t1 - t0))" "$gw" "$p"
}

fail=0
call "direct-cold" JEV_NO_DAEMON=1 || fail=1
call "daemon-first" || fail=1
for i in $(seq 1 "$WARM_CALLS"); do
  call "warm-$i" || fail=1
done

echo
echo "last response: $LAST_OUT"
echo "shadow log lines (temp dir): $(wc -l <"$JEV_STATE_DIR/jev-shadow.jsonl" | tr -d ' ')"
if grep -q '"state"' "$JEV_STATE_DIR/jev-shadow.jsonl"; then
  echo "smoke: shadow log contains state" >&2
  fail=1
fi
exit "$fail"
