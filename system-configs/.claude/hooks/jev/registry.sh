#!/bin/bash
# shellcheck shell=bash
# registry.sh - the ONE reader of the Jev registry, the ONE decision log and the kill-switch rules.
# Sourced (never executed) by gate.sh, jev-gate-lib.sh (jev-gate.sh, jev-ask-channel.sh), ctx-lib.sh
# (the context hooks) and rules-events-lib.sh (the rules/event hooks). client.mjs implements the same
# reader semantics in JavaScript (rulesRegistry()); tests/hooks/test_jev_registry.sh runs both on the
# same fixtures and compares them. Bash 3.2 compatible (macOS /bin/bash).
#
# ----------------------------------------------------------------- the registry
# Layers, later wins (objects deep-merge key by key, arrays and scalars are replaced):
#   1. gate-questions.json   the questions: per-gate label/instructions/criteria/expects/candidates,
#                            the shared choice questions, the approval and MCP-classifier questions
#   2. rules.d/*.json        modes, thresholds, scopes, tuning knobs (lexical order)
#   3. jev-rules.json        the user's overrides (LAST, so it wins)
# Each layer is {"exempt_agents":[...], "rules":{"<id>":{...}}} (a flat {"<id>":{...}} is tolerated);
# gate-questions.json keeps its own shape ({"gates":{...}, "approval":{...}, "mcp":{...},
# "choice_questions":{...}}) and is folded in as rules "<gate id>", "approval-detector" and
# "mcp-classifier". A rule that no layer registers is OFF. The merged result is ONE flat object:
#   {"<id>":{mode,threshold,scope,...questions...}, "exempt_agents":[...], "choice_questions":{...}}
# When the code runs from a checkout rather than the deployed dir, the deployed
# ~/.claude/hooks/jev rules.d/jev-rules.json are layered on top (dev/test convenience; in production
# both are the same directory). JEV_RULES_FILE (alias JEV_RULES) replaces the layers by a single file.
#
# ---------------------------------------------------------------- the decision log
# One line per decision in ~/.claude/jev/decisions.jsonl:
#   {ts, gate, mode, answers, confidence, model, latencyMs, outcome, src, ...extra}
# Every writer (client, gates, context hooks, rules/event hooks, gate.sh) appends here. The older
# logs (jev-shadow.jsonl, jev-gates.jsonl, jev/rules-events.jsonl, gate-log.jsonl) are still written
# as ALIASES for one release; read decisions.jsonl instead.
#
# ------------------------------------------------------------------ kill switches
# Two regular files in ~/.claude (a directory or symlink of that name does nothing):
#   gate.off  decision gates stand down: gate.sh (regex) AND jev-gate.sh / jev-ask-channel.sh (Jev)
#   jev.off   Jev stops answering: the client exits 3 for everyone, so safety gates fall back to
#             their regex verdict (gate.sh keeps enforcing), quality hooks no-op
# Precedence: they are independent and gate.off wins for gates (a gate behind gate.off never runs,
# whatever jev.off says). Both present = no decision gate runs and no Jev call is made. To stop only
# the Jev spend, touch jev.off; to stop all blocking, touch gate.off.

JEV_REG_DIR="${JEV_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
JEV_REG_CLAUDE_DIR="${JEV_CLAUDE_DIR:-${HOME:-}/.claude}"
JEV_DECISIONS_LOG="${JEV_DECISIONS_LOG:-$JEV_REG_CLAUDE_DIR/jev/decisions.jsonl}"

# jev_kill_switch NAME -> 0 when ~/.claude/NAME is a REGULAR file (not a directory, not a symlink).
jev_kill_switch() {
  [ -f "$JEV_REG_CLAUDE_DIR/$1" ] && [ ! -L "$JEV_REG_CLAUDE_DIR/$1" ]
}

# jev_gates_off -> 0 when the Jev decision gates must not run (gate.off master switch or jev.off).
jev_gates_off() {
  jev_kill_switch gate.off || jev_kill_switch jev.off
}

