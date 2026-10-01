#!/bin/bash
# shellcheck shell=bash
# Shared helpers for the Jev decision-gate hooks (jev-gate.sh, jev-ask-channel.sh).
# Sourced, never executed. Bash 3.2 compatible (macOS /bin/bash).
#
# Contract (system-configs/.claude/hooks/jev/): the client is `jev-ask` (stdin JSON in,
# stdout JSON out, exit 3 = unavailable). Per-rule mode/threshold/scope come from the rules
# registry (see jev_rules_json: the SAME reader semantics as client.mjs and ctx-lib.sh).
# Every rule here ships mode "shadow".

JEV_CLAUDE_DIR="${JEV_CLAUDE_DIR:-$HOME/.claude}"
JEV_DIR="${JEV_DIR:-$JEV_CLAUDE_DIR/hooks/jev}"
JEV_ASK="${JEV_ASK:-$JEV_DIR/jev-ask}"
JEV_QUESTIONS="${JEV_QUESTIONS:-$JEV_DIR/gate-questions.json}"
JEV_STATE_DIR="${JEV_STATE_DIR:-$JEV_CLAUDE_DIR/jev-state}"
JEV_GATE_LOG="${JEV_GATE_LOG:-$JEV_CLAUDE_DIR/jev-gates.jsonl}"
JEV_APPROVAL_LOG="$JEV_STATE_DIR/approvals.log"

# ---------------------------------------------------------------- context --

