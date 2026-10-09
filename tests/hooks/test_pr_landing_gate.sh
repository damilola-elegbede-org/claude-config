#!/usr/bin/env bash
# pr-landing-gate: the PR follow-up rule (pr-landing-gate.sh + pr-land-status.sh + /land).
#
# Hermetic: temp HOME, a fake gh (PR_LAND_GH) answering from fixtures, a fixed clock (PR_LAND_NOW).
# Nothing here reaches GitHub, the network or the real ~/.claude. Needs jq and python3.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/system-configs/.claude"
HOOKS="$SRC/hooks/jev"
STATUS="$HOOKS/pr-land-status.sh"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq and python3 are required" >&2
    exit 1
  fi
  echo "SKIP: jq/python3 missing" >&2
  exit 0
fi

T="$(mktemp -d /tmp/prland-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude"
unset BARECLAUDE_AGENT_SLUG CLAUDE_JOB_DIR JEV_RULES_FILE
LOG="$HOME/.claude/jev/rules-events.jsonl"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2" >&2
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
eq() { [[ "$2" == "$3" ]] && ok || bad "$1" "expected [$3] got [$2]"; }
has() { contains "$2" "$3" && ok || bad "$1" "missing [$3] in [$2]"; }
hasnt() { contains "$2" "$3" && bad "$1" "unexpected [$3] in [$2]" || ok; }
rules() { printf '%s' "$1" >"$T/rules.json"; export JEV_RULES_FILE="$T/rules.json"; }
loghas() { [[ -f "$LOG" ]] && grep -qF -- "$1" "$LOG"; }

URL="https://github.com/acme/widget/pull/42"
HEAD_OID="abc123"
HEAD_TIME="2026-10-08T12:00:00Z"
HEAD_EPOCH=$(python3 -c 'import calendar,time; print(calendar.timegm(time.strptime("2026-10-08T12:00:00Z","%Y-%m-%dT%H:%M:%SZ")))')
export PR_LAND_NOW=$((HEAD_EPOCH + 3600)) # an hour after the head: past the review grace by default

# Fake gh: `api graphql` answers $T/graphql.json; `pr view --json url,state` answers $T/prview.json.
FAKE="$T/gh"
cat >"$FAKE" <<'EOF'
#!/bin/bash
echo "gh $*" >>"$FAKE_GH_DIR/calls.log"
[ -f "$FAKE_GH_DIR/fail" ] && { echo "HTTP 502" >&2; exit 1; }
case "$1 $2" in
  "api graphql") cat "$FAKE_GH_DIR/graphql.json" ;;
  "pr view") jq -r '.url' "$FAKE_GH_DIR/prview.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE"
export PR_LAND_GH="$FAKE" FAKE_GH_DIR="$T"

# pr <field=value...>: write a GraphQL response. Defaults describe a ready PR.
pr() {
  local state=OPEN draft=false mergeable=MERGEABLE mss=CLEAN decision=null checks='[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}]'
  local threads='[]' reviews='[]' comments='[]' repo_logins='[]' kv
  for kv in "$@"; do
    case "$kv" in
      state=*) state="${kv#*=}" ;; draft=*) draft="${kv#*=}" ;; mergeable=*) mergeable="${kv#*=}" ;;
      mss=*) mss="${kv#*=}" ;; decision=*) decision="\"${kv#*=}\"" ;; checks=*) checks="${kv#*=}" ;;
      threads=*) threads="${kv#*=}" ;; reviews=*) reviews="${kv#*=}" ;; comments=*) comments="${kv#*=}" ;;
      repo=*) repo_logins="${kv#*=}" ;;
    esac
  done
  jq -n --arg state "$state" --argjson draft "$draft" --arg m "$mergeable" --arg mss "$mss" --argjson dec "$decision" \
    --argjson checks "$checks" --argjson threads "$threads" --argjson reviews "$reviews" --argjson comments "$comments" \
    --argjson repo "$repo_logins" --arg oid "$HEAD_OID" --arg ht "$HEAD_TIME" '
    {data:{repository:{
      pullRequest:{state:$state, isDraft:$draft, mergeable:$m, mergeStateStatus:$mss, reviewDecision:$dec, headRefOid:$oid,
        commits:{nodes:[{commit:{oid:$oid, committedDate:$ht, statusCheckRollup:{contexts:{nodes:$checks}}}}]},
        reviewThreads:{nodes:$threads}, reviews:{nodes:$reviews}, comments:{nodes:$comments}},
      pullRequests:{nodes:[{reviews:{nodes:[$repo[] | {author:{login:.}}]}, comments:{nodes:[]}}]}}}}' >"$T/graphql.json"
}
st() { bash "$STATUS" "$URL" "$@" 2>/dev/null; }
v() { st | jq -r .verdict; }
kinds() { st | jq -r '[.blockers[]?.kind, .pending[]?.kind] | join(",")'; }

