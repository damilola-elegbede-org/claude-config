#!/usr/bin/env bash
# Hermetic tests for the ONE registry reader (hooks/jev/registry.sh), its JavaScript twin (client.mjs
# `--registry`), the kill-switch rules and the decision log. Temp HOME throughout; nothing here touches
# the real ~/.claude or the network.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/system-configs/.claude/hooks"
JSRC="$SRC/jev"

if ! command -v jq >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: jq is required for the registry tests" >&2
    exit 1
  fi
  echo "SKIP: jq not installed (would FAIL in CI)" >&2
  exit 0
fi
HAVE_NODE=1
command -v node >/dev/null 2>&1 || HAVE_NODE=0

T="$(mktemp -d /tmp/claude-config-jev-registry.XXXXXX)"
trap 'rm -rf "$T"' EXIT
FAILS=0
PASSES=0
fail() {
  FAILS=$((FAILS + 1))
  printf 'FAIL: %s\n' "$1" >&2
}
pass() { PASSES=$((PASSES + 1)); }
eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass; else fail "$1 (expected '$2', got '$3')"; fi
}

# fresh <name>: a temp HOME with a deployed-style jev dir; sets H (home) and J (jev dir)
fresh() {
  H="$T/$1/home"
  J="$H/.claude/hooks/jev"
  rm -rf "${T:?}/$1"
  mkdir -p "$J/rules.d"
  cp "$JSRC/registry.sh" "$JSRC/gate-questions.json" "$J/"
  cp "$JSRC/rules.d/gates.json" "$J/rules.d/"
  cp "$JSRC/client.mjs" "$J/"
}

# shell_reg [ENV=VAL ...]: the merged registry from registry.sh, canonical (sorted keys)
shell_reg() {
  env -u JEV_DIR -u JEV_CLAUDE_DIR -u JEV_RULES -u JEV_RULES_FILE HOME="$H" "$@" \
    bash -c '. "$HOME/.claude/hooks/jev/registry.sh"; jev_reg_json' | jq -S -c .
}
# node_reg [ENV=VAL ...]: the same merge from the client
node_reg() {
  env -u JEV_RULES -u JEV_RULES_FILE HOME="$H" "$@" node "$J/client.mjs" --registry | jq -S -c .
}

parity() { # name [ENV=VAL ...]
  local name="$1"
  shift
  if [[ "$HAVE_NODE" != 1 ]]; then return 0; fi
  eq "shell and node readers agree: $name" "$(shell_reg "$@")" "$(node_reg "$@")"
}

# ============================================================================
# One reader, two implementations, same answers
# ============================================================================
fresh shipped
parity "shipped layers"

fresh layered
printf '%s' '{"exempt_agents":["x"],"rules":{"G1-irreversible-local":{"threshold":0.99},"new-rule":{"mode":"shadow","scope":["interactive"]}}}' >"$J/rules.d/z50-extra.json"
printf '%s' '{"flat-rule":{"mode":"off","threshold":0.5},"G4-prod-infra":{"scope":["bgjob"]}}' >"$J/rules.d/z60-flat.json"
printf '%s' '{"exempt_agents":["x-agent"],"rules":{"G1-irreversible-local":{"mode":"enforce"}}}' >"$J/jev-rules.json"
parity "wrapped + flat rules.d layers and a user override"
REG="$(shell_reg)"
eq "later rules.d layer overrides one key" "0.99" "$(jq -r '."G1-irreversible-local".threshold' <<<"$REG")"
eq "user jev-rules.json is the last layer" "enforce" "$(jq -r '."G1-irreversible-local".mode' <<<"$REG")"
eq "deep merge keeps the questions layer's fields" "true" "$(jq -r '."G1-irreversible-local".instructions | type == "string"' <<<"$REG")"
eq "deep merge keeps untouched keys of the rule" "enforce" "$(jq -r '."G4-prod-infra".mode' <<<"$REG")"
eq "arrays are replaced, not merged" '["bgjob"]' "$(jq -c '."G4-prod-infra".scope' <<<"$REG")"
eq "flat layer rule registered" "off" "$(jq -r '."flat-rule".mode' <<<"$REG")"
eq "exempt_agents comes from the last layer that sets it" '["x-agent"]' "$(jq -c '.exempt_agents' <<<"$REG")"
eq "approval-detector folded in with its question and mode" "true" "$(jq -r '."approval-detector" | (.mode == "shadow") and (.instructions | type == "string")' <<<"$REG")"
eq "mcp-classifier folded in with its questions and mode" "true" "$(jq -r '."mcp-classifier" | (.mode == "enforce") and (.class_instructions | type == "string")' <<<"$REG")"
eq "choice_questions are in the registry" "risk_class,scope" "$(jq -r '.choice_questions | keys | join(",")' <<<"$REG")"
eq "an unregistered rule is absent (so off)" "null" "$(jq -c '."nope"' <<<"$REG")"

