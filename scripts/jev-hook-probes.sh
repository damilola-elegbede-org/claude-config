#!/bin/bash
# Empirical probes of Claude Code hook behaviour, run with nested `claude -p`.
# NOT part of CI (needs a logged-in claude CLI and spends a few cents on haiku).
#
# The Jev integration plan rests on hook facts taken from a docs summary. These
# probes check them against the installed CLI instead of trusting the summary:
#   a  PreCompact hook stdout: does it reach the compaction summarizer, or only
#      the debug log?
#   b  PreToolUse permissionDecision "deny" (with reason) under
#      --permission-mode bypassPermissions; is "ask" ignored?
#   c  PostToolUse updatedToolOutput: does it replace a Bash / Read result?
#   d  (supplemental) SessionStart: does plain stdout / systemMessage surface?
#
# Usage: scripts/jev-hook-probes.sh [a|b|c|d|all]   (default: all)
#
# Isolation: each probe runs in its own temp cwd, with --setting-sources project
# plus --settings <temp file>, so the user's live hooks (TTS on Stop, sounds on
# Notification) never fire. The CLAUDE_* session vars of an enclosing session
# are unset so the nested CLI starts a clean session. Probes b, c, d use
# --no-session-persistence. Probe a MUST persist a session (compaction needs
# history to compact). Every project dir the probes create under
# ~/.claude/projects is removed on exit (see cleanup). CLAUDE_CONFIG_DIR cannot
# isolate this: a non-default config dir has no login ("Not logged in").
set -uo pipefail

WHICH="${1:-all}"
MODEL="${PROBE_MODEL:-haiku}"
BUDGET="${PROBE_BUDGET_USD:-0.30}"

command -v claude >/dev/null 2>&1 || { echo "probes: claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "probes: jq not found" >&2; exit 1; }

ROOT="$(mktemp -d /tmp/jevprobe.XXXXXX)"
# Claude Code records a project dir under ~/.claude/projects for every cwd it
# runs in (even with --no-session-persistence), named after the cwd with / and .
# turned into -. Remove exactly the ones our probes created.
ENC_ROOT="$(printf '%s' "$(cd "$ROOT" && pwd -P)" | tr '/.' '--')"
cleanup() {
  local d
  for d in "$HOME/.claude/projects/$ENC_ROOT"*; do
    case "$d" in
      "$HOME"/.claude/projects/-private-tmp-jevprobe-* | "$HOME"/.claude/projects/-tmp-jevprobe-*) rm -rf "$d" ;;
    esac
  done
  [[ -n "${KEEP:-}" ]] || rm -rf "$ROOT"
}
trap cleanup EXIT

echo "claude: $(claude --version 2>&1 | head -1)   model: $MODEL   workdir: $ROOT"

# claude_run <cwd> <name> <settings-file> <prompt> [extra claude args...]
# Writes <cwd>/<name>.jsonl (stream-json) and <cwd>/<name>.err.
claude_run() {
  local cwd="$1" name="$2" settings="$3" prompt="$4"
  shift 4
  (
    cd "$cwd" || exit 1
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_AGENT -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH \
      -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED \
      -u CLAUDE_PID -u CLAUDE_JOB_DIR \
      claude -p "$prompt" --model "$MODEL" --permission-mode bypassPermissions \
      --setting-sources project --settings "$settings" --max-budget-usd "$BUDGET" \
      --output-format stream-json --verbose "$@" >"$cwd/$name.jsonl" 2>"$cwd/$name.err"
  )
}

# Text of every tool_result in a stream-json file.
tool_results() {
  jq -r 'select(.type=="user") | .message.content | arrays | .[] | select(.type=="tool_result")
         | (.content | if type=="array" then map(.text // "") | join("") else . end)' "$1" 2>/dev/null
}
final_text() { jq -r 'select(.type=="result") | .result' "$1" 2>/dev/null; }

new_probe_dir() { local d="$ROOT/$1"; mkdir -p "$d"; (cd "$d" && pwd -P); }

verdicts=()
verdict() { verdicts+=("$1"); echo "RESULT $1"; }

# ---------------------------------------------------------------- probe b
probe_b() {
  echo "== probe b: PreToolUse permissionDecision under bypassPermissions"
  local d
  d="$(new_probe_dir b)"
  cat >"$d/deny.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"PROBE-DENY-REASON-1234"}}'
EOF
  sed 's/"deny"/"ask"/; s/PROBE-DENY-REASON-1234/PROBE-ASK-REASON-5678/' "$d/deny.sh" >"$d/ask.sh"
  chmod +x "$d/deny.sh" "$d/ask.sh"
  local mode
  for mode in deny ask; do
    cat >"$d/$mode.settings.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$d/$mode.sh"}]}]}}
