#!/bin/bash
# StopFailure — a turn ended on an API error. Classify the error and look up the
# known fix in D's memory (e.g. ECONNRESET → the CAX80 5GHz upload defect).
#
# The harness IGNORES StopFailure output and exit code (docs: "Output and exit code
# are ignored, except terminalSequence"), so nothing can be injected from here. The
# hint is written to $RE_STATE_DIR/last-stopfailure.json and session-start-project.sh
# injects it on the next SessionStart (resume/startup) — see that script.
#
# Regex table first; Jev choice (rule stopfailure-classify, default SHADOW) only
# classifies errors the table does not recognise, and its answer is used only in
# enforce mode.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
MODE=$(re_mode stopfailure-classify shadow)
SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
# Only the error fields: session_id, cwd and transcript_path must not feed the classifier
# (a project dir named billing-service would classify as billing).
ERRTEXT=$(jq -r '[.error, .error_details, .message] | map(select(. != null) | if type == "string" then . else tojson end) | join(" ")' <<<"$INPUT" 2>/dev/null | cut -c1-1500)
[ -n "$ERRTEXT" ] || exit 0

CLASS=other
if printf '%s' "$ERRTEXT" | grep -qiE 'ECONNRESET|socket (connection )?(was )?closed|socket hang up|connection (reset|error|refused)|unable to connect|bad record mac|fetch failed|ETIMEDOUT|ConnectionRefused'; then
  CLASS=network_reset
elif printf '%s' "$ERRTEXT" | grep -qiE 'rate[_ -]?limit|\b429\b|overloaded|\b529\b'; then
  CLASS=rate_limit
elif printf '%s' "$ERRTEXT" | grep -qiE 'authentication|unauthori[sz]ed|\b401\b|invalid.{0,20}(api )?key|oauth|please run /login'; then
  CLASS=auth
elif printf '%s' "$ERRTEXT" | grep -qiE 'billing|credit balance|quota|insufficient'; then
  CLASS=billing
fi
SOURCE=regex

if [ "$CLASS" = other ] && [ "$MODE" != off ]; then
  STATE=$(jq -nc --arg e "$ERRTEXT" '{error:$e}')
  Q='{"class":{"type":"choice","instructions":"Classify this Claude Code API failure.","criteria":{"network_reset":"transport-level failure: connection reset, closed socket, no HTTP response","rate_limit":"rate limited or server overloaded","auth":"authentication or authorization failure","billing":"billing, quota or credit problem","other":"none of the above"}}}'
  if RESP=$(re_jev_req stopfailure-classify "$STATE" "$Q" 1200 | re_jev_call 2>/dev/null) && [ -n "$RESP" ]; then
    JC=$(jq -r '.answers.class.choice // empty' <<<"$RESP" 2>/dev/null)
    JP=$(jq -r --arg c "$JC" '.answers.class.probabilities[$c] // empty' <<<"$RESP" 2>/dev/null)
    re_log stopfailure-classify "jev=$JC p=$JP" "mode=$MODE"
    if [ "$MODE" = enforce ] && [ -n "$JC" ] && awk -v p="${JP:-0}" -v t="$(re_cfg stopfailure-classify threshold 0.8)" 'BEGIN{exit !(p+0>=t+0)}'; then
      CLASS="$JC"
      SOURCE=jev
    fi
  fi
fi

# desc_of <memory-file-stem> — the description: line of that memory entry.
desc_of() {
  sed -n 's/^description:[[:space:]]*//p' "$(re_memory_dir)/$1.md" 2>/dev/null | head -1 | tr -d '"' | cut -c1-300
}

HINT=""
case "$CLASS" in
  network_reset)
    D1=$(desc_of cax80-5ghz-upload-defect)
    D2=$(desc_of claude-code-api-econnreset-router-ipv6)
    HINT="Transport-level API failure (ECONNRESET class). Known causes in memory: cax80-5ghz-upload-defect — ${D1:-the home CAX80 router 5GHz radio corrupts large uploads; stay on 2.4GHz SSID Halle, not Halle-5G}. First check: Wi-Fi channel (1-11 = 2.4GHz good, 36+ = 5GHz bad). Also claude-code-api-econnreset-router-ipv6 — ${D2:-the router IPv6 firewall resetting connections}."
    ;;
  rate_limit) HINT="Rate limited or overloaded: transient. Wait and retry; do not change model or effort to work around it." ;;
  auth) HINT="Authentication failure: check the login (/login) before retrying; no memory entry covers a fix." ;;
  billing) HINT="Billing or quota failure: this is a D-only surface; report it, do not retry." ;;
esac

re_log stopfailure-hint "class=$CLASS source=$SOURCE" "hint=$([ -n "$HINT" ] && echo yes || echo no)"
[ -n "$HINT" ] || exit 0
mkdir -p "$RE_STATE_DIR" 2>/dev/null || exit 0
jq -nc --arg ts "$(date +%s)" --arg sid "$SID" --arg class "$CLASS" --arg hint "$HINT" \
  '{ts:($ts|tonumber),session_id:$sid,class:$class,hint:$hint}' >"$RE_STATE_DIR/last-stopfailure.json" 2>/dev/null
exit 0
