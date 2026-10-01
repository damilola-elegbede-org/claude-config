#!/bin/bash
# A1 - PostToolUse(Read): trim a big, un-windowed Read down to the chunks that matter for the task.
#
# Fires only when ALL hold (cheap deterministic gates run before any Jev call):
#   - no offset/limit on the Read (an explicit window means Claude already chose what it wants)
#   - the output has more than `min_lines` (400) lines
#   - the file is not one Claude is likely to Edit next (see a1_edit_risk below)
#   - Jev does not itself answer will_edit >= will_edit_p (same call as the chunk scoring)
#
# Conservative "about to Edit" rule. We cannot see the future, so we skip when EITHER:
#   (a) the file has uncommitted changes (it is part of the work in progress), or
#   (b) the task text shows edit intent (fix/change/update/implement/...) AND the file is tracked in
#       its own git repo. Empty/unknown task counts as edit intent.
# Files outside any repo (logs, reference docs, node_modules, ~/.claude config being read), and
# any file when the task is a question/review/explain, are fair game. Edit needs exact text, and a
# trimmed region would be re-read first anyway: every gap carries a re-read marker with offset/limit
# and the full text is saved under ~/.claude/jev-cache/.
#
# Fail OPEN: any problem or exit-3 from jev-ask -> no output, output untouched.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

EDIT_INTENT='(^|[^a-z])(fix|change|update|edit|modify|refactor|implement|add|remove|delete|rename|replace|rewrite|patch|write|create|migrate|convert|bump|wire|make|apply|tweak|adjust|insert|extract|move)([^a-z]|$)'

a1_edit_risk() { # $1 = file, $2 = task ; prints a reason and returns 0 when trimming is unsafe
  local file="$1" task="$2" dir
  dir="$(dirname "$file")"
  [ -d "$dir" ] || return 1
  git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  if [ -n "$(git -C "$dir" status --porcelain -- "$file" 2>/dev/null)" ]; then
    echo "uncommitted-changes"
    return 0
  fi
  if [ -z "$task" ] || printf '%s' "$task" | grep -Eiq "$EDIT_INTENT"; then
    if git -C "$dir" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
      echo "tracked-file-and-edit-intent"
      return 0
    fi
  fi
  return 1
}

main() {
  ctx_bootstrap A1-read-trim || return 0
  [ "$(ctx_in .tool_name)" = "Read" ] || return 0
  [ -z "$(ctx_in .tool_input.offset)" ] && [ -z "$(ctx_in .tool_input.limit)" ] || return 0

  ctx_extract Read || return 0
  local n min file task reason state extra
  n="$(ctx_line_count "${WORK}/text.txt")"
  min="$(ctx_cfg min_lines 400)"
  [ "$n" -gt "$min" ] || return 0

  file="$(ctx_in .tool_input.file_path)"
  [ -n "$file" ] || file="$(ctx_in .tool_response.file.filePath)"
  task="$(ctx_task "$(ctx_in .transcript_path)")"

  # Egress: never send digests of a file under an excluded (work) tree, wherever the session runs.
  if ctx_target_excluded "$file"; then
    jq -cn --argjson n "$n" '{decision:"keep-full", why:"excluded-path", lines:$n}' >"${WORK}/detail.json"
    ctx_log skip "${WORK}/detail.json"
    return 0
  fi

  if reason="$(a1_edit_risk "$file" "$task")"; then
    jq -cn --arg why "$reason" --argjson n "$n" '{decision:"keep-full", why:$why, lines:$n}' >"${WORK}/detail.json"
    ctx_log skip "${WORK}/detail.json"
    return 0
  fi

  state="$(jq -cn --arg task "$task" --arg path "$file" --argjson n "$n" '{task:$task, tool:"Read", path:$path, total_lines:$n}')"
  extra='{"will_edit":{"type":"boolean","instructions":"Is the assistant likely to modify the file at state.path in its next steps, i.e. does state.task ask for a change that touches this file?","criteria":{"true":"the task needs this file changed","false":"the file is only being read for information"}}}'
  ctx_trim_flow Read read "$(ctx_cfg chunk_lines 100)" "$task" "$state" \
    "Does this chunk hold content the task in state.task needs (definitions, logic, text it refers to)?" \
    true early "$file" "$extra"
}

main
exit 0
