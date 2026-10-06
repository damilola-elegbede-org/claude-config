#!/bin/bash
# A6 - PreToolUse(Agent): is the requested subagent_type the best fit for the Agent prompt?
#
# One Jev choice over every subagent type that exists (built-ins Explore / Plan / general-purpose
# plus ~/.claude/agents/*.md, name + description). When the best fit differs from the requested type
# with probability >= threshold, add an additionalContext suggestion. NEVER denies, never edits the
# call; the hint is advice for Claude's next delegation (PreToolUse additionalContext lands next to the
# tool result, so it cannot change the call that triggered it).
# A search-style delegation (Explore requested or picked, or a prompt about locating files) also gets
# one advice line pointing at the opt-in /ask-jev ranking command for more than about five candidates.
# Fail OPEN: any problem -> no output, exit 0.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

# Prompts that are about locating files (a search-style delegation whatever the requested type).
LOCATE_FILES='(where (is|are|does|do)|which (files?|modules?|components?)|what (files?|code) (touch|handle|use|implement)|find (all |every |the )?(files?|usages?|callers?|references?|implementations?)|locate |who (calls|uses))'

main() {
  ctx_bootstrap A6-agent-router || return 0
  case "$(ctx_in .tool_name)" in Agent | Task) ;; *) return 0 ;; esac
  local prompt req min crit
  prompt="$(ctx_in .tool_input.prompt)"
  min="$(ctx_cfg min_prompt_chars 30)"
  [ "${#prompt}" -ge "$min" ] || return 0
  req="$(ctx_in .tool_input.subagent_type)"
  [ -n "$req" ] || req="general-purpose"

  # Candidate types: built-ins first, then user agents (a user agent of the same name wins).
  jq -n '{"Explore": "Read-only search agent: broad fan-out searches across many files when only the conclusion is needed",
          "Plan": "Software architect: designs an implementation plan, identifies critical files and trade-offs",
          "general-purpose": "General agent for researching complex questions, searching for code, and executing multi-step tasks"}' >"${WORK}/types.json"
  if compgen -G "${HOME}/.claude/agents/*.md" >/dev/null; then
    ctx_frontmatter "name description" "${HOME}"/.claude/agents/*.md >"${WORK}/agents.tsv"
    jq -R -n --slurpfile base "${WORK}/types.json" '
      $base[0] + ([ inputs | split("\t")
        | {key: (if (.[1] // "") != "" then .[1] else (.[0] | split("/") | last | sub("\\.md$"; "")) end), value: ((.[2] // "") | .[0:200])} ]
        | from_entries)' "${WORK}/agents.tsv" >"${WORK}/types.new" 2>/dev/null && mv "${WORK}/types.new" "${WORK}/types.json"
  fi
  jq -e --arg r "$req" 'has($r)' "${WORK}/types.json" >/dev/null 2>&1 || return 0 # unknown requested type: not ours to judge

  crit="$(jq -c '.' "${WORK}/types.json")"
  jq -n --arg rule "$RULE" --arg prompt "${prompt:0:2000}" --arg desc "$(ctx_in .tool_input.description | cut -c1-200)" --arg req "$req" \
    --argjson crit "$crit" '
    {rule: $rule, timeout_ms: 1200,
     state: {agent_prompt: $prompt, agent_description: $desc, requested_type: $req},
     questions: {best_type: {type: "choice",
       instructions: "Which subagent type is the best fit for the task in state.agent_prompt?",
       criteria: $crit}}}' >"${WORK}/req.json" || return 0
  ctx_jev "${WORK}/req.json" || return 0

  jq -c --arg req "$req" '(.answers.best_type // {}) as $a
    | {requested: $req, pick: $a.choice, p: (($a.probabilities // {})[$a.choice // ""] // null)}' "${WORK}/jev-out.json" >"${WORK}/detail.json" 2>/dev/null
  ctx_log verdict "${WORK}/detail.json"

  [ "$RULE_MODE" = "enforce" ] || return 0
  local better=0 search=0 advice=""
  jq -e --arg req "$req" --argjson thr "$RULE_THRESHOLD" '
    (.answers.best_type // {}) as $a
    | ($a.choice // "") != "" and $a.choice != $req and ((($a.probabilities // {})[$a.choice] // 0) >= $thr)' "${WORK}/jev-out.json" >/dev/null 2>&1 && better=1
  # Search-style delegation: Explore requested or picked, or a prompt about locating files.
  if [ "$req" = "Explore" ] || printf '%s' "$prompt" | grep -Eiq "$LOCATE_FILES"; then
    search=1
  elif [ "$better" = 1 ] && jq -e '.answers.best_type.choice == "Explore"' "${WORK}/jev-out.json" >/dev/null 2>&1; then
    search=1
  fi
  if [ "$better" = 1 ]; then
    advice="$(jq -r --arg req "$req" --slurpfile t "${WORK}/types.json" '
      .answers.best_type as $a
      | "Jev router: subagent_type \"\($a.choice)\" (p=\(($a.probabilities[$a.choice] * 100 | round) / 100)) looks like a better fit than the requested \"\($req)\": \($t[0][$a.choice]). A suggestion only; ignore it if the requested type was deliberate."' "${WORK}/jev-out.json" 2>/dev/null)" || return 0
  fi
  if [ "$search" = 1 ]; then
    advice="${advice:+${advice}$'\n'}Jev search hint: when the candidates for this search exceed about five files, rank them first with ~/.claude/skills/ask-jev/scripts/rank-files.sh \"<what you are looking for>\" <paths or globs...> and read only the top few. Optional; skip it when one grep settles the question."
  fi
  [ -n "$advice" ] || return 0
  jq -cn --arg a "$advice" '{additionalContext: $a}' >"${WORK}/extra.json" || return 0
  ctx_emit PreToolUse "${WORK}/extra.json"
}

main
exit 0