# jev_reg_files -> the layer files, one per line, in precedence order.
jev_reg_files() {
  local d f seen="" dp
  if [ -n "${JEV_RULES_FILE:-${JEV_RULES:-}}" ]; then
    printf '%s\n' "${JEV_RULES_FILE:-$JEV_RULES}"
    return 0
  fi
  for d in "$JEV_REG_DIR" "$JEV_REG_CLAUDE_DIR/hooks/jev"; do
    [ -d "$d" ] || continue
    dp=$(cd "$d" && pwd -P)
    case "$seen" in *"|$dp|"*) continue ;; esac
    seen="$seen|$dp|"
    [ -f "$d/gate-questions.json" ] && printf '%s\n' "$d/gate-questions.json"
    for f in "$d"/rules.d/*.json; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
    [ -f "$d/jev-rules.json" ] && printf '%s\n' "$d/jev-rules.json"
  done
  return 0
}

# The merge program, applied by `jq -s` over the layer files (shared by every reader below).
JEV_REG_MERGE='
  def layer:
    if type == "object" and has("gates") then
      {rules: ((.gates // {})
               + (if .approval then {"approval-detector": .approval} else {} end)
               + (if .mcp then {"mcp-classifier": .mcp} else {} end)),
       choice_questions: .choice_questions}
    else . end;
  reduce .[] as $raw ({};
    ($raw | layer) as $o
    | if ($o | type) != "object" then . else
        . * (($o.rules // ($o | del(.exempt_agents, .choice_questions)))
             + (if $o.exempt_agents then {exempt_agents: $o.exempt_agents} else {} end)
             + (if $o.choice_questions then {choice_questions: $o.choice_questions} else {} end))
      end)'

# jev_reg_run JQ_ARGS... -> runs `jq -s` with the merge program over the layers; the extra jq args come first
# and may end with a filter piped after the merge ("| .[$id]"). Prints nothing and returns 1 when there is
# no layer or jq fails.
jev_reg_run() {
  local files=() f
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done < <(jev_reg_files)
  [ "${#files[@]}" -gt 0 ] || return 1
  jq -s "$@" "${files[@]}" 2>/dev/null
}

# jev_reg_json -> the merged registry (see header). Prints {} when no layer exists or jq fails.
jev_reg_json() {
  jev_reg_run "$JEV_REG_MERGE" || echo '{}'
  return 0
}

# jev_reg_rule ID -> one rule's merged entry as compact JSON ({} when unregistered).
jev_reg_rule() {
  jev_reg_run -c --arg id "$1" "$JEV_REG_MERGE | .[\$id] // {} | if type == \"object\" then . else {} end" || echo '{}'
  return 0
}

# jev_reg_value ID KEY DEFAULT -> one scalar of one rule (DEFAULT when absent or empty; arrays are JSON).
# One jq spawn: this is what the per-hook mode lookups use.
jev_reg_value() {
  local v
  v=$(jev_reg_run -r --arg id "$1" --arg k "$2" "$JEV_REG_MERGE | .[\$id][\$k] // empty")
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$3"; fi
}

# jev_reg_exempt SLUG [REGISTRY_JSON] -> 0 when the fleet agent is on the exempt list (default clara).
jev_reg_exempt() {
  local reg="${2:-}"
  [ -n "$1" ] || return 1
  [ -n "$reg" ] || reg=$(jev_reg_json)
  printf '%s' "$reg" | jq -e --arg s "$1" '(.exempt_agents // ["clara"]) | map(ascii_downcase) | index($s | ascii_downcase) != null' >/dev/null 2>&1
}

# jev_decision_log GATE MODE OUTCOME [CONFIDENCE] [ANSWERS_JSON] [MODEL] [LATENCY_MS] [SRC] [EXTRA_JSON]
# Appends one decision line. Never records prompt, command or file text: callers pass ids, numbers and
# the (state-free) Jev answers only. Always returns 0.
jev_decision_log() {
  command -v jq >/dev/null 2>&1 || return 0
  (
    umask 077
    mkdir -p "$(dirname "$JEV_DECISIONS_LOG")" 2>/dev/null || exit 0
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg gate "$1" --arg mode "${2:-}" --arg outcome "${3:-}" \
      --arg conf "${4:-}" --arg ans "${5:-}" --arg model "${6:-}" --arg lat "${7:-}" --arg src "${8:-}" --arg extra "${9:-}" '
      {ts:$ts, gate:$gate, mode:(if $mode == "" then null else $mode end),
       answers:(try ($ans | fromjson) catch null), confidence:($conf | tonumber? // null),
       model:(if $model == "" then null else $model end), latencyMs:($lat | tonumber? // null),
       outcome:$outcome, src:$src}
      + (try ($extra | fromjson | if type == "object" then . else {} end) catch {})' \
      >>"$JEV_DECISIONS_LOG" 2>/dev/null
  ) 2>/dev/null
  return 0
}
