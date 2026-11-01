#!/usr/bin/env bash
# /interview run mode: gate.sh interview-contract and the interview-stop Stop hook.
#
# Hermetic: temp HOME, transcripts built here, JEV_MOCK for the judge. Nothing reaches the Gateway or the
# real ~/.claude. The grant path through jev-gate.sh is covered in test_jev_gates.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$REPO_ROOT/system-configs/.claude/hooks"

if ! command -v jq >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq is required" >&2
    exit 1
  fi
  echo "SKIP: jq missing" >&2
  exit 0
fi

T="$(mktemp -d /tmp/interview-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude"
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

Q=$'UNDERSTANDING PLAYBACK — demo\n\nGoal: ship\nGrants: G4-prod-infra, G6-spend, G8-sharing\nDone when: PR is mergeable\n\nAsk: Did I get all of it?'

# transcript <answer> [timestamp] [question]: one playback and its structured answer.
transcript() {
  local ts="${2:-$(date -u +%FT%TZ)}" q="${3:-$Q}"
  jq -nc --arg q "$q" --arg ts "$ts" \
    '{type:"assistant", timestamp:$ts, message:{content:[{type:"tool_use", id:"ask_1", name:"AskUserQuestion", input:{questions:[{question:$q}]}}]}}'
  if [[ -n "$1" ]]; then
    jq -nc --arg q "$q" --arg a "$1" \
      '{type:"user", toolUseResult:{answers:{($q):$a}}, message:{content:[{type:"tool_result", tool_use_id:"ask_1", content:"ok"}]}}'
  fi
}

contract() { bash "$HOOKS/gate.sh" interview-contract "$1" 2>/dev/null; }

transcript "Confirmed (Recommended)" >"$T/yes.jsonl"
OUT=$(contract "$T/yes.jsonl")
eq "contract: criteria parsed" "$(jq -r '.criteria' <<<"$OUT")" "PR is mergeable"
eq "contract: spend is dropped from grants" "$(jq -c '.grants' <<<"$OUT")" '["G4-prod-infra","G8-sharing"]'

transcript "Fix something" >"$T/no.jsonl"
eq "contract: a correction grants nothing" "$(contract "$T/no.jsonl")" ""
transcript "" >"$T/pending.jsonl"
eq "contract: an unanswered playback grants nothing" "$(contract "$T/pending.jsonl")" ""
transcript "Confirmed" "2020-01-01T00:00:00Z" >"$T/old.jsonl"
eq "contract: expires" "$(contract "$T/old.jsonl")" ""
transcript "Confirmed" "" $'UNDERSTANDING PLAYBACK\nGrants: G4-prod-infra' >"$T/nocrit.jsonl"
eq "contract: needs done criteria" "$(contract "$T/nocrit.jsonl")" ""
eq "contract: fleet agents get none" "$(BARECLAUDE_AGENT_SLUG=x contract "$T/yes.jsonl")" ""
{
  transcript "Confirmed"
  transcript "Fix something"
} >"$T/latest.jsonl"
eq "contract: the latest playback wins" "$(contract "$T/latest.jsonl")" ""

stop() { # transcript message [session] [agent]
  jq -nc --arg t "$1" --arg m "$2" --arg s "${3:-s1}" --arg a "${4:-}" \
    '{hook_event_name:"Stop", transcript_path:$t, last_assistant_message:$m, session_id:$s, stop_hook_active:true}
     + (if $a != "" then {agent_id:$a} else {} end)' |
    bash "$HOOKS/jev/interview-stop.sh" 2>/dev/null
}
fresh() { rm -rf "$HOME/.claude/interview-closed" "$HOME/.claude/jev"; }

export JEV_MOCK="$T/mock.json"
echo '{"answers":{"done":{"type":"boolean","probability":0.9}}}' >"$T/mock.json"

fresh
eq "stop: no contract, no block" "$(stop "$T/no.jsonl" "all done")" ""
has "stop: blocks without an end line" "$(stop "$T/yes.jsonl" "still going")" '"decision":"block"'
eq "stop: subagent is ignored" "$(stop "$T/yes.jsonl" "x" s1 agent1)" ""
eq "stop: needs input hands back" "$(stop "$T/yes.jsonl" $'text\nneeds input: merge')" ""
eq "stop: failed hands back" "$(stop "$T/yes.jsonl" 'failed: premise false')" ""
contract "$T/yes.jsonl" >/dev/null || bad "stop: a hand-back keeps the contract"

eq "stop: result meeting criteria releases" "$(stop "$T/yes.jsonl" 'result: PR is mergeable')" ""
eq "stop: release closes the contract" "$(contract "$T/yes.jsonl")" ""
eq "stop: closed contract stops blocking" "$(stop "$T/yes.jsonl" "chat")" ""

fresh
echo '{"answers":{"done":{"type":"boolean","probability":0.1}}}' >"$T/mock.json"
has "stop: unmet result keeps working" "$(stop "$T/yes.jsonl" 'result: half done' s2)" '"decision":"block"'

fresh
JEV_MOCK=unavailable
eq "stop: Jev down fails open" "$(stop "$T/yes.jsonl" 'result: done' s3)" ""
JEV_MOCK="$T/mock.json"

fresh
for _ in 1 2 3 4 5 6 7 8; do
  has "stop: blocks up to the cap" "$(stop "$T/yes.jsonl" "going" s4)" '"decision":"block"'
done
has "stop: gives up at the cap and says so" "$(stop "$T/yes.jsonl" "going" s4)" 'gave up after 8 blocks'
eq "stop: the cap closes the contract" "$(stop "$T/yes.jsonl" "going" s4)" ""

fresh
eq "stop: fleet is out of scope" "$(BARECLAUDE_AGENT_SLUG=x stop "$T/yes.jsonl" "going")" ""

printf 'Interview run tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