echo "== pr-land-status: the one definition of mergeable =="
pr
eq "clean PR: ready" "$(v)" ready
st >/dev/null
eq "ready exits 0" "$?" 0
pr mss=UNSTABLE checks='[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]'
eq "red CI under UNSTABLE (no required checks) is still blocked" "$(v)" blocked
eq "  blocker is failing-checks" "$(kinds)" failing-checks
has "  names the check and the fix" "$(st)" '"detail":"lint","fix":"/fix-ci"'
st >/dev/null
eq "blocked exits 1" "$?" 1
pr checks='[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}]'
eq "a failed commit status counts too" "$(kinds)" failing-checks
pr checks='[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"CheckRun","name":"x","status":"COMPLETED","conclusion":"NEUTRAL"}]'
eq "skipped/neutral checks do not block" "$(v)" ready
pr mss=BLOCKED threads='[{"isResolved":false},{"isResolved":true},{"isResolved":false}]'
eq "unresolved threads: blocked" "$(kinds)" unresolved-threads
eq "  counts only unresolved" "$(st | jq -r .unresolved_threads)" 2
pr mss=DIRTY mergeable=CONFLICTING
eq "conflicts: blocked with rebase fix" "$(st | jq -r '.blockers[0] | .kind + " " + .fix')" "conflicts /rebase, then /push"
pr mss=BEHIND
eq "behind base: blocked" "$(kinds)" behind-base
pr draft=true mss=DRAFT
eq "draft: blocked" "$(kinds)" draft
pr decision=CHANGES_REQUESTED mss=BLOCKED
eq "changes requested: blocked" "$(kinds)" changes-requested
pr mss=BLOCKED checks='[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}]'
eq "running checks: pending" "$(v)" pending
eq "  pending kind" "$(kinds)" checks-running
pr mss=UNKNOWN
eq "mergeability computing: pending" "$(v)" pending
pr mss=BLOCKED
eq "BLOCKED with nothing explaining it: blocked" "$(v)" blocked
eq "  needs a human" "$(st | jq -r '.needs_human, .blockers[0].kind' | paste -sd, -)" "true,blocked-other"
pr state=MERGED mss=UNKNOWN
eq "merged: done" "$(v)" merged
pr state=CLOSED
eq "closed: done" "$(v)" closed

echo "== pr-land-status: review bots =="
# A bot active on this repo that has not answered the current head waits, but only inside the grace window.
pr repo='["coderabbitai"]'
eq "silent active bot, past grace: ready" "$(v)" ready
has "  with a note saying it stopped waiting" "$(st)" "no review from coderabbitai"
eq "silent active bot inside grace: pending" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) v)" pending
eq "  kind awaiting-review" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) st | jq -r '.pending[0].kind + ":" + .pending[0].detail')" "awaiting-review:coderabbitai"
pr repo='["coderabbitai"]' reviews='[{"author":{"login":"coderabbitai"},"commit":{"oid":"abc123"},"submittedAt":"2026-10-08T12:05:00Z"}]'
eq "bot reviewed the head: no wait" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) v)" ready
pr repo='["coderabbitai"]' reviews='[{"author":{"login":"coderabbitai"},"commit":{"oid":"old999"},"submittedAt":"2026-10-08T11:00:00Z"}]'
eq "bot reviewed only an older head: waits" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) v)" pending
pr repo='["chatgpt-codex-connector"]' comments='[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-10-08T12:03:00Z"}]'
eq "bot commented after the head: no wait" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) v)" ready
pr repo='["someone-else"]'
eq "configured bot never active on the repo: not awaited" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) v)" ready
rules '{"rules":{"pr-landing-gate":{"review_grace_min":0}}}'
pr repo='["coderabbitai"]'
eq "review_grace_min from the rule config" "$(PR_LAND_NOW=$((HEAD_EPOCH + 60)) v)" ready
unset JEV_RULES_FILE