EOF
    claude_run "$d" "$mode" "$d/$mode.settings.json" \
      "Run this bash command exactly: touch $d/$mode-sentinel   Then reply with exactly the word DONE." \
      --no-session-persistence
    local sentinel="absent" tr
    [[ -e "$d/$mode-sentinel" ]] && sentinel="PRESENT"
    tr="$(tool_results "$d/$mode.jsonl" | tr '\n' ' ' | cut -c1-200)"
    echo "  [$mode] command executed (sentinel file): $sentinel"
    echo "  [$mode] tool_result seen by model: ${tr:-<none>}"
    echo "  [$mode] final text: $(final_text "$d/$mode.jsonl" | tr '\n' ' ' | cut -c1-160)"
  done
  if [[ ! -e "$d/deny-sentinel" ]] && tool_results "$d/deny.jsonl" | grep -q "PROBE-DENY-REASON-1234"; then
    verdict "b-deny: deny + reason WORKS under bypassPermissions (command blocked, reason reached the model)"
  else
    verdict "b-deny: NOT confirmed (see output above)"
  fi
  if [[ -e "$d/ask-sentinel" ]]; then
    verdict "b-ask: ask is IGNORED under bypassPermissions (command ran anyway)"
  else
    verdict "b-ask: ask blocked the command (not ignored); tool_result: $(tool_results "$d/ask.jsonl" | tr '\n' ' ' | cut -c1-120)"
  fi
}

# ---------------------------------------------------------------- probe c
# updatedToolOutput must match the tool's own output shape (the CLI logs
# "does not match Read's output shape ... schema_invalid" and silently keeps the
# original otherwise). So each tool is probed twice: with a plain string (the
# naive form) and with the hook's own .tool_response edited in place (shaped).
probe_c() {
  echo "== probe c: PostToolUse updatedToolOutput"
  local d
  d="$(new_probe_dir c)"
  printf 'ORIGINAL-READ-CONTENT-ABC\n' >"$d/c-file.txt"
  local tool variant key
  for tool in Bash Read; do
    cat >"$d/post-$tool-string.sh" <<EOF
#!/bin/bash
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"REPLACED-$tool-OUTPUT-XYZ"}}'
EOF
    cat >"$d/post-$tool-shaped.sh" <<EOF
#!/bin/bash
cat > "$d/$tool-shaped.stdin.json"
jq -c --arg v "REPLACED-$tool-OUTPUT-XYZ" '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedToolOutput:(.tool_response | if has("file") then .file.content=\$v else .stdout=\$v end)}}' "$d/$tool-shaped.stdin.json"
EOF
    chmod +x "$d/post-$tool-string.sh" "$d/post-$tool-shaped.sh"
    for variant in string shaped; do
      cat >"$d/$tool-$variant.settings.json" <<EOF
{"hooks":{"PostToolUse":[{"matcher":"$tool","hooks":[{"type":"command","command":"$d/post-$tool-$variant.sh"}]}]}}
EOF
    done
  done
  for variant in string shaped; do
    claude_run "$d" "Bash-$variant" "$d/Bash-$variant.settings.json" \
      "Run this bash command: echo ORIGINAL-BASH-OUT   Then reply with exactly the output you saw and nothing else." \
      --no-session-persistence --debug-file "$d/Bash-$variant.debug.log"
    claude_run "$d" "Read-$variant" "$d/Read-$variant.settings.json" \
      "Use the Read tool on $d/c-file.txt, then reply with exactly the file text you saw and nothing else." \
      --no-session-persistence --debug-file "$d/Read-$variant.debug.log"
  done
  for tool in Bash Read; do
    for variant in string shaped; do
      key="$tool-$variant"
      echo "  [$key] tool_result in stream: $(tool_results "$d/$key.jsonl" | tr '\n' ' ' | cut -c1-160)"
      echo "  [$key] final text: $(final_text "$d/$key.jsonl" | tr '\n' ' ' | cut -c1-120)"
      echo "  [$key] CLI log: $(grep -o 'does not match [A-Za-z]*.s output shape[^ ]*\|replaced tool output' "$d/$key.debug.log" 2>/dev/null | sort -u | tr '\n' ';')"
      if tool_results "$d/$key.jsonl" | grep -q "REPLACED-$tool-OUTPUT-XYZ"; then
        verdict "c-$key: updatedToolOutput REPLACED the $tool result"
      else
        verdict "c-$key: updatedToolOutput did NOT replace the $tool result"
      fi
    done
  done
}

