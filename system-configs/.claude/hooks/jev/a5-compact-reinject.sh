#!/bin/bash
# A5 - SessionStart(matcher "compact"): after a compaction, put back what the summary tends to lose.
#
# Two independent rules, one additionalContext:
#   A5b-compact-state    (deterministic, no Jev): branch, worktree path, open PR for the branch.
#                        Ships in enforce mode: it is additive, model-free and cheap (gh is bounded).
#   A5-compact-reinject  (Jev, ships in shadow): ONE call with a boolean per candidate - the
#                        CLAUDE.md rule sections (home + project) and MEMORY.md entries - judged against
#                        the last real user prompt. Top `top_n` (5) at p >= threshold are injected.
# Also resets the per-session memory-injection ledger (A7) so memories can be re-injected.
# Fail OPEN: any problem -> no output, exit 0.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

# a5_state: one paragraph of deterministic session facts ("" when not a git repo).
a5_state() {
  local cwd top branch gitdir common linked="" pr="" out="${WORK}/pr.json" timeout
  cwd="$(ctx_in .cwd)"
  [ -d "$cwd" ] || cwd="$PWD"
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 0
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
  gitdir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)"
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$gitdir" ] && [ -n "$common" ] && [ "$gitdir" != "$common" ]; then
    linked=" (linked git worktree)"
  fi
  if [ -n "$branch" ] && command -v gh >/dev/null 2>&1; then
    timeout="$(ctx_cfg gh_timeout_s 3)"
    if ctx_bounded "$timeout" "$out" bash -c 'cd "$1" && exec gh pr view --json number,title,url,state' _ "$cwd"; then
      pr="$(jq -r 'select(.state == "OPEN") | "open PR #\(.number) \"\(.title)\" \(.url)"' "$out" 2>/dev/null)"
    fi
  fi
  printf 'Session state (deterministic, from git): branch %s; worktree %s%s%s.' \
    "${branch:-"(detached)"}" "$top" "$linked" "${pr:+; $pr}"
}

# a5_rank: prints the "re-injected" block, or nothing. Logs the verdict either way.
a5_rank() {
  local task cwd top n cap thr mem
  task="$(ctx_task "$(ctx_in .transcript_path)")"
  [ -n "$task" ] || return 0
  cwd="$(ctx_in .cwd)"
  [ -d "$cwd" ] || cwd="$PWD"
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  printf '%s' "$task" >"${WORK}/task.txt"

  # Egress: an excluded (work) repo's CLAUDE.md is never sent; the global one still is.
  if [ -n "$top" ] && ctx_path_excluded "$top"; then top=""; fi
  ctx_rule_candidates "${WORK}/rules.json" "$HOME/CLAUDE.md" ${top:+"$top/CLAUDE.md"} || return 0
  mem="$(ctx_memory_index)"
  if [ -n "$mem" ]; then
    ctx_memory_candidates "$mem" "${WORK}/mems.json" || return 0
  else
    echo '[]' >"${WORK}/mems.json"
  fi
  jq -s 'add' "${WORK}/rules.json" "${WORK}/mems.json" >"${WORK}/cands-all.json" 2>/dev/null || return 0
  cap="$(ctx_cfg max_candidates 80)"
  ctx_prefilter "${WORK}/cands-all.json" "${WORK}/task.txt" "$cap" "${WORK}/cands.json" || return 0
  n="$(jq 'length' "${WORK}/cands.json" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] || return 0

  jq -n --arg rule "$RULE" --arg task "$task" --slurpfile c "${WORK}/cands.json" '
    { rule: $rule, timeout_ms: 1500,
      state: {task: $task, candidates: ($c[0] | map({key: .id, value: .text}) | from_entries)},
      questions: ($c[0] | map({key: .id, value: {type: "boolean",
        instructions: "The context was just compacted. Is state.candidates.\(.id) (a standing rule or saved memory) needed to continue the task in state.task correctly?",
        criteria: {true: "yes, losing it would risk a mistake on this task", false: "not relevant to this task"}}}) | from_entries)}' >"${WORK}/req.json" 2>/dev/null || return 0
  ctx_jev "${WORK}/req.json" || return 0

  thr="$RULE_THRESHOLD"
  jq -n --slurpfile c "${WORK}/cands.json" --slurpfile o "${WORK}/jev-out.json" --argjson thr "$thr" --argjson top "$(ctx_cfg top_n 5)" '
    [ $c[0][] | . + {p: ($o[0].answers[.id].probability // null)} | select(.p != null and .p >= $thr) ]
    | sort_by(-.p) | .[0:$top]' >"${WORK}/picked.json" 2>/dev/null || return 0
  jq -c '{candidates: ($ARGS.named.n | tonumber), picked: map({id, src: (.src // "memory"), p})}' --arg n "$n" "${WORK}/picked.json" >"${WORK}/detail.json" 2>/dev/null
  ctx_log verdict "${WORK}/detail.json"
  [ "$RULE_MODE" = "enforce" ] || return 0
  [ "$(jq 'length' "${WORK}/picked.json")" -gt 0 ] || return 0
  jq -r '
    "Re-injected after compaction (ranked as most relevant to the current task):\n"
    + (map(if .src != null then "- [\(.src)] \(.full)" else "- [memory] \(.text)" end) | join("\n"))' "${WORK}/picked.json"
}

main() {
  ctx_prepare || return 0
  [ "$(ctx_in .source)" = "compact" ] || return 0
  local sid det="" rank="" mode_state
  sid="$(ctx_in .session_id | tr -dc 'A-Za-z0-9_-')"
  [ -z "$sid" ] || rm -f "${JEV_STATE_DIR}/${sid}.mem" 2>/dev/null

  if ctx_rule_load A5b-compact-state; then
    mode_state="$RULE_MODE"
    det="$(a5_state)"
    jq -cn --arg d "$det" '{state_chars: ($d | length)}' >"${WORK}/detail.json"
    ctx_log verdict "${WORK}/detail.json"
    [ "$mode_state" = "enforce" ] || det=""
  fi
  if ctx_rule_load A5-compact-reinject; then
    rank="$(a5_rank)"
  fi

  [ -n "$det$rank" ] || return 0
  jq -cn --arg d "$det" --arg r "$rank" '{additionalContext: ([$d, $r] | map(select(length > 0)) | join("\n\n"))}' >"${WORK}/extra.json"
  ctx_emit SessionStart "${WORK}/extra.json"
}

main
exit 0
