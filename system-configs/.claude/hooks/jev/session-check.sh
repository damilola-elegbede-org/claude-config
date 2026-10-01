#!/bin/bash
# SessionStart hook: warn when Jev checkpoints are degraded to regex-only, and
# pre-warm the Jev daemon when they are not.
#
# Why this exists: the gateway key lives in ~/.zshrc, so sessions that do not
# start from an interactive zsh (LaunchAgent, wrapper launcher, desktop app)
# can silently lack it. The client falls back to the regex verdict when Jev is
# unavailable, so without this line a missing key is invisible.
#
# Failure policy: never block or delay session start. Always exit 0.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

cat >/dev/null 2>&1 || true # SessionStart hooks get JSON on stdin; we do not need it

if ! command -v node >/dev/null 2>&1; then
  echo "Jev checkpoints degraded to regex: node not found, so jev-ask cannot run."
  exit 0
fi

reason=$(node "$DIR/client.mjs" --check 2>/dev/null)
case "$reason" in
  "") # healthy; start the daemon in the background so the first gate call is warm
    if [ -z "${JEV_MOCK:-}" ]; then
      (node "$DIR/client.mjs" --warm >/dev/null 2>&1 &)
    fi
    ;;
  no_key)
    echo "Jev checkpoints degraded to regex: no gateway key (export VERCEL_AI_GATEWAY_TOKEN in ~/.zshrc or set AI_GATEWAY_API_KEY)."
    ;;
  no_sdk)
    echo "Jev checkpoints degraded to regex: SDK not installed in ~/.claude/hooks/jev (run /sync, which runs npm ci)."
    ;;
  kill_switch)
    echo "Jev checkpoints degraded to regex: kill switch ~/.claude/jev.off is present."
    ;;
  *)
    echo "Jev checkpoints degraded to regex: unavailable ($reason)."
    ;;
esac
exit 0