fresh single
printf '%s' '{"only":{"mode":"enforce"}}' >"$T/single.json"
parity "single-file override (JEV_RULES_FILE)" JEV_RULES_FILE="$T/single.json"
eq "JEV_RULES_FILE replaces every layer" '{"only":{"mode":"enforce"}}' "$(shell_reg JEV_RULES_FILE="$T/single.json")"
eq "JEV_RULES is an alias" '{"only":{"mode":"enforce"}}' "$(shell_reg JEV_RULES="$T/single.json")"

# the code running from a checkout still honors the deployed overrides under ~/.claude/hooks/jev
fresh deployed
mkdir -p "$H/.claude/hooks/jev"
printf '%s' '{"rules":{"retry-counter":{"mode":"off"}}}' >"$H/.claude/hooks/jev/jev-rules.json"
EXPECT="off"
GOT="$(env -u JEV_DIR -u JEV_RULES_FILE HOME="$H" bash -c '. "'"$JSRC"'/registry.sh"; jev_reg_json' | jq -r '."retry-counter".mode')"
eq "checkout code layers the deployed jev-rules.json on top" "$EXPECT" "$GOT"

fresh broken
printf '%s' 'not json' >"$J/rules.d/z70-broken.json"
eq "an unreadable layer does not crash the reader (falls back to {})" "{}" "$(shell_reg)"
fresh empty
rm -rf "$J/rules.d" "$J/gate-questions.json"
eq "no layers means an empty registry" "{}" "$(shell_reg)"

# ============================================================================
# jev_reg_value / jev_reg_rule / jev_reg_exempt
# ============================================================================
fresh helpers
printf '%s' '{"exempt_agents":["Tars"],"rules":{"x":{"mode":"enforce","n":3,"scope":["a","b"]}}}' >"$J/jev-rules.json"
run_reg() { env -u JEV_DIR -u JEV_RULES -u JEV_RULES_FILE HOME="$H" bash -c '. "$HOME/.claude/hooks/jev/registry.sh"; '"$1"; }
eq "jev_reg_value scalar" "enforce" "$(run_reg 'jev_reg_value x mode off')"
eq "jev_reg_value number" "3" "$(run_reg 'jev_reg_value x n 0')"
eq "jev_reg_value default when the key is absent" "dflt" "$(run_reg 'jev_reg_value x nope dflt')"
eq "jev_reg_value default when the rule is absent" "dflt" "$(run_reg 'jev_reg_value nope mode dflt')"
eq "jev_reg_rule one entry" '{"mode":"enforce","n":3,"scope":["a","b"]}' "$(run_reg 'jev_reg_rule x')"
eq "jev_reg_rule unregistered is {}" "{}" "$(run_reg 'jev_reg_rule nope')"
eq "jev_reg_exempt matches case-insensitively" "0" "$(run_reg 'jev_reg_exempt tars; echo $?')"
eq "jev_reg_exempt rejects others" "1" "$(run_reg 'jev_reg_exempt other-agent; echo $?')"
fresh helpers-default
eq "jev_reg_exempt defaults to clara when no layer sets a list" "0" "$(run_reg 'jev_reg_exempt clara; echo $?')"
rm -f "$J/jev-rules.json"
rm -rf "$J/rules.d"
rm -f "$J/gate-questions.json"
eq "jev_reg_exempt default list with no layers at all" "0" "$(run_reg 'jev_reg_exempt clara; echo $?')"

