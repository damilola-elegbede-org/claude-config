#!/usr/bin/env bash
# Tests for the Jev context/cost hooks (Phase 3, A1-A8) in system-configs/.claude/hooks/jev/.
#
# Jev is never called: the scripts run from a temp HOME that holds a STUB jev-ask implementing the
# client contract's JEV_MOCK switch (fixture file -> stdout, exit 0; "unavailable" -> exit 3) and
# recording every request. CI never touches the Gateway; the real HOME is never touched.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO_ROOT}/system-configs/.claude/hooks/jev"

if ! command -v jq >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq is not installed; the Jev hooks fail open without it." >&2
    exit 1
  fi
  echo "SKIP: jq not installed (would FAIL in CI)" >&2
  exit 0
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { # check <desc> <command...>
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/jev-ctx-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
export TMPDIR="$TMPROOT"

# ------------------------------------------------------------------ helpers

setup_home() { # fresh deployed layout in a temp HOME
  TEST_HOME="$(mktemp -d "${TMPROOT}/home.XXXXXX")"
  export HOME="$TEST_HOME"
  mkdir -p "$HOME/.claude/hooks/jev"
  cp -R "$SRC/." "$HOME/.claude/hooks/jev/"
  cat >"$HOME/.claude/hooks/jev/jev-ask" <<'EOF'
#!/bin/bash
# test stub of the Jev client: contract JEV_MOCK semantics + request capture
echo x >>"${STUB_COUNT:?}"
cat >"${STUB_LAST:?}"
case "${JEV_MOCK:-}" in
  "" | unavailable) exit 3 ;;
  *) cat "$JEV_MOCK"; exit 0 ;;
esac
EOF
  chmod +x "$HOME/.claude/hooks/jev/jev-ask" "$HOME/.claude/hooks/jev/"*.sh
  export STUB_COUNT="$TEST_HOME/stub.count"
  export STUB_LAST="$TEST_HOME/stub.last"
  : >"$STUB_COUNT"
  unset BARECLAUDE_AGENT_SLUG CLAUDE_JOB_DIR
  SHADOW="$HOME/.claude/jev-shadow.jsonl"
  OUTF="$TEST_HOME/hook.out"
  IN="$TEST_HOME/in.json"
}

calls() { wc -l <"$STUB_COUNT" | tr -d ' '; }

set_rule() { # set_rule <rule> <json-object-of-overrides>  -> jev-rules.json (registry override)
  local f="$HOME/.claude/hooks/jev/jev-rules.json" cur='{}'
  [[ -f "$f" ]] && cur="$(cat "$f")"
  printf '%s' "$cur" | jq --arg r "$1" --argjson x "$2" '.rules[$r] = ((.rules[$r] // {}) + $x)' >"$f.new" && mv "$f.new" "$f"
}
set_mode() { set_rule "$1" "{\"mode\":\"$2\"}"; }

# bool_fixture <outfile> <name=p> ... -> a reply holding boolean answers
bool_fixture() {
  local out="$1"
  shift
  local kv args=()
  for kv in "$@"; do args+=("${kv%%=*}" "${kv#*=}"); done
  jq -n '$ARGS.positional as $p | [range(0; $p | length; 2) as $i | {key: $p[$i], value: {type: "boolean", probability: ($p[$i + 1] | tonumber)}}] | from_entries | {answers: ., model: "mock", latency_ms: 1, cost_usd: 0}' \
    --args "${args[@]}" >"$out"
}

transcript() { # transcript <file> <prompt>: real prompt, then an assistant turn and a tool_result-only turn
  jq -cn --arg p "$2" '
    ({type:"user", message:{role:"user", content:[{type:"text", text:$p}]}},
     {type:"assistant", message:{role:"assistant", content:[{type:"text", text:"working"}]}},
     {type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"output"}]}})' >"$1"
}

run_hook() { # run_hook <script> <input-file>   -> $OUTF (stdout), HOOK_RC
  "$HOME/.claude/hooks/jev/$1" <"$2" >"$OUTF" 2>"$TEST_HOME/stderr"
  HOOK_RC=$?
}

numbered_lines() { # numbered_lines <n> <prefix>
  local i
  for ((i = 1; i <= $1; i++)); do printf '%s %d some filler text for the line\n' "$2" "$i"; done
}

