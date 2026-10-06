#!/bin/bash
# A7 + A8 - UserPromptSubmit: ONE Jev call, two jobs (latency: the API answers every question in
# parallel, so combining costs one round trip).
#
#   A7 memory injection - a boolean per MEMORY.md one-liner ("is this memory relevant to the prompt?").
#      The full bodies of the top `top_n` (3) entries at p >= threshold are added as additionalContext.
#      Each memory is injected at most once per session (ledger in ~/.claude/jev-cache/state/<sid>.mem,
#      reset by A5 on compaction) so the context never grows by repeating itself.
#   A8 skill picker - one choice over the ENABLED skills (~/.claude/skills minus skillOverrides "off"
#      and disable-model-invocation) plus "none". Pick != none at p >= threshold -> a one-line hint.
#
# Skipped without any Jev call: slash commands (/...), prompts shorter than min_prompt_chars (15).
# Rules are independent (own mode/threshold/scope); each logs under its own id. In shadow they log
# what they WOULD inject and print nothing. In a background job (CLAUDE_JOB_DIR set) only the first
# prompt of the session is considered. Fail OPEN: any problem -> no output, exit 0.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

# log_as <rule> <mode> <detail-file>: ctx_log reads RULE/RULE_MODE globals.
log_as() {
  RULE="$1"
  RULE_MODE="$2"
  ctx_log verdict "$3"
}

