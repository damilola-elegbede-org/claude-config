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
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

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

run_sync localname '{"mode":"scoped","sync":{"settings":false,"mods_exclude":["local-mine"]}}'
if [[ "$SYNC_RC" -ne 0 ]]; then ok; else bad "local-* entry: the sync fails"; fi
if [[ -f "$T/home-localname/.claude/mods/local-mine/keep" ]]; then ok; else bad "local-* entry: the local mod is never removed"; fi

run_sync string '{"mode":"scoped","sync":{"settings":false,"mods_exclude":"replay-theater"}}'
if [[ "$SYNC_RC" -ne 0 ]]; then ok; else bad "string, not array: the sync fails rather than syncing every mod"; fi
if grep -q "must be an array" <<<"$SYNC_OUT"; then ok; else bad "string, not array: the error says so"; fi

# A mod the sync cannot remove (a read-only folder inside it) fails the sync instead of claiming it was removed.
# Root removes a read-only folder anyway, so the case cannot be built there.
if [[ "$(id -u)" -ne 0 ]]; then
  home="$T/home-stuck"
  mkdir -p "$home/.claude/mods/replay-theater/locked"
  echo x >"$home/.claude/mods/replay-theater/locked/file"
  chmod 555 "$home/.claude/mods/replay-theater/locked"
  printf '%s\n' '{"mode":"scoped","sync":{"settings":false,"mods_exclude":["replay-theater"]}}' >"$T/repo/sync-manifests/$STATION.json"
  SYNC_OUT=$(env HOME="$home" JEV_SYNC_SKIP_NPM=1 HIGGSFIELD_SYNC_SKIP_CHECK=1 bash "$T/repo/scripts/sync.sh" --force 2>&1)
  SYNC_RC=$?
  chmod -R u+w "$home"
  if [[ "$SYNC_RC" -ne 0 ]]; then ok; else bad "unremovable: the sync fails"; fi
  if grep -q "could not remove replay-theater" <<<"$SYNC_OUT" && ! grep -q "removed replay-theater" <<<"$SYNC_OUT"; then ok; else bad "unremovable: says it could not remove it, never that it did"; fi
else
  echo "SKIP: unremovable-mod case (running as root)" >&2
fi

# --dry-run counts and names what the real sync would do, and flags a bad value.
preview() { # manifest-json
  printf '%s\n' "$1" >"$T/repo/sync-manifests/$STATION.json"
  SYNC_OUT=$(env HOME="$T/home-none" JEV_SYNC_SKIP_NPM=1 HIGGSFIELD_SYNC_SKIP_CHECK=1 bash "$T/repo/scripts/sync.sh" --dry-run 2>&1)
}
ALL_MODS=$(find "$REPO_ROOT/system-configs/.claude/mods" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
preview '{"mode":"scoped","sync":{"settings":false,"mods_exclude":["replay-theater"]}}'
if grep -q "$((ALL_MODS - 1)) mods → ~/.claude/mods/ (--delete; local-\* kept; excluded on $STATION: replay-theater)" <<<"$SYNC_OUT"; then ok; else bad "dry run: counts and names the exclusion (got: $(grep 'mods' <<<"$SYNC_OUT" | head -2))"; fi
preview '{"mode":"scoped","sync":{"settings":false,"mods_exclude":"replay-theater"}}'
if grep -q "must be an array of mod names (real sync would fail)" <<<"$SYNC_OUT"; then ok; else bad "dry run: flags a malformed mods_exclude"; fi

printf 'mods_exclude sync tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