out_empty() { [[ ! -s "$OUTF" ]]; }
# The harness drops an updatedToolOutput whose shape does not match the tool's own output (probe: a
# plain string is silently ignored). So the emitted object must keep EVERY key of the original
# tool_response (and, for Read, of .file), changing only the text field.
keys_kept() { # keys_kept [file-subobject?]  compares against the hook input in $IN
  jq -e --slurpfile i "$IN" '
    ($i[0].tool_response) as $r | .hookSpecificOutput.updatedToolOutput as $u
    | (($u | type) == "object") and (($r | keys) == ($u | keys))
      and ((($r.file? // null) | type) != "object" or (($r.file | keys) == ($u.file | keys)))' "$OUTF" >/dev/null
}
out_jq() { jq -e "$1" "$OUTF" >/dev/null; }
shadow_jq() { jq -e "select($1)" "$SHADOW" >/dev/null; }
shadow_lacks() { ! grep -q -- "$1" "$SHADOW" 2>/dev/null; }
no_new_calls() { [[ "$(calls)" == "$1" ]]; }
has_fixed() { grep -qF -- "$2" "$1"; }
lacks_fixed() { ! grep -qF -- "$2" "$1"; }
# GNU stat first: on Linux `stat -f` prints file-system info and succeeds, so the BSD form must be the fallback.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

read_input() { # read_input <file> <transcript> [tool_input-extras]  (content = the file itself)
  local extras="${3:-}"
  [[ -n "$extras" ]] || extras='{}'
  jq -cn --arg f "$1" --rawfile c "$1" --arg t "$2" --argjson ti "$extras" '
    ($c | split("\n") | if .[-1] == "" then .[:-1] else . end | length) as $n
    | {session_id: "s1", cwd: "/tmp", transcript_path: $t, hook_event_name: "PostToolUse", tool_name: "Read",
       tool_input: ({file_path: $f} + $ti),
       tool_response: {type: "text", file: {filePath: $f, content: $c, numLines: $n, startLine: 1, totalLines: $n}}}' >"$IN"
}

# ------------------------------------------------------------------ A1: Read trim
echo "A1 read-trim"
setup_home
BIG="$TEST_HOME/big.txt"
numbered_lines 600 line >"$BIG"
TR="$TEST_HOME/t.jsonl"
transcript "$TR" "explain how the parser handles retries"
FIX="$TEST_HOME/fix.json"
bool_fixture "$FIX" c0=0.1 c1=0.1 c2=0.9 c3=0.8 c4=0.05 c5=0.1 will_edit=0.05
read_input "$BIG" "$TR"

# shadow (pinned explicitly; rules.d ships enforce): logs what it would trim, prints nothing, saves nothing
# The fixture's 6 chunks and 200-line budget assume the pre-retune knobs; rules.d now ships chunk 50 /
# threshold 0.15 / budget 300-800, so pin the old values here rather than loosen the assertions.
set_rule A1-read-trim '{"mode":"shadow","threshold":0.35,"chunk_lines":100,"budget_floor":200,"budget_ceiling":600,"budget_frac":0.35}'
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "shadow: exit 0" test "$HOOK_RC" -eq 0
check "shadow: no stdout, output untouched" out_empty
check "shadow: logged would-trim" shadow_jq '.rule=="A1-read-trim" and .detail.decision=="would-trim"'
check "shadow: logged 200 of 600 lines kept" shadow_jq '.detail.kept_lines==200 and .detail.lines==600'
check "shadow: nothing saved to cache" test ! -d "$HOME/.claude/jev-cache"
check "shadow: log carries no file content" shadow_lacks 'some filler text'
check "request: 1 call, 6 untrusted chunk digests, task in state, will_edit asked" \
  jq -e '.rule=="A1-read-trim" and (.untrusted.chunks|length)==6 and (.state.task|test("parser")) and .questions.will_edit.type=="boolean"' "$STUB_LAST"
check "request: one Jev call" test "$(calls)" = 1

# enforce: trimmed output with markers, original line numbers, cache file
set_mode A1-read-trim enforce
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "enforce: exit 0" test "$HOOK_RC" -eq 0
check "enforce: PostToolUse updatedToolOutput" out_jq '.hookSpecificOutput.hookEventName=="PostToolUse"'
jq -r '.hookSpecificOutput.updatedToolOutput.file.content' "$OUTF" >"$TEST_HOME/content.txt"
CACHED="$(ls "$HOME"/.claude/jev-cache/*.txt 2>/dev/null | head -1)"
check "enforce: head line states 200 of 600 and the file" grep -q 'showing 200 of 600 lines of .*big.txt' "$TEST_HOME/content.txt"
check "enforce: leading gap marker" has_fixed "$TEST_HOME/content.txt" '[lines 1–200 trimmed: re-read with offset=1 limit=200]'
check "enforce: trailing gap marker" has_fixed "$TEST_HOME/content.txt" '[lines 401–600 trimmed: re-read with offset=401 limit=200]'
check "enforce: kept lines verbatim, ORIGINAL line numbers" has_fixed "$TEST_HOME/content.txt" $'201\tline 201 some filler text for the line'
check "enforce: last kept line is 400" has_fixed "$TEST_HOME/content.txt" $'400\tline 400 some filler'
check "enforce: trimmed lines are gone" lacks_fixed "$TEST_HOME/content.txt" 'line 150 '
check "enforce: emitted object has exactly the original keys (type, file.*)" keys_kept
check "enforce: response fields kept, numLines refreshed" \
  out_jq '.hookSpecificOutput.updatedToolOutput | .type=="text" and .file.filePath!=null and .file.totalLines==600 and .file.numLines<600'
check "enforce: full text saved verbatim" cmp -s "$BIG" "$CACHED"
check "enforce: head line cites the saved path" has_fixed "$TEST_HOME/content.txt" "$CACHED"
check "enforce: cache file private (0600)" test "$(file_mode "$CACHED")" = 600
check "enforce: logged trimmed" shadow_jq '.detail.decision=="trimmed"'

# gates that leave output untouched
B="$(calls)"
read_input "$BIG" "$TR" '{"offset":10,"limit":300}'
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "offset/limit given: untouched" out_empty
check "offset/limit given: no call made" no_new_calls "$B"
SMALL="$TEST_HOME/small.txt"
numbered_lines 399 line >"$SMALL"
read_input "$SMALL" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "<=400 lines: untouched" out_empty
check "<=400 lines: no call made" no_new_calls "$B"
read_input "$BIG" "$TR"
JEV_MOCK=unavailable run_hook a1-read-trim.sh "$IN"
check "Jev unavailable (exit 3): untouched, exit 0" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"
JEV_MOCK="$TEST_HOME/does-not-exist.json" run_hook a1-read-trim.sh "$IN"
check "missing reply: untouched, exit 0" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"
printf 'not json' >"$TEST_HOME/bad.json"
JEV_MOCK="$TEST_HOME/bad.json" run_hook a1-read-trim.sh "$IN"
check "malformed reply: untouched, exit 0" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"
bool_fixture "$TEST_HOME/edit.json" c0=0.1 c1=0.1 c2=0.9 c3=0.8 c4=0.05 c5=0.1 will_edit=0.9
JEV_MOCK="$TEST_HOME/edit.json" run_hook a1-read-trim.sh "$IN"
check "Jev says will_edit: untouched" out_empty
bool_fixture "$TEST_HOME/low.json" c0=0.1 c1=0.1 c2=0.1 c3=0.1 c4=0.05 c5=0.1 will_edit=0.0
JEV_MOCK="$TEST_HOME/low.json" run_hook a1-read-trim.sh "$IN"
check "nothing reaches threshold: keeps the single best chunk" out_jq '.hookSpecificOutput.updatedToolOutput.file.content | test("showing 100 of 600")'
touch "$HOME/.claude/jev.off"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "kill switch ~/.claude/jev.off: untouched" out_empty
rm -f "$HOME/.claude/jev.off"
set_rule A1-read-trim '{"scope":["interactive"]}'
BARECLAUDE_AGENT_SLUG=clara JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "scope: fleet agent outside the rule's scope -> untouched" out_empty
CLAUDE_JOB_DIR=/tmp/job JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "scope: bg job outside the rule's scope -> untouched" out_empty
set_mode A1-read-trim off
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "mode off: untouched" out_empty
set_rule A1-read-trim '{"mode":"enforce","scope":["interactive","bgjob","fleet"]}'
rm -rf "$HOME/.claude/jev-cache"
set_rule A1-read-trim '{"min_saving":0.9}'
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "saving below min_saving: untouched" out_empty
check "untrimmed output never touches the disk" bash -c "! ls '$HOME'/.claude/jev-cache/*.txt >/dev/null 2>&1"
set_rule A1-read-trim '{"min_saving":0.2}'

# egress: excluded (work) trees are never digested, wherever the session was started
mkdir -p "$TEST_HOME/visa-repo"
numbered_lines 600 secret >"$TEST_HOME/visa-repo/secret.txt"
printf '{"exclude_paths":["~/not-here","%s/visa-repo/"]}' "$TEST_HOME" >"$HOME/.claude/hooks/jev/jev-config.json"
B="$(calls)"
read_input "$TEST_HOME/visa-repo/secret.txt" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "file under exclude_paths: untouched" out_empty
check "file under exclude_paths: no Jev call (nothing leaves the machine)" no_new_calls "$B"
check "file under exclude_paths: reason logged" shadow_jq '.detail.why=="excluded-path"'
read_input "$BIG" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "file outside exclude_paths still trimmed" out_jq '.hookSpecificOutput.updatedToolOutput.file.content | test("trimmed")'
# same semantics as the client: HOME-anchored, case-insensitive, segment boundary, symlinks resolved
mkdir -p "$TEST_HOME/visa" "$TEST_HOME/proj/work/x" "$TEST_HOME/visaform"
numbered_lines 600 secret >"$TEST_HOME/visa/s.txt"
numbered_lines 600 plain >"$TEST_HOME/proj/work/x/ok.txt"
numbered_lines 600 plain >"$TEST_HOME/visaform/ok.txt"
ln -sfn "$TEST_HOME/visa" "$TEST_HOME/linked-visa"
printf '{"exclude_paths":["~/Visa","/work/"]}' >"$HOME/.claude/hooks/jev/jev-config.json"
B="$(calls)"
read_input "$TEST_HOME/visa/s.txt" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
# shellcheck disable=SC2088 # literal tilde in a test description
check "~/Visa entry excludes ~/visa/... (case-insensitive)" no_new_calls "$B"
read_input "$TEST_HOME/linked-visa/s.txt" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "a symlink into an excluded tree is excluded (realpath)" no_new_calls "$B"
read_input "$TEST_HOME/proj/work/x/ok.txt" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "a bare /work/ substring no longer excludes an unrelated path" bash -c "! [[ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" == '$B' ]]"
B="$(calls)"
read_input "$TEST_HOME/visaform/ok.txt" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
# shellcheck disable=SC2088 # literal tilde in a test description
check "~/Visa does not exclude the sibling ~/visaform (segment boundary)" bash -c "! [[ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" == '$B' ]]"
printf '{not json' >"$HOME/.claude/hooks/jev/jev-config.json"
B="$(calls)"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "unreadable jev-config.json: fail closed on egress (no call)" no_new_calls "$B"
rm -f "$HOME/.claude/hooks/jev/jev-config.json"

