#!/usr/bin/env bash
# Phase-4 Jev integration: rules extraction, lifecycle-event hooks, workflow helpers.
#
# Hermetic: every case runs under a temp HOME; Jev is mocked (JEV_MOCK=<fixture>,
# JEV_MOCK=unavailable); nothing here reaches the Gateway, the network, the real
# ~/.claude, or the real memory dir. Needs jq and python3 (CI installs both).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/system-configs/.claude"
HOOKS="$SRC/hooks/jev"

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq and python3 are required" >&2
    exit 1
  fi
  echo "SKIP: jq/python3 missing" >&2
  exit 0
fi

T="$(mktemp -d /tmp/jevrules-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude"
LOG="$HOME/.claude/jev/rules-events.jsonl"
unset BARECLAUDE_AGENT_SLUG CLAUDE_JOB_DIR JEV_MOCK JEV_MOCK_CAPTURE JEV_ASK
export RE_MEMORY_DIR="$T/memory"
export PAPERCUT_LOG="$HOME/.claude/papercuts.md"
export MEMORY_CANDIDATES_FILE="$HOME/.claude/memory-candidates.md"
export NO_SOUND=1

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2" >&2
}
check() { # name, condition-exit-code
  if [[ "$2" -eq 0 ]]; then ok; else bad "$1" "${3:-}"; fi
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
eq() { [[ "$2" == "$3" ]] && ok || bad "$1" "expected [$3] got [$2]"; }
has() { contains "$2" "$3" && ok || bad "$1" "missing [$3] in [$2]"; }
hasnt() { contains "$2" "$3" && bad "$1" "unexpected [$3] in [$2]" || ok; }
reset() { rm -rf "$HOME/.claude/jev" "$T/capture" "$HOME/.claude/jev.off"; rules '{}'; unset JEV_MOCK JEV_MOCK_CAPTURE; }
rules() { printf '%s' "$1" >"$T/rules.json"; export JEV_RULES_FILE="$T/rules.json"; }
loghas() { [[ -f "$LOG" ]] && grep -qF -- "$1" "$LOG"; }
mock() { printf '%s' "$2" >"$T/mock-$1.json"; export JEV_MOCK="$T/mock-$1.json"; }
run() { # script, stdin-json  (env passes through)
  printf '%s' "$2" | bash "$HOOKS/$1" 2>/dev/null
}
bool_ans() { printf '{"answers":{"%s":{"type":"boolean","probability":%s}}}' "$1" "$2"; }

echo "== registry, rules.d and settings wiring =="
# --- shipped rule modes: every rule ships enforce (Jev and regex) -------------
RJ="$HOOKS/rules.d/rules-events.json"
jq -e . "$RJ" >/dev/null 2>&1 && ok || bad "rules-events.json is valid JSON"
NONENFORCE=$(jq -r 'to_entries[] | select(.value.threshold != null and .value.mode != "enforce") | .key' "$RJ" | sort | paste -sd, -)
eq "every Jev rule (has threshold) ships enforce except the two D kept in shadow" "$NONENFORCE" "executive-scope-creep,executive-tag-correctness"
eq "executive-tag-correctness ships shadow" "$(jq -r '."executive-tag-correctness".mode' "$RJ")" "shadow"
eq "executive-scope-creep ships shadow" "$(jq -r '."executive-scope-creep".mode' "$RJ")" "shadow"
for r in file-org-guard pr-draft-guard executive-lint retry-counter papercut-grep; do
  eq "regex rule $r ships enforce" "$(jq -r --arg r "$r" '.[$r].mode' "$RJ")" enforce
done

# --- settings.json registers every hook, and each registered file exists -----------
SJ="$SRC/settings.json"
jq -e . "$SJ" >/dev/null 2>&1 && ok || bad "settings.json is valid JSON"
for want in \
  "PreToolUse:file-org-guard.sh" "PreToolUse:memory-dup-guard.sh" "PreToolUse:pr-draft-guard.sh" \
  "PostToolUseFailure:retry-counter.sh" "PostToolUse:retry-counter.sh" "PostToolUseFailure:papercut-grep.sh" \
  "Stop:executive-lint.sh" "Stop:papercut-nudge.sh" "StopFailure:stopfailure-hint.sh" \
  "SessionStart:session-start-project.sh" "SessionEnd:session-end-memory.sh" \
  "Notification:notification-urgency.sh" "PostCompact:postcompact-log.sh"; do
  ev="${want%%:*}"
  f="${want#*:}"
  n=$(jq -r --arg ev "$ev" --arg f "$f" '[.hooks[$ev][]?.hooks[]?.command | select(contains($f))] | length' "$SJ")
  eq "settings.json $ev registers $f" "$n" 1
  [[ -x "$HOOKS/$f" ]] && ok || bad "$f exists and is executable"
done
# existing hooks untouched
eq "existing claude-speak Stop hook kept" "$(jq -r '[.hooks.Stop[].hooks[].command | select(contains("claude-speak.sh"))] | length' "$SJ")" 1
eq "existing session_registry SessionStart kept" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("session_registry.sh"))] | length' "$SJ")" 1
# sync deploys every .sh in hooks/jev that settings.json references
for f in "$HOOKS"/*.sh; do
  b="hooks/jev/$(basename "$f")"
  grep -qF "$b" "$REPO_ROOT/scripts/sync.sh" && ok || bad "sync.sh RUNTIME_HOOK_SCRIPTS lists $b"
done

# hook `if` prefilters (settings.json handler field; verified live with scripts/jev-hook-probes.sh e):
# only handlers whose script ignores everything the rule filters out get one, one permission rule each.
if_of() { jq -r --arg f "$1" '[.hooks[][]?.hooks[]? | select(.command | contains($f)) | .if // "none"] | join(",")' "$SJ"; }
eq "if: pr-draft-guard only runs for gh pr create" "$(if_of pr-draft-guard.sh)" 'Bash(gh *pr create*)'
eq "if: memory-dup-guard only runs for memory notes" "$(if_of memory-dup-guard.sh)" 'Write(**/memory/*.md)'
eq "if: the git-agent identity guard only runs for git commands" "$(jq -r '[.hooks.PreToolUse[].hooks[] | select(.command | contains("git-agent.sh")) | .if] | join(",")' "$SJ")" 'Bash(git *)'
eq "if: the destructive-git guard has none (its --no-verify arm is not git-prefixed)" "$(jq -r '[.hooks.PreToolUse[].hooks[] | select(.command | contains("--no-gpg-sign")) | .if // "none"] | join(",")' "$SJ")" none
eq "if: gate.sh and jev-gate have none (redirects are invisible to if globs)" "$(if_of hooks/gate.sh),$(if_of hooks/jev-gate.sh)" "none,none"
eq "if: every rule is a single permission rule (no OR, no list)" "$(jq -r '[.hooks[][]?.hooks[]? | .if // empty | select(test("\\|\\||,|\\|[^)]*\\)$"))] | length' "$SJ")" 0
eq "every hook handler has an explicit timeout" "$(jq -r '[.hooks[][]?.hooks[]? | select(.timeout == null)] | length' "$SJ")" 0

# re_cfg reads the {"rules":{...}} wrapper of the client's jev-rules.json (last file wins)
mkdir -p "$HOME/.claude/hooks/jev"
printf '%s' '{"exempt_agents":["x"],"rules":{"retry-counter":{"mode":"shadow"}}}' >"$HOME/.claude/hooks/jev/jev-rules.json"
eq "re_cfg: wrapped jev-rules.json overrides the shipped mode" "$(unset JEV_RULES_FILE; . "$HOOKS/rules-events-lib.sh"; re_cfg retry-counter mode dflt)" "shadow"
eq "re_cfg: shipped value for another rule survives" "$(unset JEV_RULES_FILE; . "$HOOKS/rules-events-lib.sh"; re_cfg pr-draft-guard mode dflt)" "enforce"
rm -f "$HOME/.claude/hooks/jev/jev-rules.json"

echo "== file-org-guard =="
REPO="$T/repo"
mkdir -p "$REPO/docs" "$REPO/src" "$REPO/.tmp/plans"
git -C "$REPO" init -q 2>/dev/null
tw() { jq -nc --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}'; }
reset
out=$(run file-org-guard.sh "$(tw "$REPO/PLAN.md")")
has "root PLAN.md denied" "$out" '"permissionDecision":"deny"'
has "deny reason names .tmp/" "$out" ".tmp/plans/"
for n in report-2026.md notes.md scratch.txt implementation_plan.md analysis.json DRAFT.md; do
  out=$(run file-org-guard.sh "$(tw "$REPO/$n")")
  has "root $n denied" "$out" '"permissionDecision":"deny"'
done
for p in "$REPO/.tmp/plans/plan.md" "$REPO/docs/plan.md" "$REPO/src/report.md" "$REPO/plan.py" "$REPO/README.md" "$REPO/RELEASE_NOTES.md" "$REPO/planner.md" "$T/outside-plan.md"; do
  out=$(run file-org-guard.sh "$(tw "$p")")
  eq "allowed: ${p#"$T"/}" "$out" ""
done
printf x >"$REPO/plan.md"
out=$(run file-org-guard.sh "$(tw "$REPO/plan.md")")
eq "existing file (overwrite) allowed" "$out" ""
rm -f "$REPO/plan.md"
out=$(BARECLAUDE_AGENT_SLUG=clara run file-org-guard.sh "$(tw "$REPO/PLAN.md")")
eq "clara exempt (allowed)" "$out" ""
loghas allow-exempt-agent && ok || bad "clara exemption logged"
reset
rules '{"file-org-guard":{"mode":"shadow"}}'
out=$(run file-org-guard.sh "$(tw "$REPO/PLAN.md")")
eq "shadow mode does not deny" "$out" ""
loghas shadow-would-deny && ok || bad "shadow verdict logged"

echo "== pr-draft-guard =="
bc() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
reset
for c in 'gh pr create --draft --title x' 'gh pr create --draft=true --title x' 'gh pr create -d --title x' 'cd /r && gh pr create --title "t" --body "b" --draft' 'gh -R o/r pr create --draft'; do
  out=$(run pr-draft-guard.sh "$(bc "$c")")
  has "denied: $c" "$out" '"permissionDecision":"deny"'
done
has "deny reason says ready not draft" "$out" "ready for review"
for c in 'gh pr create --title x --body y' 'gh pr create --draft=false' 'gh pr create --draft=false --title x' 'git commit -m "docs: gh pr create --draft is banned"' $'gh pr create --title x --body "$(cat <<\'EOF\'\nmention gh pr create --draft here\nEOF\n)"' 'ALLOW_DRAFT_PR=1 gh pr create --draft' 'gh pr list --draft' 'echo hello'; do
  out=$(run pr-draft-guard.sh "$(bc "$c")")
  eq "allowed: ${c:0:50}" "$out" ""
done
out=$(BARECLAUDE_AGENT_SLUG=clara run pr-draft-guard.sh "$(bc 'gh pr create --draft')")
eq "clara exempt" "$out" ""

echo "== retry-counter =="
reset
rf() { jq -nc --arg c "$1" --arg s "${2:-s1}" --arg t "${3:-Bash}" '{session_id:$s,tool_name:$t,tool_input:{command:$c},error:"Exit code 1"}'; }
out1=$(run retry-counter.sh "$(rf 'npm test')")
out2=$(run retry-counter.sh "$(rf 'npm   test ')")
out3=$(run retry-counter.sh "$(rf 'npm test')")
eq "1st failure silent" "$out1" ""
eq "2nd failure silent (whitespace-normalized)" "$out2" ""
has "3rd failure injects context" "$out3" '"hookEventName":"PostToolUseFailure"'
has "3rd failure says stop and report" "$out3" "Stop retrying"
out4=$(run retry-counter.sh "$(rf 'npm test')")
has "4th failure still injects" "$out4" "failed 4 times"
eq "different command has its own count" "$(run retry-counter.sh "$(rf 'ls /nope')")" ""
eq "other session has its own count" "$(run retry-counter.sh "$(rf 'npm test' s2)")" ""
eq "non-Bash tool ignored" "$(run retry-counter.sh "$(rf 'x' s1 Edit)")" ""
# a success between failures resets the streak: fail x2, success, fail x2 must not reach 3
rok() { jq -nc --arg c "$1" --arg s "${2:-s1}" '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{}}'; }
r1=$(run retry-counter.sh "$(rf 'make build' s3)")
r2=$(run retry-counter.sh "$(rf 'make build' s3)")
rs=$(run retry-counter.sh "$(rok 'make build' s3)")
r3=$(run retry-counter.sh "$(rf 'make build' s3)")
r4=$(run retry-counter.sh "$(rf 'make build' s3)")
eq "success reset: failures before it are silent" "$r1$r2" ""
eq "success event itself emits nothing" "$rs" ""
eq "success reset: fail x2 after the success stays silent" "$r3$r4" ""
has "success reset: a 3rd consecutive failure after it injects" "$(run retry-counter.sh "$(rf 'make build' s3)")" "failed 3 times"
run retry-counter.sh "$(rok 'ls elsewhere' s3)" >/dev/null
has "success of a different command does not reset this one" "$(run retry-counter.sh "$(rf 'make build' s3)")" "failed 4 times"

echo "== papercut-grep =="
reset
cat >"$PAPERCUT_LOG" <<'EOF'
# Papercuts
A factual log of small tooling failures and their fixes.
Format: date (UTC) · source · symptom · fix · project/path
Append via ~/.claude/papercut.sh; never edit or reorder entries.
2026-09-01 · claude-code · API Error ECONNRESET on large uploads over 5GHz wifi · pin the laptop to 2.4GHz Halle · claude-config
2026-09-02 · claude-code · prettier hook reformats whole files on Edit · restore from origin and patch with sed · damilola.tech
EOF
pf() { jq -nc --arg e "$1" --arg c "${2:-curl x}" '{session_id:"s",tool_name:"Bash",tool_input:{command:$c},error:$e}'; }
out=$(run papercut-grep.sh "$(pf 'API Error: Unable to connect (ECONNRESET) socket closed')")
has "ECONNRESET failure injects the matching papercut" "$out" "pin the laptop to 2.4GHz"
has "injected text marks entries untrusted" "$out" "untrusted"
hasnt "unrelated entry not injected" "$out" "prettier"
eq "unrelated failure injects nothing" "$(run papercut-grep.sh "$(pf 'No such file or directory')")" ""
mkdir -p "$HOME/.claude/papercuts/archive"
printf '%s\n' '2026-01-05 · claude-code · vercel deploy EPIPE during upload · retry from wired · alocubano' >"$HOME/.claude/papercuts/archive/2026-01.md"
out=$(run papercut-grep.sh "$(pf 'vercel deploy failed: EPIPE write error' 'vercel deploy')")
has "archive searched when live log has no match" "$out" "archive"
has "archive hit content injected" "$out" "retry from wired"
rm -rf "$HOME/.claude/papercuts"
eq "missing archive dir tolerated silently" "$(run papercut-grep.sh "$(pf 'EPIPE write error vercel')")" ""
rm -f "$PAPERCUT_LOG"
eq "missing log tolerated silently" "$(run papercut-grep.sh "$(pf 'ECONNRESET socket')")" ""

echo "== executive-lint =="
reset
sl() { jq -nc --arg m "$1" --arg a "${2:-false}" '{session_id:"s",hook_event_name:"Stop",stop_hook_active:($a=="true"),last_assistant_message:$m,cwd:"/nonexistent"}'; }
GOOD=$'**FYI · All 18 tests pass.**\nDetails here.'
eq "valid FYI reply passes" "$(run executive-lint.sh "$(sl "$GOOD")")" ""
ACT=$'**ACTION · Run `/sync` once.**\nConfidence **high** (tests) · Reversible **yes** · Deadline **today**\n\n**Next:** you.'
eq "valid ACTION with meta line passes" "$(run executive-lint.sh "$(sl "$ACT")")" ""
for tag in DECISION APPROVAL BLOCKED INPUT; do
  m=$'**'"$tag"$' · conclusion.**\nConfidence **high** (x) · Reversible **yes** · Deadline **none**\nbody'
  eq "valid $tag passes" "$(run executive-lint.sh "$(sl "$m")")" ""
done
out=$(run executive-lint.sh "$(sl $'Here is the answer.\nmore')")
has "untagged reply blocked" "$out" '"decision":"block"'
has "block reason mentions tag" "$out" "starting with a tag"
out=$(run executive-lint.sh "$(sl $'**DONE · finished.**\nx')")
has "unknown tag blocked" "$out" '"decision":"block"'
out=$(run executive-lint.sh "$(sl $'FYI · not bold.\nx')")
has "non-bold line 1 blocked" "$out" '"decision":"block"'
out=$(run executive-lint.sh "$(sl $'**ACTION · do it.**\nbody without meta')")
has "ACTION without meta line blocked" "$out" "meta line"
out=$(run executive-lint.sh "$(sl $'**DECISION · pick.**\nbody')")
has "DECISION without meta line blocked" "$out" "meta line"
LONG="**FYI · long.**"
for i in $(seq 1 70); do LONG+=$'\n'"line $i"; done
out=$(run executive-lint.sh "$(sl "$LONG")")
has "reply over 60 lines blocked" "$out" "max 60"
out=$(run executive-lint.sh "$(sl $'**FYI · see ENG-1234 for details.**\nx')")
has "bare Linear ID blocked" "$out" "ENG-1234"
eq "linked Linear ID passes" "$(run executive-lint.sh "$(sl $'**FYI · see [ENG-1234](https://linear.app/b/issue/ENG-1234/x).**\nx')")" ""
eq "Linear ID in code span passes" "$(run executive-lint.sh "$(sl $'**FYI · branch `feat/ENG-1234`.**\nx')")" ""
eq "Linear ID in code fence passes" "$(run executive-lint.sh "$(sl $'**FYI · log.**\n```\nENG-1234 done\n```')")" ""
eq "UTF-8/SHA-256 are not Linear IDs" "$(run executive-lint.sh "$(sl $'**FYI · UTF-8 and SHA-256 are fine.**\nx')")" ""
eq "stop_hook_active never blocks twice" "$(run executive-lint.sh "$(sl 'plain reply' true)")" ""
loghas allow-stop-hook-active && ok || bad "stop_hook_active allow logged"
eq "subagent (agent_id) skipped" "$(printf '%s' "$(jq -c '. + {agent_id:"a1"}' <<<"$(sl 'plain reply')")" | bash "$HOOKS/executive-lint.sh" 2>/dev/null)" ""
eq "bg job skipped" "$(CLAUDE_JOB_DIR=/x run executive-lint.sh "$(sl 'plain reply')")" ""
eq "fleet skipped" "$(BARECLAUDE_AGENT_SLUG=tars run executive-lint.sh "$(sl 'plain reply')")" ""
eq "empty message skipped" "$(run executive-lint.sh "$(sl '')")" ""
rules '{"executive-lint":{"mode":"shadow"}}'
eq "shadow mode logs but does not block" "$(run executive-lint.sh "$(sl 'plain reply')")" ""
loghas shadow-would-block && ok || bad "shadow-would-block logged"

echo "== executive-lint: Jev shadow checks =="
reset
mock tag '{"answers":{"tag":{"type":"choice","choice":"DECISION","probabilities":{"DECISION":0.95,"FYI":0.05}},"unsourced":{"type":"score","score":2.4,"probabilities":{"0":0.05,"1":0.15,"2":0.5,"3":0.3}}}}'
export JEV_MOCK_CAPTURE="$T/capture"
out=$(run executive-lint.sh "$(sl "$GOOD")")
eq "Jev tag mismatch in shadow does not block" "$out" ""
loghas '"rule":"executive-tag-correctness","verdict":"mismatch"' && ok || bad "tag mismatch logged" "$(cat "$LOG" 2>/dev/null)"
# Jev returns probabilities per level (never a "level" field): the hook logs P(level>=2) = 0.5 + 0.3.
loghas '"rule":"executive-unsourced-claims","verdict":"p=0.8"' && ok || bad "unsourced P(level>=2) logged"
[[ "$(wc -l <"$T/capture" | tr -d ' ')" == 1 ]] && ok || bad "exactly one jev-ask call per Stop"
has "request carries the reply" "$(cat "$T/capture")" "All 18 tests pass"
rules '{"executive-tag-correctness":{"mode":"enforce","threshold":0.9}}'
out=$(run executive-lint.sh "$(sl "$GOOD")")
has "enforce + high-confidence mismatch blocks" "$out" "looks wrong"
rules '{"executive-unsourced-claims":{"mode":"enforce","threshold":0.75}}'
out=$(run executive-lint.sh "$(sl "$GOOD")")
has "enforce + P(level>=2) 0.8 >= threshold 0.75 blocks" "$out" "lack sources"
rules '{"executive-unsourced-claims":{"mode":"enforce","threshold":0.85}}'
out=$(run executive-lint.sh "$(sl "$GOOD")")
eq "enforce + P(level>=2) 0.8 below threshold 0.85 does not block" "$out" ""
rules '{"executive-tag-correctness":{"mode":"enforce","threshold":0.9}}'
out=$(JEV_MOCK=unavailable run executive-lint.sh "$(sl "$GOOD")")
eq "Jev unavailable fails open (enforce mode)" "$out" ""
rules '{}'
touch "$HOME/.claude/jev.off"
rm -f "$T/capture"
out=$(run executive-lint.sh "$(sl "$GOOD")")
[[ ! -s "$T/capture" ]] && ok || bad "kill switch jev.off prevents the call" "$(cat "$T/capture" 2>/dev/null)"
rm -f "$HOME/.claude/jev.off"
# scope-creep: needs a real git diff and a first user prompt
SC="$T/scope-repo"
mkdir -p "$SC"
git -C "$SC" init -q && git -C "$SC" config user.email t@t && git -C "$SC" config user.name t
printf a >"$SC/a.txt" && git -C "$SC" add . && git -C "$SC" commit -qm init
printf b >>"$SC/a.txt"
TR="$T/transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"fix the typo in a.txt"}}' >"$TR"
mock scope '{"answers":{"tag":{"type":"choice","choice":"FYI","probabilities":{"FYI":0.9}},"scope":{"type":"boolean","probability":0.93}}}'
rm -f "$T/capture"
msg="$GOOD"
out=$(printf '%s' "$(jq -nc --arg m "$msg" --arg c "$SC" --arg t "$TR" '{stop_hook_active:false,last_assistant_message:$m,cwd:$c,transcript_path:$t}')" | bash "$HOOKS/executive-lint.sh" 2>/dev/null)
eq "scope-creep shadow never blocks" "$out" ""
loghas '"rule":"executive-scope-creep","verdict":"p=0.93"' && ok || bad "scope-creep p logged"
has "scope request carries first user prompt" "$(cat "$T/capture")" "fix the typo in a.txt"
has "scope request carries diff stat" "$(cat "$T/capture")" "a.txt"

echo "== papercut-dedupe =="
reset
unset JEV_MOCK_CAPTURE
rm -f "$PAPERCUT_LOG"
export PAPERCUT_SH="$SRC/papercut.sh"
bash "$HOOKS/papercut-dedupe.sh" claude-code "hook reformats whole files" "use sed" "proj/a" >/dev/null 2>&1
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == 1 ]] && ok || bad "new papercut appended"
out=$(bash "$HOOKS/papercut-dedupe.sh" claude-code "Hook Reformats  whole files" "use sed again" "proj/a" 2>&1)
has "exact duplicate refused" "$out" "duplicate"
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == 1 ]] && ok || bad "duplicate not appended"
mock dup "$(bool_ans duplicate 0.95)"
bash "$HOOKS/papercut-dedupe.sh" claude-code "the formatter hook rewrites entire files" "use sed" "proj/a" >/dev/null 2>&1
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == 2 ]] && ok || bad "shadow: Jev duplicate verdict does not stop the append"
loghas '"rule":"papercut-dedupe","verdict":"jev p=0.95"' && ok || bad "shadow verdict logged"
rules '{"papercut-dedupe":{"mode":"enforce","threshold":0.9}}'
out=$(bash "$HOOKS/papercut-dedupe.sh" claude-code "prettier hook rewrites full files on write" "use sed" "proj/a" 2>&1)
has "enforce: Jev near-duplicate refused" "$out" "duplicate"
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == 2 ]] && ok || bad "enforce: near-duplicate not appended"
JEV_MOCK=unavailable bash "$HOOKS/papercut-dedupe.sh" claude-code "brand new unrelated thing" "fix" "proj/b" >/dev/null 2>&1
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == 3 ]] && ok || bad "Jev unavailable fails open (appends)"
bash "$HOOKS/papercut-dedupe.sh" only three args >/dev/null 2>&1 && bad "wrong arg count should fail via papercut.sh usage" || ok
# exact-duplicate check compares the symptom column only (field 3), trimmed and normalized
reset
rm -f "$PAPERCUT_LOG"
bash "$HOOKS/papercut-dedupe.sh" claude-code "formatter reflowed the file" "raised the timeout to 30s" "proj/a" >/dev/null 2>&1
n0=$(grep -c '^20' "$PAPERCUT_LOG")
out=$(bash "$HOOKS/papercut-dedupe.sh" claude-code "timeout" "bump it" "proj/b" 2>&1)
hasnt "short symptom found only in another entry's fix column is not a duplicate" "$out" "duplicate"
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == $((n0 + 1)) ]] && ok || bad "generic symptom appended despite matching a fix column"
out=$(bash "$HOOKS/papercut-dedupe.sh" claude-code "  TIMEOUT  " "other fix" "proj/c" 2>&1)
has "trimmed/lowercased exact symptom is a duplicate" "$out" "duplicate"
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == $((n0 + 1)) ]] && ok || bad "exact duplicate not appended"
out=$(bash "$HOOKS/papercut-dedupe.sh" claude-code "" "fix" "proj/d" 2>&1)
hasnt "empty symptom is not reported as a duplicate" "$out" "duplicate"
[[ "$(grep -c '^20' "$PAPERCUT_LOG")" == $((n0 + 1)) ]] && ok || bad "empty symptom is rejected by papercut.sh, nothing appended"

echo "== papercut-nudge =="
reset
TRN="$T/nudge.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"run the build"}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Exit code 1 ECONNRESET"}]}}'
} >"$TRN"
mock fr "$(bool_ans friction 0.91)"
ns() { jq -nc --arg t "$TRN" --arg m "${1:-built it}" --arg a "${2:-false}" '{stop_hook_active:($a=="true"),last_assistant_message:$m,transcript_path:$t}'; }
eq "shadow: no output" "$(run papercut-nudge.sh "$(ns)")" ""
loghas '"rule":"papercut-nudge","verdict":"p=0.91"' && ok || bad "shadow friction p logged"
rules '{"papercut-nudge":{"mode":"enforce","threshold":0.8}}'
out=$(run papercut-nudge.sh "$(ns)")
has "enforce: Stop additionalContext reminds to log" "$out" "papercut-dedupe.sh"
has "enforce: event is Stop" "$out" '"hookEventName":"Stop"'
eq "stop_hook_active: no nudge" "$(run papercut-nudge.sh "$(ns built true)")" ""
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' >"$TRN"
export JEV_MOCK_CAPTURE="$T/capture"
rm -f "$T/capture"
eq "clean turn: no output" "$(run papercut-nudge.sh "$(ns 'all done')")" ""
[[ ! -s "$T/capture" ]] && ok || bad "clean turn: Jev not called (regex pre-filter)"
eq "bg job skipped" "$(CLAUDE_JOB_DIR=/x run papercut-nudge.sh "$(ns)")" ""
unset JEV_MOCK_CAPTURE

echo "== memory-dup-guard =="
reset
mkdir -p "$RE_MEMORY_DIR"
cat >"$RE_MEMORY_DIR/MEMORY.md" <<'EOF'
# Memory Index

- [PR ready not draft](pr-ready-not-draft.md) — open PRs ready for review by default, not as drafts
- [Hyperlink Linear tickets](hyperlink-linear-tickets.md) — always give full clickable ticket URLs to D
EOF
mw() { jq -nc --arg p "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}'; }
NEWMEM=$'---\nname: prs-not-drafts\ndescription: open PRs ready for review not as drafts\nmetadata:\n  type: feedback\n---\nD wants PRs ready, never drafts.'
mock md "$(bool_ans duplicate 0.96)"
eq "shadow: no output" "$(run memory-dup-guard.sh "$(mw "$RE_MEMORY_DIR/prs-not-drafts.md" "$NEWMEM")")" ""
loghas '"rule":"memory-dup-guard","verdict":"p=0.96"' && ok || bad "shadow dup p logged"
rules '{"memory-dup-guard":{"mode":"enforce","threshold":0.9}}'
out=$(run memory-dup-guard.sh "$(mw "$RE_MEMORY_DIR/prs-not-drafts.md" "$NEWMEM")")
has "enforce: additionalContext warns of duplicate" "$out" "Possible duplicate memory"
has "enforce: names the closest entry" "$out" "pr-ready-not-draft.md"
hasnt "never denies" "$out" "deny"
eq "MEMORY.md write ignored" "$(run memory-dup-guard.sh "$(mw "$RE_MEMORY_DIR/MEMORY.md" "x")")" ""
eq "non-memory path ignored" "$(run memory-dup-guard.sh "$(mw "$T/other/notes.md" "$NEWMEM")")" ""
printf x >"$RE_MEMORY_DIR/existing.md"
eq "update of an existing memory ignored" "$(run memory-dup-guard.sh "$(mw "$RE_MEMORY_DIR/existing.md" "$NEWMEM")")" ""
out=$(JEV_MOCK=unavailable run memory-dup-guard.sh "$(mw "$RE_MEMORY_DIR/prs-not-drafts.md" "$NEWMEM")")
eq "Jev unavailable fails open (enforce mode)" "$out" ""
# egress: a memory inside an excluded (work) tree, or written from an excluded cwd, is never sent
mkdir -p "$HOME/work/acme/memory" "$HOME/Visa/app"
cp "$RE_MEMORY_DIR/MEMORY.md" "$HOME/work/acme/memory/MEMORY.md"
export JEV_MOCK_CAPTURE="$T/capture"
rm -f "$T/capture"
eq "memory under ~/work: no output" "$(run memory-dup-guard.sh "$(mw "$HOME/work/acme/memory/client-fact.md" "$NEWMEM")")" ""
[[ ! -s "$T/capture" ]] && ok || bad "memory under ~/work: Jev not called (egress)"
rm -f "$T/capture"
run memory-dup-guard.sh "$(jq -c --arg c "$HOME/Visa/app" '.cwd=$c' <<<"$(mw "$RE_MEMORY_DIR/prs-not-drafts.md" "$NEWMEM")")" >/dev/null
[[ ! -s "$T/capture" ]] && ok || bad "cwd under ~/Visa: Jev not called (egress)"
rm -f "$T/capture"
run memory-dup-guard.sh "$(jq -c --arg c "$HOME" '.cwd=$c' <<<"$(mw "work/acme/memory/rel-fact.md" "$NEWMEM")")" >/dev/null
[[ ! -s "$T/capture" ]] && ok || bad "relative path into ~/work from \$HOME: Jev not called (egress)"
unset JEV_MOCK_CAPTURE

echo "== stopfailure-hint + session-start-project =="
reset
cat >"$RE_MEMORY_DIR/cax80-5ghz-upload-defect.md" <<'EOF'
---
name: cax80-5ghz-upload-defect
description: "Home CAX80 router 5GHz radio corrupts large uploads (ECONNRESET); laptop pinned to 2.4GHz"
---
body
EOF
sfin() { jq -nc --arg e "$1" '{session_id:"sess-A",hook_event_name:"StopFailure",error:"unknown",error_details:$e}'; }
eq "StopFailure emits no stdout (harness ignores it)" "$(run stopfailure-hint.sh "$(sfin 'API Error: Unable to connect (ECONNRESET)')")" ""
STATEF="$HOME/.claude/jev/state/last-stopfailure.json"
[[ -f "$STATEF" ]] && ok || bad "hint state file written"
# only the error fields feed the classifier, not cwd / transcript_path / session_id
rm -f "$STATEF"
run stopfailure-hint.sh "$(jq -nc '{session_id:"billing-sess",cwd:"/work/billing-service",transcript_path:"/x/oauth-proxy/t.jsonl",error:"unknown",error_details:"weird gremlin 77"}')" >/dev/null
[[ ! -f "$STATEF" ]] && ok || bad "billing/oauth in a path must not classify the failure" "$(cat "$STATEF" 2>/dev/null)"
run stopfailure-hint.sh "$(jq -nc '{session_id:"s9",cwd:"/work/billing-service",error:"billing_error",error_details:"credit balance is too low"}')" >/dev/null
has "a real billing error is still classified" "$(cat "$STATEF" 2>/dev/null)" '"class":"billing"'
rm -f "$STATEF"
run stopfailure-hint.sh "$(sfin 'API Error: Unable to connect (ECONNRESET)')" >/dev/null
has "hint carries the memory fix" "$(cat "$STATEF")" "2.4GHz"
has "hint classifies as network_reset" "$(cat "$STATEF")" network_reset
ssi() { jq -nc --arg s "$1" --arg src "$2" --arg c "${3:-$T/nowhere}" '{session_id:$s,source:$src,cwd:$c}'; }
out=$(run session-start-project.sh "$(ssi sess-B resume)")
has "SessionStart(resume) injects the pending hint" "$out" '"hookEventName":"SessionStart"'
has "injected hint names the fix" "$out" "cax80-5ghz-upload-defect"
eq "hint is consumed once" "$(run session-start-project.sh "$(ssi sess-B resume)")" ""
run stopfailure-hint.sh "$(sfin 'API Error: ECONNRESET')" >/dev/null
eq "fresh startup in a different session does not get it" "$(run session-start-project.sh "$(ssi sess-C startup)")" ""
out=$(run session-start-project.sh "$(ssi sess-A startup)")
has "same-session SessionStart gets it" "$out" "ECONNRESET"
reset
run stopfailure-hint.sh "$(sfin 'weird gremlin 77')" >/dev/null
[[ ! -f "$STATEF" ]] && ok || bad "unknown error with no Jev writes no hint"
mock sf '{"answers":{"class":{"type":"choice","choice":"rate_limit","probabilities":{"rate_limit":0.95}}}}'
run stopfailure-hint.sh "$(sfin 'weird gremlin 77')" >/dev/null
[[ ! -f "$STATEF" ]] && ok || bad "shadow: Jev class does not create a hint"
loghas '"rule":"stopfailure-classify","verdict":"jev=rate_limit p=0.95"' && ok || bad "shadow classification logged"
rules '{"stopfailure-classify":{"mode":"enforce","threshold":0.8}}'
run stopfailure-hint.sh "$(sfin 'weird gremlin 77')" >/dev/null
has "enforce: Jev class selects the hint" "$(cat "$STATEF" 2>/dev/null)" rate_limit

echo "== session-start-project: project memories =="
reset
cat >"$RE_MEMORY_DIR/MEMORY.md" <<'EOF'
# Memory Index

- [ALCBF reconciliation](alcbf-2026-reconciliation.md) — DONE
- [Vercel project-pin footgun](vercel-project-pin-footgun.md) — pins to alocubano
- [Damilola profile](damilola-profile.md) — EM at Visa
EOF
ALC="$T/work/alocubano.com"
mkdir -p "$ALC"
git -C "$ALC" init -q
eq "shadow: no injection" "$(run session-start-project.sh "$(ssi s1 startup "$ALC")")" ""
loghas '"rule":"session-project-memories","verdict":"project=alcbf source=regex"' && ok || bad "shadow project classification logged"
rules '{"session-project-memories":{"mode":"enforce"}}'
out=$(run session-start-project.sh "$(ssi s1 startup "$ALC")")
has "enforce: injects alcbf memories" "$out" "alcbf-2026-reconciliation.md"
has "enforce: injects project-pin footgun" "$out" "vercel-project-pin-footgun.md"
hasnt "enforce: leaves unrelated memories out" "$out" "damilola-profile"
UNK="$T/work/mystery"
mkdir -p "$UNK"
git -C "$UNK" init -q
eq "unknown project, no Jev: nothing" "$(JEV_MOCK=unavailable run session-start-project.sh "$(ssi s1 startup "$UNK")")" ""
mock proj '{"answers":{"project":{"type":"choice","choice":"alcbf","probabilities":{"alcbf":0.93}}}}'
out=$(run session-start-project.sh "$(ssi s1 startup "$UNK")")
has "enforce: Jev choice fallback injects" "$out" "alcbf-2026-reconciliation.md"
eq "bg job: no project injection" "$(CLAUDE_JOB_DIR=/x run session-start-project.sh "$(ssi s1 startup "$ALC")")" ""

echo "== session-end-memory =="
reset
SE="$T/end.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"please add a test"}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"no, don'"'"'t open PRs as drafts, I said ready for review"}}'
} >"$SE"
se() { jq -nc --arg t "$1" '{session_id:"abcdef123456",transcript_path:$t,cwd:"/x/proj",reason:"other"}'; }
mock sem "$(bool_ans memory_worthy 0.92)"
eq "shadow: no output" "$(run session-end-memory.sh "$(se "$SE")")" ""
[[ ! -f "$MEMORY_CANDIDATES_FILE" ]] && ok || bad "shadow: candidate file not written"
loghas '"rule":"session-end-memory","verdict":"p=0.92"' && ok || bad "shadow p logged"
rules '{"session-end-memory":{"mode":"enforce","threshold":0.8}}'
run session-end-memory.sh "$(se "$SE")" >/dev/null
[[ -f "$MEMORY_CANDIDATES_FILE" ]] && ok || bad "enforce: candidate file created"
has "candidate carries the correction" "$(cat "$MEMORY_CANDIDATES_FILE")" "ready for review"
has "candidate carries session prefix + p" "$(cat "$MEMORY_CANDIDATES_FILE")" "abcdef12"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"please add a test"}}' >"$SE"
export JEV_MOCK_CAPTURE="$T/capture"
rm -f "$T/capture"
run session-end-memory.sh "$(se "$SE")" >/dev/null
[[ ! -s "$T/capture" ]] && ok || bad "no correction cue: Jev not called"
unset JEV_MOCK_CAPTURE
eq "bg job skipped" "$(CLAUDE_JOB_DIR=/x run session-end-memory.sh "$(se "$SE")")" ""

echo "== notification-urgency =="
reset
nf() { jq -nc --arg t "$1" --arg m "${2:-msg}" '{notification_type:$t,message:$m}'; }
run notification-urgency.sh "$(nf permission_prompt)" >/dev/null
loghas '"verdict":"play-urgent-regex"' && ok || bad "permission_prompt plays (regex urgent)"
reset
mock urg "$(bool_ans urgent 0.1)"
run notification-urgency.sh "$(nf idle_prompt 'Claude is waiting')" >/dev/null
loghas '"verdict":"play"' && ok || bad "shadow: sound policy unchanged (still plays)"
loghas '"verdict":"jev p=0.1"' && ok || bad "shadow: urgency logged"
reset
rules '{"notification-urgency":{"mode":"enforce","threshold":0.5}}'
mock urg "$(bool_ans urgent 0.1)"
run notification-urgency.sh "$(nf idle_prompt 'Claude is waiting')" >/dev/null
loghas '"verdict":"play"' && bad "enforce: not-urgent plays no sound" || ok
mock urg2 "$(bool_ans urgent 0.9)"
run notification-urgency.sh "$(nf idle_prompt 'build failed')" >/dev/null
loghas '"verdict":"play"' && ok || bad "enforce: urgent plays"
reset
JEV_MOCK=unavailable run notification-urgency.sh "$(nf idle_prompt)" >/dev/null
loghas '"verdict":"play-jev-unavailable"' && ok || bad "Jev unavailable: plays (fail open)"
reset
BARECLAUDE_AGENT_SLUG=clara run notification-urgency.sh "$(nf permission_prompt)" >/dev/null
[[ ! -f "$LOG" ]] && ok || bad "fleet guard: never plays"
CLAUDE_JOB_DIR=/x run notification-urgency.sh "$(nf permission_prompt)" >/dev/null
[[ ! -f "$LOG" ]] && ok || bad "bg-job guard: never plays"

echo "== postcompact-log =="
reset
run postcompact-log.sh '{"session_id":"abcdef123456","trigger":"auto","compact_summary":"secret summary text"}' >/dev/null
loghas "trigger=auto" && ok || bad "compaction logged"
contains "$(cat "$LOG")" "secret summary text" && bad "summary text must not be logged" || ok

echo "== claude-speak voice gate =="
BIN="$T/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ntouch "%s/curl.called"\nexit 0\n' "$T" >"$BIN/curl"
printf '#!/bin/sh\nexit 0\n' >"$BIN/afplay"
printf '#!/bin/sh\nexit 1\n' >"$BIN/nc"
chmod +x "$BIN"/*
touch "$HOME/.claude/voice.on"
speak() { # message → 0 when it would speak
  rm -f "$T/curl.called"
  jq -nc --arg m "$1" '{type:"assistant",message:{content:[{type:"text",text:$m}]}}' >"$T/speak.jsonl"
  printf '%s' "$(jq -nc --arg t "$T/speak.jsonl" '{transcript_path:$t,cwd:"/tmp"}')" |
    PATH="$BIN:$PATH" ELEVENLABS_API_KEY=k bash "$SRC/claude-speak.sh" >/dev/null 2>&1
  sleep 0.2
  [[ -f "$T/curl.called" ]]
}
for tg in ACTION DECISION APPROVAL INPUT BLOCKED; do
  speak "**$tg · need you.**"$'\nbody' && ok || bad "voice speaks for $tg"
done
speak $'**FYI · all good.**\nbody' && bad "voice must stay silent for FYI" || ok
speak 'Untagged plain reply.' && bad "voice must stay silent when untagged" || ok
speak $'\n**ACTION · leading blank line.**' && ok || bad "voice speaks when line 1 follows blank lines"
CLAUDE_JOB_DIR=/x speak '**ACTION · bg.**' && bad "bg job stays silent" || ok

echo "== workflow helpers =="
SKILLS="$SRC/skills"
reset
# --- process-linear presort -----------------------------------------------------------
TK='[{"id":"ENG-1","title":"Approve spend","state":"Blocked"},{"id":"OPS-2","title":"Fix typo","state":"In Review"},{"id":"ENG-3","title":"Rotate key","state":"Blocked"}]'
mock ps '{"answers":{"t0":{"type":"boolean","probability":0.9},"t1":{"type":"boolean","probability":0.1},"t2":{"type":"boolean","probability":0.7}}}'
export JEV_MOCK_CAPTURE="$T/capture"
out=$(printf '%s' "$TK" | bash "$SKILLS/process-linear/scripts/presort.sh")
eq "presort shadow: mode shadow, results empty" "$(jq -c '[.mode,(.results|length)]' <<<"$out")" '["shadow",0]'
has "presort sends titles+states only (no bodies key)" "$(cat "$T/capture")" "Approve spend"
rules '{"workflow-linear-presort":{"mode":"enforce","threshold":0.5}}'
out=$(printf '%s' "$TK" | bash "$SKILLS/process-linear/scripts/presort.sh")
eq "presort enforce: sorted by p desc" "$(jq -c '[.results[].id]' <<<"$out")" '["ENG-1","ENG-3","OPS-2"]'
eq "presort enforce: hints" "$(jq -c '[.results[].hint]' <<<"$out")" '["likely-needs-d","likely-needs-d","likely-not-d"]'
out=$(printf '%s' "$TK" | JEV_MOCK=unavailable bash "$SKILLS/process-linear/scripts/presort.sh")
eq "presort fails open when Jev unavailable" "$(jq -c '[.mode,(.results|length)]' <<<"$out")" '["unavailable",0]'
eq "presort rejects non-array input without failing" "$(printf 'garbage' | bash "$SKILLS/process-linear/scripts/presort.sh" | jq -r .mode)" unavailable
unset JEV_MOCK_CAPTURE
# --- commit / branch classify ----------------------------------------------------------
reset
CR="$T/commit-repo"
mkdir -p "$CR/tests"
git -C "$CR" init -q && git -C "$CR" config user.email t@t && git -C "$CR" config user.name t
printf a >"$CR/seed" && git -C "$CR" add . && git -C "$CR" commit -qm seed
printf t >"$CR/tests/a.test.sh" && git -C "$CR" add tests
mock cc '{"answers":{"type":{"type":"choice","choice":"test","probabilities":{"test":0.88,"chore":0.1}},"mixed":{"type":"boolean","probability":0.2}}}'
out=$(cd "$CR" && bash "$SKILLS/commit/scripts/classify.sh" commit)
eq "commit classify shadow: deterministic type only" "$(jq -c '[.mode,.deterministic_type,(.type // "none")]' <<<"$out")" '["shadow","test","none"]'
rules '{"workflow-commit-type":{"mode":"enforce"},"workflow-commit-mixed":{"mode":"enforce","threshold":0.8}}'
out=$(cd "$CR" && bash "$SKILLS/commit/scripts/classify.sh" commit)
eq "commit classify enforce: type + mixed" "$(jq -c '[.mode,.type,.mixed]' <<<"$out")" '["enforce","test",false]'
mock cm '{"answers":{"type":{"type":"choice","choice":"feat","probabilities":{"feat":0.9}},"mixed":{"type":"boolean","probability":0.95}}}'
out=$(cd "$CR" && bash "$SKILLS/commit/scripts/classify.sh" commit)
eq "commit classify enforce: mixed concerns flagged" "$(jq -r .mixed <<<"$out")" true
mock br '{"answers":{"type":{"type":"choice","choice":"fix","probabilities":{"fix":0.9}},"mixed":{"type":"boolean","probability":0.1}}}'
rules '{"workflow-branch-type":{"mode":"enforce"}}'
out=$(cd "$CR" && bash "$SKILLS/commit/scripts/classify.sh" branch "fix-auth-bug")
eq "branch classify enforce: type" "$(jq -r '.type' <<<"$out")" fix
out=$(cd "$CR" && JEV_MOCK=unavailable bash "$SKILLS/commit/scripts/classify.sh" commit)
eq "classify fails open" "$(jq -r .mode <<<"$out")" unavailable
# --- review depth ----------------------------------------------------------------------
reset
RR="$T/review-repo"
mkdir -p "$RR/docs" "$RR/hooks"
git -C "$RR" init -q -b main && git -C "$RR" config user.email t@t && git -C "$RR" config user.name t
printf a >"$RR/README.md" && git -C "$RR" add . && git -C "$RR" commit -qm seed
git -C "$RR" checkout -q -b feat/x
printf d >"$RR/docs/a.md" && git -C "$RR" add . && git -C "$RR" commit -qm doc
out=$(cd "$RR" && bash "$SKILLS/review/scripts/depth.sh")
eq "docs-only change: floor single" "$(jq -r '[.floor,.depth]|join(",")' <<<"$out")" single,single
mock rd '{"answers":{"risk":{"type":"score","score":2.8,"level":3}}}'
out=$(cd "$RR" && bash "$SKILLS/review/scripts/depth.sh")
eq "shadow: Jev risk never raises depth" "$(jq -r .depth <<<"$out")" single
rules '{"workflow-review-depth":{"mode":"enforce"}}'
out=$(cd "$RR" && bash "$SKILLS/review/scripts/depth.sh")
eq "enforce: Jev level 3 raises to deep" "$(jq -r '[.depth,.risk_level]|join(",")' <<<"$out")" deep,3
mock rd0 '{"answers":{"risk":{"type":"score","score":0.1,"level":0}}}'
out=$(cd "$RR" && bash "$SKILLS/review/scripts/depth.sh")
eq "enforce: Jev level 0 keeps single" "$(jq -r .depth <<<"$out")" single
printf h >"$RR/hooks/guard.sh" && git -C "$RR" add . && git -C "$RR" commit -qm hook
rules '{}'
out=$(cd "$RR" && bash "$SKILLS/review/scripts/depth.sh")
eq "hooks/ change: deterministic floor deep even in shadow" "$(jq -r '[.floor,.depth]|join(",")' <<<"$out")" deep,deep
rules '{"workflow-review-depth":{"mode":"enforce"}}'
out=$(cd "$RR" && bash "$SKILLS/review/scripts/depth.sh")
eq "enforce: Jev level 0 never lowers below the floor" "$(jq -r .depth <<<"$out")" deep
hasnt "depth helper never emits approve" "$out" approve
# --- failure classify ------------------------------------------------------------------
reset
fc() { printf '%s' "$2" | bash "$HOOKS/failure-classify.sh" "$1"; }
eq "ci: ECONNRESET log is infra (regex)" "$(fc ci 'npm ERR! ECONNRESET registry' | jq -r '[.class,.source]|join(",")')" infra,regex
has "ci infra steer: rerun failed once" "$(fc ci 'The runner has received a shutdown signal')" "rerun"
eq "ci: Test timeout is flaky (regex)" "$(fc ci 'Error: Test timeout of 30000ms exceeded.' | jq -r .class)" flaky
eq "ci: AssertionError is real (regex)" "$(fc ci 'AssertionError: expected 1 to equal 2' | jq -r .class)" real
eq "verify: command not found is env (regex)" "$(fc verify 'bash: shellcheck: command not found' | jq -r .class)" env
eq "verify: relative missing module is not env" "$(fc verify "Cannot find module './foo'" | jq -r .class)" unknown
eq "verify: package missing module is NOT env (ambiguous: undeclared dependency or import typo)" "$(fc verify "Cannot find module 'left-pad'" | jq -r .class)" unknown
eq "verify: python ModuleNotFoundError is NOT env either" "$(fc verify "ModuleNotFoundError: No module named 'requests'" | jq -r '.class')" unknown
eq "verify: a missing module does not carry the do-not-edit-code steer" "$(fc verify "Cannot find module 'left-pad'" | jq -r '.steer')" ""
eq "verify: assertion (regex)" "$(fc verify 'AssertionError: expected 401, received 500' | jq -r .class)" assertion
eq "verify: assertion failure mentioning ENOENT stays assertion" "$(fc verify $'FAIL src/a.test.ts\nAssertionError: expected 1 to equal 2\nENOENT: no such file or directory, open fixture.json' | jq -r .class)" assertion
has "verify env steer: do not edit code" "$(fc verify 'command not found: tsc')" "do not edit code"
mock fcm '{"answers":{"class":{"type":"choice","choice":"flaky","probabilities":{"flaky":0.9}}}}'
eq "unmatched log, shadow: unknown" "$(fc ci 'something odd happened' | jq -r .class)" unknown
rules '{"workflow-ci-class":{"mode":"enforce","threshold":0.7}}'
eq "unmatched log, enforce: Jev class" "$(fc ci 'something odd happened' | jq -r '[.class,.source]|join(",")')" flaky,jev
eq "unmatched log, Jev unavailable: unknown (fail open)" "$(printf 'something odd' | JEV_MOCK=unavailable bash "$HOOKS/failure-classify.sh" ci | jq -r .class)" unknown
# --- webapp-testing click picker ---------------------------------------------------------
reset
CANDS=$'#save\tSave\n#cancel\tCancel\n#help\tHelp'
eq "pick_target: exact quoted text wins (regex)" "$(printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'click the "Cancel" button' | jq -r '[.selector,.source]|join(",")')" "#cancel,regex"
mock pt '{"answers":{"target":{"type":"choice","choice":"c2","probabilities":{"c2":0.9}}}}'
eq "pick_target shadow: no Jev pick returned" "$(printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' | jq -r .selector)" ""
rules '{"workflow-click-target":{"mode":"enforce"}}'
eq "pick_target enforce: Jev pick" "$(printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' | jq -r .selector)" "#help"
mock pt '{"answers":{"target":{"type":"choice","choice":"c2","probabilities":{"c2":0.3}}}}'
eq "pick_target enforce: pick below the rule threshold returns no selector" "$(printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' | jq -r .selector)" ""
rules '{"workflow-click-target":{"mode":"enforce","threshold":0.2}}'
eq "pick_target enforce: threshold from rules is honoured" "$(printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' | jq -r .selector)" "#help"
rules '{"workflow-click-target":{"mode":"enforce"}}'
for bad_ch in 'c9' 'foo' 'c1x' 'a[$(touch '"$T"'/pwned)]'; do
  mock pt "$(jq -nc --arg c "$bad_ch" '{answers:{target:{type:"choice",choice:$c,probabilities:{($c):0.95}}}}')"
  eq "pick_target enforce: invalid choice [$bad_ch] returns no selector" "$(printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' | jq -r .selector)" ""
done
[[ ! -e "$T/pwned" ]] && ok || bad "pick_target must not evaluate the model's choice as arithmetic"
out=$(bash "$SKILLS/webapp-testing/scripts/pick_target.sh" --help </dev/null)
has "pick_target --help prints usage without reading stdin" "$out" "pick_target.sh"
mock pt '{"answers":{"target":{"type":"choice","choice":"c2","probabilities":{"c2":0.9}}}}'
export JEV_MOCK_CAPTURE="$T/capture"
rm -f "$T/capture"
printf '%s' "$CANDS" | bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' >/dev/null
eq "pick_target keeps page text in the untrusted field" "$(jq -r '.untrusted.candidates.c0' "$T/capture")" $'#save\tSave'
hasnt "pick_target keeps page text out of state" "$(jq -c .state "$T/capture")" "Cancel"
unset JEV_MOCK_CAPTURE
eq "pick_target fails open" "$(printf '%s' "$CANDS" | JEV_MOCK=unavailable bash "$SKILLS/webapp-testing/scripts/pick_target.sh" 'open the assistance panel' | jq -r .selector)" ""
# --- SKILL.md wiring ---------------------------------------------------------------------
for pair in "process-linear:scripts/presort.sh" "commit:scripts/classify.sh" "branch:commit/scripts/classify.sh" \
  "review:scripts/depth.sh" "fix-ci:failure-classify.sh" "verify:failure-classify.sh" "webapp-testing:scripts/pick_target.sh"; do
  s="${pair%%:*}"
  w="${pair#*:}"
  grep -qF -- "$w" "$SKILLS/$s/SKILL.md" && ok || bad "$s/SKILL.md references helper $w"
done

echo "== rules registry + generated table + skill-overlap =="
env -u RE_MEMORY_DIR python3 "$REPO_ROOT/scripts/rules-table.py" --check >"$T/rt.out" 2>&1 && ok || bad "rules-table.py --check (registry valid, docs/rules-enforcement.md up to date)" "$(head -20 "$T/rt.out")"
python3 "$REPO_ROOT/scripts/skill-overlap.py" --self-test >"$T/so.out" 2>&1 && ok || bad "skill-overlap.py --self-test" "$(head -20 "$T/so.out")"
# stub jev-ask that routes each prompt to its expected skill, with commit<->push bleed
cat >"$T/stub-jev" <<'EOF'
#!/bin/bash
req=$(cat)
prompt=$(jq -r '.state.prompt' <<<"$req")
exp=$(jq -r --arg p "$prompt" '[.. | objects | select(.prompt? == $p) | .skill][0] // empty' "$STUB_FIXTURE")
jq -nc --arg e "$exp" --argjson q "$(jq -c '.questions.skill.criteria' <<<"$req")" '
  ($q | keys) as $ks |
  {answers:{skill:{type:"choice",choice:$e,
    probabilities:( [$ks[] | {key:., value:(if .==$e then 0.7 elif ($e=="commit" and .=="push") or ($e=="push" and .=="commit") then 0.25 else 0.01 end)}] | from_entries )}},
   model:"stub",latency_ms:1,cost_usd:0}'
EOF
chmod +x "$T/stub-jev"
STUB_FIXTURE="$REPO_ROOT/tests/fixtures/skill-prompts.json" JEV_ASK="$T/stub-jev" \
  python3 "$REPO_ROOT/scripts/skill-overlap.py" --out "$T/overlap.md" >"$T/so2.out" 2>&1 && ok || bad "skill-overlap.py runs against stub Jev" "$(head -20 "$T/so2.out")"
[[ -f "$T/overlap.md" ]] && ok || bad "overlap report written"
has "overlap report flags the commit/push collision" "$(cat "$T/overlap.md" 2>/dev/null)" "commit"
has "overlap report lists a collisions table" "$(cat "$T/overlap.md" 2>/dev/null)" "| commit"

echo
echo "jev rules/events tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
