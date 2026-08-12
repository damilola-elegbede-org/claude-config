#!/usr/bin/env bash
# Assert that the PreToolUse guards in system-configs/.claude/settings.json
# actually block what they claim to block.
#
# These guards were silent no-ops until 2026-08: they read $CLAUDE_TOOL_INPUT
# and $CLAUDE_FILE_PATHS, which Claude Code does not populate. A hook reading
# the wrong input source matches nothing and exits 0, which is indistinguishable
# from a hook that ran and approved the call. Nothing caught it because nothing
# executed them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — hook guards require it and exit 0 without it"
  exit 0
fi

exec python3 "${REPO_ROOT}/scripts/test-hooks.py"
