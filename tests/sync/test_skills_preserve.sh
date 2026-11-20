#!/usr/bin/env bash
# Hermetic test: sync's skills mirror must not delete skills Claude Code keeps in ~/.claude/skills itself
# (synced/ = claude.ai-synced skills, .trash/ = removed skills). Runs into a temp HOME.
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

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-skills-preserve.XXXXXX")"
trap 'rm -rf "$T"' EXIT
HOME_DIR="$T/home"
mkdir -p "$HOME_DIR/.claude/skills/synced/x" "$HOME_DIR/.claude/skills/.trash/y" "$HOME_DIR/.claude/skills/stale-upstream-gone"
echo synced >"$HOME_DIR/.claude/skills/synced/x/SKILL.md"
echo trash >"$HOME_DIR/.claude/skills/.trash/y/SKILL.md"
echo stale >"$HOME_DIR/.claude/skills/stale-upstream-gone/SKILL.md"

SYNC_OUT=$(env HOME="$HOME_DIR" JEV_SYNC_SKIP_NPM=1 HIGGSFIELD_SYNC_SKIP_CHECK=1 bash "$REPO_ROOT/scripts/sync.sh" --force 2>&1)
SYNC_RC=$?

if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "sync succeeds (rc=$SYNC_RC): $(tail -3 <<<"$SYNC_OUT")"; fi
if [[ -f "$HOME_DIR/.claude/skills/synced/x/SKILL.md" ]]; then ok; else bad "skills/synced/x/SKILL.md survives a sync"; fi
if [[ -f "$HOME_DIR/.claude/skills/.trash/y/SKILL.md" ]]; then ok; else bad "skills/.trash/y/SKILL.md survives a sync"; fi
if [[ ! -e "$HOME_DIR/.claude/skills/stale-upstream-gone" ]]; then ok; else bad "a repo-less skill is still mirrored away"; fi
if [[ -f "$HOME_DIR/.claude/skills/commit/SKILL.md" ]]; then ok; else bad "repo skills are still synced"; fi

printf 'skills-preserve tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
