#!/bin/bash
# Credit-mode tests for statusline.sh
#
# Once a plan limit is exhausted and usage credits take over, the plan meters
# (burn / all / fable / 5h) stop carrying information — burn in particular
# DECAYS toward 1.0x/green while real money is being spent. These tests pin the
# replacement instrument: cap utilisation, dollars, and a burn that is simply
# two percentages divided —
#
#   burn = (share of the binding limit's cycle still to run)
#          / (share of the spend cap still unspent)
#
# Both terms come straight from the usage payload, so burn is live on the first
# render and holds no state between runs.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Resolve paths relative to this file, not the caller's cwd (tests/test.sh runs
# it from tests/), matching the sibling statusline suites.
cd "$(dirname "$0")"

TEST_TEMP_DIR="/tmp/statusline_credit_test_$$"
mkdir -p "$TEST_TEMP_DIR"

STATUSLINE_PATH="$(cd ../../system-configs/.claude && pwd)/statusline.sh"

STDIN_JSON='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/claude-config"},"output_style":{"name":"Concise"},"version":"2.0.44","context_window":{"used_percentage":31}}'

print_pass() { echo -e "${GREEN}✓${NC} $1"; }
print_fail() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }

cleanup() { rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ISO8601 timestamp N seconds from now
iso_in() {
    date -u -r $(( $(date -u +%s) + $1 )) +"%Y-%m-%dT%H:%M:%S.000000+00:00" 2>/dev/null \
        || date -u -d "@$(( $(date -u +%s) + $1 ))" +"%Y-%m-%dT%H:%M:%S.000000+00:00"
}

# cache <weekly_pct> <session_pct> <enabled> <used_minor> <limit_minor> <pct>
#       <exhausted> [weekly_in_secs] [session_in_secs]
cache() {
    local wk_in="${8:-131400}" se_in="${9:-5400}"
    cat <<EOF
{
  "extra_usage": { "spend_limit_reached": $7 },
  "spend": {
    "used":  { "amount_minor": $4, "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": $5, "currency": "USD", "exponent": 2 },
    "percent": $6, "enabled": $3
  },
  "limits": [
    { "kind": "session",       "percent": $2, "resets_at": "$(iso_in "$se_in")" },
    { "kind": "weekly_all",    "percent": $1, "resets_at": "$(iso_in "$wk_in")" },
    { "kind": "weekly_scoped", "percent": 25, "resets_at": "$(iso_in "$wk_in")" }
  ]
}
EOF
}

# render <cache-json> -> plain (ANSI-stripped) statusline
render() {
    local h="$TEST_TEMP_DIR/home_$RANDOM$RANDOM"
    mkdir -p "$h/.claude"
    printf '%s' "$1" > "$h/.claude/.usage_cache.json"
    LAST_HOME="$h"
    printf '%s' "$STDIN_JSON" | HOME="$h" bash "$STATUSLINE_PATH" 2>/dev/null \
        | sed $'s/\033\\[[0-9;]*m//g'
}

assert_contains() {
    local out="$1" needle="$2" name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (expected '$needle' in: $out)"
    fi
}

assert_missing() {
    local out="$1" needle="$2" name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (should not contain '$needle')"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "$name"
    fi
}

echo "======================================="
echo "Statusline Credit Mode Tests"
echo "======================================="
echo

print_info "Plan mode is unaffected (weekly 62%, credits idle)"
OUT=$(render "$(cache 62 45 true 75160 200000 38 false)")
assert_contains "$OUT" "burn "  "plan mode keeps burn"
assert_contains "$OUT" "all "   "plan mode keeps weekly-all"
assert_contains "$OUT" "fable " "plan mode keeps fable"
assert_contains "$OUT" "5h "    "plan mode keeps 5h"
assert_missing  "$OUT" "credits " "plan mode shows no credit segment"

echo
print_info "Credit mode drops every dead plan meter"
OUT=$(render "$(cache 100 14 true 75160 200000 38 false)")
assert_contains "$OUT" "credits "      "credit segment rendered"
assert_contains "$OUT" '$751.60/$2000' "dollars spent against the cap"
assert_missing  "$OUT" "all "          "weekly-all dropped (pinned at 100%)"
assert_missing  "$OUT" "fable "        "fable dropped (moot sub-limit)"
assert_missing  "$OUT" "5h "           "5h dropped (non-binding)"

echo
print_info "Burn is live on the very first render, with no stored state"
# 36.5h of a 7d weekly cycle still to run = 21.7%; $1248.40 of $2000 unspent
# = 62.4%. 0.217 / 0.624 = 0.35. Nothing sampled, nothing remembered.
assert_contains "$OUT" "burn 0.35" "burn computed from the payload alone"
assert_missing  "$OUT" "burn --"   "no warm-up period"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -e "$LAST_HOME/.claude/.credit_samples" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "renders without writing sample state"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "renders without writing sample state"
fi

echo
print_info "More waiting than money reads red"
# Only $100 of $2000 left (5%) with 36.5h (21.7%) still to wait -> 4.35x.
OUT=$(render "$(cache 100 14 true 190000 200000 95 false)")
assert_contains "$OUT" "burn 4.35" "credits far too thin for the remaining wait"

echo
print_info "More money than waiting reads green"
# $1900 of $2000 left (95%) and only 1h of the week (0.6%) to wait -> 0.01x.
OUT=$(render "$(cache 100 14 true 10000 200000 5 false 3600)")
assert_contains "$OUT" "burn 0.01" "plenty of credits for a short wait"

echo
print_info "Session exhaustion scopes burn to the 5h cycle, not the week"
# 1.5h of a 5h session cycle = 30%; 62.4% of the cap unspent -> 0.48x.
OUT=$(render "$(cache 40 100 true 75160 200000 38 false)")
assert_contains "$OUT" "credits "   "5h exhaustion engages credit mode"
assert_contains "$OUT" "burn 0.48"  "burn uses the 5h window as the denominator"

echo
print_info "Both limits exhausted: binding reset is the later of the two"
# Weekly resets in 1h, session in 3h. Billing continues until both refresh, so
# the session reset governs: 3h of a 5h cycle = 60%, over 62.4% -> 0.96x.
OUT=$(render "$(cache 100 100 true 75160 200000 38 false 3600 10800)")
assert_contains "$OUT" "burn 0.96" "later (session) reset governs"

echo
print_info "Both limits exhausted, reversed: later reset chosen by time, not kind"
# Mirror: session in 1h, weekly in 3h -> weekly governs, and 3h of a 7d cycle is
# a very different figure. Guards against the choice being positional.
OUT=$(render "$(cache 100 100 true 75160 200000 38 false 10800 3600)")
assert_contains "$OUT" "burn 0.03" "later (weekly) reset governs"
assert_missing  "$OUT" "burn 0.96" "session cycle not used when weekly resets later"

echo
print_info "Both exhausted with one unreadable reset: no burn rather than a guess"
# Weekly parses, session doesn't. Which reset is later is now unknowable, and
# defaulting to weekly would understate burn whenever the session reset trails
# it. The credits bar and dollars still render, so spend is never hidden.
ONEBAD=$(cache 100 100 true 75160 200000 38 false 3600 10800)
ONEBAD=${ONEBAD//$(iso_in 10800)/not-a-timestamp}
OUT=$(render "$ONEBAD")
assert_contains "$OUT" "credits "      "still in credit mode"
assert_contains "$OUT" '$751.60/$2000' "spend still shown"
assert_contains "$OUT" "burn --"       "no burn guessed from a half-known horizon"

echo
print_info "Exhausted credits are called out as a hard block"
OUT=$(render "$(cache 100 14 true 200000 200000 100 true)")
assert_contains "$OUT" "credits spent" "exhaustion flagged"
assert_missing  "$OUT" "burn"          "no ratio to show once the cap is gone"

echo
print_info "Unparsable reset falls back to a blank burn"
BAD=$(cache 100 14 true 75160 200000 38 false)
BAD=${BAD//$(iso_in 131400)/not-a-timestamp}
OUT=$(render "$BAD")
assert_contains "$OUT" "burn --" "no number invented from an unreadable reset"

echo
print_info "Credits disabled keeps plan mode even at 100%"
OUT=$(render "$(cache 100 14 false 0 0 0 false)")
assert_contains "$OUT" "all "     "plan meters retained"
assert_missing  "$OUT" "credits " "no credit segment without credits enabled"

echo
echo "======================================="
echo "Credit Mode Test Summary"
echo "======================================="
echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} All statusline credit mode tests passed!"
    exit 0
else
    echo -e "${RED}✗${NC} Some statusline credit mode tests failed!"
    exit 1
fi
