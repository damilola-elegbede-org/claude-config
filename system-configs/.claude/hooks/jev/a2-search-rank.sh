#!/bin/bash
# A2 - PostToolUse(Grep|Glob): when a search returns more than `min_hits` (100) results, rank the
# hits (25-line chunks) against the task, keep the best ~100 in original order, replace the rest with
# markers, and save the full list under ~/.claude/jev-cache/.
#
# Skipped when Claude already bounded the search (Grep head_limit) or asked for counts only.
# Fail OPEN: any problem or exit-3 from jev-ask -> no output, output untouched.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

main() {
  ctx_bootstrap A2-search-rank || return 0
  local tool task n min state
  tool="$(ctx_in .tool_name)"
  case "$tool" in Grep | Glob) ;; *) return 0 ;; esac
  [ -z "$(ctx_in .tool_input.head_limit)" ] || return 0
  [ "$(ctx_in .tool_input.output_mode)" != "count" ] || return 0

  ctx_extract "$tool" || return 0
  n="$(ctx_line_count "${WORK}/text.txt")"
  min="$(ctx_cfg min_hits 100)"
  [ "$n" -gt "$min" ] || return 0

  # Egress: never send digests of hits from an excluded (work) tree. No path = the cwd; a relative
  # path is resolved against the cwd (see ctx_target_excluded).
  if ctx_target_excluded "$(ctx_in .tool_input.path)"; then
    jq -cn --argjson n "$n" '{decision:"keep-full", why:"excluded-path", lines:$n}' >"${WORK}/detail.json"
    ctx_log skip "${WORK}/detail.json"
    return 0
  fi
  # ... and every returned path is checked too: a search of a clean ancestor ($HOME) can return hits from an
  # excluded descendant (~/work). Grep content lines are "path:line:text"; files modes are bare paths.
  # Every distinct path is checked; past max_hit_paths (500) nothing is sent rather than checking a prefix.
  local hit
  sed -E 's/^([^:]+):[0-9]+[:-].*/\1/; s/^([^:]+)-[0-9]+-.*/\1/' "${WORK}/text.txt" | awk '!seen[$0]++' >"${WORK}/hits.txt"
  if [ "$(wc -l <"${WORK}/hits.txt")" -gt "$(ctx_cfg max_hit_paths 500)" ]; then
    jq -cn --argjson n "$n" '{decision:"keep-full", why:"too-many-hit-paths", lines:$n}' >"${WORK}/detail.json"
    ctx_log skip "${WORK}/detail.json"
    return 0
  fi
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if ctx_target_excluded "$hit"; then
      jq -cn --argjson n "$n" '{decision:"keep-full", why:"excluded-hit", lines:$n}' >"${WORK}/detail.json"
      ctx_log skip "${WORK}/detail.json"
      return 0
    fi
  done <"${WORK}/hits.txt"

  task="$(ctx_task "$(ctx_in .transcript_path)")"
  state="$(jq -cn --arg task "$task" --arg tool "$tool" --arg pat "$(ctx_in .tool_input.pattern | cut -c1-200)" --argjson n "$n" \
    '{task:$task, tool:$tool, pattern:$pat, total_hits:$n}')"
  ctx_trim_flow "$tool" hits "$(ctx_cfg chunk_lines 25)" "$task" "$state" \
    "Do the search hits in this chunk look like what the task in state.task is looking for (right files, right symbols)?" \
    false early ""
}

main
exit 0
