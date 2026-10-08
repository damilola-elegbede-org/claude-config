#!/usr/bin/env bash
# Hermetic test: a station manifest's sync.mods_exclude keeps named mods off that station.
# A real sync runs into a temp HOME from a temp repo layout; nothing touches the real ~/.claude.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

for t in jq rsync python3; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "SKIP: $t not installed" >&2
    exit 0
  }
done
for m in glassbox replay-theater; do
  [[ -d "$REPO_ROOT/system-configs/.claude/mods/$m" ]] || {
    echo "SKIP: mod $m not in the source tree" >&2
    exit 0
  }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-mods-exclude.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# sync.sh finds its manifest from its own location + the host name, so run a copy inside a temp repo layout.
STATION="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
mkdir -p "$T/repo/scripts" "$T/repo/sync-manifests"
cp "$REPO_ROOT/scripts/sync.sh" "$T/repo/scripts/sync.sh"
ln -s "$REPO_ROOT/system-configs" "$T/repo/system-configs"

run_sync() { # label manifest-json ('' for none)
  local home="$T/home-$1"
  rm -rf "$home"
  mkdir -p "$home/.claude/mods/replay-theater/hooks" "$home/.claude/mods/local-mine"
  # What an earlier sync left, and a mod of the person's own.
  echo stale >"$home/.claude/mods/replay-theater/hooks/old.mjs"
  echo mine >"$home/.claude/mods/local-mine/keep"
  if [[ -n "$2" ]]; then
    printf '%s\n' "$2" >"$T/repo/sync-manifests/$STATION.json"
  else
    rm -f "$T/repo/sync-manifests/$STATION.json"
  fi
  SYNC_OUT=$(env HOME="$home" JEV_SYNC_SKIP_NPM=1 HIGGSFIELD_SYNC_SKIP_CHECK=1 bash "$T/repo/scripts/sync.sh" --force 2>&1)
  SYNC_RC=$?
}

run_sync excluded '{"mode":"scoped","sync":{"settings":false,"mods_exclude":["replay-theater"]}}'
M="$T/home-excluded/.claude/mods"
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "excluded: sync succeeds (rc=$SYNC_RC): $(grep -i 'mods\|❌' <<<"$SYNC_OUT" | head -3)"; fi
if [[ -f "$M/glassbox/hooks/register.tsx" ]]; then ok; else bad "excluded: other mods still sync"; fi
if [[ ! -e "$M/replay-theater" ]]; then ok; else bad "excluded: an excluded mod an earlier sync left is removed"; fi
if [[ -f "$M/local-mine/keep" ]]; then ok; else bad "excluded: a local-* mod is kept"; fi
if grep -q "excluded on $STATION: replay-theater" <<<"$SYNC_OUT"; then ok; else bad "excluded: the summary names the excluded mod"; fi

run_sync none ''
M="$T/home-none/.claude/mods"
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "no manifest: sync succeeds (rc=$SYNC_RC)"; fi
if [[ -f "$M/replay-theater/hooks/replay-theater.mjs" ]]; then ok; else bad "no manifest: every mod syncs"; fi
if [[ ! -e "$M/replay-theater/hooks/old.mjs" ]]; then ok; else bad "no manifest: --delete still clears stale files"; fi

run_sync invalid '{"mode":"scoped","sync":{"settings":false,"mods_exclude":["../skills"]}}'
if [[ "$SYNC_RC" -ne 0 ]]; then ok; else bad "invalid entry: the sync fails"; fi
if grep -q "invalid mods_exclude entry" <<<"$SYNC_OUT"; then ok; else bad "invalid entry: the error names it"; fi
if [[ -d "$T/home-invalid/.claude/mods/local-mine" ]]; then ok; else bad "invalid entry: nothing outside mods is removed"; fi

printf 'mods_exclude sync tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