# ============================================================================
# Kill switches: regular files only, gate.off is the master switch for gates
# ============================================================================
fresh kill
CL="$H/.claude"
run_kill() { env -u JEV_DIR HOME="$H" bash -c '. "$HOME/.claude/hooks/jev/registry.sh"; '"$1"'; echo $?'; }
eq "no switch: gates run" "1" "$(run_kill 'jev_gates_off')"
touch "$CL/jev.off"
eq "jev.off stops the Jev gates" "0" "$(run_kill 'jev_gates_off')"
eq "jev.off is a kill switch" "0" "$(run_kill 'jev_kill_switch jev.off')"
eq "jev.off is not gate.off" "1" "$(run_kill 'jev_kill_switch gate.off')"
rm -f "$CL/jev.off"
touch "$CL/gate.off"
eq "gate.off (master) stops the Jev gates too" "0" "$(run_kill 'jev_gates_off')"
rm -f "$CL/gate.off"
mkdir "$CL/jev.off" "$CL/gate.off"
eq "a directory named jev.off is not a switch" "1" "$(run_kill 'jev_gates_off')"
rmdir "$CL/jev.off" "$CL/gate.off"
touch "$T/target-file"
ln -s "$T/target-file" "$CL/jev.off"
eq "a symlink named jev.off is not a switch" "1" "$(run_kill 'jev_gates_off')"
rm -f "$CL/jev.off"

# ============================================================================
# The decision log
# ============================================================================
fresh log
LOGF="$H/.claude/jev/decisions.jsonl"
env -u JEV_DIR -u JEV_DECISIONS_LOG HOME="$H" bash -c '. "$HOME/.claude/hooks/jev/registry.sh"
  jev_decision_log G1-irreversible-local shadow would-deny-shadow 0.91 "{\"risk_class\":{\"choice\":\"data_loss\"}}" typesafe-ai/jev 312 hook:test "{\"tool\":\"Bash\"}"
  jev_decision_log some-rule "" skip "" "" "" "" hook:test'
eq "two lines appended" "2" "$(grep -c . "$LOGF")"
LINE1="$(sed -n 1p "$LOGF")"
eq "every documented field is present" "answers,confidence,gate,latencyMs,mode,model,outcome,src,ts" "$(jq -r 'del(.tool) | keys | join(",")' <<<"$LINE1")"
eq "gate" "G1-irreversible-local" "$(jq -r .gate <<<"$LINE1")"
eq "mode" "shadow" "$(jq -r .mode <<<"$LINE1")"
eq "outcome" "would-deny-shadow" "$(jq -r .outcome <<<"$LINE1")"
eq "confidence is a number" "0.91" "$(jq -r .confidence <<<"$LINE1")"
eq "answers is an object" "data_loss" "$(jq -r .answers.risk_class.choice <<<"$LINE1")"
eq "model" "typesafe-ai/jev" "$(jq -r .model <<<"$LINE1")"
eq "latencyMs is a number" "312" "$(jq -r .latencyMs <<<"$LINE1")"
eq "extra fields merge in" "Bash" "$(jq -r .tool <<<"$LINE1")"
LINE2="$(sed -n 2p "$LOGF")"
eq "absent fields are null, not empty strings" "null,null,null,null" "$(jq -r '[.mode, .answers, .confidence, .model] | map(tostring) | join(",")' <<<"$LINE2")"
# GNU stat first: on Linux `stat -f` prints file-system info and exits 0, so the BSD form must be the fallback.
eq "the log is private (0600)" "600" "$(stat -c '%a' "$LOGF" 2>/dev/null || stat -f '%Lp' "$LOGF")"