echo "== pr-land-status: errors and bounded-out =="
touch "$T/fail"
eq "gh failure: error verdict" "$(v)" error
st >/dev/null
eq "error exits 2" "$?" 2
rm -f "$T/fail"
eq "not a PR URL: error" "$(bash "$STATUS" https://example.com/x 2>/dev/null | jq -r .verdict)" error
pr mss=BLOCKED threads='[{"isResolved":false}]'
out=$(st --bounded-out "Codex thread needs D's call")
has "bounded-out records the head" "$out" '"head":"abc123"'
has "  and the reason" "$out" "Codex thread needs D's call"
[[ -f "$HOME/.claude/jev/state/landing-bounded/https___github_com_acme_widget_pull_42.json" ]] && ok || bad "bounded-out record written"

echo "== pr-landing-gate: PostToolUse records the PR =="
SID=sess-1
SDIR="$HOME/.claude/jev/state/$SID/landing"
post() { # <command> [stdout] [cwd]
  jq -nc --arg c "$1" --arg o "${2:-}" --arg cwd "${3:-$T}" --arg s "$SID" \
    '{hook_event_name:"PostToolUse",session_id:$s,cwd:$cwd,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:""}}' |
    bash "$HOOKS/pr-landing-gate.sh" 2>/dev/null
}
stop() { jq -nc --arg s "$SID" --argjson a "${1:-false}" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a}' | bash "$HOOKS/pr-landing-gate.sh" 2>/dev/null; }
out=$(post "gh pr create --title t --body b" "$URL")
has "gh pr create: tells the model to run /land" "$out" '"additionalContext"'
has "  names the PR and the skill" "$out" "/land skill on $URL"
[[ -f "$SDIR/https___github_com_acme_widget_pull_42.json" ]] && ok || bad "gh pr create recorded the PR"
loghas '"verdict":"recorded"' && ok || bad "recorded verdict logged"
rm -rf "$SDIR"
eq "a commit message that mentions gh pr create records nothing" "$(post "git commit -m 'gh pr create is the step after this'" "$URL")" ""
[[ ! -d "$SDIR" ]] && ok || bad "mention did not record"
eq "gh pr create that printed no URL records nothing" "$(post "gh pr create --title t" "error: no commits")" ""
eq "an unrelated command records nothing" "$(post "gh pr list" "$URL")" ""
printf '{"url":"%s","state":"OPEN"}' "$URL" >"$T/prview.json"
out=$(post "git push origin feat/x" "")
has "git push to a branch with an open PR: hint" "$out" "/land skill on $URL"
[[ -f "$SDIR/https___github_com_acme_widget_pull_42.json" ]] && ok || bad "git push recorded the branch's PR"
rm -rf "$SDIR"
printf '{"url":"","state":""}' >"$T/prview.json"
eq "git push with no PR for the branch: nothing" "$(post "git push -u origin feat/y" "")" ""
rules '{"rules":{"pr-landing-gate":{"mode":"shadow"}}}'
eq "shadow: records but prints nothing" "$(post "gh pr create --title t" "$URL")" ""
loghas shadow-recorded && ok || bad "shadow-recorded logged"
unset JEV_RULES_FILE
rm -rf "$SDIR"
eq "clara exempt" "$(BARECLAUDE_AGENT_SLUG=clara post "gh pr create --title t" "$URL")" ""

