#!/bin/bash
# rules-events-lib.sh — shared helpers for the Phase-4 rules, lifecycle-event and
# workflow-helper hooks. Sourced by those scripts; never run directly, and never
# registered as a hook itself.
#
# Contract it codes against: ~/.claude/hooks/jev/jev-ask (the Jev client, built
# in a parallel branch). One request JSON on stdin, one response JSON on stdout,
# exit 3 = unavailable. Callers apply their own fail mode; every caller in this
# family fails OPEN (quality hooks), and regex verdicts stand without Jev.
#
# Per-rule mode lives in rules.d/rules-events.json (and the client's
# jev-rules.json, which wins): off | shadow | enforce. Shadow means Jev is
# called and logged but its answer never changes what the hook does.
# shellcheck shell=bash

RE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RE_CLAUDE_DIR="${HOME}/.claude"
RE_STATE_DIR="${RE_CLAUDE_DIR}/jev/state"
# Legacy event log, kept as an ALIAS for one release; decisions.jsonl (registry.sh) is the log to read.
RE_EVENT_LOG="${RE_CLAUDE_DIR}/jev/rules-events.jsonl"

# The ONE registry reader, decision log and kill-switch rules (registry.sh).
JEV_DIR="${JEV_DIR:-$RE_HERE}"
# shellcheck source=registry.sh
. "$RE_HERE/registry.sh" || return 1

re_need_jq() { command -v jq >/dev/null 2>&1; }

# interactive | bgjob | fleet — same gating signals as claude-speak.sh.
re_scope() {
  if [ -n "${BARECLAUDE_AGENT_SLUG:-}" ]; then
    echo fleet
  elif [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    echo bgjob
  else
    echo interactive
  fi
}

# Clara is fully exempt from every gate (D, 2026-09-30): log only. The list is the registry's
# exempt_agents (default clara), the same one gate.sh and the Jev gates read.
re_is_exempt_agent() {
  [ -n "${BARECLAUDE_AGENT_SLUG:-}" ] || return 1
  re_need_jq || {
    case "${BARECLAUDE_AGENT_SLUG:-}" in clara) return 0 ;; esac
    return 1
  }
  jev_reg_exempt "$BARECLAUDE_AGENT_SLUG"
}

# re_cfg <rule> <key> <default> — value of rules[<rule>][<key>] from the ONE registry reader
# (registry.sh: questions layer, rules.d/*.json, jev-rules.json last; JEV_RULES_FILE = a single file),
# else <default>.
re_cfg() {
  local out
  if re_need_jq; then
    out=$(jev_reg_value "$1" "$2" "")
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  printf '%s' "$3"
}

# re_mode <rule> <default> — off | shadow | enforce (anything else → default).
re_mode() {
  local m
  m=$(re_cfg "$1" mode "$2")
  case "$m" in off | shadow | enforce) printf '%s' "$m" ;; *) printf '%s' "$2" ;; esac
}

# re_log <rule> <verdict> [detail] — one JSON line per decision. No prompt text.
re_log() {
  re_need_jq || return 0
  jev_decision_log "$1" "" "$2" "" "" "" "" "hook:rules-events" \
    "$(jq -nc --arg detail "${3:-}" --arg scope "$(re_scope)" '{detail:$detail, scope:$scope}' 2>/dev/null)"
  mkdir -p "$(dirname "$RE_EVENT_LOG")" 2>/dev/null || return 0
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg rule "$1" --arg verdict "$2" \
    --arg detail "${3:-}" --arg scope "$(re_scope)" \
    '{ts:$ts,rule:$rule,verdict:$verdict,detail:$detail,scope:$scope}' \
    >>"$RE_EVENT_LOG" 2>/dev/null || true
}

# re_jev_call — request JSON on stdin, response JSON on stdout.
# Returns 3 when Jev is unavailable (kill switch, no client, no key, timeout).
# JEV_MOCK=<file> returns the file; JEV_MOCK=unavailable returns 3 — same as the
# client's own mock, honored here too so tests never need a client installed.
# JEV_MOCK_CAPTURE=<file> records the request (tests assert on minimal state).
re_jev_call() {
  local req bin
  jev_kill_switch jev.off && return 3
  req=$(cat)
  [ -n "${JEV_MOCK_CAPTURE:-}" ] && printf '%s\n' "$req" >>"$JEV_MOCK_CAPTURE"
  case "${JEV_MOCK:-}" in
    unavailable) return 3 ;;
    "") ;;
    *)
      [ -f "$JEV_MOCK" ] || return 3
      cat "$JEV_MOCK"
      return 0
      ;;
  esac
  bin="${JEV_ASK:-$RE_CLAUDE_DIR/hooks/jev/jev-ask}"
  [ -x "$bin" ] || return 3
  printf '%s' "$req" | "$bin"
}

# re_jev_req <rule> <state-json> <questions-json> [timeout_ms] — build a request.
re_jev_req() {
  jq -nc --arg rule "$1" --argjson state "$2" --argjson q "$3" --argjson t "${4:-1000}" \
    '{rule:$rule,state:$state,questions:$q,timeout_ms:$t}'
}

# --- hook output helpers (stdout JSON, exit 0) -------------------------------
re_deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}
re_ctx() { # <HookEventName> <text>
  jq -nc --arg e "$1" --arg c "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
}
re_block() { jq -nc --arg r "$1" '{decision:"block",reason:$r}'; }

# re_session_dir [session_id] — per-session scratch dir, keyed on the session id.
re_session_dir() {
  local sid="${1:-nosession}"
  sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
  printf '%s/%s' "$RE_STATE_DIR" "$sid"
}

# re_memory_dir — D's auto-memory directory (index + entries).
re_memory_dir() { printf '%s' "${RE_MEMORY_DIR:-$RE_CLAUDE_DIR/projects/-Users-daelegbe/memory}"; }
