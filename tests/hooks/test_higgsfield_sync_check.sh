#!/usr/bin/env bash
# Hermetic test: scripts/sync.sh requires the `higgsfield` CLI because the vendored higgsfield-* skills drive it.
# A real sync runs into a temp HOME with a stub `higgsfield`; nothing touches the real ~/.claude or the network.
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

for t in jq rsync python3; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "SKIP: $t not installed" >&2
    exit 0
  }
done
ls -d "$REPO_ROOT"/system-configs/.claude/skills/higgsfield-* >/dev/null 2>&1 || {
  echo "SKIP: no higgsfield-* skills in the source tree" >&2
  exit 0
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-higgsfield-sync.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/shadow"

# stub higgsfield: --version prints build info; `account status` exits $STUB_HF_ACCOUNT_RC
cat >"$T/stub/higgsfield" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo "higgsfield 9.9.9 (stub) built 2026-01-01T00:00:00Z" ;;
  account) exit "${STUB_HF_ACCOUNT_RC:-0}" ;;
esac
STUB
chmod +x "$T/stub/higgsfield"

# PATH without any real higgsfield: shadow every PATH dir that holds one with symlinks to its other entries.
CLEAN_PATH=""
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  if [[ -e "$d/higgsfield" ]]; then
    s="$T/shadow/$(printf '%s' "$d" | tr '/' '_')"
    mkdir -p "$s"
    for f in "$d"/*; do
      [[ "$(basename "$f")" == "higgsfield" ]] && continue
      ln -s "$f" "$s/$(basename "$f")" 2>/dev/null || true
    done
    d="$s"
  fi
  CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$d"
done

run_sync() { # label path account_rc [extra env assignment]
  local home="$T/home-$1"
  rm -rf "$home"
  mkdir -p "$home"
  SYNC_OUT=$(env HOME="$home" PATH="$2" STUB_HF_ACCOUNT_RC="$3" JEV_SYNC_SKIP_NPM=1 ${4:+"$4"} bash "$SYNC" --force 2>&1)
  SYNC_RC=$?
}

run_sync missing "$CLEAN_PATH" 0
if grep -q "higgsfield not found" <<<"$SYNC_OUT"; then ok; else bad "missing CLI: reports it with the install command"; fi
if [[ "$SYNC_RC" -ne 0 ]]; then ok; else bad "missing CLI: the prerequisite check fails the sync"; fi
if [[ ! -d "$T/home-missing/.claude/skills" ]]; then ok; else bad "missing CLI: nothing is synced"; fi

run_sync ready "$T/stub:$CLEAN_PATH" 0
if grep -q "higgsfield 9.9.9" <<<"$SYNC_OUT" && grep -q "signed in with a workspace" <<<"$SYNC_OUT"; then ok; else bad "ready CLI: version and sign-in shown"; fi
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "ready CLI: sync succeeds (rc=$SYNC_RC)"; fi
if [[ -f "$T/home-ready/.claude/skills/higgsfield-generate/SKILL.md" ]]; then ok; else bad "ready CLI: higgsfield-generate is synced"; fi

run_sync signedout "$T/stub:$CLEAN_PATH" 1
if grep -q "higgsfield not ready" <<<"$SYNC_OUT"; then ok; else bad "signed out: warns with the login command"; fi
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "signed out: warns but still syncs (rc=$SYNC_RC)"; fi

run_sync skipped "$CLEAN_PATH" 0 HIGGSFIELD_SYNC_SKIP_CHECK=1
if [[ "$SYNC_RC" -eq 0 ]] && ! grep -q "higgsfield" <<<"$(grep -i 'prereq\|✅\|❌' <<<"$SYNC_OUT")"; then ok; else bad "HIGGSFIELD_SYNC_SKIP_CHECK=1: check is skipped (rc=$SYNC_RC)"; fi

printf 'higgsfield sync-check tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
