#!/usr/bin/env bash
# idle-helper-stop: the Stop hook that keeps the lead from ending its turn while a finished
# (isActive == false) agent-teams helper is still alive (ENG-3103).
#
# Hermetic: temp HOME with fixture team files. Nothing here touches the real ~/.claude.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/system-configs/.claude/hooks/jev/idle-helper-stop.sh"

if ! command -v jq >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq is required" >&2
    exit 1
  fi
  echo "SKIP: jq missing" >&2
  exit 0
fi

T="$(mktemp -d /tmp/idle-helper-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude/teams"
unset BARECLAUDE_AGENT_SLUG CLAUDE_JOB_DIR JEV_RULES_FILE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2" >&2
}
eq() { [[ "$2" == "$3" ]] && ok || bad "$1" "expected [$3] got [$2]"; }
has() { printf '%s' "$2" | grep -qF -- "$3" && ok || bad "$1" "missing [$3] in [$2]"; }
hasnt() { printf '%s' "$2" | grep -qF -- "$3" && bad "$1" "unexpected [$3] in [$2]" || ok; }

SID="abcdef12-3456-7890-abcd-ef1234567890"
TEAM="$HOME/.claude/teams/session-abcdef12"
LEAD='{"agentId":"team-lead@session-abcdef12","name":"team-lead","agentType":"team-lead","tmuxPaneId":"leader"}'
helper() { # <name> <isActive>
  jq -nc --arg n "$1" --argjson a "$2" \
    '{agentId:($n + "@session-abcdef12"), name:$n, backendType:"tmux", tmuxPaneId:"%7", joinedAt:1, isActive:$a}'
}
team() { # <member json>... -> writes the fixture team file
  mkdir -p "$TEAM"
  printf '%s\n' "$@" | jq -s '{name:"session-abcdef12", leadSessionId:"abcdef12-3456-7890-abcd-ef1234567890", members:.}' >"$TEAM/config.json"
}
reset() { rm -f "$TEAM/config.json"; }
run() { # <stdin json> -> hook stdout (stderr kept apart)
  printf '%s' "$1" | bash "$HOOK" 2>"$T/stderr"
}
payload() { jq -nc --arg s "$SID" --argjson a "${1:-false}" '{hook_event_name:"Stop", session_id:$s, stop_hook_active:$a}'; }

# Core: a live idle helper blocks; with none, it passes.
team "$LEAD" "$(helper scout false)"
out=$(run "$(payload false)")
has "idle helper blocks" "$out" '"decision":"block"'
has "names the idle helper" "$out" "scout"
has "says TaskStop" "$out" "TaskStop"
has "offers the keep-with-reason route" "$out" "why"

team "$LEAD"
eq "lead only: no block" "$(run "$(payload false)")" ""

team "$LEAD" "$(helper scout false)" "$(helper builder true)"
out=$(run "$(payload false)")
has "mixed: blocks on the idle one" "$out" "scout"
hasnt "mixed: working helper not named" "$out" "builder"

team "$LEAD" "$(helper builder true)"
eq "working helper only: no block" "$(run "$(payload false)")" ""

team "$LEAD" "$(helper scout false)"
eq "stop_hook_active true: allowed" "$(run "$(payload true)")" ""

# Idle helper removed after TaskStop => nothing left to block on.
team "$LEAD"
eq "helper stopped (removed): passes" "$(run "$(payload false)")" ""

# Fail open.
reset
eq "missing team file: no block" "$(run "$(payload false)")" ""
mkdir -p "$TEAM"
printf '{not json' >"$TEAM/config.json"
eq "malformed JSON: no block" "$(run "$(payload false)")" ""
printf '{"members":null}' >"$TEAM/config.json"
eq "members null: no block" "$(run "$(payload false)")" ""
printf '{"name":"x"}' >"$TEAM/config.json"
eq "no members key: no block" "$(run "$(payload false)")" ""
printf '{"members":[]}' >"$TEAM/config.json"
eq "empty members: no block" "$(run "$(payload false)")" ""
team "$LEAD" "$(helper scout false)"
eq "no session id: no block" "$(run '{"hook_event_name":"Stop","stop_hook_active":false}')" ""
eq "empty stdin: no block" "$(run '')" ""
eq "garbage stdin: no block" "$(run 'zzz')" ""
eq "path-traversal session id: no block" \
  "$(run '{"hook_event_name":"Stop","session_id":"../../../x","stop_hook_active":false}')" ""

# Only the lead's own session file is read.
team "$LEAD"
OTHER="$HOME/.claude/teams/session-99999999"
mkdir -p "$OTHER"
jq -nc --argjson h "$(helper stranger false)" '{members:[$h]}' >"$OTHER/config.json"
eq "other session's idle helper ignored" "$(run "$(payload false)")" ""

# Scope/mode: a subagent's Stop and an off rule do not block.
team "$LEAD" "$(helper scout false)"
eq "subagent Stop: no block" \
  "$(run "$(jq -nc --arg s "$SID" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,agent_id:"a1"}')")" ""
printf '{"rules":{"idle-helper-stop":{"mode":"off"}}}' >"$T/rules.json"
export JEV_RULES_FILE="$T/rules.json"
eq "mode off: no block" "$(run "$(payload false)")" ""
printf '{"rules":{"idle-helper-stop":{"mode":"shadow"}}}' >"$T/rules.json"
eq "mode shadow: no block" "$(run "$(payload false)")" ""
unset JEV_RULES_FILE

# Clara is NOT exempt: the ticket came from her session.
team "$LEAD" "$(helper scout false)"
has "Clara session still blocks" "$(BARECLAUDE_AGENT_SLUG=clara run "$(payload false)")" '"decision":"block"'

# Exit code is always 0 (the block is the JSON decision, not a nonzero exit).
printf '%s' "$(payload false)" | bash "$HOOK" >/dev/null 2>&1
eq "exits 0 when blocking" "$?" "0"

printf 'Idle helper stop tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
