#!/bin/bash
# shellcheck shell=bash disable=SC2154
# jev-gate.sh - PreToolUse decision gates judged by Jev (G1, G3-G8, G13-G16, MCP classifier,
# approval detector). Phase 2 of the Jev integration.
#
# Flow: cheap regex candidate match (gate-questions.json) -> one Jev call with a boolean per
# candidate gate -> per-rule mode/threshold (jev-rules.json + rules.d/*.json) -> on a hit,
# the approval detector asks whether D explicitly approved exactly this action -> deny + reason.
#
# Every rule ships mode "shadow": Jev is called and the verdict is logged, nothing is denied.
# Fail mode: Jev unavailable -> allow with one warning per session (the regex gates in
# gate.sh keep enforcing). Dara/Clara are exempt. Output is JSON on stdout, exit 0 always.
set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=jev-gate-lib.sh
. "$HOOK_DIR/jev-gate-lib.sh" || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0
[ -e "$JEV_CLAUDE_DIR/jev.off" ] && exit 0
[ -f "$JEV_QUESTIONS" ] || exit 0

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

IFS=$'\t' read -r TOOL SESSION TRANSCRIPT CWD AGENT_ID < <(
  printf '%s' "$INPUT" | jq -r 'def nz: if . == null or . == "" then "-" else . end; [(.tool_name | nz), (.session_id | nz), (.transcript_path | nz), (.cwd | nz), (.agent_id | nz)] | @tsv' 2>/dev/null
)
[ -n "${TOOL:-}" ] && [ "$TOOL" != "-" ] || exit 0
JEV_SUBAGENT=""
[ "${AGENT_ID:--}" != "-" ] && JEV_SUBAGENT="$AGENT_ID"
jev_init_context
REPO=$(jev_cwd_repo "$CWD")
RULES=$(jev_rules_json)

ACTION=""
ACTION_SHA=""
TAILJSON=""
HIT_LINES=""
APPROVED=0
PENDING_WARN=""

finish() {
  if [ -n "$PENDING_WARN" ]; then
    jev_warn_once "$SESSION" "$PENDING_WARN"
  fi
  exit 0
}

unavailable() { # RULE
  jev_log "$1" "unavailable" "" ""
  PENDING_WARN="Jev decision gates are degraded (client unavailable or key missing); the regex gates still enforce and Jev judgments are skipped."
  finish
}

hit_label() { # ID
  case "$1" in
    mcp-classifier:outward) echo "outward-facing action as D (send, publish, invite, share)" ;;
    mcp-classifier:spend) echo "spends money" ;;
    mcp-classifier:delete) echo "deletes data in an external tool" ;;
    *) jq -r --arg id "$1" '.gates[$id].label // $id' "$JEV_QUESTIONS" ;;
  esac
}

# check_approval DRY -> sets APPROVED (1 only when D explicitly approved exactly this action and the
# approval has not been consumed). Untrusted text is never part of this call.
check_approval() {
  local dry="$1" ap thr state q req resp p key duuid
  APPROVED=0
  ap=$(jev_resolve_rules "$RULES" approval-detector)
  [ -n "$ap" ] || return 0
  thr=$(printf '%s' "$ap" | cut -f3)
  [ "$(printf '%s' "$TAILJSON" | jq -r '.has_d')" = "true" ] || { jev_log approval-detector "no-d-turn" "" ""; return 0; }
  state=$(jq -nc --arg tool "$TOOL" --arg action "$ACTION" --argjson t "$TAILJSON" '{tool:$tool, action:$action, turns:$t.turns}')
  q=$(jq -c '{d_approved_exact_action: {type:"boolean", instructions:.approval.instructions, criteria:.approval.criteria}}' "$JEV_QUESTIONS")
  req=$(jev_build_request approval-detector "$state" '{}' "$q")
  resp=$(jev_call "$req") || { jev_log approval-detector "unavailable" "" ""; return 0; }
  p=$(jev_prob "$resp" d_approved_exact_action)
  if ! jev_ge "${p:-0}" "$thr"; then
    jev_log approval-detector "not-approved" "" "$p"
    return 0
  fi
  duuid=$(printf '%s' "$TAILJSON" | jq -r '.d_uuid')
  key="${SESSION}|${ACTION_SHA}|${duuid}"
  if jev_stamp_seen "$key"; then
    jev_log approval-detector "approval-already-used" "" "$p"
    return 0
  fi
  [ "$dry" = "1" ] || jev_stamp_add "$key"
  jev_log approval-detector "approved" "" "$p"
  APPROVED=1
}

