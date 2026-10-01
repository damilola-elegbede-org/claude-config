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
# Background job      : (CLAUDE_JOB_DIR set) deny, do not retry, end the report
#                       with `needs input:`.
# Fleet agent         : (BARECLAUDE_AGENT_SLUG set) rule lanes allow specific
#                       agents; exempt_agents are never blocked (decision is
#                       logged as allow-exempt-agent); everyone else is treated
#                       like a background job.
#
# Kill switch  : touch ~/.claude/gate.off (D only; agents are denied from it).
# Log          : ~/.claude/gate-log.jsonl, one line per decision. Write/Edit log
#                file_path only, MCP tools log the tool name only, and anything
#                that looks like a secret is never logged.
# State        : ~/.claude/gate-pending/<hash>   written on deny (interactive)
#                ~/.claude/gate-approved/<hash>  written by `gate.sh approve`
#
# Failure policy: every error path exits 0 (fail open, with a loud stderr
# warning), like the inline guards in settings.json. No `set -e`: a non-matching
# test must never kill the hook with an exit code Claude Code reports as an error.
# Bash 3.2 compatible (macOS /bin/bash).

umask 077

CLAUDE_DIR="${HOME:-}/.claude"
PENDING_DIR="$CLAUDE_DIR/gate-pending"
APPROVED_DIR="$CLAUDE_DIR/gate-approved"
LOG_FILE="$CLAUDE_DIR/gate-log.jsonl"
KILL_SWITCH="$CLAUDE_DIR/gate.off"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
RULES_FILE="$SCRIPT_DIR/gate-rules.json"
APPROVAL_TTL_MIN=30

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
    mkdir -p "$APPROVED_DIR" 2>/dev/null
    if mv "$pending" "$APPROVED_DIR/$h" 2>/dev/null; then
        touch "$APPROVED_DIR/$h"
        log_decision "approve" "approved" "gate.sh" "interactive" "${PWD:-}" "$h"
        printf 'approved: retry the exact same action within %s minutes (single use)\n' "$APPROVAL_TTL_MIN"
        return 0
    fi
    warn "could not record the approval"
    return 1
}

if [[ "${1:-}" == "approve" ]]; then
    cmd_approve "${2:-}"
    exit $?
fi

[[ -n "${HOME:-}" ]] || exit 0
[[ -e "$KILL_SWITCH" ]] && exit 0

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
$rules[0] as $R
| (($R.macros // {}) + {
    HOME: ($home | esc),
    TMPDIR: (if $tmpdir == "" then never else ($tmpdir | rtrimstr("/") | esc) end),
    JOBDIR: (if $jobdir == "" then never else ($jobdir | rtrimstr("/") | esc) end)
  }) as $M
| def expand: reduce range(0; 3) as $i (.; reduce ($M | to_entries[]) as $m (.; gsub("\\{\\{" + $m.key + "\\}\\}"; $m.value)));
(.tool_name // "") as $tn
| (.tool_input | if type == "object" then . else {} end) as $ti
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
def subject:
  if $tn == "Bash" then ($ti.command // "")
  elif ($ti.file_path? // null) != null then fv("file_path")
  else ($ti | tojson) end;
("^[[:space:]]*(?:~|\"?\\$\\{?HOME\\}?\"?|" + ($home | esc) + ")/\\.claude/hooks/gate\\.sh\"?[[:space:]]+approve[[:space:]]+[0-9a-f]{64}[[:space:]]*\\z") as $approve_re
| if $tn == "Bash" and (($ti.command // "") | test($approve_re)) then {errors: [], matches: [], exempt_agent: false}
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
           hash_input: ($r.id + "\u001f" + $tn + "\u001f" + subject),
           target: safe_target}
        else empty end ]
    | {errors: [.[] | select(.error != null) | .error],
       matches: [.[] | select(.error == null)],
       exempt_agent: ($slug != "" and (($R.exempt_agents // []) | any(. == $slug)))}
  end
JQEOF

RESULT=$(printf '%s' "$INPUT" | jq -c --slurpfile rules "$RULES_FILE" \
    --arg home "$HOME" --arg tmpdir "${TMPDIR:-}" --arg jobdir "${CLAUDE_JOB_DIR:-}" \
    --arg scope "$SCOPE" --arg slug "${BARECLAUDE_AGENT_SLUG:-}" "$JQ_PROG" 2>&1)
if [[ $? -ne 0 ]]; then
    warn "rule evaluation failed — decision gates skipped for this call: ${RESULT:0:200}"
    exit 0
fi

while IFS= read -r bad; do
    [[ -n "$bad" ]] && warn "rule $bad failed to evaluate (bad regex?) — it was skipped"
done < <(printf '%s' "$RESULT" | jq -r '.errors[]' 2>/dev/null)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
CWD="${CWD:-$PWD}"
EXEMPT_AGENT=$(printf '%s' "$RESULT" | jq -r '.exempt_agent' 2>/dev/null)

while IFS= read -r M; do
    [[ -z "$M" ]] && continue
    read -r ID ENFORCE LANE < <(printf '%s' "$M" | jq -r '[.id, (.enforce | tostring), (.lane_allowed | tostring)] | join(" ")')
    TARGET=$(printf '%s' "$M" | jq -r '.target')

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

    HASH=$(hash_str "$(printf '%s' "$M" | jq -r '.hash_input')")

    if [[ -n "$HASH" && -f "$APPROVED_DIR/$HASH" ]]; then
        if expired "$APPROVED_DIR/$HASH"; then
            rm -f "$APPROVED_DIR/$HASH"
        else
            rm -f "$APPROVED_DIR/$HASH"
            log_decision "$ID" "allow-by-approval" "$TOOL" "$SCOPE" "$CWD" "$TARGET"
            continue
        fi
    fi

    MESSAGE=$(printf '%s' "$M" | jq -r '.message')
    if [[ "$SCOPE" == "interactive" ]]; then
        if [[ -n "$HASH" ]]; then
            mkdir -p "$PENDING_DIR" 2>/dev/null
            jq -nc --arg rule "$ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{rule:$rule,ts:$ts}' >"$PENDING_DIR/$HASH" 2>/dev/null
            REASON="CHECKPOINT $ID: $MESSAGE. Put this action to D via AskUserQuestion; if D approves, run \`~/.claude/hooks/gate.sh approve $HASH\` and retry with the exact same command."
        else
            REASON="CHECKPOINT $ID: $MESSAGE. Put this action to D via AskUserQuestion; if D approves, retry with the exact same command."
        fi
    else
        REASON="CHECKPOINT $ID: $MESSAGE. Do not retry; end your report with \`needs input:\` naming this action."
    fi
    log_decision "$ID" "deny" "$TOOL" "$SCOPE" "$CWD" "$TARGET"
    jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
done < <(printf '%s' "$RESULT" | jq -c '.matches[]' 2>/dev/null)

exit 0