# "about to Edit" protection: tracked file + edit intent, or uncommitted changes
REPO="$TEST_HOME/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
numbered_lines 600 code >"$REPO/mod.js"
git -C "$REPO" add mod.js
git -C "$REPO" commit -q -m init
transcript "$TR" "fix the retry bug in mod.js"
read_input "$REPO/mod.js" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "tracked file + edit intent: untouched" out_empty
check "tracked file + edit intent: reason logged" shadow_jq '.detail.why=="tracked-file-and-edit-intent"'
transcript "$TR" "explain how mod.js handles retries"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "tracked file, question-only task: trimmed" out_jq '.hookSpecificOutput.updatedToolOutput.file.content | test("trimmed")'
echo "// wip" >>"$REPO/mod.js"
read_input "$REPO/mod.js" "$TR"
JEV_MOCK="$FIX" run_hook a1-read-trim.sh "$IN"
check "uncommitted changes: untouched even for a question" out_empty
check "uncommitted changes: reason logged" shadow_jq '.detail.why=="uncommitted-changes"'

# ------------------------------------------------------------------ A2: Grep/Glob ranking
echo "A2 search-rank"
setup_home
TR="$TEST_HOME/t.jsonl"
transcript "$TR" "where is the retry backoff implemented"
FIX="$TEST_HOME/fix.json"
bool_fixture "$FIX" c0=0.1 c1=0.9 c2=0.1 c3=0.8 c4=0.7 c5=0.1
HITS="$TEST_HOME/hits.txt"
numbered_lines 150 src/file >"$HITS"
jq -cn --rawfile c "$HITS" --arg t "$TR" '{session_id:"s2", cwd:"/tmp", transcript_path:$t, tool_name:"Grep",
  tool_input:{pattern:"retry", output_mode:"content"},
  tool_response:{mode:"content", numFiles:0, filenames:[], content:$c, numLines:150}}' >"$IN"
# pin shadow plus the pre-retune A2 knobs (rules.d now ships 0.25 / 150-300 / 0.3) so kept_lines stays 75
set_rule A2-search-rank '{"mode":"shadow","threshold":0.35,"budget_floor":100,"budget_ceiling":100,"budget_frac":0}'
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep shadow: nothing printed" out_empty
check "Grep shadow: would-trim logged (75 of 150 hits)" shadow_jq '.rule=="A2-search-rank" and .detail.decision=="would-trim" and .detail.kept_lines==75'
set_mode A2-search-rank enforce
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
jq -r '.hookSpecificOutput.updatedToolOutput.content' "$OUTF" >"$TEST_HOME/content.txt"
CACHED="$(ls "$HOME"/.claude/jev-cache/*.txt 2>/dev/null | head -1)"
check "Grep enforce: ranked hits kept in original order, verbatim" has_fixed "$TEST_HOME/content.txt" 'src/file 26 some filler text for the line'
check "Grep enforce: unranked hits dropped" lacks_fixed "$TEST_HOME/content.txt" 'src/file 3 some filler'
check "Grep enforce: marker with count and saved path" has_fixed "$TEST_HOME/content.txt" "[hits 1–25 trimmed (25 omitted): full list at $CACHED]"
check "Grep enforce: full list saved" cmp -s "$HITS" "$CACHED"
check "Grep enforce: hits are not line-numbered" lacks_fixed "$TEST_HOME/content.txt" $'26\tsrc/file'
check "Grep enforce: other fields preserved" out_jq '.hookSpecificOutput.updatedToolOutput | .mode=="content" and .numLines==150'
check "Grep enforce: emitted object has exactly the original keys" keys_kept

