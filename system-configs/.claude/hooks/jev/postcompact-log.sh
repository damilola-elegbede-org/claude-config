#!/bin/bash
# PostCompact — log only. Records that a compaction happened (trigger, summary
# length) so context-loss incidents can be correlated later. No transcript or
# summary text is stored. Output is ignored by the harness for this event.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
[ "$(re_mode postcompact-log enforce)" = off ] && exit 0
TRIGGER=$(jq -r '.trigger // "unknown"' <<<"$INPUT" 2>/dev/null)
LEN=$(jq -r '(.compact_summary // "") | length' <<<"$INPUT" 2>/dev/null)
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
re_log postcompact-log compacted "trigger=$TRIGGER summary_chars=${LEN:-0} session=${SID:0:8}"
exit 0
