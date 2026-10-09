#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2154 # RULES is the global the caller (jev-gate.sh) sets (RULES=$(jev_rules_json))
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
JEV_STATE_DIR="${JEV_STATE_DIR:-$JEV_CLAUDE_DIR/jev-state}"
# Legacy per-hook log, kept as an ALIAS for one release; decisions.jsonl (registry.sh) is the log to read.
JEV_GATE_LOG="${JEV_GATE_LOG:-$JEV_CLAUDE_DIR/jev-gates.jsonl}"
JEV_APPROVAL_LOG="$JEV_STATE_DIR/approvals.log"

# The ONE registry reader, the decision log and the kill-switch rules (jev/registry.sh). Sourcing it can
# fail on a partial deploy: the callers' `|| exit 0` then fail open, like every other missing dependency.
# shellcheck source=jev/registry.sh
. "$JEV_DIR/registry.sh" || return 1

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

# Merged registry (rules + questions): jev_reg_json in registry.sh is the one reader. Callers keep the
# result in the global RULES; the question helpers below read the questions out of it.
jev_rules_json() {
  jev_reg_json
}

# jev_is_exempt RULES_JSON -> 0 when the fleet agent is on the exempt list (default clara).
jev_is_exempt() {
  [ -n "$JEV_SLUG" ] || return 1
  jev_reg_exempt "$JEV_SLUG" "$1"
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
    s{(\b[A-Za-z0-9_-]*(?:key|token|secret|pass|pwd|credential|auth)[A-Za-z0-9_-]*\s*[=:]\s*)(?:(\\"|")[^"\\]*|(\x27)[^\x27\\"]*|[^\s"\x27\\]+)}{$1.(defined $2 ? $2 : defined $3 ? $3 : "")."[REDACTED]"}gie; # redaction pattern: NAME=value, NAME: value, export NAME=..., --flag=value: any length, quoted or not
    s{(--[A-Za-z0-9_-]*(?:key|token|secret|pass|pwd|credential|auth)[A-Za-z0-9_-]*\s+)(?!-)(?:(\\"|")[^"\\]*|(\x27)[^\x27\\"]*|[^\s"\x27\\]+)}{$1.(defined $2 ? $2 : defined $3 ? $3 : "")."[REDACTED]"}gie; # --password VALUE
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
# {turns:[{role,text}], untrusted:[{source,text}], d_uuid, d_epoch, d_ask, has_d}.
# Genuine D turns = real user messages + AskUserQuestion answers. Every other tool_result from
# web/MCP/gh/curl is untrusted. Gmail/Slack bodies are withheld (egress rule). `untrusted` holds only the
# content that arrived AFTER the last genuine D turn (what Claude read this turn). d_epoch is the last D
# turn's timestamp (null when absent) and d_ask says that turn was an AskUserQuestion answer.
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
            elif ($c | test("<command-name>")) then {r:"D", t:($c | slash), u:$m.uuid, ts:$m.timestamp}
            elif ($c | isharness) then empty
            else ($c | strip) as $s | if ($s | length) > 0 then {r:"D", t:($s | clip(600)), u:$m.uuid, ts:$m.timestamp} else empty end
            end
        else
          (($c // []) | if type=="array" then . else [] end)[] | select(type=="object")
          | if .type=="text" then
              (.text | strip) as $s
              | if ($s | length) > 0 and (($s | isharness) | not) then {r:"D", t:($s | clip(600)), u:$m.uuid, ts:$m.timestamp} else empty end
            elif .type=="tool_result" then
              ($tools[.tool_use_id] // {n:"", c:""}) as $tl
              | (.content | txt) as $b
              | if $tl.n == "AskUserQuestion" then {r:"D", t:($b | if length > 800 then .[0:350] + " ... " + .[-450:] else . end), u:$m.uuid, ts:$m.timestamp, ask:true}
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
| ($en | map(select(.value.r=="D")) | last // null) as $lastdE
| ($lastdE.value // null) as $lastd
| ($en | map(select(.value.r=="untrusted" and .key > ($lastdE.key // -1))) | .[-3:] | map(.value)) as $un
| {turns: ($turns | map({role: (if .r=="D" then "D" else "claude" end), text: .t})),
   untrusted: ($un | map({source: .src, text: .t})),
   d_uuid: ($lastd.u // ""),
   d_epoch: (try ($lastd.ts | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null),
   d_ask: (($lastd.ask // false) == true),
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
  printf '%s' '{"turns":[],"untrusted":[],"d_uuid":"","d_epoch":null,"d_ask":false,"has_d":false}'
}

# ---------------------------------------------------------------- Jev calls --

# jev_call REQUEST_JSON -> response JSON on stdout; returns 3 when Jev is unavailable. Callers run it in a
# command substitution, so they pass a good response to jev_note in their own shell afterwards.
jev_call() {
  local out
  [ -x "$JEV_ASK" ] || return 3
  out=$(printf '%s' "$1" | "$JEV_ASK" 2>/dev/null) || return 3
  printf '%s' "$out" | jq -e '.answers | type == "object"' >/dev/null 2>&1 || return 3
  printf '%s' "$out"
}

# jev_note RESPONSE -> remembers the response's answers, model and latency (JEV_LAST_*) so the decision
# lines logged after this call carry them. One jq spawn.
jev_note() {
  local row
  # "-" stands for an absent field: a tab-separated read would collapse an empty one and shift the rest.
  row=$(printf '%s' "$1" | jq -r '[(.answers | tojson), (.model // "-"), ((.latency_ms // "-") | tostring)] | @tsv' 2>/dev/null) || return 0
  IFS=$'\t' read -r JEV_LAST_ANSWERS JEV_LAST_MODEL JEV_LAST_LATENCY <<<"$row"
  [ "$JEV_LAST_MODEL" = "-" ] && JEV_LAST_MODEL=""
  [ "$JEV_LAST_LATENCY" = "-" ] && JEV_LAST_LATENCY=""
  return 0
}

# jev_build_request RULE STATE_JSON UNTRUSTED_JSON QUESTIONS_JSON -> request JSON
# JEV_EGRESS_PATHS (JSON array, optional): paths the action targets; the client refuses egress when any is
# inside an excluded tree (a relative one resolves against JEV_EGRESS_CWD).
jev_build_request() {
  jq -nc --arg rule "$1" --argjson state "$2" --argjson un "$3" --argjson q "$4" \
    --argjson paths "${JEV_EGRESS_PATHS:-[]}" --arg cwd "${JEV_EGRESS_CWD:-}" '
    {rule:$rule, state:$state, questions:$q} + (if ($un | length) > 0 then {untrusted:$un} else {} end)
    + (if ($paths | length) > 0 then {paths:$paths} + (if $cwd != "" then {cwd:$cwd} else {} end) else {} end)'
}

# The question helpers read the merged registry (registry.sh) out of the global RULES the caller set.

# jev_bool_questions IDS_JSON -> {id: {type:"boolean", instructions, criteria}}
jev_bool_questions() {
  printf '%s' "$RULES" | jq -c --argjson ids "$1" '
    . as $d | $ids | map({key: ., value: {type:"boolean", instructions: $d[.].instructions, criteria: $d[.].criteria}}) | from_entries'
}

# jev_gate_questions IDS_JSON -> the questions object for ONE call covering every candidate gate.
# Gates with an `expects` block share choice questions, each asked once however many gates need it (choice
# probabilities are calibrated; a boolean's |2p-1| is not): the risk gates (G1, G3-G8, G13) share risk_class
# and scope, G15 asks origin. Gates without `expects` (G14, ...) keep their own boolean question in the same
# call. JEV_EXTRA_QUESTIONS (a JSON object, optional) adds further questions to the same call.
jev_gate_questions() {
  local extra="${JEV_EXTRA_QUESTIONS:-}"
  [ -n "$extra" ] || extra='{}'
  printf '%s' "$RULES" | jq -c --argjson ids "$1" --argjson extra "$extra" '
    . as $d
    | ($ids | map(select($d[.].expects != null))) as $cls
    | ($ids | map(select($d[.].expects == null))) as $bools
    | ([$cls[] | $d[.].expects | keys[]] | unique) as $k0
    | ($k0 + (if ($k0 | index("risk_class")) != null then ["scope"] else [] end)) as $names
    | ($d.choice_questions | with_entries(select(.key as $k | $names | index($k) != null)) | map_values({type: "choice", instructions, criteria}))
      + ($bools | map({key: ., value: {type: "boolean", instructions: $d[.].instructions, criteria: $d[.].criteria}}) | from_entries)
      + $extra'
}

# jev_gate_scores RESPONSE IDS_JSON -> one TSV line per gate: "id<TAB>p<TAB>scope_ok" (p is "-" when the answer is
# absent). A choice gate's p is the summed probability of its expected options (expects.risk_class, else
# expects.origin); scope_ok is 0 only when the gate names expected scopes, the scope answer is present, and
# their summed probability is below 0.5.
jev_gate_scores() {
  jq -nr --argjson reg "$RULES" --argjson r "$1" --argjson ids "$2" '
    def probs: (.probabilities // (if .choice then {(.choice): 1} else {} end));
    def psum($a; $opts): ($a | probs) as $p | [$opts[] | ($p[.] // 0)] | add // 0;
    $ids[] as $id | ($reg[$id].expects) as $e
    | if $e == null then [$id, ($r.answers[$id].probability // "-" | tostring), 1]
      else
        ($e | if has("risk_class") then "risk_class" else (keys - ["scope"])[0] end) as $k
        | [$id,
           (if $r.answers[$k] == null then "-" else (psum($r.answers[$k]; $e[$k]) | tostring) end),
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

# jev_log RULE VERDICT [MODE] [PROB] -- writes the decision line (decisions.jsonl, the log to read) and the
# legacy jev-gates.jsonl alias. The decision line carries `action`, the redacted display string (ACTION, or
# ACTION_DISPLAY when set) cut to 200 chars, next to the action sha; never file contents or heredoc bodies.
# JEV_LOG_EXTRA (a JSON object, optional) is merged into the line.
jev_log() {
  local disp xtra="${JEV_LOG_EXTRA:-}"
  disp="${ACTION_DISPLAY:-${ACTION:-}}"
  disp=$(jev_trim "$disp" 195)
  [ -n "$xtra" ] || xtra='{}'
  jev_decision_log "$1" "${3:-}" "$2" "${4:-}" "${JEV_LAST_ANSWERS:-}" "${JEV_LAST_MODEL:-}" "${JEV_LAST_LATENCY:-}" "hook:${JEV_HOOK_NAME:-jev-gate}" \
    "$(jq -nc --arg tool "${TOOL:-}" --arg ctx "${JEV_CTX:-}" --arg act "${ACTION_SHA:-}" --arg slug "${JEV_SLUG:-}" --arg action "$disp" --argjson xtra "$xtra" \
      '{tool:$tool, ctx:$ctx, agent:$slug, action_sha:$act} + (if $action != "" then {action:$action} else {} end) + $xtra' 2>/dev/null)"
  mkdir -p "$(dirname "$JEV_GATE_LOG")" 2>/dev/null || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rule "$1" --arg v "$2" --arg mode "${3:-}" \
    --arg p "${4:-}" --arg tool "${TOOL:-}" --arg ctx "${JEV_CTX:-}" --arg act "${ACTION_SHA:-}" \
    --arg slug "${JEV_SLUG:-}" '
    {ts:$ts, rule:$rule, verdict:$v, mode:$mode, p:($p | tonumber? // null), tool:$tool, ctx:$ctx, agent:$slug, action_sha:$act}' \
    >>"$JEV_GATE_LOG" 2>/dev/null || true
}

# --------------------------------------------------------------- one-shot state --

# An approval is consumed by CLAIMING its key: a mkdir under approvals.d/ (atomic, so of two concurrent
# identical calls only one wins), mirrored in approvals.log for the audit trail.
JEV_APPROVAL_CLAIMS="$JEV_STATE_DIR/approvals.d"

# jev_stamp_seen KEY -> 0 when this approval was already consumed.
jev_stamp_seen() {
  [ -d "$JEV_APPROVAL_CLAIMS/$(jev_sha "$1")" ] && return 0
  [ -f "$JEV_APPROVAL_LOG" ] && grep -qxF -- "$1" "$JEV_APPROVAL_LOG"
}

# jev_stamp_claim KEY -> 0 for exactly ONE caller per key; 1 when the key was already claimed.
# Fails closed: when the claim directory cannot be created the approval is not granted.
jev_stamp_claim() {
  mkdir -p "$JEV_APPROVAL_CLAIMS" 2>/dev/null || return 1
  mkdir "$JEV_APPROVAL_CLAIMS/$(jev_sha "$1")" 2>/dev/null || return 1
  printf '%s\n' "$1" >>"$JEV_APPROVAL_LOG" 2>/dev/null || true
  return 0
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

# jev_deny_reason ID_LIST LABEL ACTION -> wording per context. Interactive and job sessions (no subagent) can
# put the action to D; fleet agents and subagents cannot, so they hand off with `needs input:`.
jev_deny_reason() {
  local ids="$1" label="$2" action="${3:0:300}"
  if [ -n "${JEV_SUBAGENT:-}" ] || [ "${JEV_CTX:-interactive}" = "fleet" ]; then
    printf 'Jev gate [%s]: %s needs D, and this session cannot ask. Do not retry or work around it. End your final message with `needs input:` followed by the action and the decision D must make. Action: %s' \
      "$ids" "$label" "$action"
  elif [ "${JEV_CTX:-interactive}" = "bgjob" ]; then
    printf 'Jev gate [%s]: %s. Put this to D via AskUserQuestion before doing it (one question, state the exact action). If D approves exactly this action, retry it once; the approval does not carry to any other action. If D does not answer, do not retry or work around it: end your final message with `needs input:` naming the action. Action: %s' \
      "$ids" "$label" "$action"
  else
    printf 'Jev gate [%s]: %s. Put this to D via AskUserQuestion before doing it (one question, state the exact action). If D approves exactly this action, retry it once; the approval does not carry to any other action. Action: %s' \
      "$ids" "$label" "$action"
  fi
}

# ------------------------------------------------------------- deny trail --

# jev_g1_context COMMAND -> JSON {deleted_paths, created_in_command, script_calls} when the command deletes
# (rm, rmdir, unlink, shred, srm), else nothing. Plain statement-level parsing, no shell evaluation: paths
# written by redirects, mkdir, touch, tee and the target of cp/mv/install count as created; script_calls
# lists interpreter or ./script invocations. A path counts as created only if it does not exist yet (this runs
# before the command): relative paths resolve against CWD (2nd arg, default $CWD from jev-gate.sh) and are omitted
# when the cwd is unknown, after a cd, or when the path has expansions. scripts/jev-replay.py g1_context() mirrors this.
jev_g1_context() {
  printf '%s' "$1" | jev_redact | JEV_G1_CWD="${2:-${CWD:-}}" perl -MJSON::PP -0777 -ne '
    my (@del, @new, @scr, %cdat);
    my $cdseen = 0;
    my $add = sub {
      my ($l, $v) = @_;
      $v =~ s/^["\x27]+//;
      $v =~ s/["\x27]+$//;
      return if $v eq "" || length($v) > 160;
      $cdat{$v} = $cdseen if $l == \@new && !exists $cdat{$v};
      push @$l, $v unless grep { $_ eq $v } @$l;
    };
    foreach my $stmt (split /\|\||&&|[;&|\n]/) {
      while ($stmt =~ /(?<![<>0-9&])>>?\s*([^\s;&|<>()]+)/g) {
        my $t = $1;
        $add->(\@new, $t) unless $t =~ m{^/dev/};
      }
      (my $s = $stmt) =~ s/[0-9]*(?:>>?|<)\s*[^\s;&|<>()]*//g;
      $s =~ s/\s+$//;
      $s =~ s/^\s*[({]?\s*//;
      while ($s =~ s/^[A-Za-z_]\w*=(?:"[^"]*"|\x27[^\x27]*\x27|\S*)\s+//) { }
      $s =~ s/^(?:sudo|command)\s+//;
      my @w = $s =~ /"[^"]*"|\x27[^\x27]*\x27|\S+/g;
      my $cmd = shift @w;
      next unless defined $cmd;
      $cdseen = 1 if $cmd =~ /^(?:cd|pushd)$/;
      my @args = grep { !/^-/ } @w;
      if ($cmd =~ /^(?:rm|rmdir|unlink|shred|srm)$/) { $add->(\@del, $_) for @args; }
      elsif ($cmd =~ /^(?:mkdir|touch|tee)$/) { $add->(\@new, $_) for @args; }
      elsif ($cmd =~ /^(?:cp|mv|install)$/) { $add->(\@new, $args[-1]) if @args >= 2; }
      elsif ($cmd =~ /^(?:python3?|node|bash|sh|zsh|ruby|perl|deno|bun|uv)$/ && @args) { push @scr, substr($s, 0, 80) if @scr < 3; }
      elsif ($cmd =~ m{^\./}) { push @scr, substr($s, 0, 80) if @scr < 3; }
    }
    if (@del) {
      my $cwd = $ENV{JEV_G1_CWD}; $cwd = "" if !defined $cwd || $cwd !~ m{^/};
      my @keep;
      foreach my $v (@new) {
        my $p = $v;
        if ($p =~ m{^~(?:/|$)}) { next unless length($ENV{HOME} // ""); $p =~ s{^~}{$ENV{HOME}}; }
        next if $p =~ m{^~};
        next if $p =~ /[\$`*?\[\]{}\\]/;
        if ($p !~ m{^/}) { next if $cwd eq "" || $cdat{$v}; $p = "$cwd/$p"; }
        next if -e $p || -l $p;
        push @keep, $v;
      }
      @new = @keep;
      splice(@del, 6) if @del > 6;
      splice(@new, 8) if @new > 8;
      print JSON::PP->new->canonical->encode({deleted_paths => \@del, created_in_command => \@new, script_calls => \@scr});
    }
  ' 2>/dev/null
}

# jev_norm TEXT -> the normalized action stored in the deny trail: whitespace collapsed, trimmed, redacted,
# first 500 chars.
jev_norm() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | jev_redact | head -c 500
}

# jev_deny_session -> the session id for the deny trail (hook input, else CLAUDE_CODE_SESSION_ID); fails when
# none is usable as a file name.
jev_deny_session() {
  local s="${SESSION:-}"
  if [ -z "$s" ] || [ "$s" = "-" ]; then s="${CLAUDE_CODE_SESSION_ID:-}"; fi
  case "$s" in
    "" | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$s"
}

JEV_LAST_DENY_DIR="${JEV_CLAUDE_DIR}/jev-state/last-deny"

# jev_write_last_deny RULE -> overwrites last-deny/<session>.json with the action that was just denied:
# {ts, epoch, src, tool, rule, norm}. Reader: jev-gate.sh (retry detector, bgjob approval). NORM_RAW is the
# command (or file path) the caller set. Always returns 0.
jev_write_last_deny() {
  local sid epoch tmp
  sid=$(jev_deny_session) || return 0
  epoch=$(date +%s)
  (
    umask 077
    mkdir -p "$JEV_LAST_DENY_DIR" 2>/dev/null || exit 0
    tmp=$(mktemp "$JEV_LAST_DENY_DIR/.tmp.XXXXXX" 2>/dev/null) || exit 0
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$epoch" --arg tool "${TOOL:-}" --arg rule "$1" --arg norm "$(jev_norm "${NORM_RAW:-${ACTION:-}}")" \
      '{ts:$ts, epoch:$epoch, src:"jev-gate", tool:$tool, rule:$rule, norm:$norm}' >"$tmp" 2>/dev/null &&
      mv "$tmp" "$JEV_LAST_DENY_DIR/$sid.json" 2>/dev/null || rm -f "$tmp"
  ) 2>/dev/null
  return 0
}

# jev_retry_prior NORM -> one JSON line {sim, rule, src, age, norm} when the session's last deny is at most 600 s
# old, was for the same tool, and the current action differs from it with token-set Jaccard similarity >= 0.5;
# nothing otherwise.
jev_retry_prior() {
  local sid f
  sid=$(jev_deny_session) || return 0
  f="$JEV_LAST_DENY_DIR/$sid.json"
  [ -f "$f" ] || return 0
  jq -c --arg tool "${TOOL:-}" --arg norm "$1" --argjson now "$(date +%s)" '
    def toks: split(" ") | map(select(length > 0)) | unique;
    select(.tool == $tool and .norm != $norm and (($now - (.epoch // 0)) <= 600))
    | (.norm | toks) as $x | ($norm | toks) as $y
    | (($x | length) + ($y | length)) as $total | (($x - ($x - $y)) | length) as $inter
    | select(($total - $inter) > 0)
    | ($inter / ($total - $inter)) as $sim
    | select($sim >= 0.5)
    | {sim: (($sim * 100 | round) / 100), rule, src, age: ($now - .epoch), norm}' "$f" 2>/dev/null
}

jev_emit_deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
}