# Glob: filenames array
GL="$TEST_HOME/glob.txt"
numbered_lines 130 pkg/mod >"$GL"
jq -cn --rawfile c "$GL" --arg t "$TR" '{session_id:"s2", cwd:"/tmp", transcript_path:$t, tool_name:"Glob",
  tool_input:{pattern:"**/*.js"},
  tool_response:{filenames: ($c | split("\n") | .[:-1]), numFiles:130, durationMs:4, truncated:false}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Glob enforce: filenames stay an array with markers inside" out_jq '.hookSpecificOutput.updatedToolOutput.filenames | type=="array" and any(.[]; test("^\\[hits ")) and (map(select(test("^pkg/mod 2[6-9] "))) | length) > 0'
check "Glob enforce: fewer entries than before" out_jq '(.hookSpecificOutput.updatedToolOutput.filenames | length) < 130'
check "Glob enforce: numFiles untouched" out_jq '.hookSpecificOutput.updatedToolOutput.numFiles==130'
check "Glob enforce: emitted object has exactly the original keys" keys_kept
B="$(calls)"
numbered_lines 100 pkg/mod >"$GL"
jq -cn --rawfile c "$GL" '{tool_name:"Glob", tool_input:{pattern:"*"}, tool_response:{filenames: ($c | split("\n") | .[:-1]), numFiles:100}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "exactly 100 hits: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
jq -cn --rawfile c "$HITS" '{tool_name:"Grep", tool_input:{pattern:"x", output_mode:"content", head_limit:300}, tool_response:{content:$c, numLines:150}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep with head_limit: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
jq -cn --rawfile c "$HITS" '{tool_name:"Grep", tool_input:{pattern:"x"}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK=unavailable run_hook a2-search-rank.sh "$IN"
check "Jev unavailable: untouched" out_empty
B="$(calls)"
printf '{"exclude_paths":["%s/visa-repo"]}' "$TEST_HOME" >"$HOME/.claude/hooks/jev/jev-config.json"
jq -cn --rawfile c "$HITS" --arg p "$TEST_HOME/visa-repo/src" '{tool_name:"Grep", tool_input:{pattern:"x", path:$p}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep path under exclude_paths: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
jq -cn --rawfile c "$HITS" --arg cwd "$TEST_HOME/visa-repo" '{tool_name:"Grep", cwd:$cwd, tool_input:{pattern:"x"}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep with NO path in an excluded cwd: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
jq -cn --rawfile c "$HITS" --arg cwd "$TEST_HOME/visa-repo" '{tool_name:"Grep", cwd:$cwd, tool_input:{pattern:"x", path:"src"}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep with a RELATIVE path resolved against an excluded cwd: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
# a search rooted at a clean ancestor whose hits come from an excluded descendant
mkdir -p "$TEST_HOME/other"
{ for i in $(seq 1 150); do printf '%s/other/a.txt:%s:clean line %s\n' "$TEST_HOME" "$i" "$i"; done
  printf '%s/visa-repo/secret.ts:7:CONFIDENTIAL work line\n' "$TEST_HOME"; } >"$TEST_HOME/mixed-hits.txt"
jq -cn --rawfile c "$TEST_HOME/mixed-hits.txt" --arg p "$TEST_HOME" --arg cwd "$TEST_HOME/other" '{tool_name:"Grep", cwd:$cwd, tool_input:{pattern:"line", path:$p}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep of a clean ancestor with ONE hit inside an excluded tree: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
# the excluded hit sits after 600 distinct clean paths: no prefix check, nothing is sent
{ for i in $(seq 1 600); do printf '%s/other/f%s.txt:1:clean line\n' "$TEST_HOME" "$i"; done
  printf '%s/visa-repo/secret.ts:7:CONFIDENTIAL work line\n' "$TEST_HOME"; } >"$TEST_HOME/many-hits.txt"
jq -cn --rawfile c "$TEST_HOME/many-hits.txt" --arg p "$TEST_HOME" --arg cwd "$TEST_HOME/other" '{tool_name:"Grep", cwd:$cwd, tool_input:{pattern:"line", path:$p}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "Grep with an excluded hit past 500 distinct paths: untouched, no call" bash -c "[ ! -s '$OUTF' ] && [ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" = '$B' ]"
grep -v visa-repo "$TEST_HOME/mixed-hits.txt" >"$TEST_HOME/clean-hits.txt"
jq -cn --rawfile c "$TEST_HOME/clean-hits.txt" --arg p "$TEST_HOME" --arg cwd "$TEST_HOME/other" '{tool_name:"Grep", cwd:$cwd, tool_input:{pattern:"line", path:$p}, tool_response:{content:$c}}' >"$IN"
JEV_MOCK="$FIX" run_hook a2-search-rank.sh "$IN"
check "same search without the excluded hit is still ranked (control)" bash -c "! [[ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" == '$B' ]]"
rm -f "$HOME/.claude/hooks/jev/jev-config.json"

# ------------------------------------------------------------------ A3: Bash log trim
echo "A3 bash-trim"
setup_home
TR="$TEST_HOME/t.jsonl"
transcript "$TR" "run the build and tell me why it fails"
LOG="$TEST_HOME/build.log"
{ numbered_lines 230 build; echo "Error: Cannot find module 'left-pad' (root cause)"; numbered_lines 269 build; } >"$LOG"
FIX="$TEST_HOME/fix.json"
bool_fixture "$FIX" c0=0.02 c1=0.02 c2=0.02 c3=0.02 c4=0.95 c5=0.02 c6=0.02 c7=0.02 c8=0.02 c9=0.02
bash_input() { # bash_input <command> <log> [extra tool_input]
  local extras="${3:-}"
  [[ -n "$extras" ]] || extras='{}'
  jq -cn --arg cmd "$1" --rawfile c "$2" --arg t "$TR" --argjson ti "$extras" '{session_id:"s3", cwd:"/tmp", transcript_path:$t, tool_name:"Bash",
    tool_input:({command:$cmd} + $ti), tool_response:{stdout:$c, stderr:"", interrupted:false, isImage:false}}' >"$IN"
}
bash_input "npm run build" "$LOG"
set_mode A3-bash-trim shadow
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "shadow: nothing printed" out_empty
check "shadow: would-trim logged, tail 40 + 1 chunk kept" shadow_jq '.rule=="A3-bash-trim" and .detail.decision=="would-trim" and .detail.kept_lines==90'
check "request: command + untrusted digests; error digest surfaces the error line" \
  jq -e '.state.command=="npm run build" and (.untrusted.chunks.c4|test("Cannot find module"))' "$STUB_LAST"
set_mode A3-bash-trim enforce
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
jq -r '.hookSpecificOutput.updatedToolOutput.stdout' "$OUTF" >"$TEST_HOME/content.txt"
CACHED="$(ls "$HOME"/.claude/jev-cache/*.txt 2>/dev/null | head -1)"
check "enforce: error cause kept verbatim with line number" has_fixed "$TEST_HOME/content.txt" $'231\tError: Cannot find module'
check "enforce: last 40 lines kept" has_fixed "$TEST_HOME/content.txt" $'500\tbuild 269 some filler'
check "enforce: line 461 (first tail line) kept, 460 is not" bash -c "grep -qF \$'461\t' '$TEST_HOME/content.txt' && ! grep -qF \$'460\t' '$TEST_HOME/content.txt'"
check "enforce: marker for first gap cites file" has_fixed "$TEST_HOME/content.txt" "[lines 1–200 trimmed (200 lines): full output at $CACHED"
check "enforce: marker for middle gap" has_fixed "$TEST_HOME/content.txt" '[lines 251–460 trimmed (210 lines)'
check "enforce: full output saved verbatim" cmp -s "$LOG" "$CACHED"
check "enforce: stderr/other fields preserved" out_jq '.hookSpecificOutput.updatedToolOutput | .stderr=="" and .interrupted==false'
check "enforce: emitted object has exactly the original keys (stdout, stderr, interrupted, isImage)" keys_kept
check "enforce: never a plain-string updatedToolOutput" out_jq '.hookSpecificOutput.updatedToolOutput | type == "object"'
B="$(calls)"
for c in "cat build.log" "git diff HEAD~1" "git -C /x show abc" "sed -n 1,500p f" "tail -n 500 f" "cd /x && head -500 f"; do
  bash_input "$c" "$LOG"
  JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
  check "content-viewing command left alone: $c" out_empty