echo "== pr-landing-gate: Stop blocks until mergeable =="
rm -rf "$HOME/.claude/jev/state" # drop the bounded-out record written above
eq "no PR this session: no block" "$(stop)" ""
post "gh pr create --title t" "$URL" >/dev/null
pr mss=BLOCKED threads='[{"isResolved":false}]'
out=$(stop)
has "unmergeable PR: block" "$out" '"decision":"block"'
has "  reason names the PR" "$out" "$URL"
has "  and the blocker with its fix" "$out" "unresolved-threads (1 unresolved) -> /resolve-comments"
has "  and the skill" "$out" "/land skill"
has "re-blocks on a stop-hook continuation (block 2)" "$(stop true)" '"decision":"block"'
has "block 3" "$(stop true)" '"decision":"block"'
eq "after max_blocks (3) for this head: released" "$(stop true)" ""
loghas released-cap && ok || bad "cap release logged"
rm -rf "$SDIR"
post "gh pr create --title t" "$URL" >/dev/null
pr mss=BLOCKED checks='[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}]'
has "pending CI: block, says wait" "$(stop)" "checks-running (test) -> wait"
pr
eq "PR became ready: released" "$(stop true)" ""
[[ ! -f "$SDIR/https___github_com_acme_widget_pull_42.json" ]] && ok || bad "ready PR dropped from the session"
eq "and stays released" "$(stop)" ""
post "gh pr create --title t" "$URL" >/dev/null
pr state=MERGED
eq "merged: released" "$(stop)" ""
post "gh pr create --title t" "$URL" >/dev/null
touch "$T/fail"
eq "gh down: fail open" "$(stop)" ""
loghas fail-open-status-error && ok || bad "fail-open logged"
rm -f "$T/fail"
pr mss=BLOCKED threads='[{"isResolved":false}]'
st --bounded-out "needs D" >/dev/null
eq "bounded-out for the current head: released" "$(stop)" ""
HEAD_OID="def456"
pr mss=BLOCKED threads='[{"isResolved":false}]'
has "a new head after bounded-out: blocks again" "$(stop)" '"decision":"block"'
HEAD_OID="abc123"
rm -rf "$HOME/.claude/jev/state"
post "gh pr create --title t" "$URL" >/dev/null
pr mss=BLOCKED threads='[{"isResolved":false}]'
rules '{"rules":{"pr-landing-gate":{"mode":"shadow"}}}'
eq "shadow: never blocks" "$(stop)" ""
loghas shadow-would-block && ok || bad "shadow-would-block logged"
rules '{"rules":{"pr-landing-gate":{"mode":"off"}}}'
eq "off: never blocks" "$(stop)" ""
unset JEV_RULES_FILE
SID=other-session
eq "another session's PR does not block this one" "$(stop)" ""

echo "== wiring =="
SJ="$SRC/settings.json"
RJ="$HOOKS/rules.d/rules-events.json"
eq "PostToolUse registers the gate for gh pr create and git push" \
  "$(jq -r '[.hooks.PostToolUse[].hooks[] | select(.command | contains("pr-landing-gate.sh")) | .if] | join(",")' "$SJ")" \
  'Bash(gh *pr create*),Bash(git *push*)'
eq "Stop registers the gate once, without an if" \
  "$(jq -r '[.hooks.Stop[].hooks[] | select(.command | contains("pr-landing-gate.sh")) | .if // "none"] | join(",")' "$SJ")" none
eq "rule ships enforce" "$(jq -r '."pr-landing-gate".mode' "$RJ")" enforce
eq "rule covers bg jobs and the fleet (where PRs are opened)" "$(jq -r '."pr-landing-gate".scope | join(",")' "$RJ")" "interactive,bgjob,fleet"
for f in pr-landing-gate.sh pr-land-status.sh; do
  [[ -x "$HOOKS/$f" ]] && ok || bad "$f is executable"
  grep -qF "hooks/jev/$f" "$REPO_ROOT/scripts/sync.sh" && ok || bad "sync.sh deploys $f"
done
grep -qF 'INVOKE: /land {pr_url}' "$SRC/skills/pr/SKILL.md" && ok || bad "/pr hands off to /land"
grep -qF 'pr-land-status.sh' "$SRC/skills/land/SKILL.md" && ok || bad "/land reads the shared status script"

echo
echo "pr-landing-gate tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
