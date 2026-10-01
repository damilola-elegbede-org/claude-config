#!/bin/bash
# Credit-mode tests for statusline.sh
#
# Once a plan limit is exhausted and usage credits take over, the plan meters
# (burn / all / fable / 5h) stop carrying information — burn in particular
# DECAYS toward 1.0x/green while real money is being spent. These tests pin the
# replacement instrument: cap utilisation, dollars, and a burn that is simply
# two percentages divided —
#
#   burn = (share of the calendar month still to run, UTC)
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

# Pinned clocks (UTC midnight) so month math is deterministic.
# Sep 16: 15 of 30 days left (50%). Sep 30: 1 of 30 left. Dec 16: 16 of 31 left.
NOW_SEP16=1789516800
NOW_SEP30=1790726400
NOW_DEC16=1797379200

# render <cache-json> [now_epoch] -> plain (ANSI-stripped) statusline
render() {
    local h="$TEST_TEMP_DIR/home_$RANDOM$RANDOM"
    mkdir -p "$h/.claude"
    printf '%s' "$1" > "$h/.claude/.usage_cache.json"
    LAST_HOME="$h"
    printf '%s' "$STDIN_JSON" | STATUSLINE_NOW_EPOCH="${2:-$NOW_SEP16}" HOME="$h" bash "$STATUSLINE_PATH" 2>/dev/null \
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
assert_contains "$OUT" "credits "      "cap utilisation shown as a percentage"
assert_missing  "$OUT" '$751.60'       "raw dollar figures dropped"
assert_missing  "$OUT" '/$2000'        "cap no longer printed in dollars"

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$OUT" | grep -qE 'burn [^·]*· credits'; then
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "burn is rendered before credits"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "burn is rendered before credits (got: $OUT)"
fi
assert_missing  "$OUT" "all "          "weekly-all dropped (pinned at 100%)"
assert_missing  "$OUT" "fable "        "fable dropped (moot sub-limit)"
assert_missing  "$OUT" "5h "           "5h dropped (non-binding)"

echo
print_info "Burn is live on the very first render, with no stored state"
# 15 of 30 days of the month still to run = 50%; $1248.40 of $2000 unspent
# = 62.4%. 0.50 / 0.624 = 0.80. Nothing sampled, nothing remembered.
assert_contains "$OUT" "burn 0.80" "burn computed from the payload alone"
assert_missing  "$OUT" "burn --"   "no warm-up period"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -e "$LAST_HOME/.claude/.credit_samples" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "renders without writing sample state"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "renders without writing sample state"
fi

echo
print_info "More waiting than money reads red"
# $500 of $2000 left (25%) with half the month (50%) still to run -> 2.00x.
OUT=$(render "$(cache 100 14 true 150000 200000 75 false)")
assert_contains "$OUT" "burn 2.00" "credits far too thin for the rest of the month"

echo
print_info "More money than waiting reads green"
# $1900 of $2000 left (95%) and 1 of 30 days (3.3%) to run -> 0.04x.
OUT=$(render "$(cache 100 14 true 10000 200000 5 false)" "$NOW_SEP30")
assert_contains "$OUT" "burn 0.04" "plenty of credits for a short wait"

echo
print_info "Burn is month-scoped whichever plan limit is exhausted"
# Session exhaustion engages credit mode but no longer changes the horizon.
OUT=$(render "$(cache 40 100 true 75160 200000 38 false)")
assert_contains "$OUT" "credits "   "5h exhaustion engages credit mode"
assert_contains "$OUT" "burn 0.80"  "burn uses the month, not the 5h window"
OUT=$(render "$(cache 100 100 true 75160 200000 38 false 3600 10800)")
assert_contains "$OUT" "burn 0.80"  "both exhausted: reset times don't move burn"
OUT=$(render "$(cache 100 100 true 75160 200000 38 false 10800 3600)")
assert_contains "$OUT" "burn 0.80"  "both exhausted, reversed: same month burn"

echo
print_info "Month math rolls over the year and honours month length"
# Dec 16, 31-day month: 16/31 = 51.6% over 62.4% -> 0.83x.
OUT=$(render "$(cache 100 14 true 75160 200000 38 false)" "$NOW_DEC16")
assert_contains "$OUT" "burn 0.83" "December uses 31 days and rolls to January"

echo
print_info "An unreadable plan reset no longer blanks burn"
# Burn no longer reads the plan resets at all, so a bad timestamp is harmless.
ONEBAD=$(cache 100 100 true 75160 200000 38 false 3600 10800)
ONEBAD=${ONEBAD//$(iso_in 10800)/not-a-timestamp}
OUT=$(render "$ONEBAD")
assert_contains "$OUT" "credits "  "still in credit mode"
assert_contains "$OUT" "38%"       "cap utilisation still shown"
assert_contains "$OUT" "burn 0.80" "burn unaffected by a bad plan reset"

echo
print_info "Exhausted credits are called out as a hard block"
OUT=$(render "$(cache 100 14 true 200000 200000 100 true)")
assert_contains "$OUT" "blocked" "exhaustion flagged in the burn slot"
assert_contains "$OUT" "100%"    "credits meter still shown alongside"
assert_missing  "$OUT" "burn"    "no ratio to show once the cap is gone"

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
