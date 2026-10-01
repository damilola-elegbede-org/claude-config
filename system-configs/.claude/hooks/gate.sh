#!/bin/bash
# Claude Code decision-gate runner (PreToolUse).
#
# One hook that checks every tool call against the rules registry in
# gate-rules.json (same directory) and DENIES the ones that need a human
# decision. It always denies rather than "asks": permissionDecision "ask" is
# ignored under bypassPermissions, and "deny" + a reason is what reaches Claude.
#
# Interactive session : deny with a CHECKPOINT reason telling Claude to put the
#                       action to D via AskUserQuestion. If D approves, Claude
#                       runs `gate.sh approve <hash>` and retries the exact
#                       same action; the approval is good for ONE use, 30 min.
#                       `approve` is model-mediated (D accepted that residual
#                       risk) but verified: it refuses unless the session
#                       transcript shows an AskUserQuestion issued AFTER the
#                       deny whose answer is present and is not a no/deny/
#                       cancel, whose question text carries this checkpoint's
#                       code (first 12 hex of the hash, printed in the
#                       CHECKPOINT reason: an unrelated "Continue?" prompt can
#                       never approve it), and each such question can approve
#                       only one action (claimed atomically with mkdir). The
#                       approval is bound to the action itself
#                       (tool + command/path + written content + cwd + scope),
#                       not to a rule: one approval covers every rule the
#                       action matches. A single-use approval is claimed with
#                       an atomic rename, so concurrent identical calls cannot
#                       both consume it.
# Background job      : (CLAUDE_JOB_DIR set) deny, do not retry, end the report
#                       with `needs input:`.
# Fleet agent         : (BARECLAUDE_AGENT_SLUG set) rule lanes allow specific
#                       agents; exempt_agents are never blocked (decision is
#                       logged as allow-exempt-agent); everyone else is treated
#                       like a background job.
#
# Kill switch  : touch ~/.claude/gate.off (D only; agents are denied from it).
#                Only a REGULAR FILE counts: `mkdir ~/.claude/gate.off` or a
#                symlink does nothing, and G10-tamper denies creating one.
#                gate.off is the MASTER switch for every decision gate, the Jev
#                gates included (jev-gate.sh); jev.off only stops Jev. See
#                hooks/jev/registry.sh for the precedence.
# Registry     : the regex rules live in gate-rules.json (data). Mode overrides
#                (off|shadow|enforce per rule id) and exempt_agents come from the
#                ONE Jev registry (hooks/jev/registry.sh) when it is deployed.
# Log          : ~/.claude/jev/decisions.jsonl (the one decision log) and, as an
#                alias for one release, ~/.claude/gate-log.jsonl. One line per
#                decision. Write/Edit log file_path only, MCP tools log the tool
#                name only, and anything that looks like a secret is never logged.
# State        : ~/.claude/gate-pending/<hash>   written on deny (interactive)
#                ~/.claude/gate-approved/<hash>  written by `gate.sh approve`
#                ~/.claude/gate-asks-used(.d/)   AskUserQuestion ids already spent (.d/ = atomic claims)
#
# Matching text: heredoc bodies and quoted DATA (echo/printf/grep arguments,
# --body/--title/-m/-f body= values) are blanked before rules run, so prose
# about `rm -rf` never trips a rule; the approval identity still uses the exact
# raw command.
#
# Failure policy: every error path exits 0 (fail open, with a loud stderr
# warning), like the inline guards in settings.json. No `set -e`: a non-matching
# test must never kill the hook with an exit code Claude Code reports as an error.
# Bash 3.2 compatible (macOS /bin/bash).

umask 077

CLAUDE_DIR="${HOME:-}/.claude"
PENDING_DIR="$CLAUDE_DIR/gate-pending"
APPROVED_DIR="$CLAUDE_DIR/gate-approved"
ASKS_USED="$CLAUDE_DIR/gate-asks-used"
ASKS_CLAIM_DIR="$ASKS_USED.d"
LOG_FILE="$CLAUDE_DIR/gate-log.jsonl"
KILL_SWITCH="$CLAUDE_DIR/gate.off"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RULES_FILE="$SCRIPT_DIR/gate-rules.json"
APPROVAL_TTL_MIN=30
# The ONE registry reader / decision log (deployed next to the Jev hooks). Missing = the file-local behavior.
REGISTRY_LIB="$SCRIPT_DIR/jev/registry.sh"
HAVE_REGISTRY=0
if [[ -r "$REGISTRY_LIB" ]]; then
    # shellcheck source=jev/registry.sh
    . "$REGISTRY_LIB" 2>/dev/null && HAVE_REGISTRY=1
