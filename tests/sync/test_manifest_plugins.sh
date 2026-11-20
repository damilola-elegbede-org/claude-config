#!/usr/bin/env bash
# Hermetic test: a manifest station in settings "merge" mode installs exactly the manifest's sync.plugins
# (user scope, marketplaces registered from the repo settings.json). No sync.plugins key = no plugin install.
# A stub `claude` on PATH records every call; a real sync runs into a temp HOME. Nothing touches ~/.claude or the network.
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

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-manifest-plugins.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/stub"

# stub claude: empty inventories; records "plugin marketplace add" and "plugin install"; install fails when STUB_CLAUDE_FAIL=1
cat >"$T/stub/claude" <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB_CLAUDE_LOG"
case "$1 $2 $3" in
  "plugin marketplace list" | "plugin list --json"*) echo '[]' ;;
  "plugin install --scope") [ "${STUB_CLAUDE_FAIL:-0}" = 1 ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/stub/claude"

# sync.sh finds its manifest from its own location + the host name, so run a copy inside a temp repo layout.
# The repo's settings.json is replaced by a fixed one so the test does not depend on which marketplaces it declares.
STATION="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
mkdir -p "$T/repo/scripts" "$T/repo/sync-manifests"
cp "$REPO_ROOT/scripts/sync.sh" "$T/repo/scripts/sync.sh"
cp -R "$REPO_ROOT/system-configs" "$T/repo/system-configs"
cat >"$T/repo/system-configs/.claude/settings.json" <<'JSON'
{
  "model": "sonnet",
  "enabledPlugins": { "laptop-only@laptop-mkt": true },
  "extraKnownMarketplaces": {
    "docs-mkt": { "source": { "source": "github", "repo": "acme/docs-skills" }, "autoUpdate": true },
    "other-mkt": { "source": { "source": "github", "repo": "acme/other" }, "autoUpdate": true }
  }
}
JSON

run_sync() { # label manifest-json [claude-install-fails]
  local home="$T/home-$1"
  rm -rf "$home"
  mkdir -p "$home"
  : >"$T/claude-$1.log"
  printf '%s\n' "$2" >"$T/repo/sync-manifests/$STATION.json"
  SYNC_OUT=$(env HOME="$home" PATH="$T/stub:$PATH" STUB_CLAUDE_LOG="$T/claude-$1.log" STUB_CLAUDE_FAIL="${3:-0}" \
    JEV_SYNC_SKIP_NPM=1 HIGGSFIELD_SYNC_SKIP_CHECK=1 bash "$T/repo/scripts/sync.sh" --force 2>&1)
  SYNC_RC=$?
}

run_sync listed '{"mode":"scoped","sync":{"settings":"merge","settings_owned_keys":["model"],"plugins":["a@docs-mkt","b@docs-mkt"]}}'
LOG="$T/claude-listed.log"
if [[ "$SYNC_RC" -eq 0 ]]; then ok; else bad "listed: sync succeeds (rc=$SYNC_RC): $(tail -3 <<<"$SYNC_OUT")"; fi
if grep -qx "plugin install --scope user a@docs-mkt" "$LOG" && grep -qx "plugin install --scope user b@docs-mkt" "$LOG"; then ok; else bad "listed: both manifest plugins installed at user scope (log: $(tr '\n' '|' <"$LOG"))"; fi
if [[ "$(grep -c '^plugin install' "$LOG")" -eq 2 ]]; then ok; else bad "listed: exactly the manifest list is installed (not enabledPlugins)"; fi
if grep -qx "plugin marketplace add acme/docs-skills" "$LOG"; then ok; else bad "listed: marketplace registered from the repo settings.json"; fi

run_sync failing '{"mode":"scoped","sync":{"settings":"merge","settings_owned_keys":["model"],"plugins":["a@docs-mkt"]}}' 1
if [[ "$SYNC_RC" -eq 0 ]] && grep -q "plugin install failed: a@docs-mkt" <<<"$SYNC_OUT"; then ok; else bad "failing install: warns and the sync still succeeds (rc=$SYNC_RC)"; fi

run_sync none '{"mode":"scoped","sync":{"settings":"merge","settings_owned_keys":["model"]}}'
if [[ "$SYNC_RC" -eq 0 ]] && [[ ! -s "$T/claude-none.log" ]]; then ok; else bad "no sync.plugins key: claude is never called (rc=$SYNC_RC, log: $(tr '\n' '|' <"$T/claude-none.log"))"; fi

printf 'manifest-plugins tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