# resolve_hits: HIT_LINES = "id<TAB>mode<TAB>prob" lines. Logs, runs the approval detector, denies.
resolve_hits() {
  local id mode p enforce_ids="" labels="" any=0 reason
  while IFS=$'\t' read -r id mode p; do
    [ -n "$id" ] || continue
    any=1
    if [ "$mode" = "enforce" ]; then
      jev_log "$id" "hit-enforce" "$mode" "$p"
      enforce_ids="${enforce_ids:+$enforce_ids,}$id"
      labels="${labels:+$labels; }$(hit_label "$id")"
    else
      jev_log "$id" "would-deny-shadow" "$mode" "$p"
    fi
  done <<<"$HIT_LINES"
  [ "$any" = "1" ] || return 0
  if [ -z "$enforce_ids" ]; then
    check_approval 1 # shadow: log what the approval detector would say, consume nothing
    finish
  fi
  check_approval 0
  if [ "$APPROVED" = "1" ]; then
    jev_log "$enforce_ids" "allow-approved-once" "enforce" ""
    finish
  fi
  reason=$(jev_deny_reason "$enforce_ids" "$labels" "$ACTION")
  jev_log "$enforce_ids" "deny" "enforce" ""
  jev_emit_deny "$reason"
  exit 0
}

# run_gates STATE_JSON UNTRUSTED_JSON CAND_TSV -> fills HIT_LINES, or finishes when unavailable
run_gates() {
  local state="$1" un="$2" cand="$3" ids q req resp id mode thr p
  ids=$(printf '%s\n' "$cand" | cut -f1 | jq -Rn '[inputs | select(length > 0)]')
  q=$(jev_bool_questions "$ids")
  req=$(jev_build_request "gates/$TOOL" "$state" "$un" "$q")
  resp=$(jev_call "$req") || unavailable "gates/$TOOL"
  HIT_LINES=""
  while IFS=$'\t' read -r id mode thr; do
    [ -n "$id" ] || continue
    p=$(jev_prob "$resp" "$id")
    if [ -n "$p" ] && jev_ge "$p" "$thr"; then
      HIT_LINES="${HIT_LINES}${id}"$'\t'"${mode}"$'\t'"${p}"$'\n'
    else
      jev_log "$id" "pass" "$mode" "$p"
    fi
  done <<<"$cand"
}

# candidates_for SUBJECT -> gate ids whose regex candidate matches for $TOOL
candidates_for() {
  jq -nr --slurpfile q "$JEV_QUESTIONS" --arg tool "$TOOL" --arg s "$1" '
    $q[0].gates | to_entries[]
    | select(.value.candidates[$tool] != null)
    | select(.value.candidates[$tool] as $re | $s | test($re))
    | .key'
}

# ------------------------------------------------------------ AskUserQuestion --

