#!/bin/bash
# pr-landing-gate.sh — a PR is done when GitHub would let D click Merge, not when it is created.
#
#   PostToolUse(Bash, if gh pr create / git push / git-agent.sh <agent> push): record the session's PR
#     (a push records the open PR of the pushed branch, if any) and, in enforce, tell the model in-band
#     to run /land on it now.
#   Stop: while a recorded PR is not ready (pr-land-status.sh), block the stop with the blockers and
#     "run /land <url>". Released by: ready, merged, closed, or a /land bounded-out record for the
#     current head. Re-blocks even on a stop-hook continuation (that is the point), capped at
#     max_blocks per PR head so a stuck PR can never trap the session (the harness caps at 8).
#
# No Jev model call: every verdict is GitHub state. Mode/scope/exempt come from the shared rule
# registry (rules.d/rules-events.json "pr-landing-gate"). Fails OPEN on any error (gh missing,
# offline, unauthenticated). Headless probes behind the design: claude-config
# .tmp/reports/landing-gate-probe-2026-10-08 (Stop block re-prompted the model 4/4 in claude -p).
# Test seams: PR_LAND_GH (gh binary, passed through to pr-land-status.sh).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

RULE=pr-landing-gate
INPUT=$(cat)
MODE=$(re_mode "$RULE" enforce)
[ "$MODE" = off ] && exit 0
if re_is_exempt_agent; then
  re_log "$RULE" allow-exempt-agent ""
  exit 0
fi

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
DIR="$(re_session_dir "$SID")/landing"
STATUS="$(dirname "$0")/pr-land-status.sh"
GH="${PR_LAND_GH:-gh}"

record() { # <url> -> 0 when newly recorded
  local key f
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
  f="$DIR/$key.json"
  mkdir -p "$DIR" 2>/dev/null || return 1
  jq -nc --arg u "$1" --arg ts "$(date -u +%FT%TZ)" '{url:$u, recorded_at:$ts}' >"$f"
}

# pushed_branch <command>: the branch a push updated ("" = the current branch); fails for a
# dry run or a delete, which change no PR. Reads the first push in the command, first refspec only.
pushed_branch() {
  local args a pos=0 ref="" skip=0 opts=1
  args=$(printf '%s' "$1" | grep -oE '(git|git-agent\.sh)[^;&|]*[[:space:]]push([[:space:]][^;&|]*)?' | head -1 | sed -E 's/^.*[[:space:]]push//')
  for a in $args; do
    if [ "$skip" = 1 ]; then
      skip=0
      continue
    fi
    case "$opts:$a" in
      1:--dry-run | 1:-n | 1:--delete | 1:-d) return 1 ;;
      # Options whose value is the next word (git push -h); the =value forms fall to -* below.
      1:--repo | 1:--receive-pack | 1:--exec | 1:-o | 1:--push-option | 1:--recurse-submodules) skip=1 ;;
      1:--) opts=0 ;;
      1:-*) ;;
      *)
        pos=$((pos + 1))
        [ "$pos" -eq 2 ] && ref="$a"
        ;;
    esac
  done
  ref="${ref#+}"
  case "$ref" in :* | *:) return 1 ;; *:*) ref="${ref#*:}" ;; esac
  ref="${ref#refs/heads/}"
  case "$ref" in HEAD | '') ref="" ;; *[!A-Za-z0-9._/-]*) return 1 ;; esac
  printf '%s' "$ref"
}