done
check "content-viewing commands made no Jev call" no_new_calls "$B"
bash_input "npm run build" "$LOG" '{"run_in_background":true}'
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "background command: untouched" out_empty
numbered_lines 300 build >"$TEST_HOME/short.log"
bash_input "npm test" "$TEST_HOME/short.log"
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "300 lines (not more): untouched" out_empty
bash_input "npm run build" "$LOG"
JEV_MOCK=unavailable run_hook a3-bash-trim.sh "$IN"
check "Jev unavailable: untouched" out_empty
B="$(calls)"
jq -cn --rawfile c "$LOG" '{tool_name:"Bash", tool_input:{command:"npm run build"}, tool_response:$c}' >"$IN"
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "tool_response that is a bare string (shape the harness would drop): untouched, no call" no_new_calls "$B"
check "bare-string tool_response: silent" out_empty
printf '{"exclude_paths":["%s/visa-repo"]}' "$TEST_HOME" >"$HOME/.claude/hooks/jev/jev-config.json"
bash_input "npm run build" "$LOG"
jq -c --arg c "$TEST_HOME/visa-repo" '.cwd=$c' "$IN" >"$IN.x" && mv "$IN.x" "$IN"
B="$(calls)"
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "cwd under exclude_paths: untouched, no Jev call (output of an excluded tree never leaves)" no_new_calls "$B"
check "cwd under exclude_paths: silent" out_empty
# provenance: the cwd is NOT excluded, but the command reads an excluded tree
mkdir -p "$TEST_HOME/visa-repo/app" "$TEST_HOME/other/sub"
for c in "git -C $TEST_HOME/visa-repo/app test" "cd $TEST_HOME/visa-repo && npm test" "$TEST_HOME/visa-repo/run.sh --all" \
  "FOO=1 make -C '$TEST_HOME/visa-repo/app'" 'cd ~/visa-repo/app && make' 'cd $HOME/visa-repo && make' "npm test --prefix=$TEST_HOME/visa-repo" "cd ../visa-repo/app && make" 'cd "$VISA_DIR/app" && make' \
  'cd "$VISA_DIR" && npm test' 'npm test --prefix=${HOME}/visa-repo/app' 'cd ${HOME}/visa-repo && make' 'make -C ${VISA_DIR:-x}' \
  "awk 1 $TEST_HOME/vi\\sa-repo/app/log.txt" 'cd vi\sa-repo && make'; do
  bash_input "$c" "$LOG"
  case "$c" in "cd ../visa-repo"*) jq -c --arg c "$TEST_HOME/other" '.cwd=$c' "$IN" >"$IN.x" && mv "$IN.x" "$IN" ;; esac
  B="$(calls)"
  JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
  check "command naming an excluded tree (cwd elsewhere): untouched, no Jev call: $c" no_new_calls "$B"
done
bash_input "cd $TEST_HOME/other && make" "$LOG"
B="$(calls)"
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "command naming only a non-excluded path is still trimmed (control)" bash -c "! [[ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" == '$B' ]]"
bash_input "cd \$PWD && make; echo \$? \$(date)" "$LOG"
B="$(calls)"
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "\$PWD, \$? and \$( ) are not unresolved paths: still trimmed (control)" bash -c "! [[ \"\$(wc -l <'$STUB_COUNT' | tr -d ' ')\" == '$B' ]]"
rm -f "$HOME/.claude/hooks/jev/jev-config.json"
bash_input "npm run build" "$LOG"
B="$(calls)"
set_rule A3-bash-trim '{"max_lines":400}'
JEV_MOCK="$FIX" run_hook a3-bash-trim.sh "$IN"
check "over max_lines ceiling: untouched, no Jev call" no_new_calls "$B"
check "over max_lines ceiling: silent" out_empty

# ------------------------------------------------------------------ A4: Stop / task boundary
echo "A4 task-boundary"
setup_home
big_transcript() { # big_transcript <file> <bytes>
  {
    jq -cn '{type:"user", message:{role:"user", content:"ship the feature"}}'
    # Pad inside jq: a 700 KB --arg exceeds Linux's per-argument limit (MAX_ARG_STRLEN, 128 KB).
    jq -cn --argjson n "$2" '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:("a" * $n)}]}}'
    jq -cn '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Shipped. All checks pass."}]}}'
  } >"$1"
}
big_transcript "$TEST_HOME/big.jsonl" 700000
big_transcript "$TEST_HOME/small.jsonl" 20000
choice_fixture() { # choice_fixture <out> <rule-answer-name> <choice> <p>
  jq -n --arg n "$2" --arg c "$3" --argjson p "$4" '{answers: {($n): {type:"choice", choice:$c, probabilities:{($c): $p, other: (1 - $p)}}}, model:"mock"}' >"$1"
}
choice_fixture "$TEST_HOME/done.json" phase task_completed 0.93
stop_input() { # stop_input <transcript> [session] [active]
  jq -cn --arg t "$1" --arg s "${2:-s4}" --argjson a "${3:-false}" '{session_id:$s, cwd:"/tmp", transcript_path:$t, stop_hook_active:$a, hook_event_name:"Stop", last_assistant_message:"Shipped. All checks pass."}' >"$IN"
}
stop_input "$TEST_HOME/big.jsonl"
set_mode A4-task-boundary shadow
JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "shadow: prints nothing, never blocks" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"
check "shadow: verdict logged with size estimate" shadow_jq '.rule=="A4-task-boundary" and .detail.phase=="task_completed" and .detail.est_tokens>150000'
check "request: choice with the three phases, transcript tail present" \
  jq -e '.questions.phase.type=="choice" and (.questions.phase.criteria|keys|sort)==["in_progress","switched","task_completed"] and (.state.transcript_tail|length)>0' "$STUB_LAST"
set_mode A4-task-boundary enforce
JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "enforce: systemMessage suggests /clear or /compact" out_jq '.systemMessage | test("/clear") and test("/compact")'
check "enforce: never a block decision" out_jq 'has("decision") | not'
B="$(calls)"
JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "cooldown: second Stop in the same session says nothing" out_empty
check "cooldown: ...and makes no Jev call" no_new_calls "$B"
stop_input "$TEST_HOME/big.jsonl" other-session
choice_fixture "$TEST_HOME/prog.json" phase in_progress 0.9
JEV_MOCK="$TEST_HOME/prog.json" run_hook a4-task-boundary.sh "$IN"
check "in_progress: no suggestion" out_empty
choice_fixture "$TEST_HOME/weak.json" phase task_completed 0.6
JEV_MOCK="$TEST_HOME/weak.json" run_hook a4-task-boundary.sh "$IN"
check "completed below threshold: no suggestion" out_empty
choice_fixture "$TEST_HOME/sw.json" phase switched 0.95
JEV_MOCK="$TEST_HOME/sw.json" run_hook a4-task-boundary.sh "$IN"
check "switched is not in suggest_on by default: no suggestion" out_empty
B="$(calls)"
stop_input "$TEST_HOME/small.jsonl" s4b
JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "small transcript (<150k tokens est.): silent, no Jev call" bash -c "[ ! -s '$OUTF' ]"
check "small transcript: no call made" no_new_calls "$B"
stop_input "$TEST_HOME/big.jsonl" s4c true
JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "stop_hook_active: silent, no call" bash -c "[ ! -s '$OUTF' ]"
check "stop_hook_active: no call made" no_new_calls "$B"
stop_input "$TEST_HOME/big.jsonl" s4d
CLAUDE_JOB_DIR=/tmp/job JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "bg job (interactive-only rule): silent" out_empty
check "bg job: no call made" no_new_calls "$B"
# only bytes since the last compaction count
{
  head -c 700000 "$TEST_HOME/big.jsonl"
  echo
  jq -cn '{type:"system", subtype:"compact_boundary"}'
  jq -cn '{type:"user", isCompactSummary:true, message:{role:"user", content:"summary"}}'
  jq -cn '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"ok"}]}}'
} >"$TEST_HOME/compacted.jsonl"
stop_input "$TEST_HOME/compacted.jsonl" s4e
JEV_MOCK="$TEST_HOME/done.json" run_hook a4-task-boundary.sh "$IN"
check "compacted transcript: size counted since the boundary -> silent, no call" no_new_calls "$B"
JEV_MOCK=unavailable run_hook a4-task-boundary.sh "$IN"
check "Jev unavailable: silent, exit 0" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"

