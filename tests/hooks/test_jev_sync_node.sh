#!/usr/bin/env bash
# Hermetic test: scripts/sync.sh refuses to npm-install the Jev SDK on a Node older than package.json's
# engines.node (npm treats engines as advisory), and installs with --engine-strict otherwise.
# A real sync runs into a temp HOME with stub `node` and `npm`; nothing touches the real ~/.claude or the registry.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$REPO_ROOT/scripts/sync.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

for t in jq rsync; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "SKIP: $t not installed" >&2
    exit 0
  }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-jev-sync-node.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# stub node: `node -p 'process.versions.node...'` answers $STUB_NODE_MAJOR; anything else is a no-op
printf '%s\n' '#!/bin/sh' 'echo "${STUB_NODE_MAJOR:-22}"' >"$T/bin/node"
# stub npm: records its arguments, creating node_modules like a real install would
printf '%s\n' '#!/bin/sh' 'echo "$@" >>"$NPM_LOG"' 'mkdir -p node_modules' >"$T/bin/npm"
chmod +x "$T/bin/node" "$T/bin/npm"

run_sync() { # major -> output; npm log in $T/npm.log
  local home="$T/home-$1"
  rm -rf "$home" "$T/npm.log"
  mkdir -p "$home"
  : >"$T/npm.log"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >"$home/.zshrc"
  SYNC_OUT=$(HOME="$home" NPM_LOG="$T/npm.log" STUB_NODE_MAJOR="$1" PATH="$T/bin:$PATH" HIGGSFIELD_SYNC_SKIP_CHECK=1 \
    env -u JEV_SYNC_SKIP_NPM -u AI_GATEWAY_API_KEY -u VERCEL_AI_GATEWAY_TOKEN -u VERCEL_AI_GATEWAY_KEY bash "$SYNC" --force 2>&1)
  SYNC_RC=$?
}

run_sync 20
if grep -q "older than the Node 22" <<<"$SYNC_OUT"; then ok; else bad "Node 20: reports that the SDK needs Node 22 (got: $(grep -i 'jev\|node' <<<"$SYNC_OUT" | head -3))"; fi
if [[ "$SYNC_RC" -ne 0 ]]; then ok; else bad "Node 20: the prerequisite check fails the sync"; fi
if [[ ! -d "$T/home-20/.claude/agents" ]]; then ok; else bad "Node 20: nothing is synced when a prerequisite is missing"; fi
if [[ ! -s "$T/npm.log" ]]; then ok; else bad "Node 20: npm ci is not run ($(cat "$T/npm.log"))"; fi
if [[ ! -e "$T/home-20/.claude/hooks/jev/node_modules/.jev-installed" ]]; then ok; else bad "Node 20: no installed marker is written"; fi

run_sync 22
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "Node 22: sync succeeds (rc=$SYNC_RC)"; fi
if grep -q "no Jev gateway key" <<<"$SYNC_OUT"; then ok; else bad "no key: the gateway-key warning is shown"; fi
if [[ "$(cat "$T/npm.log")" == *"ci --omit=dev"*"--engine-strict"* ]]; then ok; else bad "Node 22: npm ci runs with --engine-strict (got: $(cat "$T/npm.log"))"; fi
if [[ -e "$T/home-22/.claude/hooks/jev/node_modules/.jev-installed" ]]; then ok; else bad "Node 22: the installed marker is written"; fi

run_sync 22 'export VERCEL_AI_GATEWAY_TOKEN=abc123'
if grep -q "Jev gateway key" <<<"$SYNC_OUT" && ! grep -q "no Jev gateway key" <<<"$SYNC_OUT"; then ok; else bad "key in ~/.zshrc: recognised, no warning"; fi
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "key present: sync succeeds (rc=$SYNC_RC)"; fi

printf 'jev sync node-version tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
