#!/bin/bash
# PostToolUseFailure(Bash) + PostToolUse(Bash) — CLAUDE.md "Verification": retry a failing step at
# most 3 times, then stop and report. Counts failures of the SAME normalized
# command per session; from the 3rd failure on, injects additionalContext
# telling Claude to stop and report. A nudge, not a block: it cannot stop a 4th
# attempt (registry marks it advisory). A successful run of the same command
# (PostToolUse) resets its counter, so only consecutive failures count.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
[ "$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null)" = Bash ] || exit 0
[ "$(jq -r '.is_interrupt // false' <<<"$INPUT" 2>/dev/null)" = true ] && exit 0
MODE=$(re_mode retry-counter enforce)
[ "$MODE" = off ] && exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$CMD" ] || exit 0
SID=$(jq -r '.session_id // "nosession"' <<<"$INPUT" 2>/dev/null)

NORM=$(printf '%s' "$CMD" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
KEY=$(printf '%s' "$NORM" | shasum -a 256 | cut -c1-24)
DIR="$(re_session_dir "$SID")/retries"
mkdir -p "$DIR" 2>/dev/null || exit 0

# Success: the command worked, so its failure streak is over.
if [ "$(jq -r '.hook_event_name // empty' <<<"$INPUT" 2>/dev/null)" = PostToolUse ]; then
  rm -f "$DIR/$KEY" 2>/dev/null
  exit 0
fi

COUNT=0
[ -f "$DIR/$KEY" ] && COUNT=$(cat "$DIR/$KEY" 2>/dev/null)
case "$COUNT" in '' | *[!0-9]*) COUNT=0 ;; esac
COUNT=$((COUNT + 1))
printf '%s' "$COUNT" >"$DIR/$KEY"

# Housekeeping: drop state of sessions untouched for 3 days.
find "$RE_STATE_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null

[ "$COUNT" -ge 3 ] || exit 0
re_log retry-counter inject "count=$COUNT"
SHORT=$(printf '%s' "$NORM" | cut -c1-160)
re_ctx PostToolUseFailure "Retry bound (CLAUDE.md Verification): this exact command has now failed ${COUNT} times this session: ${SHORT}. Stop retrying it. Report the failing check with diagnostics (command, exit status, error text) to D instead of trying again."
exit 0