# ------------------------------------------------------------------ A5: SessionStart(compact)
echo "A5 compact-reinject"
setup_home
TR="$TEST_HOME/t.jsonl"
transcript "$TR" "verify the retry change before we merge"
REPO="$TEST_HOME/repo5"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo hi >"$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -q -m init
git -C "$REPO" checkout -q -b feat/retry
git -C "$REPO" worktree add -q -b feat/linked "$TEST_HOME/wt5"
cat >"$HOME/CLAUDE.md" <<'EOF'
## Decisions
Ask when a decision is irreversible.

## Evidence
Back every claim with its source.

## Verification
Retry a failing step up to 3 times, then stop and report.
EOF
SLUG="$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HOME/.claude/projects/$SLUG/memory"
cat >"$HOME/.claude/projects/$SLUG/memory/MEMORY.md" <<'EOF'
# Memory Index

- [Merge policy](merge-policy.md) — fleet auto-merges; unresolved review threads block merge
- [Vercel pin footgun](vercel-pin.md) — shell pins the wrong project id
EOF
STUBBIN="$TEST_HOME/bin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/gh" <<'EOF'
#!/bin/bash
[ "$1 $2" = "pr view" ] || exit 1
echo '{"number":12,"title":"Retry backoff","url":"https://example.com/pr/12","state":"OPEN"}'
EOF
chmod +x "$STUBBIN/gh"
compact_input() { jq -cn --arg c "$1" --arg t "$TR" --arg s "${2:-compact}" '{session_id:"s5", cwd:$c, transcript_path:$t, source:$s, hook_event_name:"SessionStart"}' >"$IN"; }
FIX="$TEST_HOME/fix.json"
bool_fixture "$FIX" r0=0.3 r1=0.1 r2=0.9 m0=0.8 m1=0.1
mkdir -p "$HOME/.claude/jev-cache/state"
echo mem.md >"$HOME/.claude/jev-cache/state/s5.mem"
compact_input "$REPO"
set_mode A5-compact-reinject shadow
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "default modes: deterministic state is injected as SessionStart additionalContext" out_jq '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext|test("branch feat/retry"))'
check "state names the worktree path" out_jq ".hookSpecificOutput.additionalContext | contains(\"$(cd "$REPO" && pwd -P)\")"
check "state names the open PR" out_jq '.hookSpecificOutput.additionalContext | test("open PR #12 \"Retry backoff\" https://example.com/pr/12")'
check "Jev ranking in shadow: nothing ranked is injected" out_jq '.hookSpecificOutput.additionalContext | test("Re-injected") | not'
check "shadow: ranking verdict logged with picks" shadow_jq '.rule=="A5-compact-reinject" and (.detail.picked|map(.id))==["r2","m0"]'
check "request: boolean per rule section + memory entry, 5 candidates" jq -e '(.questions|length)==5 and (.state.candidates.r2|test("Verification"))' "$STUB_LAST"
check "memory ledger reset on compaction" test ! -e "$HOME/.claude/jev-cache/state/s5.mem"
set_mode A5-compact-reinject enforce
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "enforce: top-ranked rule section injected" out_jq '.hookSpecificOutput.additionalContext | test("Verification") and test("up to 3 times")'
check "enforce: top-ranked memory entry injected" out_jq '.hookSpecificOutput.additionalContext | test("Merge policy")'
check "enforce: candidates under threshold left out" out_jq '.hookSpecificOutput.additionalContext | (test("Decisions|Vercel pin") | not)'
check "enforce: rank order r2 before m0" out_jq '.hookSpecificOutput.additionalContext | (index("Verification")) < (index("Merge policy"))'
printf '## Repo rule\nProject specific standing rule text.\n' >"$REPO/CLAUDE.md"
compact_input "$REPO"
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "project CLAUDE.md is a candidate when the repo is not excluded" jq -e '.state.candidates | to_entries | any(.value | test("Project specific standing rule"))' "$STUB_LAST"
printf '{"exclude_paths":["%s"]}' "$REPO" >"$HOME/.claude/hooks/jev/jev-config.json"
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "project CLAUDE.md of an excluded repo is never sent" jq -e '.state.candidates | to_entries | any(.value | test("Project specific standing rule")) | not' "$STUB_LAST"
check "the global CLAUDE.md is still ranked for an excluded repo" jq -e '.state.candidates | to_entries | any(.value | test("Back every claim"))' "$STUB_LAST"
rm -f "$HOME/.claude/hooks/jev/jev-config.json" "$REPO/CLAUDE.md"
compact_input "$TEST_HOME/wt5"
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "linked worktree is flagged" out_jq '.hookSpecificOutput.additionalContext | test("branch feat/linked") and test("linked git worktree")'
compact_input "$REPO"
FAILBIN="$TEST_HOME/failbin"
mkdir -p "$FAILBIN"
printf '#!/bin/bash\nexit 1\n' >"$FAILBIN/gh"
chmod +x "$FAILBIN/gh"
PATH="$FAILBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "gh failing (no PR / not logged in): state still injected, no PR text" out_jq '.hookSpecificOutput.additionalContext | test("branch feat/retry") and (test("open PR") | not)'
JEV_MOCK=unavailable PATH="$STUBBIN:$PATH" run_hook a5-compact-reinject.sh "$IN"
check "Jev unavailable: deterministic state alone" out_jq '.hookSpecificOutput.additionalContext | test("branch feat/retry") and (test("Re-injected") | not)'
compact_input "$REPO" startup
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "source!=compact: nothing" out_empty
compact_input "$TEST_HOME"
PATH="$STUBBIN:$PATH" JEV_MOCK=unavailable run_hook a5-compact-reinject.sh "$IN"
check "not a git repo: nothing to say" out_empty
compact_input "$REPO"
set_mode A5b-compact-state shadow
JEV_MOCK=unavailable PATH="$STUBBIN:$PATH" run_hook a5-compact-reinject.sh "$IN"
check "A5b in shadow mode: injects nothing" out_empty
touch "$HOME/.claude/jev.off"
set_mode A5b-compact-state enforce
PATH="$STUBBIN:$PATH" JEV_MOCK="$FIX" run_hook a5-compact-reinject.sh "$IN"
check "kill switch silences even the deterministic part" out_empty
rm -f "$HOME/.claude/jev.off"

# ------------------------------------------------------------------ A6: Agent router
echo "A6 agent-router"
setup_home
mkdir -p "$HOME/.claude/agents"
cat >"$HOME/.claude/agents/security-auditor.md" <<'EOF'
---
name: security-auditor
description: >-
  Use when checking for security issues,
  vulnerabilities, or auth problems.
tools: Read, Grep
---