handle_ask() {
  local rule mode thr state q req resp p
  rule=$(jev_resolve_rules "$RULES" G16-ask-bundled)
  [ -n "$rule" ] || exit 0
  mode=$(printf '%s' "$rule" | cut -f2)
  thr=$(printf '%s' "$rule" | cut -f3)
  if [ "$(printf '%s' "$INPUT" | jq '(.tool_input.questions // []) as $q | (($q | length) <= 1) and (all($q[]?; (.multiSelect // false) == false))')" = "true" ]; then
    exit 0 # one single-select question cannot bundle
  fi
  jev_is_exempt "$RULES" && { jev_log G16-ask-bundled allow-exempt-agent "$mode" ""; exit 0; }
  state=$(printf '%s' "$INPUT" | jq -c --arg ctx "$JEV_CTX" '
    {tool:"AskUserQuestion", context:$ctx,
     questions: [(.tool_input.questions // [])[] | {header:(.header // ""), question:((.question // "")[0:300]), multiSelect:(.multiSelect // false),
                                                   options:[(.options // [])[] | ((.label // "")[0:80])]}]}' | jev_redact)
  ACTION="AskUserQuestion"
  ACTION_SHA=$(jev_sha "$state")
  q=$(jev_bool_questions '["G16-ask-bundled"]')
  req=$(jev_build_request "gates/AskUserQuestion" "$state" '{}' "$q")
  resp=$(jev_call "$req") || { jev_log G16-ask-bundled unavailable "$mode" ""; exit 0; } # quality hook fails open
  p=$(jev_prob "$resp" G16-ask-bundled)
  if [ -n "$p" ] && jev_ge "$p" "$thr"; then
    if [ "$mode" = "enforce" ]; then
      jev_log G16-ask-bundled deny "$mode" "$p"
      jev_emit_deny "Jev gate [G16-ask-bundled]: this AskUserQuestion bundles unrelated decisions. D wants one decision per ask. Split it and ask sequentially: one question per call, headline then context then ONE ask, 2-4 options, exactly one recommended."
    else
      jev_log G16-ask-bundled would-deny-shadow "$mode" "$p"
    fi
  else
    jev_log G16-ask-bundled pass "$mode" "$p"
  fi
  exit 0
}

# ------------------------------------------------------------------------ MCP --

mcp_cache_lookup() { # -> "class<TAB>prod<TAB>p" or empty
  [ -f "$JEV_DIR/mcp-classes.json" ] || return 0
  jq -r --arg t "$TOOL" '.[$t] // empty | [.class, ((.prod_infra // false) | tostring), ((.p // 0) | tostring)] | @tsv' "$JEV_DIR/mcp-classes.json" 2>/dev/null
}

mcp_cache_store() { # class prod p
  local f="$JEV_DIR/mcp-classes.json" lock="$JEV_DIR/mcp-classes.lock" tmp i=0
  mkdir -p "$JEV_DIR" 2>/dev/null || return 0
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 20 ] && return 0
    sleep 0.05
  done
  [ -f "$f" ] || echo '{}' >"$f"
  tmp=$(mktemp "$JEV_DIR/mcp-classes.XXXXXX") && {
    jq --arg t "$TOOL" --arg c "$1" --argjson pr "$2" --argjson p "$3" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.[$t] = {class:$c, prod_infra:$pr, p:$p, source:"jev", ts:$ts}' "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
  }
  rmdir "$lock" 2>/dev/null || true
}

# Name-keyword fallback used when Jev is unavailable. First known verb token decides.
mcp_heuristic() { # OP -> read|write|spend|delete|outward|unknown
  jq -nr --slurpfile d "$JEV_QUESTIONS" --arg op "$1" '
    ($op | ascii_downcase | gsub("-"; "_") | split("_")) as $tk
    | $d[0].mcp.heuristics as $h
    | ["read","write","spend","delete","outward"] as $order
    | [ $tk[] as $w | $order[] as $c | select(($h[$c] | split("|") | index($w)) != null) | $c ] | (.[0] // "unknown")'
}

handle_mcp() {
  local rule mode thr cached class prod p prod_p state q req resp args desc op server g4 g4mode cand un
  rule=$(jev_resolve_rules "$RULES" mcp-classifier)
  [ -n "$rule" ] || exit 0
  mode=$(printf '%s' "$rule" | cut -f2)
  thr=$(printf '%s' "$rule" | cut -f3)
  ACTION="mcp tool ${TOOL}"
  ACTION_SHA=$(jev_sha "$TOOL|$(printf '%s' "$INPUT" | jq -c '(.tool_input // {}) | if type=="object" then keys else [] end')")
  if jev_is_exempt "$RULES"; then
    jev_log mcp-classifier allow-exempt-agent "$mode" ""
    exit 0
  fi
  op="${TOOL#mcp__}"
  server="${op%%__*}"
  op="${op#*__}"
  cached=$(mcp_cache_lookup)
  if [ -n "$cached" ]; then
    IFS=$'\t' read -r class prod p <<<"$cached"
    jev_log mcp-classifier "cache-hit:$class" "$mode" "$p"
  else
    args=$(printf '%s' "$INPUT" | jq -c '
      (.tool_input // {}) | if type=="object" then
        to_entries | map({key, value: (if (.key | test("^(body|text|content|message|html|description|prompt|note|notes|comment|raw|markdown|blocks|properties)$"; "i")) then "<omitted>"
          elif (.value | type) == "string" then (.value[0:60])
          elif ((.value | type) == "number" or (.value | type) == "boolean") then .value
          else "<" + (.value | type) + ">" end)}) | from_entries
      else {} end' | jev_redact)
    desc=$(printf '%s' "$INPUT" | jq -r '.tool_description // .tool_input.description // empty' | head -c 300 | jev_redact)
    state=$(jq -nc --arg tool "$TOOL" --arg server "$server" --arg op "$op" --argjson args "$args" --arg desc "$desc" --arg ctx "$JEV_CTX" \
      '{tool_name:$tool, server:$server, operation:$op, arguments:$args, context:$ctx} + (if $desc != "" then {description:$desc} else {} end)')
    q=$(jq -c '{
      class: {type:"choice", instructions:.mcp.class_instructions, criteria:.mcp.class_criteria},
      prod_infra: {type:"boolean", instructions:.mcp.prod_instructions, criteria:{true:"Changes a live production or shared deployed system.", false:"Does not affect production or shared infrastructure."}}}' "$JEV_QUESTIONS")
    req=$(jev_build_request "mcp-classifier" "$state" '{}' "$q")
    if resp=$(jev_call "$req"); then
      class=$(printf '%s' "$resp" | jq -r '.answers.class.choice // empty')
      p=$(printf '%s' "$resp" | jq -r --arg c "$class" '.answers.class.probabilities[$c] // 1')
      prod_p=$(printf '%s' "$resp" | jq -r '.answers.prod_infra.probability // 0')
      prod=false
      g4=$(jev_resolve_rules "$RULES" G4-prod-infra)
      if [ -n "$g4" ] && jev_ge "$prod_p" "$(printf '%s' "$g4" | cut -f3)"; then prod=true; fi
      case "$class" in
        read | write | outward | spend | delete)
          mcp_cache_store "$class" "$([ "$prod" = true ] && echo true || echo false)" "$p"
          jev_log mcp-classifier "classified:$class" "$mode" "$p"
          ;;
        *) class="" ;;
      esac
    else
      class=""
    fi
    if [ -z "$class" ]; then
      # Jev unavailable (or nonsense): regex fallback per D's ruling. Not cached, so Jev can classify later.
      class=$(mcp_heuristic "$op")
      p=1
      prod=false
      jev_log mcp-classifier "heuristic:$class" "$mode" ""
      if [ "$class" = "unknown" ]; then
        PENDING_WARN="Jev is unavailable and MCP tool ${TOOL} is unclassified; allowing it. Classify it once Jev is back."
        finish
      fi
    fi
  fi
  HIT_LINES=""
  case "$class" in
    outward | spend | delete)
      if jev_ge "$p" "$thr"; then HIT_LINES="mcp-classifier:${class}"$'\t'"${mode}"$'\t'"${p}"$'\n'; fi
      ;;
    write)
      if [ "${prod:-false}" = "true" ]; then
        g4=$(jev_resolve_rules "$RULES" G4-prod-infra)
        if [ -n "$g4" ]; then
          g4mode=$(printf '%s' "$g4" | cut -f2)
          HIT_LINES="G4-prod-infra"$'\t'"${g4mode}"$'\t'"${p}"$'\n'
        fi
      fi
      ;;
  esac
  # G15: a non-read MCP call while untrusted content is in the recent transcript.
  if [ -z "$HIT_LINES" ] && [ "$class" != "read" ]; then
    TAILJSON=$(jev_tail "$TRANSCRIPT")
    cand=$(jev_resolve_rules "$RULES" G15-untrusted-origin)
    un=$(printf '%s' "$TAILJSON" | jq -c '.untrusted')
    if [ -n "$cand" ] && [ "$un" != "[]" ]; then
      state=$(jq -nc --arg tool "$TOOL" --arg ctx "$JEV_CTX" --argjson t "$TAILJSON" '{tool_name:$tool, context:$ctx, turns:$t.turns}')
      run_gates "$state" "$un" "$cand"
    fi
  fi
  [ -n "$HIT_LINES" ] || exit 0
  [ -n "$TAILJSON" ] || TAILJSON=$(jev_tail "$TRANSCRIPT")
  resolve_hits
  finish
}

# ----------------------------------------------------- Bash / Write / Edit / ... --

handle_generic() {
  local subject="" state cand cand_ids active un has_g14 has_g15 cmd_clean excerpt path existed tracked clean bytes need_excerpt=0 extra_g1=0
  case "$TOOL" in
    Bash)
      local cmd
      cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
      [ -n "$cmd" ] || exit 0
      printf '%s' "$cmd" | grep -q -- '-----BEGIN [A-Z ]*PRIVATE KEY' && exit 0 # G9 territory: never send keys
      cmd_clean=$(printf '%s' "$INPUT" | jq -r '
        def strip_heredocs: split("\n") | reduce .[] as $l ({out:[], hd:null};
          if .hd != null then (.hd as $hd | if ($l | test("^\\s*" + $hd + "\\s*$")) then .hd = null else . end)
          else .out += [$l] | (if ($l | test("(^|[^<])<<-?\\s*[\"\u0027]?[A-Za-z_][A-Za-z0-9_]*")) then .hd = ($l | capture("(?:^|[^<])<<-?\\s*[\"\u0027]?(?<w>[A-Za-z_][A-Za-z0-9_]*)").w) else . end) end) | .out | join("\n");
        (.tool_input.command // "") | strip_heredocs')
      subject="$cmd_clean"
      ACTION=$(printf '%s' "$cmd_clean" | jev_redact)
      ACTION=$(jev_trim "$ACTION" 700)
      state=$(jq -nc --arg tool "$TOOL" --arg cmd "$ACTION" --arg repo "$REPO" --arg ctx "$JEV_CTX" '{tool:$tool, command:$cmd, repo:$repo, context:$ctx}')
      ;;
    Write | Edit)
      path=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
      [ -n "$path" ] || exit 0
      # Only dependency-like or model lines are ever sent, never file contents.
      excerpt=$(printf '%s' "$INPUT" | jq -r '[.tool_input.content, .tool_input.new_string] | map(select(. != null)) | join("\n")' |
        grep -E '"model"|^[[:space:]]*"[@a-zA-Z0-9/_.-]+"[[:space:]]*:[[:space:]]*"[~^<>=*0-9a-zA-Z.-]+"|^[A-Za-z0-9_.-]+(==|>=|~=)[0-9]' | head -10 | jev_redact)
      subject="${path}"$'\n'"${excerpt}"
      ACTION="${TOOL} ${path}"
      if [ "$TOOL" = "Write" ] && [ -f "$path" ]; then
        # An overwrite is only a G1 candidate when the old content is not recoverable from git or scratch.
        case "$path" in
          /tmp/* | /private/tmp/* | */.tmp/* | */node_modules/* | */__pycache__/* | */dist/* | */.cache/*) ;;
          *)
            tracked=false
            clean=false
            if git -C "$(dirname "$path")" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
              tracked=true
              git -C "$(dirname "$path")" diff --quiet -- "$path" 2>/dev/null && clean=true
            fi
            if [ "$tracked" = false ] || [ "$clean" = false ]; then extra_g1=1; fi
            ;;
        esac
      fi
      [ -f "$path" ] && bytes=$(wc -c <"$path" | tr -d ' ')
      state=$(jq -nc --arg tool "$TOOL" --arg path "$path" --arg repo "$REPO" --arg ctx "$JEV_CTX" --arg ex "${excerpt:-}" \
        --argjson existed "$([ -f "$path" ] && echo true || echo false)" --arg tracked "${tracked:-unknown}" --arg clean "${clean:-unknown}" --arg bytes "${bytes:-0}" \
        '{tool:$tool, path:$path, repo:$repo, context:$ctx, file_existed:$existed, git_tracked:$tracked, git_clean:$clean, bytes:($bytes|tonumber? // 0)}
         + (if $ex != "" then {relevant_lines:($ex | split("\n"))} else {} end)')
      ;;
    Workflow)
      subject="workflow"
      ACTION="Workflow launch"
      state=$(printf '%s' "$INPUT" | jq -c --arg ctx "$JEV_CTX" --arg repo "$REPO" '{tool:"Workflow", repo:$repo, context:$ctx, input_keys:((.tool_input // {}) | if type=="object" then keys else [] end), name:((.tool_input.name // .tool_input.workflow // "") | tostring | .[0:80])}')
      ;;
    Artifact)
      subject=$(printf '%s' "$INPUT" | jq -r '.tool_input.action // "publish"')
      ACTION="Artifact ${subject}"
      state=$(jq -nc --arg a "$subject" --arg ctx "$JEV_CTX" '{tool:"Artifact", action:$a, context:$ctx}')
      ;;
    *) exit 0 ;;
  esac
  ACTION_SHA=$(jev_sha "$TOOL|$ACTION")

  cand_ids=$(candidates_for "$subject")
  if [ "$extra_g1" = "1" ]; then cand_ids="${cand_ids:+$cand_ids$'\n'}G1-irreversible-local"; fi
  cand_ids=$(printf '%s\n' "$cand_ids" | sort -u | sed '/^$/d')
  [ -n "$cand_ids" ] || exit 0

  # shellcheck disable=SC2086
  cand=$(jev_resolve_rules "$RULES" $cand_ids)
  [ -n "$cand" ] || exit 0

  if jev_is_exempt "$RULES"; then
    jev_log "gates/$TOOL" allow-exempt-agent "" ""
    exit 0
  fi

  TAILJSON=$(jev_tail "$TRANSCRIPT")
  un='{}'
  has_g14=$(printf '%s\n' "$cand" | cut -f1 | grep -c '^G14-non-routine$' || true)
  g15=$(jev_resolve_rules "$RULES" G15-untrusted-origin)
  if [ -n "$g15" ] && [ "$(printf '%s' "$TAILJSON" | jq '.untrusted | length')" -gt 0 ]; then
    cand="${cand}"$'\n'"${g15}"
    un=$(printf '%s' "$TAILJSON" | jq -c '.untrusted')
    has_g15=1
  fi
  if [ "${has_g14:-0}" -gt 0 ] || [ "${has_g15:-0}" = "1" ]; then
    state=$(printf '%s' "$state" | jq -c --argjson t "$TAILJSON" '. + {turns:$t.turns}')
  fi
  run_gates "$state" "$un" "$cand"
  [ -n "$HIT_LINES" ] || finish
  resolve_hits
  finish
}

case "$TOOL" in
  AskUserQuestion) handle_ask ;;
  mcp__*) handle_mcp ;;
  Bash | Write | Edit | Workflow | Artifact) handle_generic ;;
  *) exit 0 ;;
esac