# ---------------------------------------------------------------- probe a
probe_a() {
  echo "== probe a: PreCompact stdout -> compaction summarizer?"
  local d sid
  d="$(new_probe_dir a)"
  cat >"$d/precompact.sh" <<EOF
#!/bin/bash
cat > "$d/PRECOMPACT_STDIN.json"
touch "$d/PRECOMPACT_FIRED"
echo 'PROBE-COMPACT-TOKEN-777: the summary MUST include this exact token.'
EOF
  chmod +x "$d/precompact.sh"
  cat >"$d/settings.json" <<EOF
{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"$d/precompact.sh"}]}]}}
EOF
  sid="$(uuidgen | tr 'A-Z' 'a-z')"
  claude_run "$d" s1 "$d/settings.json" "Remember the secret word ZEBRA-42. Reply with just OK." --session-id "$sid"
  claude_run "$d" s2 "$d/settings.json" "/compact" --resume "$sid" --include-hook-events --debug-file "$d/debug.log"
  local fired="no" boundary="no" in_summary="no"
  [[ -e "$d/PRECOMPACT_FIRED" ]] && fired="yes"
  jq -e 'select(.subtype=="compact_boundary")' "$d/s2.jsonl" >/dev/null 2>&1 && boundary="yes"
  # The summary is the user message that starts "This session is being continued".
  if jq -e 'select(.type=="user" and ((.message.content|tostring)|test("This session is being continued")) and ((.message.content|tostring)|test("PROBE-COMPACT-TOKEN-777")))' "$d/s2.jsonl" >/dev/null 2>&1; then
    in_summary="yes"
  fi
  echo "  PreCompact hook fired: $fired   (stdin: $(jq -c '{hook_event_name,trigger,custom_instructions}' "$d/PRECOMPACT_STDIN.json" 2>/dev/null))"
  echo "  compact_boundary emitted: $boundary"
  echo "  hook-stdout token present in the compaction summary message: $in_summary"
  echo "  debug log mentions hook: $(grep -c 'PreCompact' "$d/debug.log" 2>/dev/null)x"
  if [[ "$fired" == yes && "$in_summary" == yes ]]; then
    verdict "a: PreCompact plain stdout REACHES the compaction summary (trigger=manual via /compact in -p; auto trigger untested)"
  elif [[ "$fired" == yes ]]; then
    verdict "a: PreCompact fired but its stdout did NOT reach the summary (debug log only)"
  else
    verdict "a: PreCompact did not fire (compaction may not have run; see $d/s2.jsonl)"
  fi
}

# ---------------------------------------------------------------- probe d
probe_d() {
  echo "== probe d (supplemental): SessionStart plain stdout vs systemMessage"
  local d
  d="$(new_probe_dir d)"
  cat >"$d/ss-plain.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "Jev checkpoints degraded to regex: PROBE-SESSIONSTART-PLAIN-555"
EOF
  cat >"$d/ss-json.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf '%s' '{"systemMessage":"PROBE-SYSTEMMESSAGE-666"}'
EOF
  chmod +x "$d/ss-plain.sh" "$d/ss-json.sh"
  cat >"$d/settings.json" <<EOF
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"$d/ss-plain.sh"},{"type":"command","command":"$d/ss-json.sh"}]}]}}
EOF
  claude_run "$d" s "$d/settings.json" \
    "List every line of text you were given by SessionStart hooks, verbatim. If none, say NONE." \
    --no-session-persistence --include-hook-events
  echo "  model answer: $(final_text "$d/s.jsonl" | tr '\n' ' ' | cut -c1-240)"
  local plain_in_model="no" sysmsg_in_model="no" plain_in_stream="no" sysmsg_in_stream="no"
  final_text "$d/s.jsonl" | grep -q "PROBE-SESSIONSTART-PLAIN-555" && plain_in_model="yes"
  final_text "$d/s.jsonl" | grep -q "PROBE-SYSTEMMESSAGE-666" && sysmsg_in_model="yes"
  grep -q "PROBE-SESSIONSTART-PLAIN-555" "$d/s.jsonl" && plain_in_stream="yes"
  grep -q "PROBE-SYSTEMMESSAGE-666" "$d/s.jsonl" && sysmsg_in_stream="yes"
  verdict "d: SessionStart plain stdout -> model sees it: $plain_in_model (in stream: $plain_in_stream); systemMessage -> model sees it: $sysmsg_in_model (in stream: $sysmsg_in_stream)"
}

case "$WHICH" in
  a) probe_a ;;
  b) probe_b ;;
  c) probe_c ;;
  d) probe_d ;;
  all)
    probe_b
    probe_c
    probe_a
    probe_d
    ;;
  *)
    echo "usage: $0 [a|b|c|d|all]" >&2
    exit 2
    ;;
esac

echo
echo "== summary"
printf '%s\n' "${verdicts[@]}"