on_post() {
  local cmd out url cwd
  cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  out=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // empty')
  # Strip quoted strings so a commit message that MENTIONS these commands is not one. A quoted
  # word with no space (git push origin "feat/x") is unwrapped first: a ref never has a space.
  local bare
  bare=$(printf '%s' "$cmd" | sed -E "s/\"([^\"[:space:]\\\\]*)\"/\\1/g; s/'([^'[:space:]]*)'/\\1/g; s/\"([^\"\\\\]|\\\\.)*\"//g; s/'[^']*'//g")
  if printf '%s' "$bare" | grep -qE '(^|[[:space:];&|(])gh[[:space:]]+(-R[[:space:]]+[^[:space:]]+[[:space:]]+)?pr[[:space:]]+create([[:space:]]|$)'; then
    url=$(printf '%s' "$out" | grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' | tail -1)
  elif printf '%s' "$bare" | grep -qE '(^|[[:space:];&|(])(git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?|([^[:space:]]*/)?git-agent\.sh[[:space:]]+[A-Za-z0-9_-]+)[[:space:]]+push([[:space:]]|$)'; then
    cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
    [ -n "$cwd" ] && [ -d "$cwd" ] || return 0
    local branch
    branch=$(pushed_branch "$bare") || return 0
    # shellcheck disable=SC2086 # $branch is one ref name, or empty for the current branch
    url=$(cd "$cwd" && "$GH" pr view $branch --json url,state --jq 'select(.state == "OPEN") | .url' 2>/dev/null)
  else
    return 0
  fi
  [ -n "$url" ] || return 0
  record "$url" || return 0
  if [ "$MODE" = shadow ]; then
    re_log "$RULE" shadow-recorded "$url"
    return 0
  fi
  re_log "$RULE" recorded "$url"
  re_ctx PostToolUse "PR $url is open, and opening or pushing it is not the end of the task. Invoke the /land skill on $url now and keep going until it reports the PR mergeable (CI green, every review thread resolved, no conflicts) or bounded out. Do not tell D it is ready to merge before that."
}

on_stop() {
  local f url st v head max n cnt open="" detail notes=""
  [ -d "$DIR" ] || return 0
  max=$(re_cfg "$RULE" max_blocks 3)
  case "$max" in '' | *[!0-9]*) max=3 ;; esac
  for f in "$DIR"/*.json; do
    [ -e "$f" ] || continue
    url=$(jq -r '.url // empty' "$f" 2>/dev/null)
    [ -n "$url" ] || continue
    # Bound each call so several PRs stay inside the hook's 60s budget; a timeout fails open below.
    if command -v perl >/dev/null 2>&1; then
      st=$(PR_LAND_GH="$GH" perl -e 'alarm shift; exec @ARGV' "${PR_LAND_CALL_TIMEOUT:-15}" bash "$STATUS" "$url" 2>/dev/null)
    else
      st=$(PR_LAND_GH="$GH" bash "$STATUS" "$url" 2>/dev/null)
    fi
    v=$(printf '%s' "$st" | jq -r '.verdict // "error"' 2>/dev/null)
    case "$v" in
      ready | merged | closed)
        re_log "$RULE" "released-$v" "$url"
        rm -f "$f"
        continue
        ;;
      pending | blocked) ;;
      *)
        re_log "$RULE" fail-open-status-error "$url"
        notes="$notes
- $url: could not read its state from GitHub, so it was not checked"
        continue
        ;;
    esac
    head=$(printf '%s' "$st" | jq -r '.head // empty')
    bfile="${RE_STATE_DIR}/landing-bounded/$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_').json"
    if [ -n "$head" ] && [ -f "$bfile" ] && [ "$(jq -r '.head // empty' "$bfile" 2>/dev/null)" = "$head" ]; then
      re_log "$RULE" released-bounded-out "$url"
      continue
    fi
    cnt="$f.blocks.$head"
    n=$(cat "$cnt" 2>/dev/null || echo 0)
    if [ "$n" -ge "$max" ]; then
      re_log "$RULE" released-cap "$url"
      # Tell D once per head that the gate gave up, so an unmergeable PR never ends a session silently.
      if [ ! -e "$cnt.noticed" ]; then
        : >"$cnt.noticed"
        notes="$notes
- $url: still not mergeable after $max blocks; stopped blocking"
      fi
      continue
    fi
    # Check names come from the PR, so they never enter this hook-injected reason; /land reads them
    # from pr-land-status.sh output like any other gh data. Counts, kinds and fixes are ours.
    detail=$(printf '%s' "$st" | jq -r 'def d: if (.kind | test("checks")) or (.detail | not) then "" else " (\(.detail))" end;
      [(.blockers[]? | "\(.kind)\(d) -> \(.fix)"), (.pending[]? | "\(.kind)\(d) -> wait")] | join("; ")')
    open="$open
- $url: $detail"
    [ "$MODE" = shadow ] || echo $((n + 1)) >"$cnt"
  done
  if [ -z "$open" ]; then
    # Stop has no additionalContext channel; systemMessage is the line D sees.
    [ -n "$notes" ] && [ "$MODE" != shadow ] &&
      jq -nc --arg n "$notes" '{systemMessage:("Landing gate [pr-landing-gate]: a PR from this session may not be mergeable." + $n)}'
    return 0
  fi
  if [ "$MODE" = shadow ]; then
    re_log "$RULE" shadow-would-block "$open"
    return 0
  fi
  re_log "$RULE" block "$open"
  # Notes (cap reached, state unreadable) are marked as told, so they must ride along here too.
  [ -n "$notes" ] && open="$open
Not blocking, but tell D:$notes"
  re_block "Landing gate [pr-landing-gate]: a PR from this session is not mergeable yet, so the task is not done.$open
Invoke the /land skill on each URL and continue until it reports ready to merge, or records bounded-out with the remaining blocker. Do not tell D a PR is ready to merge before then."
}

case "$EVENT" in
  PostToolUse) on_post ;;
  Stop) on_stop ;;
esac
exit 0
