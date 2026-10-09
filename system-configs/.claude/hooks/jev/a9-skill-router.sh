#!/bin/bash
# A9 - PreToolUse(Bash|Write|Edit|MultiEdit|NotebookEdit): is there a skill for what this call does?
#
# Skills declare triggers in their frontmatter (metadata.triggers: "cmd:<regex>" for Bash commands,
# "path:<glob>" for Write/Edit targets). skill-catalog.py --match lists the user, project,
# directory-scoped and enabled-plugin skills whose triggers match this call and apply to its target,
# then drops any skill already loaded since the last real user message (Skill tool or a typed
# /command), including skills an orchestrator that is running invokes itself.
#
# What is left gets surfaced BEFORE the call runs. PreToolUse additionalContext arrives with the
# tool result, too late for the call that triggered it, so enforce mode denies the call once with
# the skill named in the reason. The deny is a prompt, not a ban: each skill is surfaced at most once
# per user turn, so re-issuing the same call proceeds. Shadow mode only logs what it would surface.
# No Jev call: the match is deterministic and runs on every matched tool call.
# Fail OPEN: any problem -> no output, exit 0.
# shellcheck disable=SC2154 # WORK, RULE*, JEV_* are globals set by ctx-lib.sh
# shellcheck source=ctx-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ctx-lib.sh" || exit 0

main() {
  ctx_bootstrap A9-skill-router || return 0
  case "$(ctx_in .tool_name)" in Bash | Write | Edit | MultiEdit | NotebookEdit) ;; *) return 0 ;; esac
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I "${JEV_DIR}/skill-catalog.py" --match "$INPUT_FILE" "${WORK}/route.json" 2>/dev/null
  jq -e '(.route | length) > 0' "${WORK}/route.json" >/dev/null 2>&1 || return 0

  # Once per skill per user turn: a second identical attempt is a deliberate choice, let it through.
  local sid turn seen
  sid="$(ctx_in .session_id | tr -dc 'A-Za-z0-9_-')"
  [ -n "$sid" ] || sid=nosession
  turn="$(jq -r '.turn // ""' "${WORK}/route.json" | tr -dc 'A-Za-z0-9_-')"
  seen="${JEV_STATE_DIR}/${sid}.a9"
  jq --rawfile seen <(cat "$seen" 2>/dev/null || true) --arg turn "$turn" '
    ($seen | split("\n")) as $s
    | .route |= map(select((($turn + " " + .base) as $k | $s | index($k)) | not))' \
    "${WORK}/route.json" >"${WORK}/route2.json" 2>/dev/null || return 0
  jq -e '(.route | length) > 0' "${WORK}/route2.json" >/dev/null 2>&1 || return 0
  (
    umask 077
    mkdir -p "$JEV_STATE_DIR" && jq -r --arg turn "$turn" '.route[] | "\($turn) \(.base)"' "${WORK}/route2.json" >>"$seen"
  ) 2>/dev/null

  jq -c --arg tool "$(ctx_in .tool_name)" '{tool: $tool, surfaced: [.route[].name], loaded: .loaded,
    matched: [.candidates[].name]}' "${WORK}/route2.json" >"${WORK}/detail.json" 2>/dev/null
  ctx_log verdict "${WORK}/detail.json"
  [ "$RULE_MODE" = "enforce" ] || return 0

  local reason
  reason="$(jq -r '
    (.route | map("/\(.name): \(.desc)") | join("\n")) as $list
    | (.route | map("skill: \"\(.name)\"") | join(" or ")) as $calls
    | "Jev skill router: a skill covers this step and is not loaded yet.\n\($list)\nInvoke it with the Skill tool (\($calls)) and let it run this step; it carries the checks this command skips. If doing it by hand is deliberate, re-issue the same call: this notice appears once per skill per user turn."' \
    "${WORK}/route2.json" 2>/dev/null)" || return 0
  jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

main
exit 0
