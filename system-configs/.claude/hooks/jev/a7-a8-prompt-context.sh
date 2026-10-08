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

# a8_skills <outfile> <prompt-file>: {name: description<=160} of every skill this session can invoke:
# user, project, directory-scoped and enabled-plugin skills (skill-catalog.py). One entry per base
# name: a directory-scoped variant wins when the session cwd is inside its directory, else the user
# or project skill. Plugin skills beyond skill_cap are prefiltered by keyword overlap with the prompt.
# Falls back to ~/.claude/skills alone when the catalog is unavailable.
a8_skills() {
  local cwd cap
  cwd="$(ctx_in .cwd)"
  [ -n "$cwd" ] || cwd="$PWD"
  # The catalog records real paths (git resolves symlinks), so compare against the real cwd.
  cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || cwd="$PWD"
  cap="$(ctx_cfg skill_cap 40)"
  if command -v python3 >/dev/null 2>&1 && python3 -I "${JEV_DIR}/skill-catalog.py" "$cwd" "${WORK}/catalog.json" &&
    jq -e 'type == "array" and length > 0' "${WORK}/catalog.json" >/dev/null 2>&1; then
    jq --arg cwd "$cwd" '
      def applies: .scope_dir as $d | $d == "" or ($cwd + "/" | startswith($d + "/"));
      def rank: if .source == "directory" and applies then 0 elif .source == "project" then 1
                elif .source == "user" then 2 elif .source == "plugin" then 3 else 4 end;
      [ group_by(.base)[] | sort_by(rank) | .[0] | select(.source != "directory" or applies) ]
      | map({id: .name, text: ((.name + " " + .desc) | .[0:260]), plugin: (.source == "plugin")})' \
      "${WORK}/catalog.json" >"${WORK}/sk-all.json" 2>/dev/null || { echo '{}' >"$1"; return 0; }
    jq '[.[] | select(.plugin)]' "${WORK}/sk-all.json" >"${WORK}/sk-plugin.json"
    ctx_prefilter "${WORK}/sk-plugin.json" "$2" "$cap" "${WORK}/sk-plugin-kept.json" || cp "${WORK}/sk-plugin.json" "${WORK}/sk-plugin-kept.json"
    jq -n --slurpfile a "${WORK}/sk-all.json" --slurpfile p "${WORK}/sk-plugin-kept.json" '
      ([$a[0][] | select(.plugin | not)] + $p[0])
      | map((.id | length) as $n | {key: .id, value: (.text | .[$n + 1:] | .[0:160])}) | from_entries' >"$1" 2>/dev/null || echo '{}' >"$1"
    return 0
  fi
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
  local prompt p7=0 p8=0 mode7="" mode8="" thr7="" thr8="" top7 body7 cap7 min7 min8 sid ledger mem memdir first later=0
  # A background job gets memory notes (A7) for its FIRST prompt only (the job brief); the skill pick (A8)
  # runs on every prompt, because each request can need a different skill. A marker under the state dir
  # records that the first prompt was seen; it is written only once a prompt qualifies for evaluation (not a
  # slash command, long enough), so a skipped prompt does not use it up.
  if [ "$(ctx_session_kind)" = "bgjob" ]; then
    sid="$(ctx_in .session_id | tr -dc 'A-Za-z0-9_-')"
    [ -n "$sid" ] || return 0 # no session id: the first prompt cannot be told apart
    first="${JEV_STATE_DIR}/${sid}.first"
    if [ -e "$first" ]; then
      later=1
      first=""
    fi
  fi
  prompt="$(ctx_in .prompt)"
  prompt="${prompt#"${prompt%%[![:space:]]*}"}"
  case "$prompt" in /*) return 0 ;; esac

  if [ "$later" = 0 ] && ctx_rule_load A7-memory-inject; then
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
  if [ -n "${first:-}" ]; then
    (
      umask 077
      mkdir -p "$JEV_STATE_DIR" && : >"$first"
    ) 2>/dev/null
  fi

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
  if [ "$p8" = 1 ]; then
    printf '%s' "$prompt" >"${WORK}/task8.txt"
    a8_skills "${WORK}/skills.json" "${WORK}/task8.txt"
  fi

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
    # Two bands: >= threshold is "relevant", >= likely_threshold is "possibly relevant". A right pick at
    # moderate confidence is still worth surfacing; the hint is advice, and naming the exact Skill call
    # leaves no translation step between seeing it and using it.
    jq -c --argjson thr "$thr8" --argjson lik "$(ctx_cfg likely_threshold "$thr8")" '(.answers.skill // {}) as $a
      | (($a.probabilities // {})[$a.choice // ""] // 0) as $p
      | {pick: $a.choice, p: (if $a.choice then $p else null end),
         would_hint: (($a.choice // "none") != "none" and $p >= $thr),
         would_hint_likely: (($a.choice // "none") != "none" and $p < $thr and $p >= $lik)}' "${WORK}/jev-out.json" >"${WORK}/detail.json" 2>/dev/null
    log_as A8-skill-picker "$mode8" "${WORK}/detail.json"
    if [ "$mode8" = "enforce" ]; then
      local pick pp
      pick="$(jq -r '.pick' "${WORK}/detail.json")"
      pp="$(jq -r '.p * 100 | round / 100' "${WORK}/detail.json")"
      if jq -e '.would_hint == true' "${WORK}/detail.json" >/dev/null 2>&1; then
        printf '\nRelevant skill: /%s (p=%s). Invoke it with the Skill tool (skill: "%s") before doing this work by hand, or say why it does not fit.\n' "$pick" "$pp" "$pick" >>"$ctxparts"
      elif jq -e '.would_hint_likely == true' "${WORK}/detail.json" >/dev/null 2>&1; then
        printf '\nPossibly relevant skill: /%s (p=%s). If it fits, invoke it with the Skill tool (skill: "%s").\n' "$pick" "$pp" "$pick" >>"$ctxparts"
      fi
    fi
  fi

  [ -s "$ctxparts" ] || return 0
  jq -cn --rawfile t "$ctxparts" '{additionalContext: $t}' >"${WORK}/extra.json" || return 0
  ctx_emit UserPromptSubmit "${WORK}/extra.json"
}

main
exit 0