# Security auditor
EOF
cat >"$HOME/.claude/agents/test-engineer.md" <<'EOF'
---
name: test-engineer
description: Use when writing tests or validating code works correctly.
---
EOF
agent_input() { # agent_input <subagent_type|""> <prompt>
  jq -cn --arg s "$1" --arg p "$2" '{session_id:"s6", cwd:"/tmp", hook_event_name:"PreToolUse", tool_name:"Agent",
    tool_input:({prompt:$p, description:"d"} + (if $s == "" then {} else {subagent_type:$s} end))}' >"$IN"
}
PROMPT="Review the diff for security vulnerabilities and injection risks in the auth module"
agent_input general-purpose "$PROMPT"
choice_fixture "$TEST_HOME/sec.json" best_type security-auditor 0.91
set_mode A6-agent-router shadow
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "shadow: nothing printed" out_empty
check "shadow: verdict logged" shadow_jq '.rule=="A6-agent-router" and .detail.requested=="general-purpose" and .detail.pick=="security-auditor"'
check "request: built-ins + user agents, folded description joined" \
  jq -e '.questions.best_type.criteria | has("Explore") and has("Plan") and has("general-purpose") and has("test-engineer") and (.["security-auditor"]|test("security issues, vulnerabilities, or auth problems"))' "$STUB_LAST"
check "request: agent prompt in state, one call" test "$(calls)" = 1
set_mode A6-agent-router enforce
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "enforce: PreToolUse additionalContext suggests the better type" out_jq '.hookSpecificOutput | .hookEventName=="PreToolUse" and (.additionalContext|test("security-auditor") and test("general-purpose"))'
check "enforce: never denies or sets a permission decision" out_jq '.hookSpecificOutput | (has("permissionDecision") | not) and (has("decision") | not)'
agent_input security-auditor "$PROMPT"
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "pick == requested: silent" out_empty
agent_input "" "$PROMPT"
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "no subagent_type means general-purpose: suggestion fires" out_jq '.hookSpecificOutput.additionalContext | test("security-auditor")'
choice_fixture "$TEST_HOME/weak.json" best_type security-auditor 0.5
agent_input general-purpose "$PROMPT"
JEV_MOCK="$TEST_HOME/weak.json" run_hook a6-agent-router.sh "$IN"
check "below threshold: silent" out_empty
B="$(calls)"
agent_input general-purpose "too short"
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "short prompt: silent, no call" bash -c "[ ! -s '$OUTF' ]"
agent_input some-plugin-agent "$PROMPT"
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "unknown requested type: not judged, silent" out_empty
check "short prompt / unknown type: no calls made" no_new_calls "$B"
agent_input general-purpose "$PROMPT"
JEV_MOCK=unavailable run_hook a6-agent-router.sh "$IN"
check "Jev unavailable: silent, exit 0" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"
jq -cn '{tool_name:"Bash", tool_input:{command:"ls"}}' >"$IN"
JEV_MOCK="$TEST_HOME/sec.json" run_hook a6-agent-router.sh "$IN"
check "other tools: ignored" out_empty

# ------------------------------------------------------------------ A7 + A8: UserPromptSubmit
echo "A7/A8 prompt-context"
setup_home
SLUG="$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9]/-/g')"
MEMDIR="$HOME/.claude/projects/$SLUG/memory"
mkdir -p "$MEMDIR"
cat >"$MEMDIR/MEMORY.md" <<'EOF'
# Memory Index

- [Verify before done](verify-before-done.md) — run the real gates before saying done
- [Merge policy](merge-policy.md) — fleet auto-merges; unresolved threads block merge
- [Papercuts log](papercuts.md) — append friction one-liners
EOF
printf -- '---\nname: verify-before-done\ntype: feedback\n---\nBODY-VERIFY: run the repo gates and show the output.\n' >"$MEMDIR/verify-before-done.md"
printf -- '---\nname: merge-policy\n---\nBODY-MERGE: threads must be resolved, not just replied to.\n' >"$MEMDIR/merge-policy.md"
printf -- '---\nname: papercuts\n---\nBODY-PAPERCUT: use papercut.sh.\n' >"$MEMDIR/papercuts.md"
mkdir -p "$HOME/.claude/skills/verify" "$HOME/.claude/skills/commit" "$HOME/.claude/skills/plan" "$HOME/.claude/skills/docs" "$HOME/.claude/skills/hidden"
printf -- '---\nname: verify\ndescription: Run the real verification gates and fix what fails.\n---\n' >"$HOME/.claude/skills/verify/SKILL.md"
printf -- '---\nname: commit\ndescription: "Create git commits with intelligent message generation."\n---\n' >"$HOME/.claude/skills/commit/SKILL.md"
printf -- '---\nname: plan\ndescription: Shape a task into a PRD.\n---\n' >"$HOME/.claude/skills/plan/SKILL.md"
printf -- '---\nname: docs\ndescription: >-\n  Documentation generation\n  and updates.\n---\n' >"$HOME/.claude/skills/docs/SKILL.md"
printf -- '---\nname: hidden\ndescription: User-only skill.\ndisable-model-invocation: true\n---\n' >"$HOME/.claude/skills/hidden/SKILL.md"
printf '{"skillOverrides":{"plan":"off"}}' >"$HOME/.claude/settings.json"
prompt_input() { jq -cn --arg p "$1" --arg s "${2:-s7}" '{session_id:$s, cwd:"/tmp", hook_event_name:"UserPromptSubmit", prompt:$p}' >"$IN"; }
mixed_fixture() { # mixed_fixture <out> <skill> <skill-p> <name=p>...
  local out="$1" sk="$2" sp="$3"
  shift 3
  bool_fixture "$out.b" "$@"
  jq --arg c "$sk" --argjson p "$sp" '.answers.skill = {type:"choice", choice:$c, probabilities:{($c): $p, none: (1 - $p)}}' "$out.b" >"$out"
}
mixed_fixture "$TEST_HOME/mix.json" verify 0.85 m0=0.9 m1=0.8 m2=0.1
prompt_input "please verify the config change works end to end"
set_mode A7-memory-inject shadow
set_mode A8-skill-picker shadow
JEV_MOCK="$TEST_HOME/mix.json" run_hook a7-a8-prompt-context.sh "$IN"
check "shadow: nothing printed" out_empty
check "ONE Jev call carries both A7 and A8 questions" jq -e '(.questions|has("skill")) and (.questions|has("m0") and has("m1") and has("m2"))' "$STUB_LAST"
check "exactly one call" test "$(calls)" = 1
check "skill choice: enabled skills + none; off/disable-model-invocation excluded" \
  jq -e '.questions.skill.criteria | has("verify") and has("commit") and has("docs") and has("none") and (has("plan")|not) and (has("hidden")|not)' "$STUB_LAST"
