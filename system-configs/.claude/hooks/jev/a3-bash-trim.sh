#!/bin/bash
# A3 - PostToolUse(Bash): a command log longer than `min_lines` (300) is cut down to the chunks Jev
# scores as holding the cause of an error, plus always the last `tail_lines` (40) lines. The full
# output is saved under ~/.claude/jev-cache/ and cited in every marker.
#
# Not touched: background commands, commands whose output IS the content Claude may need
# verbatim or edit against (cat/sed/head/tail/git diff|show|blame/diff/jq/nl/bat/less), and commands
# that name a path inside an excluded (work) tree or run with such a cwd (egress ruling).
# Fail OPEN: any problem or exit-3 from jev-ask -> no output, output untouched.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

# Ordinary prefixes still mean a content view: FOO=1 cat f, FOO='a b' cat f, FOO=$(x y) cat f, env cat f,
# env -i -u X cat f, command -p cat f. A value is shell words (quoted, escaped, plain, or one level of
# $(...) / $((...)) / ${...} / `...`); an unquoted ; & | ends it, so FOO=1;echo cat f is not a view.
# Best effort: a form this misses is trimmed, and A3 keeps the full output in the file its marker cites.
CONTENT_VIEW="^[[:space:]]*((cd[[:space:]]+[^;&|]+(&&|;)[[:space:]]*)?)(([A-Za-z_][A-Za-z0-9_]*=(\\\$\\(\\([^()]*\\)\\)|\\\$\\([^()]*\\)|\\\$\\{[^}]*\\}|\`[^\`]*\`|'[^']*'|\"([^\"\\\\]|\\\\.)*\"|\\\\.|[^[:space:];&|'\"\\\\])*|env([[:space:]]+(-[iv0]+|--ignore-environment|--null|--debug|-u[[:space:]]*[^[:space:];&|]+|--unset=[^[:space:];&|]+|-C[[:space:]]*[^[:space:];&|]+|--chdir=[^[:space:];&|]+))*|command([[:space:]]+-p)?)[[:space:]]+)*(cat|bat|nl|sed|head|tail|less|more|diff|jq|git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(diff|show|blame|log[[:space:]]+-p))([[:space:]]|\$)"

main() {
  ctx_bootstrap A3-bash-trim || return 0
  [ "$(ctx_in .tool_name)" = "Bash" ] || return 0
  [ "$(ctx_in .tool_input.run_in_background)" != "true" ] || return 0
  local cmd task n min state
  cmd="$(ctx_in .tool_input.command)"
  if printf '%s' "$cmd" | grep -Eq "$CONTENT_VIEW"; then
    return 0
  fi

  # Egress: output produced in an excluded (work) tree never leaves the machine.
  if ctx_target_excluded ""; then
    return 0
  fi

  ctx_extract Bash || return 0
  n="$(ctx_line_count "${WORK}/text.txt")"
  min="$(ctx_cfg min_lines 300)"
  [ "$n" -gt "$min" ] || return 0
  # Egress, provenance: the session cwd is clean, but the command may still have read an excluded tree
  # (`git -C ~/Visa/app test`, `cd ../work && make`). Checked only for outputs that would be sent.
  if ctx_cmd_touches_excluded "$cmd"; then
    return 0
  fi

  task="$(ctx_task "$(ctx_in .transcript_path)")"
  state="$(jq -cn --arg task "$task" --arg cmd "$(printf '%s' "$cmd" | cut -c1-200)" --argjson n "$n" \
    '{task:$task, tool:"Bash", command:$cmd, total_lines:$n}')"
  ctx_trim_flow Bash log "$(ctx_cfg chunk_lines 50)" "$task" "$state" \
    "Does this chunk contain the cause of an error or failure (error message, stack trace, failing test, non-zero exit, root-cause line) for the command in state.command?" \
    true late ""
}

main
exit 0