# Sets JEV_CTX (fleet|bgjob|interactive) and JEV_SLUG (lowercased fleet agent slug or "").
jev_init_context() {
  JEV_SLUG=$(printf '%s' "${BARECLAUDE_AGENT_SLUG:-}" | tr '[:upper:]' '[:lower:]')
  if [ -n "$JEV_SLUG" ]; then
    JEV_CTX=fleet
  elif [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    JEV_CTX=bgjob
  else
    JEV_CTX=interactive
  fi
}

# Merged rules registry. ONE reader semantics, shared with client.mjs rulesRegistry() and ctx-lib.sh
# ctx_rule_load: files = rules.d/*.json in lexical order, then jev-rules.json LAST (the user's file
# wins). Each file is {"exempt_agents":[...], "rules":{"<id>":{...}}}; a flat {"<id>":{...}} is
# tolerated. Entries deep-merge (later wins); exempt_agents comes from the last file that sets it.
# Output: {"<id>":{mode,threshold,scope}, ..., "exempt_agents":[...]} (flat, what the helpers below read).
jev_rules_json() {
  local files=() f
  if [ -d "$JEV_DIR/rules.d" ]; then
    for f in "$JEV_DIR"/rules.d/*.json; do
      [ -f "$f" ] && files+=("$f")
    done
  fi
  [ -f "$JEV_DIR/jev-rules.json" ] && files+=("$JEV_DIR/jev-rules.json")
  if [ "${#files[@]}" -eq 0 ]; then
    echo '{}'
    return 0
  fi
  jq -s 'reduce .[] as $o ({};
    . * (($o.rules // ($o | del(.exempt_agents)))
         + (if $o.exempt_agents then {exempt_agents: $o.exempt_agents} else {} end)))' \
    "${files[@]}" 2>/dev/null || echo '{}'
}

# jev_is_exempt RULES_JSON -> 0 when the fleet agent is on the exempt list (default dara, clara).
jev_is_exempt() {
  [ -n "$JEV_SLUG" ] || return 1
  printf '%s' "$1" | jq -e --arg s "$JEV_SLUG" '(.exempt_agents // ["dara","clara"]) | map(ascii_downcase) | index($s) != null' >/dev/null 2>&1
}

# jev_resolve_rules RULES_JSON ID... -> TSV lines "id<TAB>mode<TAB>threshold" for rules that are
# enabled (mode != off) and in scope for JEV_CTX. Absent rules are off.
jev_resolve_rules() {
  local rules="$1"
  shift
  printf '%s\n' "$@" | jq -rR --argjson r "$rules" --arg ctx "$JEV_CTX" '
    select(length > 0) as $id
    | ($r[$id] // {}) as $o
    | ($o.mode // "off") as $m
    | select($m != "off")
    | select((($o.scope // ["interactive","bgjob","fleet"]) | index($ctx)) != null)
    | [$id, $m, ($o.threshold // 0.9 | tostring)] | @tsv'
}

# ------------------------------------------------------------------ hygiene --

# Also run over serialized JSON (jev_tail): a value never swallows a backslash or a closing quote, so a
# transcript string that exports a quoted credential keeps its JSON escapes and the JSON stays valid.
jev_redact() {
  perl -pe '
    s/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/[REDACTED]/g;
    s/\bgh[pousr]_[A-Za-z0-9]{20,}/[REDACTED]/g;
    s/\bgithub_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g;
    s/\bxox[abprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g;
    s/\bAKIA[0-9A-Z]{16}\b/[REDACTED]/g;
    s/\bglpat-[A-Za-z0-9_-]{16,}/[REDACTED]/g;
    s/\b(Bearer|Basic|token)\s+[A-Za-z0-9._~+\/=-]{12,}/$1 [REDACTED]/gi;
    s{(://)[^/\s:@\\"]+:[^/\s@\\"]+@}{$1\[REDACTED\]@}g;
    s/(\b[A-Za-z0-9_]*(?:key|token|secret|passw(?:or)?d|pwd|credential)[A-Za-z0-9_]*\s*[=:]\s*(?:\\"|\\\x27)?)[^\s"\x27\\]+/$1\[REDACTED\]/gi; # assignment pattern: NAME=value or NAME: value
    s/[A-Za-z0-9+_=-]{40,}/[REDACTED-LONG]/g;
  '
}

# jev_trim STRING MAX -> head 70% + marker + tail 30% when longer than MAX.
jev_trim() {
  local s="$1" n="${2:-700}"
  if [ "${#s}" -gt "$n" ]; then
    printf '%s ... %s' "${s:0:$((n * 7 / 10))}" "${s: -$((n * 3 / 10))}"
  else
    printf '%s' "$s"
  fi
}

# jev_sha STRING -> 16 hex chars.
jev_sha() {
  printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-16
}

# jev_cwd_repo CWD -> basename only (never the full path).
jev_cwd_repo() {
  basename "${1:-unknown}"
}

# --------------------------------------------------------------- transcript --

# Reads the bounded tail of a transcript and emits one JSON object:
# {turns:[{role,text}], untrusted:[{source,text}], d_uuid, has_d}.
# Genuine D turns = real user messages + AskUserQuestion answers. Every other tool_result from
# web/MCP/gh/curl is untrusted. Gmail/Slack bodies are withheld (egress rule).
JEV_TAIL_JQ='
def txt: if type=="string" then . elif type=="array" then ([.[]? | select(type=="object" and .type=="text") | .text] | join("\n")) else "" end;
def clip($n): if length > $n then .[0:$n] + "…" else . end;
def strip: gsub("(?s)<system-reminder>.*?</system-reminder>"; "") | gsub("(?s)<local-command-caveat>.*?</local-command-caveat>"; "") | gsub("^\\s+|\\s+$"; "");
def isharness: test("^\\s*<(local-command-std|command-message|task-notification|user-prompt-submit-hook|bash-input|bash-stdout|bash-stderr)");
def slash: "[slash command] " + (try (match("<command-name>([^<]*)</command-name>").captures[0].string) catch "") + " " + (try (match("<command-args>([^<]*)</command-args>").captures[0].string) catch "");
[inputs | fromjson? | select(type=="object")] as $all
| ([$all[] | select(.type=="assistant") | ((.message.content // []) | if type=="array" then . else [] end)[] | select(type=="object" and .type=="tool_use") | {key: .id, value: {n: .name, c: (.input.command // "")}}] | from_entries) as $tools
| [ $all[]
    | select((.type=="user" or .type=="assistant") and ((.isSidechain // false) | not) and ((.isMeta // false) | not))
    | . as $m
    | if .type=="assistant" then
        ((.message.content // []) | if type=="array" then . else [] end | map(select(type=="object" and .type=="text") | .text) | join("\n") | strip) as $t
        | if ($t | length) > 0 then {r:"claude", t:($t | clip(500)), u:$m.uuid} else empty end
      else
        (.message.content) as $c
        | if ($c | type) == "string" then
            if ($c | test("<task-notification")) then {r:"untrusted", src:"notification", t:($c | strip | clip(300))}
            elif ($c | test("<command-name>")) then {r:"D", t:($c | slash), u:$m.uuid}
            elif ($c | isharness) then empty
            else ($c | strip) as $s | if ($s | length) > 0 then {r:"D", t:($s | clip(600)), u:$m.uuid} else empty end
            end
        else
          (($c // []) | if type=="array" then . else [] end)[] | select(type=="object")
          | if .type=="text" then
              (.text | strip) as $s
              | if ($s | length) > 0 and (($s | isharness) | not) then {r:"D", t:($s | clip(600)), u:$m.uuid} else empty end
            elif .type=="tool_result" then
              ($tools[.tool_use_id] // {n:"", c:""}) as $tl
              | (.content | txt) as $b
              | if $tl.n == "AskUserQuestion" then {r:"D", t:($b | clip(800)), u:$m.uuid}
                elif (($tl.n | test("gmail|slack"; "i")) or ($tl.n == "Bash" and ($tl.c | test("gmail|slack"; "i")))) then
                  {r:"untrusted", src:(if ($tl.n + $tl.c | test("gmail"; "i")) then "gmail" else "slack" end), t:"[body withheld by egress policy]"}
                elif (($tl.n | test("^(WebFetch|WebSearch)$|^mcp__")) or ($tl.n == "Bash" and ($tl.c | test("\\b(gh\\s+(pr|issue|api)|curl|wget)\\b")))) then
                  {r:"untrusted", src:$tl.n, t:($b | clip(300))}
                else empty end
            else empty end
        end
      end
  ] as $ev
| ($ev | to_entries) as $en
| (($en | map(select(.value.r=="D")) | .[-3:]) + ($en | map(select(.value.r=="claude")) | .[-2:]) | sort_by(.key) | map(.value)) as $turns
| ($ev | map(select(.r=="untrusted")) | .[-3:]) as $un
| ($ev | map(select(.r=="D")) | last // null) as $lastd
| {turns: ($turns | map({role: (if .r=="D" then "D" else "claude" end), text: .t})),
   untrusted: ($un | map({source: .src, text: .t})),
   d_uuid: ($lastd.u // ""),
   has_d: ($lastd != null)}'

jev_tail() {
  local tp="$1" out
  if [ -n "$tp" ] && [ "$tp" != "-" ] && [ -r "$tp" ]; then
    out=$(tail -c 1000000 "$tp" 2>/dev/null | jq -nR -c "$JEV_TAIL_JQ" 2>/dev/null | jev_redact)
    if [ -n "$out" ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
  fi
  printf '%s' '{"turns":[],"untrusted":[],"d_uuid":"","has_d":false}'
}

# ---------------------------------------------------------------- Jev calls --

# jev_call REQUEST_JSON -> response JSON on stdout; returns 3 when Jev is unavailable.
jev_call() {
  local out
  [ -x "$JEV_ASK" ] || return 3
  out=$(printf '%s' "$1" | "$JEV_ASK" 2>/dev/null) || return 3
  printf '%s' "$out" | jq -e '.answers | type == "object"' >/dev/null 2>&1 || return 3
  printf '%s' "$out"
}

# jev_build_request RULE STATE_JSON UNTRUSTED_JSON QUESTIONS_JSON -> request JSON
jev_build_request() {
  jq -nc --arg rule "$1" --argjson state "$2" --argjson un "$3" --argjson q "$4" '
    {rule:$rule, state:$state, questions:$q} + (if ($un | length) > 0 then {untrusted:$un} else {} end)'
}

# jev_bool_questions IDS_JSON -> {id: {type:"boolean", instructions, criteria}} from gate-questions.json
jev_bool_questions() {
  jq -c --argjson ids "$1" '
    . as $d | $ids | map({key: ., value: {type:"boolean", instructions: $d.gates[.].instructions, criteria: $d.gates[.].criteria}}) | from_entries' "$JEV_QUESTIONS"
}

# jev_gate_questions IDS_JSON -> the questions object for ONE call covering every candidate gate.
# Gates with an `expects` block (G1, G3-G8, G13) share two choice questions, risk_class and scope, asked once
# however many of those gates are candidates (choice probabilities are calibrated; a boolean's |2p-1| is not).
# Gates without `expects` (G14, G15, ...) keep their own boolean question in the same call.
jev_gate_questions() {
  jq -c --argjson ids "$1" '
    . as $d
    | ($ids | map(select($d.gates[.].expects != null))) as $cls
    | ($ids | map(select($d.gates[.].expects == null))) as $bools
    | (if ($cls | length) > 0
       then ($d.choice_questions | map_values({type: "choice", instructions, criteria}))
       else {} end)
      + ($bools | map({key: ., value: {type: "boolean", instructions: $d.gates[.].instructions, criteria: $d.gates[.].criteria}}) | from_entries)' "$JEV_QUESTIONS"
}

# jev_gate_scores RESPONSE IDS_JSON -> one TSV line per gate: "id<TAB>p<TAB>scope_ok" (p is "-" when the answer is
# absent). A choice gate's p is the summed probability of its expected risk classes; scope_ok is 0 only when the
# gate names expected scopes, the scope answer is present, and their summed probability is below 0.5.
jev_gate_scores() {
  printf '%s' "$1" | jq -r --slurpfile q "$JEV_QUESTIONS" --argjson ids "$2" '
    . as $r | $q[0] as $d
    | def probs: (.probabilities // (if .choice then {(.choice): 1} else {} end));
      def psum($a; $opts): ($a | probs) as $p | [$opts[] | ($p[.] // 0)] | add // 0;
    $ids[] as $id | ($d.gates[$id].expects) as $e
    | if $e == null then [$id, ($r.answers[$id].probability // "-" | tostring), 1]
      else
        [$id,
         (if $r.answers.risk_class == null then "-" else (psum($r.answers.risk_class; $e.risk_class) | tostring) end),
         (if $e.scope == null or $r.answers.scope == null then 1 elif psum($r.answers.scope; $e.scope) >= 0.5 then 1 else 0 end)]
      end | @tsv'
}

# jev_prob RESPONSE NAME -> probability (empty when absent)
jev_prob() {
  printf '%s' "$1" | jq -r --arg n "$2" '.answers[$n].probability // empty'
}

# jev_ge A B -> 0 when A >= B (floats)
jev_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# ------------------------------------------------------------------ logging --

# jev_log RULE VERDICT [MODE] [PROB] -- never records command text, only a sha.
jev_log() {
  mkdir -p "$(dirname "$JEV_GATE_LOG")" 2>/dev/null || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rule "$1" --arg v "$2" --arg mode "${3:-}" \
    --arg p "${4:-}" --arg tool "${TOOL:-}" --arg ctx "${JEV_CTX:-}" --arg act "${ACTION_SHA:-}" \
    --arg slug "${JEV_SLUG:-}" '
    {ts:$ts, rule:$rule, verdict:$v, mode:$mode, p:($p | tonumber? // null), tool:$tool, ctx:$ctx, agent:$slug, action_sha:$act}' \
    >>"$JEV_GATE_LOG" 2>/dev/null || true
}

# --------------------------------------------------------------- one-shot state --

# jev_stamp_seen KEY -> 0 when this approval was already consumed.
jev_stamp_seen() {
  [ -f "$JEV_APPROVAL_LOG" ] && grep -qxF -- "$1" "$JEV_APPROVAL_LOG"
}

jev_stamp_add() {
  mkdir -p "$JEV_STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$JEV_APPROVAL_LOG" 2>/dev/null || true
}

# jev_warn_once SESSION MESSAGE -> prints a systemMessage JSON the first time per session.
jev_warn_once() {
  local f="$JEV_STATE_DIR/warned.${1:-nosession}"
  [ -e "$f" ] && return 0
  mkdir -p "$JEV_STATE_DIR" 2>/dev/null && : >"$f" 2>/dev/null
  jq -nc --arg m "$2" '{systemMessage:$m}'
}

# jev_deny_reason ID_LIST LABEL ACTION -> wording per context (interactive vs job/fleet/subagent).
jev_deny_reason() {
  local ids="$1" label="$2" action="${3:0:300}"
  if [ "${JEV_CTX:-interactive}" != "interactive" ] || [ -n "${JEV_SUBAGENT:-}" ]; then
    printf 'Jev gate [%s]: %s needs D, and this session cannot ask. Do not retry or work around it. End your final message with `needs input:` followed by the action and the decision D must make. Action: %s' \
      "$ids" "$label" "$action"
  else
    printf 'Jev gate [%s]: %s. Put this to D via AskUserQuestion before doing it (one question, state the exact action). If D approves exactly this action, retry it once; the approval does not carry to any other action. Action: %s' \
      "$ids" "$label" "$action"
  fi
}

jev_emit_deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
}