fi

warn() { printf 'gate.sh: %s\n' "$1" >&2; }

hash_str() {
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(printf '%s' "$1" | sha256sum 2>/dev/null)
    elif command -v shasum >/dev/null 2>&1; then
        out=$(printf '%s' "$1" | shasum -a 256 2>/dev/null)
    else
        out=""
    fi
    printf '%s' "${out%% *}"
}

# phys_path <path> <cwd>: the physical form of <path>: the deepest existing ancestor is resolved
# (cd && pwd -P, which also collapses `..` through symlinks), the not-yet-existing tail is kept, and a final
# symlink is followed (up to 10 hops). Relative paths resolve against <cwd>. Prints nothing on failure.
phys_path() {
    local p="$1" d tail t hops=0
    # shellcheck disable=SC2088 # a literal "~/" prefix in the tool input, not a tilde to expand
    case "$p" in
        "~/"*) p="$HOME/${p#\~/}" ;;
        /*) ;;
        *) p="${2:-$PWD}/$p" ;;
    esac
    while [[ $hops -lt 10 ]]; do
        d="$p"
        tail=""
        while [[ -n "$d" && "$d" != "/" && ! -d "$d" ]]; do
            tail="/$(basename "$d")$tail"
            d=$(dirname "$d")
        done
        d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
        [[ "$d" == "/" ]] && d=""
        p="$d$tail"
        [[ -L "$p" ]] || break
        t=$(readlink "$p") || break
        case "$t" in
            /*) p="$t" ;;
            *) p="$(dirname "$p")/$t" ;;
        esac
        hops=$((hops + 1))
    done
    printf '%s' "$p"
}

# expired <file>: succeeds when the file is older than the approval TTL.
expired() {
    [[ -n "$(find "$1" -mmin +"$APPROVAL_TTL_MIN" 2>/dev/null)" ]]
}

# log_decision <rule> <decision> <tool> <scope> <cwd> <target>
log_decision() {
    mkdir -p "$CLAUDE_DIR" 2>/dev/null || return 0
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rule "$1" --arg decision "$2" \
        --arg tool "$3" --arg scope "$4" --arg cwd "$5" --arg target "$6" \
        '{ts:$ts,rule:$rule,tool:$tool,decision:$decision,scope:$scope,cwd:$cwd,target:$target}' \
        >>"$LOG_FILE" 2>/dev/null || true
    if [[ "$HAVE_REGISTRY" == 1 ]]; then
        jev_decision_log "$1" regex "$2" "" "" "" "" "hook:gate.sh" \
            "$(jq -nc --arg tool "$3" --arg scope "$4" --arg cwd "$5" --arg target "$6" '{tool:$tool,scope:$scope,cwd:$cwd,target:$target}' 2>/dev/null)"
    fi
}

# ask_code <hash>: the short checkpoint code D's question must carry (first 12 hex of the action hash).
ask_code() { printf '%s' "${1:0:12}"; }

# ask_ids_after <transcript> <since-epoch> <code>: prints the tool_use id of every AskUserQuestion issued at or
# after <since> whose question (every string of its input: question, header, option labels) contains <code>
# and whose tool_result carries at least one answer and no answer is a refusal. The answers
# come from toolUseResult.answers (the structured form Claude Code writes) or, failing that, from the
# "question"="answer" pairs in the result text. A dismissed question has no answers and never counts.
ask_ids_after() {
    tail -c 4000000 "$1" 2>/dev/null | jq -R -n -r --argjson since "$2" --arg code "$3" '
        def arr: if type == "array" then .[] else empty end;
        def secs: (. // "" | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0));
        def refusal: test("\\b(deny|denied|no|nope|reject|rejected|cancel|cancelled|canceled|stop|abort|decline|declined|do not|don.?t|not now)\\b"; "i");
        [inputs | fromjson? | select(type == "object")] as $all
        | [$all[] | select(.type == "assistant") | . as $m | (.message.content | arr)
           | select(type == "object" and .type == "tool_use" and .name == "AskUserQuestion")
           | {id: .id, ts: ($m.timestamp | secs), text: ([.input | .. | strings] | join("\n") | ascii_downcase)}
           | select(.ts >= $since and ($code | length) > 0 and (.text | contains($code | ascii_downcase)))] as $asks
        | [$all[] | select(.type == "user") | . as $m | (.message.content | arr)
           | select(type == "object" and .type == "tool_result")
           | . as $r
           | {id: .tool_use_id,
              answers: (($m.toolUseResult.answers? // null) as $a
                | if ($a | type) == "object" then [$a[] | tostring]
                  else ($r.content | if type == "string" then . elif type == "array" then ([.[]? | select(type == "object") | (.text // "")] | join(" ")) else "" end
                        | [scan("\"=\"((?:[^\"\\\\]|\\\\.)*)\"") | .[0]]) end)}] as $res
        | $asks[] | . as $a
        | select([$res[] | select(.id == $a.id) | .answers | select(length > 0 and all(.[]; (gsub("[[:space:]]"; "") | length > 0) and (refusal | not)))] | length > 0)
        | .id' 2>/dev/null
}

cmd_approve() {
    local h="${1:-}"
    if [[ ! "$h" =~ ^[0-9a-f]{64}$ ]]; then
        warn "approve needs the 64-character hash printed in the CHECKPOINT reason"
        return 1
    fi
    if [[ -n "${BARECLAUDE_AGENT_SLUG:-}" || -n "${CLAUDE_JOB_DIR:-}" ]]; then
        warn "approvals are interactive-only: end your report with 'needs input:' instead"
        return 1
    fi
    local pending="$PENDING_DIR/$h"
    if [[ ! -f "$pending" ]]; then
        warn "no pending checkpoint for that hash (never denied, already approved, or expired)"
        return 1
    fi
    if expired "$pending"; then
        rm -f "$pending"
        warn "that checkpoint expired (older than $APPROVAL_TTL_MIN min); retry the action to get a fresh one"
        return 1
    fi

    # Verify D actually answered: an AskUserQuestion after the deny with a non-refusal answer, unspent.
    local tp since ask spent="" claim code
    tp=$(jq -r '.transcript_path // empty' "$pending" 2>/dev/null)
    since=$(jq -r '.ts_epoch // empty' "$pending" 2>/dev/null)
    if [[ -z "$tp" || ! -r "$tp" || ! "$since" =~ ^[0-9]+$ ]]; then
        warn "cannot verify D's answer (no readable session transcript recorded with this checkpoint): ask D with AskUserQuestion, then retry the action to get a fresh checkpoint"
        return 1
    fi
    code=$(ask_code "$h")
    mkdir -p "$ASKS_CLAIM_DIR" 2>/dev/null
    while IFS= read -r ask; do
        [[ -n "$ask" ]] || continue
        if [[ -f "$ASKS_USED" ]] && grep -qxF -- "$ask" "$ASKS_USED"; then continue; fi
        # The claim is a mkdir: of two concurrent approves reading the same unspent question only one wins it.
        claim="$ASKS_CLAIM_DIR/$(printf '%s' "$ask" | tr -c 'A-Za-z0-9_-' '_')"
        if mkdir "$claim" 2>/dev/null; then
            spent="$ask"
            break
        fi
    done < <(ask_ids_after "$tp" "$since" "$code")
    if [[ -z "$spent" ]]; then
        warn "refused: no unspent AskUserQuestion answered by D after this checkpoint names its code $code (or its answer was a no/deny/cancel, or it already approved another action). Put the exact action to D with AskUserQuestion, include the code $code in the question text, then approve."
        return 1
    fi

    mkdir -p "$APPROVED_DIR" 2>/dev/null
    if mv "$pending" "$APPROVED_DIR/$h" 2>/dev/null; then
        touch "$APPROVED_DIR/$h"
        printf '%s\n' "$spent" >>"$ASKS_USED" 2>/dev/null
        log_decision "approve" "approved" "gate.sh" "interactive" "${PWD:-}" "$h"
        printf 'approved: retry the exact same action within %s minutes (single use)\n' "$APPROVAL_TTL_MIN"
        return 0
    fi
    rmdir "$claim" 2>/dev/null # not approved after all: give the question back
    warn "could not record the approval"
    return 1
}

# claim_approval <hash>: succeeds for exactly ONE caller per approval. The approval file is renamed to a
# per-process name (atomic), so of several concurrent identical calls only the winner proceeds.
claim_approval() {
    local f="$APPROVED_DIR/$1" mine="$APPROVED_DIR/.claim.$1.$$"
    [[ -f "$f" ]] || return 1
    mv "$f" "$mine" 2>/dev/null || return 1
    if expired "$mine"; then
        rm -f "$mine"
        return 1
    fi
    rm -f "$mine"
    return 0
}

if [[ "${1:-}" == "approve" ]]; then
    cmd_approve "${2:-}"
    exit $?
fi

[[ -n "${HOME:-}" ]] || exit 0
# Only a regular file is the kill switch (a directory or symlink created by an agent is not).
[[ -f "$KILL_SWITCH" && ! -L "$KILL_SWITCH" ]] && exit 0

if ! command -v jq >/dev/null 2>&1; then
    warn "jq missing — Claude Code decision gates are disabled"
    exit 0
fi
if [[ ! -r "$RULES_FILE" ]]; then
    warn "rules file $RULES_FILE unreadable — decision gates are disabled"
    exit 0
fi

INPUT=$(cat)

SCOPE="interactive"
[[ -n "${CLAUDE_JOB_DIR:-}" ]] && SCOPE="bgjob"
[[ -n "${BARECLAUDE_AGENT_SLUG:-}" ]] && SCOPE="fleet"

# One jq call evaluates every rule against the tool call and returns the matches.
read -r -d '' JQ_PROG <<'JQEOF'
def esc: gsub("(?<x>[.\\[\\]\\\\^$*+?(){}|/-])"; "\\\(.x)");
def never: "@@NEVER@@";
# Heredoc bodies are data, unless the heredoc feeds a shell (bash/sh <<EOF, ssh host <<EOF, eval, source).
def strip_heredocs:
  split("\n")
  | reduce .[] as $l ({out: [], hd: null};
      if .hd != null then
        (.hd as $w | if ($l | test("^[[:space:]]*" + $w + "[[:space:]]*$")) then .hd = null else . end)
      else
        .out += [$l]
        | (if ($l | test("(?<!<)<<(?!<)-?[[:space:]]*[\"']?[A-Za-z_][A-Za-z0-9_]*"))
              and (($l | test("(?:^|[^A-Za-z0-9_./-])(?:(?:ba|z|da|k)?sh|ssh|eval|source)(?:[[:space:]]|$)")) | not)
           then .hd = ($l | capture("(?<!<)<<(?!<)-?[[:space:]]*[\"']?(?<w>[A-Za-z_][A-Za-z0-9_]*)").w)
           else . end)
      end)
  | .out | join("\n");
# A double-quoted string WITHOUT command substitution, a single-quoted string, a bare word.
def dq: "\"(?:(?!\\$\\(|`)(?:[^\"\\\\]|\\\\.))*\"";
def sq: "'[^']*'";
# A bare word must END at whitespace or a separator: "2" in "2>/dev/null" (an fd, not an argument) is not a token,
# so redirections stay visible to the rules.
def tok: "(?:" + dq + "|" + sq + "|[^[:space:];&|<>\"'`()]+(?![^[:space:];&|\"'`()]))";
# Quoted text that is DATA, not a command, is blanked: values of --body/--title/--message/-m/-f body=,
# and every argument of echo/printf/grep/rg/ag. Skipped entirely when the text could be executed
# (piped into a shell, eval, xargs) and for strings containing $( or a backtick.
def blank_data:
  if test("\\|[[:space:]]*(?:sudo[[:space:]]+)?(?:(?:ba|z|da|k)?sh|xargs)(?:[[:space:]]|$)|(?:^|[^A-Za-z0-9_])eval[[:space:]]") then .
  else
    gsub("(?<f>(?:--body|--title|--message|--notes|--subject|--description|--comment|-m|-b|-t)(?:[[:space:]]+|=))(?:" + dq + "|" + sq + ")"; "\(.f)\"\"")
    | gsub("(?<f>(?:-f|-F|--field|--raw-field)[[:space:]]+(?:body|title|message|comment|commit_message|description|text)=)(?:" + dq + "|" + sq + ")"; "\(.f)\"\"")
    | gsub("(?<h>(?:^|[;&|(\\n`])[[:space:]]*(?:(?:/usr)?/bin/)?(?:echo|printf|grep|egrep|fgrep|rg|ag)(?:[[:space:]]+-[A-Za-z-]+)*)(?:[[:space:]]+" + tok + ")+"; "\(.h) \"\"")
  end;
$rules[0] as $R
| (($R.macros // {}) + {
    HOME: (if $home_phys != "" and $home_phys != $home then "(?:" + ($home | esc) + "|" + ($home_phys | esc) + ")" else ($home | esc) end),
    TMPDIR: (if $tmpdir == "" then never else ($tmpdir | rtrimstr("/") | esc) end),
    JOBDIR: (if $jobdir == "" then never else ($jobdir | rtrimstr("/") | esc) end)
  }) as $M
| def expand: reduce range(0; 3) as $i (.; reduce ($M | to_entries[]) as $m (.; gsub("\\{\\{" + $m.key + "\\}\\}"; $m.value)));
(.tool_name // "") as $tn
| (.tool_input | if type == "object" then . else {} end) as $ti
| (.cwd // "") as $cwd
| (if $tn == "Bash" then (($ti.command // "") | if type == "string" then (strip_heredocs | blank_data) else "" end) else "" end) as $cc
| def normpath:
    if type != "string" then ""
    else sub("^~/"; $home + "/")
      | if startswith("/")
        then "/" + ([split("/")[] | select(. != "" and . != ".")]
                    | reduce .[] as $s ([]; if $s == ".." then .[:-1] else . + [$s] end)
                    | join("/"))
        else . end
    end;
def fv($f):
  if $f == "_tool_name" then $tn
  elif $f == "content" then ([$ti.content?, $ti.new_string?, ($ti.edits[]?.new_string?)] | map(select(type == "string")) | join("\n"))
  elif $f == "file_path" then ($ti.file_path | normpath)
  elif $f == "command" and $tn == "Bash" then $cc
  else ($ti[$f] // "" | if type == "string" then . else tojson end)
  end;
def hits($r):
  ($r.flags // "") as $fl
  | (if $r.pattern == null then [$tn]
     else
       ($r.pattern | expand) as $p0
       | (if $r.anchor == "cmd"
          then (($M.SEP | expand) + "(?<c>" + ($M.PFX | expand) + "(?:" + $p0 + ")[^;&|\\n]*)")
          else $p0 end) as $p
       | [fv($r.field // "command") | match($p; "g" + $fl) | ((.captures[] | select(.name == "c") | .string) // .string)]
     end)
  | map(select(. != null))
  | if $r.exempt == null then . else map(select(test($r.exempt | expand; $fl) | not)) end;
def secret: "AKIA[0-9A-Z]{16}|sk-[a-zA-Z0-9]{20,}|gh[pousr]_[a-zA-Z0-9]{20,}|xox[abprs]-[0-9a-zA-Z-]{10,}|glpat-[a-zA-Z0-9_-]{20}|-----BEGIN [A-Z ]*PRIVATE KEY|eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{10,}|(?:password|passwd|secret|token|api[_-]?key|authorization)[^[:space:]]*[=:][[:space:]]*[^[:space:]]+|bearer[[:space:]]+[A-Za-z0-9._-]{8,}";
def safe_target:
  (if $tn == "Bash" then ($ti.command // "")
   elif ($ti.file_path? // null) != null then fv("file_path")
   else "" end) as $t
  | if ($t | test(secret; "i")) then "[redacted:secret-pattern]" else $t[0:300] end;
# The approval identity: the ACTION (tool, exact raw command or path+written content, cwd, scope), never a rule.
def subject:
  if $tn == "Bash" then ($ti.command // "")
  elif ($ti.file_path? // null) != null then fv("file_path") + "\u001e" + fv("content")
  else ($ti | tojson) end;
def action_id: $tn + "\u001f" + subject + "\u001f" + $cwd + "\u001f" + $scope;
("^[[:space:]]*(?:~|\"?\\$\\{?HOME\\}?\"?|" + ($home | esc) + ")/\\.claude/hooks/gate\\.sh\"?[[:space:]]+approve[[:space:]]+[0-9a-f]{64}[[:space:]]*\\z") as $approve_re
| if $tn == "Bash" and (($ti.command // "") | test($approve_re)) then {errors: [], matches: [], exempt_agent: false, action: ""}
  else
    [ $R.rules[] | . as $r
      | select(($r.scope // ["interactive", "bgjob", "fleet"]) | any(. == $scope))
      | select($tn | test($r.tools; ($r.flags // "")))
      | select(($r.path == null) or (fv("file_path") | test($r.path; ($r.flags // ""))))
      | select(($r.exempt_path == null) or ((fv("file_path") | test($r.exempt_path; "")) | not))
      | select(($r.exempt_fields == null) or ([$r.exempt_fields | to_entries[] | . as $e | select(fv($e.key) | test($e.value; ""))] | length == 0))
      | select(($r.exempt_all == null) or ((fv($r.field // "command") | test($r.exempt_all | expand; ($r.flags // ""))) | not))
      | (try hits($r) catch "ERR") as $h
      | if $h == "ERR" then {error: $r.id}
        elif ($h | length) > 0 then
          {id: $r.id, class: $r.class, message: $r.message, enforce: ($r.enforce != false),
           lane_allowed: ($scope == "fleet" and (($r.lanes // {})[$slug] == "allow")),
           target: safe_target}
        else empty end ]
    | {errors: [.[] | select(.error != null) | .error],
       matches: [.[] | select(.error == null)],
       exempt_agent: ($slug != "" and (($R.exempt_agents // []) | any(. == $slug))),
       action: action_id}
  end
JQEOF

HOME_PHYS=$(cd "$HOME" 2>/dev/null && pwd -P)

eval_rules() { # <input json> -> the matches JSON on stdout
    printf '%s' "$1" | jq -c --slurpfile rules "$RULES_FILE" \
        --arg home "$HOME" --arg home_phys "${HOME_PHYS:-}" --arg tmpdir "${TMPDIR:-}" --arg jobdir "${CLAUDE_JOB_DIR:-}" \
        --arg scope "$SCOPE" --arg slug "${BARECLAUDE_AGENT_SLUG:-}" "$JQ_PROG" 2>&1
}

RESULT=$(eval_rules "$INPUT")
if [[ $? -ne 0 ]]; then
    warn "rule evaluation failed — decision gates skipped for this call: ${RESULT:0:200}"
    exit 0
fi

# A Write/Edit through a symlinked parent (or onto a symlink) changes the file the link points at, so the
# path rules also run against the PHYSICAL path; the approval identity and the log keep the lexical form.
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path? // empty | strings' 2>/dev/null)
if [[ -n "$FILE_PATH" ]]; then
    PHYS=$(phys_path "$FILE_PATH" "$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)")
    if [[ -n "$PHYS" && "$PHYS" != "$FILE_PATH" ]]; then
        RESULT2=$(eval_rules "$(printf '%s' "$INPUT" | jq -c --arg p "$PHYS" '.tool_input.file_path = $p' 2>/dev/null)")
        if [[ $? -eq 0 ]] && MERGED=$(printf '%s' "$RESULT" | jq -c --argjson b "$RESULT2" \
            '. as $a | .matches += [$b.matches[] | select(.id as $i | ($a.matches | map(.id) | index($i)) == null)] | .errors += $b.errors' 2>/dev/null); then
            RESULT="$MERGED"
        fi
    fi
fi

while IFS= read -r bad; do
    [[ -n "$bad" ]] && warn "rule $bad failed to evaluate (bad regex?) — it was skipped"
done < <(printf '%s' "$RESULT" | jq -r '.errors[]' 2>/dev/null)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
CWD="${CWD:-$PWD}"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
EXEMPT_AGENT=$(printf '%s' "$RESULT" | jq -r '.exempt_agent' 2>/dev/null)
# A registry layer that sets exempt_agents (rules.d or jev-rules.json) wins over the shipped gate-rules.json list.
if [[ "$HAVE_REGISTRY" == 1 && -n "${BARECLAUDE_AGENT_SLUG:-}" ]]; then
    REG_JSON=$(jev_reg_json)
    if [[ "$(printf '%s' "$REG_JSON" | jq -r '(.exempt_agents | type)' 2>/dev/null)" == "array" ]]; then
        if jev_reg_exempt "$BARECLAUDE_AGENT_SLUG" "$REG_JSON"; then EXEMPT_AGENT=true; else EXEMPT_AGENT=false; fi
    fi
fi

# Pass 1: log shadow / exempt / lane matches, collect the ENFORCED ones. Approvals are per action, so a
# command matching several rules is decided once (no approve-A / approve-B / approve-A deadlock).
BLOCK_IDS=()
BLOCK_MSGS=()
BLOCK_TARGET=""
while IFS= read -r M; do
    [[ -z "$M" ]] && continue
    read -r ID ENFORCE LANE < <(printf '%s' "$M" | jq -r '[.id, (.enforce | tostring), (.lane_allowed | tostring)] | join(" ")')
    TARGET=$(printf '%s' "$M" | jq -r '.target')

    # A registry entry with this rule id overrides the rule's own enforce flag: off | shadow | enforce.
    if [[ "$HAVE_REGISTRY" == 1 ]]; then
        case "$(jev_reg_value "$ID" mode "")" in
            off) continue ;;
            shadow) ENFORCE=false ;;
            enforce) ENFORCE=true ;;
        esac
    fi

    if [[ "$ENFORCE" != "true" ]]; then
        log_decision "$ID" "shadow" "$TOOL" "$SCOPE" "$CWD" "$TARGET"
        continue
    fi
    if [[ "$EXEMPT_AGENT" == "true" ]]; then
        log_decision "$ID" "allow-exempt-agent" "$TOOL" "$SCOPE" "$CWD" "$TARGET"
        continue
    fi
    if [[ "$LANE" == "true" ]]; then
        log_decision "$ID" "allow-by-lane" "$TOOL" "$SCOPE" "$CWD" "$TARGET"
        continue
    fi
    BLOCK_IDS+=("$ID")
    BLOCK_MSGS+=("$(printf '%s' "$M" | jq -r '.message')")
    [[ -z "$BLOCK_TARGET" ]] && BLOCK_TARGET="$TARGET"
done < <(printf '%s' "$RESULT" | jq -c '.matches[]' 2>/dev/null)

[[ ${#BLOCK_IDS[@]} -eq 0 ]] && exit 0

ACTION=$(printf '%s' "$RESULT" | jq -r '.action' 2>/dev/null)
HASH=""
[[ -n "$ACTION" ]] && HASH=$(hash_str "$ACTION")

if [[ -n "$HASH" ]] && claim_approval "$HASH"; then
    for ID in "${BLOCK_IDS[@]}"; do
        log_decision "$ID" "allow-by-approval" "$TOOL" "$SCOPE" "$CWD" "$BLOCK_TARGET"
    done
    exit 0
fi

# Name every matched rule in one reason: the first keeps the "CHECKPOINT <id>:" prefix.
MESSAGE="${BLOCK_MSGS[0]}"
ALSO=""
i=1
while [[ $i -lt ${#BLOCK_IDS[@]} ]]; do
    ALSO="$ALSO Also matched ${BLOCK_IDS[$i]}: ${BLOCK_MSGS[$i]}."
    i=$((i + 1))
done
if [[ "$SCOPE" == "interactive" ]]; then
    if [[ -n "$HASH" ]]; then
        mkdir -p "$PENDING_DIR" 2>/dev/null
        IDS_JSON=$(printf '%s\n' "${BLOCK_IDS[@]}" | jq -R . | jq -sc . 2>/dev/null)
        jq -nc --argjson rules "${IDS_JSON:-[]}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson te "$(date +%s)" \
            --arg sid "$SESSION_ID" --arg tp "$TRANSCRIPT" --arg cwd "$CWD" --arg scope "$SCOPE" \
            '{rules:$rules,ts:$ts,ts_epoch:$te,session_id:$sid,transcript_path:$tp,cwd:$cwd,scope:$scope}' >"$PENDING_DIR/$HASH" 2>/dev/null
        REASON="CHECKPOINT ${BLOCK_IDS[0]}: $MESSAGE.$ALSO Put this action to D via AskUserQuestion: quote the exact action and put the checkpoint code $(ask_code "$HASH") in the question text (approve refuses any question without it). If D approves, run \`~/.claude/hooks/gate.sh approve $HASH\` and retry with the exact same command."
    else
        REASON="CHECKPOINT ${BLOCK_IDS[0]}: $MESSAGE.$ALSO Put this action to D via AskUserQuestion; if D approves, retry with the exact same command."
    fi
else
    REASON="CHECKPOINT ${BLOCK_IDS[0]}: $MESSAGE.$ALSO Do not retry; end your report with \`needs input:\` naming this action."
fi
for ID in "${BLOCK_IDS[@]}"; do
    log_decision "$ID" "deny" "$TOOL" "$SCOPE" "$CWD" "$BLOCK_TARGET"
done
jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
