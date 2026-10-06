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

SESSION_INPUT=$(cat 2>/dev/null || true) # SessionStart hooks get JSON on stdin; only session_id is used

# Deployed-hook drift: count hook files under ~/.claude/hooks whose content differs from the claude-config
# clone's origin/main copy (whatever the clone last fetched; never fetches). Prints one line when any differ.
# Files absent from the deployed side are not counted. JEV_DRIFT_REPO / JEV_DRIFT_HOOKS override the paths.
# Silent on any error; the caller bounds it with a timeout.
drift_count() {
  local repo="${JEV_DRIFT_REPO:-$HOME/repos/claude-config}"
  local hooks="${JEV_DRIFT_HOOKS:-$HOME/.claude/hooks}"
  local base=system-configs/.claude/hooks sha path n=0 line
  local -a shas=() paths=() sums=()
  [ -d "$repo" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r line path; do
    case "$path" in */node_modules/* | *jev.sock | *.sock) continue ;; esac
    [ -f "$hooks/${path#"$base"/}" ] || continue
    shas+=("${line##* }")
    paths+=("$hooks/${path#"$base"/}")
  done < <(git -C "$repo" ls-tree -r origin/main -- "$base/gate.sh" "$base/gate-rules.json" "$base/jev-gate.sh" "$base/jev-gate-lib.sh" "$base/jev" 2>/dev/null)
  [ "${#paths[@]}" -gt 0 ] || return 0
  while IFS= read -r sha; do sums+=("$sha"); done < <(git hash-object --no-filters -- "${paths[@]}" 2>/dev/null)
  [ "${#sums[@]}" -eq "${#shas[@]}" ] || return 0
  local i
  for i in "${!shas[@]}"; do
    [ "${shas[$i]}" = "${sums[$i]}" ] || n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "Deployed hooks differ from claude-config origin/main in $n file(s): run /sync."
  return 0
}

drift_warn_once() {
  local sid marker out wd pid
  sid=$(printf '%s' "$SESSION_INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9_-' '_')
  marker=""
  if [ -n "$sid" ]; then
    marker="$HOME/.claude/jev/state/drift-$sid"
    [ -e "$marker" ] && return 0
  fi
  out=$(mktemp 2>/dev/null) || return 0
  drift_count >"$out" 2>/dev/null &
  pid=$!
  (
    sleep 3
    kill "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null
  kill "$wd" 2>/dev/null
  if [ -s "$out" ]; then
    cat "$out"
    if [ -n "$marker" ]; then
      mkdir -p "$(dirname "$marker")" 2>/dev/null && : >"$marker" 2>/dev/null
    fi
  fi
  rm -f "$out"
  return 0
}
drift_warn_once 2>/dev/null || true

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
