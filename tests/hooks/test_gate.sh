#!/bin/bash
# Tests for the decision-gate PreToolUse runner (system-configs/.claude/hooks/gate.sh)
# and its rules registry (gate-rules.json).
#
# Everything runs against a throwaway HOME so nothing touches the real ~/.claude.
# Fixtures live in gate-fixtures.jsonl: one JSON object per line,
#   {"rule": <rule id>, "expect": "deny"|"allow", "tool": ..., "input": {...}, "env": {...}}
# "deny" asserts the CHECKPOINT reason names exactly that rule; "allow" asserts the
# gate prints nothing at all (no rule denies it). @HOME@ @TMPDIR@ @JOBDIR@ are
# substituted with the sandbox paths.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_SRC="$REPO_ROOT/system-configs/.claude/hooks"
FIXTURES="$(dirname "${BASH_SOURCE[0]}")/gate-fixtures.jsonl"

if ! command -v jq >/dev/null 2>&1; then
    if [[ -n "${CI:-}" ]]; then
        echo "FAIL: jq is not installed. gate.sh fails open without it." >&2
        exit 1
    fi
    echo "SKIP: jq not installed - gate.sh fails open without it (would FAIL in CI)" >&2
    exit 0
fi

# A background job or fleet agent running this suite must not leak its own scope
# into the sandboxed runs.
unset CLAUDE_JOB_DIR BARECLAUDE_AGENT_SLUG

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); }
fail() {
    FAIL=$((FAIL + 1))
    FAILURES+=("$1")
    echo "  FAIL  $1"
}
check() { # check <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then pass; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() { # check_contains <description> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then pass; else fail "$1 (missing '$3' in: ${2:0:200})"; fi
}
check_absent() { # check_absent <description> <haystack> <needle>
    if [[ "$2" != *"$3"* ]]; then pass; else fail "$1 (unexpected '$3')"; fi
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# make_home <name> [jq filter applied to the rules]: a HOME with the hook deployed
# the way sync deploys it (~/.claude/hooks/gate.sh next to gate-rules.json).
make_home() {
    local h="$SANDBOX/$1"
    mkdir -p "$h/.claude/hooks" "$h/tmp"
    cp "$HOOKS_SRC/gate.sh" "$h/.claude/hooks/gate.sh"
    chmod +x "$h/.claude/hooks/gate.sh"
    if [[ -n "${2:-}" ]]; then
        jq "$2" "$HOOKS_SRC/gate-rules.json" >"$h/.claude/hooks/gate-rules.json"
    else
        cp "$HOOKS_SRC/gate-rules.json" "$h/.claude/hooks/gate-rules.json"
    fi
    echo "$h"
}

# run_gate <home> <payload-json> [NAME=value ...]  -> GOUT (stdout), GRC, GERR (stderr)
run_gate() {
    local h="$1" payload="$2"
    shift 2
    GOUT=$(printf '%s' "$payload" | env -u BARECLAUDE_AGENT_SLUG -u CLAUDE_JOB_DIR \
        HOME="$h" TMPDIR="$h/tmp" "$@" bash "$h/.claude/hooks/gate.sh" 2>"$SANDBOX/stderr")
    GRC=$?
    GERR=$(cat "$SANDBOX/stderr")
}

# GATE_TP (the session transcript) and GATE_CWD ride along in every payload, like Claude Code sends them.
GATE_TP=""
GATE_CWD="/work"
payload() { # payload <tool> <input-json>
    jq -nc --arg t "$1" --argjson i "$2" --arg tp "$GATE_TP" --arg cwd "$GATE_CWD" \
        '{tool_name:$t,tool_input:$i,cwd:$cwd} + (if $tp != "" then {transcript_path:$tp,session_id:"sess-1"} else {} end)'
}
write_payload() { payload Write "$(jq -nc --arg p "$1" --arg c "$2" '{file_path:$p,content:$c}')"; }
bash_payload() { payload Bash "$(jq -nc --arg c "$1" '{command:$c}')"; }
# mk_ask <transcript> <tool_use id> <offset-secs-from-now> <answer|NONE>: append an AskUserQuestion and (unless
# NONE) its answered tool_result, in the shape Claude Code writes (toolUseResult.answers).
mk_ask() {
    local ts=$(($(date +%s) + $3))
    jq -nc --arg id "$2" --argjson e "$ts" \
        '{type:"assistant",timestamp:($e|todate),message:{content:[{type:"tool_use",id:$id,name:"AskUserQuestion",input:{questions:[{question:"Approve this action?"}]}}]}}' >>"$1"
    if [[ "$4" != "NONE" ]]; then
        jq -nc --arg id "$2" --arg a "$4" --argjson e "$((ts + 1))" \
            '{type:"user",timestamp:($e|todate),toolUseResult:{answers:{"Approve this action?":$a}},message:{content:[{type:"tool_result",tool_use_id:$id,content:("User has answered your questions: \"Approve this action?\"=\"" + $a + "\".")}]}}' >>"$1"
    fi
}
# deny_hash <home> <payload>: run the gate (expected to deny) and print the approval hash.
deny_hash() { run_gate "$1" "$2"; hash_from_reason; }
# approve_rc <home> <hash>: run `gate.sh approve`, sets AOUT, returns its exit code.
approve_rc() { AOUT=$(HOME="$1" bash "$1/.claude/hooks/gate.sh" approve "$2" 2>&1); return $?; }
reason() { printf '%s' "$GOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
decision() { printf '%s' "$GOUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
hash_from_reason() { reason | sed -n 's/.*gate\.sh approve \([0-9a-f]\{64\}\).*/\1/p'; }

H=$(make_home main)
RULES="$HOOKS_SRC/gate-rules.json"

echo "== registry sanity =="
if jq -e . "$RULES" >/dev/null 2>&1; then pass; else fail "gate-rules.json is not valid JSON"; fi
check "rule ids are unique" "0" "$(jq '[.rules[].id] | length - (unique | length)' "$RULES")"
check "every rule has the required fields" "0" "$(jq '[.rules[] | select((.id and .class and .tools and .message and (.action == "deny") and (.scope | type == "array") and (.lanes | type == "object") and (.enforce | type == "boolean")) | not)] | length' "$RULES")"
check "exempt agents come from the rules file" "dara,clara" "$(jq -r '.exempt_agents | join(",")' "$RULES")"
if grep -qiE 'dara|clara' "$HOOKS_SRC/gate.sh"; then fail "gate.sh must not hard-code agent names"; else pass; fi
if [[ -x "$HOOKS_SRC/gate.sh" ]]; then pass; else fail "gate.sh is not executable"; fi

echo "== fixtures (table-driven) =="
FIXTURE_COUNT=0
while IFS= read -r rule && IFS= read -r expect && IFS= read -r envj && IFS= read -r pl; do
    FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
    pl=${pl//@HOME@/$H}
    pl=${pl//@TMPDIR@/$H/tmp}
    pl=${pl//@JOBDIR@/$H/job}
    envj=${envj//@HOME@/$H}
    envj=${envj//@JOBDIR@/$H/job}
    envargs=()
    while IFS= read -r kv; do
        [[ -n "$kv" ]] && envargs+=("$kv")
    done < <(printf '%s' "$envj" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    run_gate "$H" "$pl" "${envargs[@]}"
    label="[$rule/$expect] $(printf '%s' "$pl" | jq -r '.tool_input | (.command // .file_path // .action // "") | .[0:70]') ($(printf '%s' "$pl" | jq -r .tool_name))"
    if [[ "$expect" == "deny" ]]; then
        if [[ $GRC -eq 0 && "$(decision)" == "deny" && "$(reason)" == "CHECKPOINT $rule:"* ]]; then
            pass
        else
            fail "$label expected deny by $rule, got rc=$GRC out=${GOUT:0:160}"
        fi
    else
        if [[ $GRC -eq 0 && -z "$GOUT" ]]; then pass; else fail "$label expected allow, got rc=$GRC out=${GOUT:0:200}"; fi
    fi
    if [[ -n "$GERR" ]]; then fail "$label unexpected stderr (rule evaluation error?): ${GERR:0:200}"; fi
done < <(jq -r '.rule, .expect, ((.env // {}) | tojson), ({tool_name: .tool, tool_input: .input, cwd: "/work"} | tojson)' "$FIXTURES")
echo "  $FIXTURE_COUNT fixtures run"

echo "== fixture coverage: >=2 deny and >=2 allow per enforced rule =="
while IFS= read -r rid; do
    d=$(jq -s --arg r "$rid" '[.[] | select(.rule == $r and .expect == "deny")] | length' "$FIXTURES")
    a=$(jq -s --arg r "$rid" '[.[] | select(.rule == $r and .expect == "allow")] | length' "$FIXTURES")
    if [[ "$d" -ge 2 && "$a" -ge 2 ]]; then pass; else fail "rule $rid has $d deny / $a allow fixtures (need >=2 each)"; fi
done < <(jq -r '.rules[] | select(.enforce) | .id' "$RULES")
check "no fixture names an unknown rule" "0" "$(jq -s --slurpfile r "$RULES" '[.[] | .rule as $x | select($x != "general" and ([$r[0].rules[].id] | any(. == $x) | not))] | length' "$FIXTURES")"

echo "== deny output shape and wording =="
run_gate "$H" "$(bash_payload 'rm -rf foo')"
check "interactive: exit code" "0" "$GRC"
check "interactive: permissionDecision" "deny" "$(decision)"
check "interactive: hookEventName" "PreToolUse" "$(printf '%s' "$GOUT" | jq -r '.hookSpecificOutput.hookEventName')"
check_contains "interactive: asks D" "$(reason)" "Put this action to D via AskUserQuestion"
check_contains "interactive: retry wording" "$(reason)" "retry with the exact same command"
# shellcheck disable=SC2088 # the literal tilde is the text Claude is told to run
check_contains "interactive: approve command" "$(reason)" "~/.claude/hooks/gate.sh approve "
check_absent "interactive: no needs-input wording" "$(reason)" "needs input:"

run_gate "$H" "$(bash_payload 'rm -rf foo')" CLAUDE_JOB_DIR="$H/job"
check "bg job: permissionDecision" "deny" "$(decision)"
check_contains "bg job: needs input" "$(reason)" "end your report with \`needs input:\`"
check_contains "bg job: do not retry" "$(reason)" "Do not retry"
check_absent "bg job: no AskUserQuestion" "$(reason)" "AskUserQuestion"
check_absent "bg job: no approve command" "$(reason)" "gate.sh approve"

echo "== fleet: exempt agents (dara, clara never blocked) =="
H_EX=$(make_home exempt)
run_gate "$H_EX" "$(bash_payload 'gh pr merge 12 --squash')" BARECLAUDE_AGENT_SLUG=dara
check "dara + gh pr merge allowed" "" "$GOUT"
run_gate "$H_EX" "$(payload mcp__claude_ai_Gmail__send_message '{"to":"d@example.com"}')" BARECLAUDE_AGENT_SLUG=clara
check "clara + Gmail send allowed" "" "$GOUT"
run_gate "$H_EX" "$(bash_payload 'rm -rf /srv/data')" BARECLAUDE_AGENT_SLUG=clara
check "clara + rm -rf allowed (exempt)" "" "$GOUT"
check_contains "clara rm -rf is still logged as exempt" "$(cat "$H_EX/.claude/gate-log.jsonl")" '"rule":"G1-rm","tool":"Bash","decision":"allow-exempt-agent","scope":"fleet"'
run_gate "$H_EX" "$(bash_payload 'git push origin main')" BARECLAUDE_AGENT_SLUG=dara
check "dara + push to main allowed (exempt, whole gate)" "" "$GOUT"
run_gate "$H_EX" "$(bash_payload 'gh pr merge 12 --squash')" BARECLAUDE_AGENT_SLUG=tars
check "tars + gh pr merge denied" "deny" "$(decision)"
check_contains "tars: needs input wording" "$(reason)" "needs input:"
run_gate "$H_EX" "$(payload mcp__claude_ai_Gmail__send_message '{"to":"a@b.c"}')" BARECLAUDE_AGENT_SLUG=tars
check "tars + Gmail send denied (no lane)" "deny" "$(decision)"
run_gate "$H_EX" "$(bash_payload 'ls -la')" BARECLAUDE_AGENT_SLUG=tars
check "tars + harmless command allowed" "" "$GOUT"

echo "== fleet: lanes mechanism (exempt list emptied to exercise it) =="
H_LANE=$(make_home lanes '.exempt_agents = []')
run_gate "$H_LANE" "$(bash_payload 'gh pr merge 12')" BARECLAUDE_AGENT_SLUG=dara
check "lane: dara + gh pr merge allowed" "" "$GOUT"
check_contains "lane: logged as allow-by-lane" "$(cat "$H_LANE/.claude/gate-log.jsonl")" '"decision":"allow-by-lane"'
run_gate "$H_LANE" "$(bash_payload 'gh pr merge 12')" BARECLAUDE_AGENT_SLUG=clara
check "lane: clara + gh pr merge denied" "deny" "$(decision)"
run_gate "$H_LANE" "$(payload mcp__claude_ai_Gmail__send_message '{}')" BARECLAUDE_AGENT_SLUG=clara
check "lane: clara + Gmail send allowed" "" "$GOUT"
run_gate "$H_LANE" "$(payload mcp__claude_ai_Gmail__send_message '{}')" BARECLAUDE_AGENT_SLUG=dara
check "lane: dara + Gmail send denied" "deny" "$(decision)"
run_gate "$H_LANE" "$(bash_payload 'rm -rf /srv/data')" BARECLAUDE_AGENT_SLUG=clara
check "lane: clara + rm -rf denied (no lane)" "deny" "$(decision)"
run_gate "$H_LANE" "$(bash_payload 'gh pr merge 12')" BARECLAUDE_AGENT_SLUG=dara CLAUDE_JOB_DIR="$H_LANE/job"
check "lane: still applies for a fleet bg job" "" "$GOUT"

echo "== per-rule enforce and scope =="
H_SHADOW=$(make_home shadow '(.rules[] | select(.id == "G1-rm") | .enforce) = false')
run_gate "$H_SHADOW" "$(bash_payload 'rm -rf foo')"
check "enforce=false does not deny" "" "$GOUT"
check_contains "enforce=false is logged as shadow" "$(cat "$H_SHADOW/.claude/gate-log.jsonl")" '"decision":"shadow"'
H_SCOPE=$(make_home scope '(.rules[] | select(.id == "G1-rm") | .scope) = ["interactive"]')
run_gate "$H_SCOPE" "$(bash_payload 'rm -rf foo')"
check "scope=interactive denies interactive" "deny" "$(decision)"
run_gate "$H_SCOPE" "$(bash_payload 'rm -rf foo')" CLAUDE_JOB_DIR="$H_SCOPE/job"
check "scope=interactive skips bg jobs" "" "$GOUT"

echo "== kill switch =="
H_KS=$(make_home killswitch)
run_gate "$H_KS" "$(bash_payload 'rm -rf foo')"
check "before kill switch: denied" "deny" "$(decision)"
touch "$H_KS/.claude/gate.off"
run_gate "$H_KS" "$(bash_payload 'rm -rf foo')"
check "kill switch: allowed" "" "$GOUT"
check "kill switch: exit 0" "0" "$GRC"
rm -f "$H_KS/.claude/gate.off"
run_gate "$H_KS" "$(bash_payload 'rm -rf foo')"
check "kill switch removed: denied again" "deny" "$(decision)"
mkdir "$H_KS/.claude/gate.off"
run_gate "$H_KS" "$(bash_payload 'rm -rf foo')"
check "kill switch: a DIRECTORY named gate.off does not disable the gate" "deny" "$(decision)"
rmdir "$H_KS/.claude/gate.off"
touch "$H_KS/.claude/real-target"
ln -s "$H_KS/.claude/real-target" "$H_KS/.claude/gate.off"
run_gate "$H_KS" "$(bash_payload 'rm -rf foo')"
check "kill switch: a SYMLINK named gate.off does not disable the gate" "deny" "$(decision)"
rm -f "$H_KS/.claude/gate.off"

echo "== one-shot approval =="
H_AP=$(make_home approval)
TX_AP="$SANDBOX/tx-approval.jsonl"
: >"$TX_AP"
GATE_TP="$TX_AP"
P=$(bash_payload 'rm -rf foo')
run_gate "$H_AP" "$P"
HASH=$(hash_from_reason)
check "approval: 64-hex hash is in the reason" "64" "${#HASH}"
if [[ -f "$H_AP/.claude/gate-pending/$HASH" ]]; then pass; else fail "approval: pending file written"; fi
check "approval: pending records the transcript path" "$TX_AP" "$(jq -r .transcript_path "$H_AP/.claude/gate-pending/$HASH")"
check "approval: pending records the session id" "sess-1" "$(jq -r .session_id "$H_AP/.claude/gate-pending/$HASH")"
check "approval: pending records cwd" "/work" "$(jq -r .cwd "$H_AP/.claude/gate-pending/$HASH")"
run_gate "$H_AP" "$P"
check "approval: unapproved retry still denied" "deny" "$(decision)"
check "approval: same action hashes the same" "$HASH" "$(hash_from_reason)"
# D never answered: approve must refuse.
approve_rc "$H_AP" "$HASH"
check "approval: refused when no AskUserQuestion happened" "1" "$?"
check_contains "approval: refusal says what is missing" "$AOUT" "no AskUserQuestion answered"
if [[ -f "$H_AP/.claude/gate-pending/$HASH" && ! -e "$H_AP/.claude/gate-approved/$HASH" ]]; then pass; else fail "approval: a refused approve leaves the pending file alone"; fi
mk_ask "$TX_AP" ask-old -120 Approve
approve_rc "$H_AP" "$HASH"
check "approval: an AskUserQuestion from BEFORE the deny does not count" "1" "$?"
mk_ask "$TX_AP" ask-nores 2 NONE
approve_rc "$H_AP" "$HASH"
check "approval: a question with no answer (dismissed) does not count" "1" "$?"
mk_ask "$TX_AP" ask-deny 3 "Deny"
approve_rc "$H_AP" "$HASH"
check "approval: a Deny answer does not count" "1" "$?"
mk_ask "$TX_AP" ask-no 4 "No, do not run it"
approve_rc "$H_AP" "$HASH"
check "approval: a No answer does not count" "1" "$?"
mk_ask "$TX_AP" ask-yes 5 "Approve"
approve_rc "$H_AP" "$HASH"
check "approval: approve exits 0 after a real Approve" "0" "$?"
check_contains "approval: approve says approved" "$AOUT" "approved"
check_contains "approval: the spent question is recorded" "$(cat "$H_AP/.claude/gate-asks-used")" "ask-yes"
if [[ -f "$H_AP/.claude/gate-approved/$HASH" && ! -f "$H_AP/.claude/gate-pending/$HASH" ]]; then pass; else fail "approval: pending moved to approved"; fi
run_gate "$H_AP" "$(bash_payload 'rm -rf bar')"
check "approval: a different command is not approved" "deny" "$(decision)"
run_gate "$H_AP" "$P"
check "approval: retry after approve is allowed" "" "$GOUT"
if [[ ! -e "$H_AP/.claude/gate-approved/$HASH" ]]; then pass; else fail "approval: consumed after one use"; fi
check_contains "approval: logged" "$(cat "$H_AP/.claude/gate-log.jsonl")" '"decision":"allow-by-approval"'
run_gate "$H_AP" "$P"
check "approval: second retry denied again (single use)" "deny" "$(decision)"

echo "== approval: one question approves one action =="
H_ONE=$(make_home onequestion)
TX_ONE="$SANDBOX/tx-one.jsonl"
: >"$TX_ONE"
GATE_TP="$TX_ONE"
H1=$(deny_hash "$H_ONE" "$(bash_payload 'rm -rf one')")
H2=$(deny_hash "$H_ONE" "$(bash_payload 'rm -rf two')")
mk_ask "$TX_ONE" ask-a 2 "Approve"
approve_rc "$H_ONE" "$H1"
check "one question: first approve works" "0" "$?"
approve_rc "$H_ONE" "$H2"
check "one question: the same question cannot approve a second action" "1" "$?"
mk_ask "$TX_ONE" ask-b 3 "Approve"
approve_rc "$H_ONE" "$H2"
check "one question: a second question approves the second action" "0" "$?"

echo "== approval: bound to the action, cwd and scope =="
H_BIND=$(make_home binding)
TX_B="$SANDBOX/tx-bind.jsonl"
: >"$TX_B"
GATE_TP="$TX_B"
GATE_CWD="/work/a"
HB=$(deny_hash "$H_BIND" "$(bash_payload 'rm -rf foo')")
mk_ask "$TX_B" ask-c 2 "Approve"
approve_rc "$H_BIND" "$HB"
GATE_CWD="/work/b"
run_gate "$H_BIND" "$(bash_payload 'rm -rf foo')"
check "binding: the same command in another cwd is NOT approved" "deny" "$(decision)"
check "binding: another cwd is a different action" "1" "$([[ "$(hash_from_reason)" == "$HB" ]] && echo 0 || echo 1)"
GATE_CWD="/work/a"
run_gate "$H_BIND" "$(bash_payload 'rm -rf foo')"
check "binding: the approved cwd still works" "" "$GOUT"
# Write/Edit: the written content is part of the identity.
HW=$(deny_hash "$H_BIND" "$(write_payload "$H_BIND/.claude/hooks/x.sh" "echo A")")
mk_ask "$TX_B" ask-d 4 "Approve"
approve_rc "$H_BIND" "$HW"
run_gate "$H_BIND" "$(write_payload "$H_BIND/.claude/hooks/x.sh" "echo EVIL")"
check "binding: different Write content is NOT approved" "deny" "$(decision)"
run_gate "$H_BIND" "$(write_payload "$H_BIND/.claude/hooks/x.sh" "echo A")"
check "binding: the approved Write content is allowed" "" "$GOUT"
GATE_CWD="/work"

echo "== approval: one approval per action when several rules match =="
H_MR=$(make_home multirule)
TX_MR="$SANDBOX/tx-mr.jsonl"
: >"$TX_MR"
GATE_TP="$TX_MR"
MR_CMD='sudo rm -rf foo'
run_gate "$H_MR" "$(bash_payload "$MR_CMD")"
HM=$(hash_from_reason)
check_contains "multi-rule: the reason names the first rule" "$(reason)" "CHECKPOINT G1-rm:"
check_contains "multi-rule: the reason names the other matched rule" "$(reason)" "Also matched "
check "multi-rule: ONE pending file for the action" "1" "$(find "$H_MR/.claude/gate-pending" -type f | wc -l | tr -d ' ')"
check "multi-rule: the pending file lists every rule" "true" "$(jq '.rules | length >= 2' "$H_MR/.claude/gate-pending/$HM")"
mk_ask "$TX_MR" ask-m 2 "Approve"
approve_rc "$H_MR" "$HM"
check "multi-rule: a single approve succeeds" "0" "$?"
run_gate "$H_MR" "$(bash_payload "$MR_CMD")"
check "multi-rule: one approval clears all matched rules (no deadlock)" "" "$GOUT"

echo "== approval: single use under concurrency =="
H_CC=$(make_home concurrent)
TX_CC="$SANDBOX/tx-cc.jsonl"
: >"$TX_CC"
GATE_TP="$TX_CC"
CCP=$(bash_payload 'rm -rf foo')
HC=$(deny_hash "$H_CC" "$CCP")
mk_ask "$TX_CC" ask-cc 2 "Approve"
approve_rc "$H_CC" "$HC"
rm -f "$SANDBOX"/cc-out.*
for n in 1 2 3 4 5 6; do
    (printf '%s' "$CCP" | env -u BARECLAUDE_AGENT_SLUG -u CLAUDE_JOB_DIR HOME="$H_CC" TMPDIR="$H_CC/tmp" bash "$H_CC/.claude/hooks/gate.sh" >"$SANDBOX/cc-out.$n" 2>/dev/null) &
done
wait
ALLOWED=0
for n in 1 2 3 4 5 6; do
    [[ -s "$SANDBOX/cc-out.$n" ]] || ALLOWED=$((ALLOWED + 1))
done
check "concurrency: exactly one of six identical calls consumed the approval" "1" "$ALLOWED"
GATE_TP=""

echo "== approve command hardening =="
approve() { HOME="$H_AP" env "$@" bash "$H_AP/.claude/hooks/gate.sh" approve "$APPROVE_ARG" >/dev/null 2>&1; }
APPROVE_ARG="../../etc/passwd"; approve; check "approve: path traversal rejected" "1" "$?"
APPROVE_ARG="abc"; approve; check "approve: short hash rejected" "1" "$?"
APPROVE_ARG="$(printf '0%.0s' $(seq 1 64))"; approve; check "approve: unknown hash rejected" "1" "$?"
run_gate "$H_AP" "$P"
APPROVE_ARG=$(hash_from_reason); approve CLAUDE_JOB_DIR=/x/job; check "approve: refused inside a bg job" "1" "$?"
approve BARECLAUDE_AGENT_SLUG=tars; check "approve: refused for fleet agents" "1" "$?"
# shellcheck disable=SC2088 # the literal tilde form must be accepted by the gate
run_gate "$H_AP" "$(bash_payload "~/.claude/hooks/gate.sh approve $APPROVE_ARG")"
check "approve: the approve command itself is not gated" "" "$GOUT"
run_gate "$H_AP" "$(bash_payload "$H_AP/.claude/hooks/gate.sh approve $APPROVE_ARG")"
check "approve: absolute-path form is not gated" "" "$GOUT"
run_gate "$H_AP" "$(bash_payload "cp x ~/.claude/gate-approved/$APPROVE_ARG")"
check "approve: forging an approval by hand is denied" "deny" "$(decision)"
run_gate "$H_AP" "$(write_payload "$H_AP/.claude/gate-approved/$APPROVE_ARG" "")"
check "approve: forging via Write is denied" "deny" "$(decision)"

echo "== approval expiry =="
H_EXP=$(make_home expiry)
TX_EXP="$SANDBOX/tx-exp.jsonl"
: >"$TX_EXP"
GATE_TP="$TX_EXP"
EXP_P=$(bash_payload 'rm -rf foo')
run_gate "$H_EXP" "$EXP_P"
HASH=$(hash_from_reason)
mk_ask "$TX_EXP" ask-e1 2 "Approve"
approve_rc "$H_EXP" "$HASH"
check "expiry: approve succeeds while fresh" "0" "$?"
touch -t 200001010000 "$H_EXP/.claude/gate-approved/$HASH"
run_gate "$H_EXP" "$EXP_P"
check "expiry: stale approval no longer allows" "deny" "$(decision)"
if [[ ! -e "$H_EXP/.claude/gate-approved/$HASH" ]]; then pass; else fail "expiry: stale approval removed"; fi
HASH=$(hash_from_reason)
touch -t 200001010000 "$H_EXP/.claude/gate-pending/$HASH"
mk_ask "$TX_EXP" ask-e2 4 "Approve"
approve_rc "$H_EXP" "$HASH"
check "expiry: stale pending cannot be approved" "1" "$?"
GATE_TP=""

echo "== shadow rules log but never deny (G7: PR review-reply workflow) =="
H_G7=$(make_home g7)
run_gate "$H_G7" "$(bash_payload 'gh pr comment 12 --body hi')"
check "G7-gh is shadow: no deny" "" "$GOUT"
check_contains "G7-gh is shadow: logged" "$(cat "$H_G7/.claude/gate-log.jsonl")" '"rule":"G7-gh","tool":"Bash","decision":"shadow"'
run_gate "$H_G7" "$(bash_payload 'gh api repos/o/r/issues/3/comments -f body=hi')"
check "G7-gh-api is shadow: no deny" "" "$GOUT"
check "G7 rules ship with enforce=false" "2" "$(jq '[.rules[] | select((.id == "G7-gh" or .id == "G7-gh-api") and .enforce == false)] | length' "$RULES")"

echo "== matching text: data is not code =="
H_DATA=$(make_home data)
for c in \
    'git commit -m "rm -rf the build dir"' \
    'echo "run rm -rf / to nuke it"' \
    'printf "%s\n" "DELETE FROM users"' \
    'grep -rn "git push origin main" docs/' \
    'gh issue create --title "git stash pop broke" --body "rm -rf x"' \
    'gh api repos/o/r/issues -f body="rm -rf x" -f title=t'; do
    run_gate "$H_DATA" "$(bash_payload "$c")"
    check "data: allowed -> $c" "" "$GOUT"
done
for c in \
    'echo "$(rm -rf foo)"' \
    'echo "x; rm -rf foo" | bash' \
    'eval "x; rm -rf foo"' \
    'bash -lc "rm -rf foo"' \
    'git commit -m x && rm -rf foo'; do
    run_gate "$H_DATA" "$(bash_payload "$c")"
    check "data: still denied -> $c" "deny" "$(decision)"
done
run_gate "$H_DATA" "$(bash_payload "$(printf 'cat > n.md <<EOF\nrm -rf foo\nEOF')")"
check "data: a heredoc body is data" "" "$GOUT"
run_gate "$H_DATA" "$(bash_payload "$(printf 'bash <<EOF\nrm -rf foo\nEOF')")"
check "data: a heredoc fed to bash is code" "deny" "$(decision)"
run_gate "$H_DATA" "$(bash_payload "$(printf 'cat > n.md <<EOF\nhi\nEOF\nrm -rf foo')")"
check "data: code AFTER a heredoc is still checked" "deny" "$(decision)"
run_gate "$H_DATA" "$(bash_payload 'mkdir ~/.claude/gate.off')"
check "tamper: mkdir gate.off is denied" "deny" "$(decision)"
check_contains "tamper: by G10-tamper" "$(reason)" "CHECKPOINT G10-tamper:"

echo "== logging =="
H_LOG=$(make_home logging)
run_gate "$H_LOG" "$(write_payload "$H_LOG/.claude/hooks/x.sh" "TOPSECRETBODY-12345")"
run_gate "$H_LOG" "$(bash_payload 'rm -rf foo # AKIAABCDEFGHIJKLMNOP')"
run_gate "$H_LOG" "$(bash_payload 'rm -rf foo # password=hunter2hunter2')"
run_gate "$H_LOG" "$(payload mcp__claude_ai_Gmail__send_message '{"to":"x@y.z","body":"MAILBODY-98765"}')"
LOG=$(cat "$H_LOG/.claude/gate-log.jsonl")
check "log: every line is valid JSON with the expected keys" "4" "$(printf '%s\n' "$LOG" | jq -c 'select(has("ts") and has("rule") and has("tool") and has("decision") and has("scope") and has("cwd"))' | wc -l | tr -d ' ')"
check_absent "log: Write content is never logged" "$LOG" "TOPSECRETBODY"
check_contains "log: Write logs file_path" "$LOG" "$H_LOG/.claude/hooks/x.sh"
check_absent "log: secret-looking AWS key never logged" "$LOG" "AKIAABCDEFGHIJKLMNOP"
check_absent "log: password never logged" "$LOG" "hunter2"
check_contains "log: secret commands are replaced by a marker" "$LOG" "[redacted:secret-pattern]"
check_absent "log: MCP input never logged" "$LOG" "MAILBODY"
check_contains "log: MCP tool name logged" "$LOG" '"tool":"mcp__claude_ai_Gmail__send_message"'
check_absent "pending files carry no command text" "$(cat "$H_LOG"/.claude/gate-pending/* 2>/dev/null)" "AKIA"

echo "== failure policy (always exit 0) =="
EMPTY_BIN="$SANDBOX/empty-bin"
mkdir -p "$EMPTY_BIN"
GERR=$(printf '%s' "$(bash_payload 'rm -rf foo')" | PATH="$EMPTY_BIN" HOME="$H" /bin/bash "$H/.claude/hooks/gate.sh" 2>&1 >"$SANDBOX/out")
check "jq missing: exit 0" "0" "$?"
check_contains "jq missing: loud warning" "$GERR" "jq missing"
check "jq missing: no deny" "" "$(cat "$SANDBOX/out")"
H_NR="$SANDBOX/norules"
mkdir -p "$H_NR/.claude/hooks"
cp "$HOOKS_SRC/gate.sh" "$H_NR/.claude/hooks/gate.sh"
run_gate "$H_NR" "$(bash_payload 'rm -rf foo')"
check "rules file missing: exit 0" "0" "$GRC"
check_contains "rules file missing: loud warning" "$GERR" "rules file"
check "rules file missing: no deny" "" "$GOUT"
H_BAD=$(make_home badrules)
echo '{ not json' >"$H_BAD/.claude/hooks/gate-rules.json"
run_gate "$H_BAD" "$(bash_payload 'rm -rf foo')"
check "rules file corrupt: exit 0" "0" "$GRC"
check_contains "rules file corrupt: loud warning" "$GERR" "rule evaluation failed"
run_gate "$H" 'this is not json'
check "garbage stdin: exit 0" "0" "$GRC"
check "garbage stdin: no deny" "" "$GOUT"
H_RX=$(make_home badregex '(.rules[] | select(.id == "G1-rm") | .pattern) = "(unclosed"')
run_gate "$H_RX" "$(bash_payload 'rm -rf foo')"
check "one bad regex: exit 0" "0" "$GRC"
check_contains "one bad regex: names the rule" "$GERR" "G1-rm"
run_gate "$H_RX" "$(bash_payload 'git push origin main')"
check "one bad regex: other rules still deny" "deny" "$(decision)"

echo "== sync, settings and live-config coverage =="
SYNC="$REPO_ROOT/scripts/sync.sh"
# sync.sh may extend the list with RUNTIME_HOOK_SCRIPTS="$RUNTIME_HOOK_SCRIPTS ..."; drop the self-reference.
SCRIPTS=$(sed -n 's/^RUNTIME_HOOK_SCRIPTS="\(.*\)"$/\1/p' "$SYNC" | sed 's/\$RUNTIME_HOOK_SCRIPTS//g' | tr '\n' ' ')
DATA=$(sed -n 's/^RUNTIME_HOOK_DATA="\(.*\)"$/\1/p' "$SYNC" | sed 's/\$RUNTIME_HOOK_DATA//g' | tr '\n' ' ')
check_contains "sync.sh deploys gate.sh" " $SCRIPTS " " hooks/gate.sh "
check_contains "sync.sh deploys gate-rules.json" " $DATA " " hooks/gate-rules.json "
for f in $SCRIPTS $DATA; do
    if [[ -f "$REPO_ROOT/system-configs/.claude/$f" ]]; then pass; else fail "sync lists $f but it is missing from the source tree"; fi
    run_gate "$H" "$(write_payload "$H/.claude/$f" "x")"
    case "$f" in
        hooks/*) want="CHECKPOINT G10-file:" ;;
        *) want="CHECKPOINT G12-file:" ;;
    esac
    check_contains "live ~/.claude/$f is guarded by Write/Edit" "$(reason)" "$want"
done
SETTINGS="$REPO_ROOT/system-configs/.claude/settings.json"
check "settings.json registers gate.sh once, timeout 5" "1" "$(jq '[.hooks.PreToolUse[] | select(.hooks[]? | .command == "${HOME}/.claude/hooks/gate.sh" and .timeout == 5)] | length' "$SETTINGS")"
MATCHER=$(jq -r '.hooks.PreToolUse[] | select(.hooks[]? | .command == "${HOME}/.claude/hooks/gate.sh") | .matcher' "$SETTINGS")
for t in Bash Write Edit Artifact CronCreate RemoteTrigger mcp__claude_ai_Gmail__send_message; do
    check "matcher selects $t" "true" "$(jq -n --arg m "$MATCHER" --arg t "$t" '$t | test($m)')"
done
for t in Read Grep Glob ScheduleWakeup; do
    check "matcher skips $t" "false" "$(jq -n --arg m "$MATCHER" --arg t "$t" '$t | test($m)')"
done

echo ""
echo "gate tests: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILURES[@]}"
    exit 1
fi
exit 0