# ============================================================================
# gate.sh (the regex gate) reads the same registry and writes the same log
# ============================================================================
gate_home() { # name: a HOME with gate.sh + gate-rules.json + the registry, deployed the way sync does
  fresh "$1"
  cp "$SRC/gate.sh" "$H/.claude/hooks/gate.sh"
  cp "$SRC/gate-rules.json" "$H/.claude/hooks/gate-rules.json"
  mkdir -p "$H/tmp"
}
run_gate() { # payload [ENV=VAL ...]  -> GOUT
  local payload="$1"
  shift
  GOUT=$(printf '%s' "$payload" | env -u BARECLAUDE_AGENT_SLUG -u CLAUDE_JOB_DIR -u JEV_DIR -u JEV_RULES -u JEV_RULES_FILE \
    HOME="$H" TMPDIR="$H/tmp" "$@" bash "$H/.claude/hooks/gate.sh" 2>/dev/null)
}
RM_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"rm -rf /srv/data"},"cwd":"/work"}'
decision_of() { jq -r '.hookSpecificOutput.permissionDecision // ""' <<<"$GOUT" 2>/dev/null; }

gate_home gate-default
run_gate "$RM_PAYLOAD"
eq "gate.sh denies rm -rf by default" "deny" "$(decision_of)"
GL="$H/.claude/jev/decisions.jsonl"
eq "gate.sh writes the one decision log" "G1-rm" "$(jq -rs '[.[] | select(.outcome == "deny")][0].gate' "$GL")"
eq "the decision-log line carries src and mode" "hook:gate.sh,regex" "$(jq -rs '[.[] | select(.outcome == "deny")][0] | [.src, .mode] | join(",")' "$GL")"
eq "the legacy gate-log.jsonl alias is still written" "G1-rm" "$(jq -rs '[.[] | select(.decision == "deny")][0].rule' "$H/.claude/gate-log.jsonl")"

gate_home gate-off-mode
printf '%s' '{"rules":{"G1-rm":{"mode":"off"}}}' >"$J/jev-rules.json"
run_gate "$RM_PAYLOAD"
eq "registry mode off silences a regex rule" "" "$GOUT"
printf '%s' '{"rules":{"G1-rm":{"mode":"shadow"}}}' >"$J/jev-rules.json"
run_gate "$RM_PAYLOAD"
eq "registry mode shadow logs but allows" "" "$GOUT"
eq "shadow match is logged as shadow" "shadow" "$(jq -rs '[.[] | select(.gate == "G1-rm")][0].outcome' "$H/.claude/jev/decisions.jsonl")"
printf '%s' '{"rules":{"G1-rm":{"mode":"enforce"}}}' >"$J/jev-rules.json"
run_gate "$RM_PAYLOAD"
eq "registry mode enforce still denies" "deny" "$(decision_of)"

gate_home gate-exempt
run_gate "$RM_PAYLOAD" BARECLAUDE_AGENT_SLUG=clara
eq "clara exempt (gate-rules.json list)" "" "$GOUT"
printf '%s' '{"exempt_agents":["tars"]}' >"$J/jev-rules.json"
run_gate "$RM_PAYLOAD" BARECLAUDE_AGENT_SLUG=clara
eq "a registry exempt_agents list replaces the shipped one (clara no longer exempt)" "deny" "$(decision_of)"
run_gate "$RM_PAYLOAD" BARECLAUDE_AGENT_SLUG=tars
eq "a registry exempt_agents list exempts its members" "" "$GOUT"

gate_home gate-killswitch
touch "$H/.claude/gate.off"
run_gate "$RM_PAYLOAD"
eq "gate.off stops the regex gate" "" "$GOUT"
rm -f "$H/.claude/gate.off"
touch "$H/.claude/jev.off"
run_gate "$RM_PAYLOAD"
eq "jev.off does NOT stop the regex gate" "deny" "$(decision_of)"

gate_home gate-noreg
rm -rf "$H/.claude/hooks/jev"
run_gate "$RM_PAYLOAD"
eq "without the registry gate.sh falls back to its own rules (still denies)" "deny" "$(decision_of)"

printf 'Jev registry: %d passed, %d failed\n' "$PASSES" "$FAILS"
[[ "$FAILS" -eq 0 ]]
