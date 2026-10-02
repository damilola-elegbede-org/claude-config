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

# Content-view contract. Recognized, and ONLY these (a grep on the hot path, no parser). The WHOLE
# command must be one view, optionally piped into more views:
#   [cd DIR && | cd DIR ;]  NAME=VALUE...  [env OPTS [- | --] NAME=VALUE... | command [-p]]  VIEW ARGS  [| VIEW ARGS]...
#   - env OPTS: -i -v -u NAME -C DIR, --unset[=| ]NAME, --chdir[=| ]DIR; NAME, DIR and git's -C DIR are
#     plain words (no quotes, escapes, $, ` or redirections), and so is cd's DIR; not -0/--null: env
#     refuses a command with it
#   - NAME=VALUE after env is an ordinary, word-split argument: expansions only inside "..."
#   - VALUE and ARGS: plain chars, '...', "..." with \ escapes, \x, $NAME, one level of $(...) $((...))
#     ${...} `...` with no backslash, $ or ` inside (no nesting), and N>&M; an unclosed expansion
#     matches nothing; an unquoted ; & | ends the view
#   - ARGS never hold <, except a plain input redirect (< file, <file): no <<, <<< or <(...)
#   - VIEW: cat bat nl sed head tail less more diff jq, git [-C DIR] diff|show|blame|log -p
# So cat f && npm run build, a multi-line command, FOO=1;echo cat f, command FOO=1 cat f and
# env -0 cat f are NOT views.
# Not recognized, by design: other wrappers (exec nice time nohup sudo xargs), quoted or escaped command
# names, subshells, nested expansions, pipes into non-view commands. A miss is safe: the output is
# trimmed, and the full output stays in the cache file every marker cites.
# Out of scope the other way: A3 classifies the command line, not what a view tool runs inside it
# (sed 'e cmd', GIT_EXTERNAL_DIFF=cmd git diff). Such output stays untrimmed: a token cost, never data loss.
CONTENT_VIEW="^[[:space:]]*((cd[[:space:]]+[^[:space:];&|<>\\\\'\"\$\`]+[[:space:]]*(&&|;)[[:space:]]*)?)([A-Za-z_][A-Za-z0-9_]*=(\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-]|'[^']*'|\"([^\"\\\\\$\`]|\\\\.|\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-])*\"|\\\\.|[^[:space:];&|'\"\\\\\$()\`<>])*[[:space:]]+)*(env([[:space:]]+(-[iv]+|--ignore-environment|--debug|-u[[:space:]]*[^[:space:];&|<>\\\\'\"\$\`]+|--unset(=|[[:space:]]+)[^[:space:];&|<>\\\\'\"\$\`]+|-C[[:space:]]*[^[:space:];&|<>\\\\'\"\$\`]+|--chdir(=|[[:space:]]+)[^[:space:];&|<>\\\\'\"\$\`]+))*([[:space:]]+--?)?[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=('[^']*'|\"([^\"\\\\\$\`]|\\\\.|\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-])*\"|\\\\.|[^[:space:];&|'\"\\\\\$()\`<>])*[[:space:]]+)*|command([[:space:]]+-p)?[[:space:]]+)?(cat|bat|nl|sed|head|tail|less|more|diff|jq|git([[:space:]]+-C[[:space:]]+[^[:space:];&|<>\\\\'\"\$\`]+)?[[:space:]]+(diff|show|blame|log[[:space:]]+-p))([[:space:]]+([0-9]*<|[0-9]*<(\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-]|'[^']*'|\"([^\"\\\\\$\`]|\\\\.|\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-])*\"|\\\\.|[^[:space:];&|'\"\\\\\$()\`<>])+|[0-9]*>&[0-9-]|(\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-]|'[^']*'|\"([^\"\\\\\$\`]|\\\\.|\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-])*\"|\\\\.|[^[:space:];&|'\"\\\\\$()\`<])+))*[[:space:]]*(\\|[[:space:]]*(cat|bat|nl|sed|head|tail|less|more|diff|jq|git([[:space:]]+-C[[:space:]]+[^[:space:];&|<>\\\\'\"\$\`]+)?[[:space:]]+(diff|show|blame|log[[:space:]]+-p))([[:space:]]+([0-9]*<|[0-9]*<(\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-]|'[^']*'|\"([^\"\\\\\$\`]|\\\\.|\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-])*\"|\\\\.|[^[:space:];&|'\"\\\\\$()\`<>])+|[0-9]*>&[0-9-]|(\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-]|'[^']*'|\"([^\"\\\\\$\`]|\\\\.|\\\$\\(\\([^()\\\\\$\`]*\\)\\)|\\\$\\([^()\\\\\$\`]*\\)|\\\$\\{[^}\\\\\$\`]*\\}|\`[^\`\\\\\$]*\`|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$[0-9@*#?\$!-])*\"|\\\\.|[^[:space:];&|'\"\\\\\$()\`<])+))*[[:space:]]*)*\$"

main() {
  ctx_bootstrap A3-bash-trim || return 0
  [ "$(ctx_in .tool_name)" = "Bash" ] || return 0
  [ "$(ctx_in .tool_input.run_in_background)" != "true" ] || return 0
  local cmd task n min state
  cmd="$(ctx_in .tool_input.command)"
  # A newline separates commands and grep matches per line, so a multi-line command is never a view.
  if [[ "$cmd" != *$'\n'* ]] && printf '%s' "$cmd" | grep -Eq "$CONTENT_VIEW"; then
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
