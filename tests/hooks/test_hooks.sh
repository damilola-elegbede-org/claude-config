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

# Every guard begins `command -v jq || exit 0`, so without jq they all fail open.
# Skipping here would hide exactly that state — the test for the disarmed guards
# would itself be disarmed. In CI this is a hard failure; locally it is a loud
# skip, because a developer without jq still needs the rest of the suite to run.
if ! command -v jq >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq is not installed. Every hook guard fails open without it." >&2
    exit 1
  fi
  echo "SKIP: jq not installed — hook guards fail open without it (would FAIL in CI)" >&2
  exit 0
fi

exec python3 "${REPO_ROOT}/scripts/test-hooks.py"