check "skill choice: folded description joined" jq -e '.questions.skill.criteria.docs | test("Documentation generation and updates")' "$STUB_LAST"
check "A7 shadow log: would inject 2 memories, bodies not logged" shadow_jq '.rule=="A7-memory-inject" and (.detail.would_inject|length)==2'
check "A8 shadow log: would hint /verify" shadow_jq '.rule=="A8-skill-picker" and .detail.pick=="verify" and .detail.would_hint==true'
check "shadow log carries no memory body" shadow_lacks 'BODY-'
set_mode A7-memory-inject enforce
set_mode A8-skill-picker enforce
JEV_MOCK="$TEST_HOME/mix.json" run_hook a7-a8-prompt-context.sh "$IN"
check "enforce: UserPromptSubmit additionalContext" out_jq '.hookSpecificOutput.hookEventName=="UserPromptSubmit"'
check "enforce: memory bodies injected without frontmatter" out_jq '.hookSpecificOutput.additionalContext | test("BODY-VERIFY") and test("BODY-MERGE") and (test("type: feedback") | not)'
check "enforce: below-threshold memory not injected" out_jq '.hookSpecificOutput.additionalContext | test("BODY-PAPERCUT") | not'
check "enforce: skill hint" out_jq '.hookSpecificOutput.additionalContext | test("Relevant skill: /verify — consider invoking it")'
check "enforce: memories flagged as possibly stale" out_jq '.hookSpecificOutput.additionalContext | test("may be stale")'
B="$(calls)"
mixed_fixture "$TEST_HOME/mix2.json" verify 0.85 m0=0.9
prompt_input "please verify the config change works end to end"
JEV_MOCK="$TEST_HOME/mix2.json" run_hook a7-a8-prompt-context.sh "$IN"
check "same session, second prompt: already-injected memories are not asked about again" jq -e '(.questions|has("m0")|not) and (.questions|has("m1")|not) and (.questions|has("m2"))' "$STUB_LAST"
check "same session, second prompt: no memory re-injection" out_jq '.hookSpecificOutput.additionalContext | test("BODY-") | not'
prompt_input "please verify the config change works end to end" other-session
JEV_MOCK="$TEST_HOME/mix.json" run_hook a7-a8-prompt-context.sh "$IN"
check "new session: memories are injectable again" out_jq '.hookSpecificOutput.additionalContext | test("BODY-VERIFY")'
B="$(calls)"
prompt_input "/verify the config change works end to end" s7x
JEV_MOCK="$TEST_HOME/mix.json" run_hook a7-a8-prompt-context.sh "$IN"
check "slash command: skipped" out_empty
check "slash command: no Jev call" no_new_calls "$B"
prompt_input "  /commit -m wip please now" s7x
JEV_MOCK="$TEST_HOME/mix.json" run_hook a7-a8-prompt-context.sh "$IN"
check "slash command after leading spaces: skipped, no call" bash -c "[ ! -s '$OUTF' ]"
check "slash command after spaces: no call made" no_new_calls "$B"
prompt_input "ok thanks" s7x
JEV_MOCK="$TEST_HOME/mix.json" run_hook a7-a8-prompt-context.sh "$IN"
check "trivial prompt (<15 chars): skipped" out_empty
check "trivial prompt: no Jev call" no_new_calls "$B"
prompt_input "please verify the config change works end to end" s7y
JEV_MOCK=unavailable run_hook a7-a8-prompt-context.sh "$IN"
check "Jev unavailable: prompt untouched, exit 0" bash -c "[ ! -s '$OUTF' ] && [ '$HOOK_RC' = 0 ]"
mixed_fixture "$TEST_HOME/lowskill.json" verify 0.4 m0=0.1 m1=0.1 m2=0.1
JEV_MOCK="$TEST_HOME/lowskill.json" run_hook a7-a8-prompt-context.sh "$IN"
check "nothing above thresholds: silent" out_empty
mixed_fixture "$TEST_HOME/none.json" none 0.95 m0=0.1 m1=0.1 m2=0.1
JEV_MOCK="$TEST_HOME/none.json" run_hook a7-a8-prompt-context.sh "$IN"
check "skill pick 'none': silent" out_empty
set_mode A7-memory-inject off
mixed_fixture "$TEST_HOME/skillonly.json" commit 0.9 m0=0.9
JEV_MOCK="$TEST_HOME/skillonly.json" run_hook a7-a8-prompt-context.sh "$IN"
check "A7 off, A8 on: hint only, and the request has no memory questions" bash -c "jq -e '.hookSpecificOutput.additionalContext | test(\"/commit\") and (test(\"BODY-\") | not)' '$OUTF' >/dev/null && jq -e '.questions | has(\"m0\") | not' '$STUB_LAST' >/dev/null"
set_mode A8-skill-picker off
B="$(calls)"
JEV_MOCK="$TEST_HOME/skillonly.json" run_hook a7-a8-prompt-context.sh "$IN"
check "both rules off: silent, no call" bash -c "[ ! -s '$OUTF' ]"
check "both rules off: no call made" no_new_calls "$B"

# ------------------------------------------------------------------ registry / wiring
echo "registry + wiring"
RULES="$SRC/rules.d/context.json"
check "rules.d/context.json is valid JSON" jq -e . "$RULES"
check "every Phase 3 rule is registered under the \"rules\" key" jq -e '.rules | has("A1-read-trim") and has("A2-search-rank") and has("A3-bash-trim") and has("A4-task-boundary") and has("A5-compact-reinject") and has("A5b-compact-state") and has("A6-agent-router") and has("A7-memory-inject") and has("A8-skill-picker")' "$RULES"
check "every Jev rule ships enforce" jq -e '.rules | to_entries | all(.value.mode == "enforce")' "$RULES"
check "every rule declares a scope" jq -e '.rules | to_entries | all(.value.scope | type == "array" and length > 0)' "$RULES"
SETTINGS="$REPO_ROOT/system-configs/.claude/settings.json"
for s in a1-read-trim a2-search-rank a3-bash-trim a4-task-boundary a5-compact-reinject a6-agent-router a7-a8-prompt-context; do
  check "settings.json registers $s.sh" jq -e --arg s "hooks/jev/$s.sh" '[.hooks[][].hooks[].command] | any(endswith($s))' "$SETTINGS"
  check "$s.sh exists, is executable and parses" bash -c "[ -x '$SRC/$s.sh' ] && bash -n '$SRC/$s.sh'"
  check "scripts/sync.sh deploys $s.sh" grep -q "hooks/jev/$s.sh" "$REPO_ROOT/scripts/sync.sh"
done
check "scripts/sync.sh deploys ctx-lib.sh" grep -q 'hooks/jev/ctx-lib.sh' "$REPO_ROOT/scripts/sync.sh"
check "scripts/sync.sh deploys rules.d/context.json as data (not bash -n'd)" grep -q '^RUNTIME_HOOK_DATA=.*hooks/jev/rules.d/context.json' "$REPO_ROOT/scripts/sync.sh"
check "A5 hook is scoped to the compact matcher" jq -e '.hooks.SessionStart | any(.matcher=="compact" and (.hooks|any(.command|endswith("a5-compact-reinject.sh"))))' "$SETTINGS"
check "hook timeouts are short (<= 10s)" jq -e '[.hooks[][].hooks[] | select(.command|test("hooks/jev/a[0-9]")) | .timeout] | all(. != null and . <= 10)' "$SETTINGS"
check "existing Stop hook (claude-speak) untouched" jq -e '.hooks.Stop | any(.hooks|any(.command|endswith("claude-speak.sh")))' "$SETTINGS"

# ------------------------------------------------------------------ summary
echo
echo "jev-context tests: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