# a8_skills <outfile>: {name: description<=160} of enabled, model-invocable skills.
a8_skills() {
  local overrides='{}'
  [ -f "${HOME}/.claude/settings.json" ] && overrides="$(jq -c '.skillOverrides // {}' "${HOME}/.claude/settings.json" 2>/dev/null || echo '{}')"
  [ -n "$overrides" ] || overrides='{}'
  compgen -G "${HOME}/.claude/skills/*/SKILL.md" >/dev/null || { echo '{}' >"$1"; return 0; }
  ctx_frontmatter "name description disable-model-invocation" "${HOME}"/.claude/skills/*/SKILL.md >"${WORK}/skills.tsv"
  jq -R -n --argjson ov "$overrides" '
    [ inputs | split("\t")
      | {name: (if (.[1] // "") != "" then .[1] else (.[0] | split("/") | .[-2]) end), desc: (.[2] // ""), dmi: (.[3] // "")}
      | select(($ov[.name] // "") != "off" and .dmi != "true")
      | {key: .name, value: (.desc | .[0:160])} ] | from_entries' "${WORK}/skills.tsv" >"$1" 2>/dev/null
}

# a7_body <memory-dir> <file> <max-chars>: the memory file body without YAML frontmatter.
a7_body() {
  case "$2" in *[!A-Za-z0-9._-]* | "" | .*) return 1 ;; esac
  [ -f "$1/$2" ] || return 1
  awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm { print }' "$1/$2" | cut -c1-2000 | head -c "$3"
}

main() {
  ctx_prepare || return 0
  local prompt p7=0 p8=0 mode7="" mode8="" thr7="" thr8="" top7 body7 cap7 min7 min8 sid ledger mem memdir first
  # A background job gets hints for its FIRST prompt only (the job brief); later prompts are skipped
  # without any Jev call. A marker under the state dir records that the first prompt was seen.
  if [ "$(ctx_session_kind)" = "bgjob" ]; then
    sid="$(ctx_in .session_id | tr -dc 'A-Za-z0-9_-')"
    [ -n "$sid" ] || return 0 # no session id: the first prompt cannot be told apart
    first="${JEV_STATE_DIR}/${sid}.first"
    [ ! -e "$first" ] || return 0
    (
      umask 077
      mkdir -p "$JEV_STATE_DIR" && : >"$first"
    ) 2>/dev/null
  fi
  prompt="$(ctx_in .prompt)"
  prompt="${prompt#"${prompt%%[![:space:]]*}"}"
  case "$prompt" in /*) return 0 ;; esac

  if ctx_rule_load A7-memory-inject; then
    min7="$(ctx_cfg min_prompt_chars 15)"
    if [ "${#prompt}" -ge "$min7" ]; then
      p7=1; mode7="$RULE_MODE"; thr7="$RULE_THRESHOLD"
      top7="$(ctx_cfg top_n 3)"; body7="$(ctx_cfg body_chars 3000)"; cap7="$(ctx_cfg max_candidates 60)"
    fi
  fi
  if ctx_rule_load A8-skill-picker; then
    min8="$(ctx_cfg min_prompt_chars 15)"
    if [ "${#prompt}" -ge "$min8" ]; then
      p8=1; mode8="$RULE_MODE"; thr8="$RULE_THRESHOLD"
    fi
  fi
  [ "$p7" = 1 ] || [ "$p8" = 1 ] || return 0

  sid="$(ctx_in .session_id | tr -dc 'A-Za-z0-9_-')"
  [ -n "$sid" ] || sid=nosession
  ledger="${JEV_STATE_DIR}/${sid}.mem"

  # ---- candidates
  echo '[]' >"${WORK}/mems.json"
  echo '{}' >"${WORK}/skills.json"
  mem=""
  if [ "$p7" = 1 ]; then
    mem="$(ctx_memory_index)"
    if [ -n "$mem" ]; then
      ctx_memory_candidates "$mem" "${WORK}/mems-all.json" || return 0
      if [ -f "$ledger" ]; then
        jq --rawfile seen "$ledger" '($seen | split("\n")) as $d | map(select(.file as $f | $d | index($f) | not))' "${WORK}/mems-all.json" >"${WORK}/mems-new.json" || return 0
      else
        cp "${WORK}/mems-all.json" "${WORK}/mems-new.json"
      fi
      printf '%s' "$prompt" >"${WORK}/task.txt"
      ctx_prefilter "${WORK}/mems-new.json" "${WORK}/task.txt" "$cap7" "${WORK}/mems.json" || return 0
    fi
  fi
  [ "$p8" = 1 ] && a8_skills "${WORK}/skills.json"

  # ---- ONE request: skill choice + a boolean per memory
  jq -n --arg prompt "${prompt:0:1500}" --slurpfile m "${WORK}/mems.json" --slurpfile s "${WORK}/skills.json" '
    ($s[0] | length) as $ns
    | {rule: "A7-A8-prompt-context", timeout_ms: 1500,
       state: {prompt: $prompt, memories: ($m[0] | map({key: .id, value: .text}) | from_entries)},
       questions: ( ($m[0] | map({key: .id, value: {type: "boolean",
                      instructions: "Is state.memories.\(.id) (a saved memory note) relevant enough to the user prompt in state.prompt that the assistant should have it in context?",
                      criteria: {true: "yes, it bears on this prompt", false: "unrelated to this prompt"}}}) | from_entries)
                  + (if $ns > 0 then {skill: {type: "choice",
                      instructions: "Which skill, if any, should the assistant invoke to handle the user prompt in state.prompt?",
                      criteria: ($s[0] + {none: "no skill is needed for this prompt"})}} else {} end) )}' >"${WORK}/req.json" || return 0
  jq -e '.questions | length > 0' "${WORK}/req.json" >/dev/null 2>&1 || return 0
  ctx_jev "${WORK}/req.json" || return 0

  local ctxparts="${WORK}/ctx-parts.txt"
  : >"$ctxparts"

  # ---- A7: memory bodies
  if [ "$p7" = 1 ] && [ -n "$mem" ]; then
    memdir="$(dirname "$mem")"
    jq -n --slurpfile c "${WORK}/mems.json" --slurpfile o "${WORK}/jev-out.json" --argjson thr "$thr7" --argjson top "$top7" '
      [ $c[0][] | . + {p: ($o[0].answers[.id].probability // null)} | select(.p != null and .p >= $thr) ]
      | sort_by(-.p) | .[0:$top]' >"${WORK}/picked7.json" 2>/dev/null || return 0
    jq -c --argjson n "$(jq 'length' "${WORK}/mems.json")" '{candidates: $n, would_inject: map({file, p})}' "${WORK}/picked7.json" >"${WORK}/detail.json"
    log_as A7-memory-inject "$mode7" "${WORK}/detail.json"
    if [ "$mode7" = "enforce" ] && [ "$(jq 'length' "${WORK}/picked7.json")" -gt 0 ]; then
      printf '[jev-context] Saved memory notes that look relevant to this prompt (auto-selected; they may be stale, verify before relying on them):\n' >>"$ctxparts"
      local file title body pp
      : >"${WORK}/ledger.new"
      while IFS=$'\t' read -r file title pp; do
        body="$(a7_body "$memdir" "$file" "$body7")" || continue
        printf '\n## %s (p=%s, %s)\n%s\n' "$title" "$pp" "$file" "$body" >>"$ctxparts"
        printf '%s\n' "$file" >>"${WORK}/ledger.new"
      done < <(jq -r '.[] | [.file, .title, (.p * 100 | round / 100 | tostring)] | @tsv' "${WORK}/picked7.json")
      (
        umask 077
        mkdir -p "$JEV_STATE_DIR" && cat "${WORK}/ledger.new" >>"$ledger"
      ) 2>/dev/null
    fi
  fi

  # ---- A8: skill hint
  if [ "$p8" = 1 ]; then
    jq -c --argjson thr "$thr8" '(.answers.skill // {}) as $a
      | {pick: $a.choice, p: (($a.probabilities // {})[$a.choice // ""] // null),
         would_hint: (($a.choice // "none") != "none" and ((($a.probabilities // {})[$a.choice // ""] // 0) >= $thr))}' "${WORK}/jev-out.json" >"${WORK}/detail.json" 2>/dev/null
    log_as A8-skill-picker "$mode8" "${WORK}/detail.json"
    if [ "$mode8" = "enforce" ] && jq -e '.would_hint == true' "${WORK}/detail.json" >/dev/null 2>&1; then
      printf '\nRelevant skill: /%s — consider invoking it.\n' "$(jq -r '.pick' "${WORK}/detail.json")" >>"$ctxparts"
    fi
  fi

  [ -s "$ctxparts" ] || return 0
  jq -cn --rawfile t "$ctxparts" '{additionalContext: $t}' >"${WORK}/extra.json" || return 0
  ctx_emit UserPromptSubmit "${WORK}/extra.json"
}

main
exit 0
