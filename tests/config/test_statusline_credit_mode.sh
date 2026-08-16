#!/bin/bash
# Credit-mode tests for statusline.sh
#
# Once a plan limit is exhausted and usage credits take over, the plan meters
# (burn / all / fable / 5h) stop carrying information — burn in particular
# DECAYS toward 1.0x/green while real money is being spent. These tests pin the
# replacement instrument: cap utilisation, dollars, and a weekly-scoped burn
# measuring whether the remaining credits survive until the plan comes back.

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

# mk_cache <weekly_pct> <session_pct> <spend_enabled> <used_minor> <limit_minor> <spend_pct> <exhausted>
mk_cache() {
    cat <<EOF
{
  "extra_usage": { "spend_limit_reached": $7 },
  "spend": {
    "used":  { "amount_minor": $4, "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": $5, "currency": "USD", "exponent": 2 },
    "percent": $6, "enabled": $3
  },
  "limits": [
    { "kind": "session",       "percent": $2, "resets_at": "$(iso_in 5400)"   },
    { "kind": "weekly_all",    "percent": $1, "resets_at": "$(iso_in 131400)" },
    { "kind": "weekly_scoped", "percent": 25, "resets_at": "$(iso_in 131400)" }
  ]
}
EOF
}

# render <cache-json> [credit-samples-content] -> plain (ANSI-stripped) statusline
render() {
    local cache="$1" samples="$2"
    local h="$TEST_TEMP_DIR/home_$RANDOM$RANDOM"
    mkdir -p "$h/.claude"
    printf '%s' "$cache" > "$h/.claude/.usage_cache.json"
    [[ -n "$samples" ]] && printf '%s' "$samples" > "$h/.claude/.credit_samples"
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
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (expected to contain '$needle')"
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

NOW=$(date -u +%s)

print_info "Plan mode is unaffected (weekly 62%, credits idle)"
OUT=$(render "$(mk_cache 62 45 true 75160 200000 38 false)")
assert_contains "$OUT" "burn "  "plan mode keeps burn"
assert_contains "$OUT" "all "   "plan mode keeps weekly-all"
assert_contains "$OUT" "fable " "plan mode keeps fable"
assert_contains "$OUT" "5h "    "plan mode keeps 5h"
assert_missing  "$OUT" "credits " "plan mode shows no credit segment"

echo
print_info "Credit mode drops every dead plan meter"
OUT=$(render "$(mk_cache 100 14 true 75160 200000 38 false)")
assert_contains "$OUT" "credits "         "credit segment rendered"
assert_contains "$OUT" '$751.60/$2000'    "dollars spent against the cap"
assert_missing  "$OUT" "all "             "weekly-all dropped (pinned at 100%)"
assert_missing  "$OUT" "fable "           "fable dropped (moot sub-limit)"
assert_missing  "$OUT" "5h "              "5h dropped (non-binding)"

echo
print_info "Cold start falls back to the reset countdown"
# No sample history yet: the usage endpoint takes ~20min to register first spend.
assert_contains "$OUT" "plan back "       "countdown shown while burn is unknowable"
assert_missing  "$OUT" "burn "            "no burn invented without a rate"

echo
print_info "Burn appears once a spend rate is measurable"
# ~\$15/hr over the past hour against \$1248.40 remaining, ~36.5h to reset.
OUT=$(render "$(mk_cache 100 14 true 75160 200000 38 false)" "$((NOW-3600)) 73655
")
assert_contains "$OUT" "burn "            "burn rendered from endpoint deltas"
assert_missing  "$OUT" "plan back"        "countdown yields to burn"

echo
print_info "Heavy spend produces a burn above the stranding line"
# ~\$66/hr -> projected spend exceeds remaining credits before the reset.
OUT=$(render "$(mk_cache 100 14 true 75160 200000 38 false)" "$((NOW-3600)) 68520
")
assert_contains "$OUT" "burn 1.9"         "burn exceeds 1.0x when credits run out first"

echo
print_info "Session exhaustion also triggers credit mode"
OUT=$(render "$(mk_cache 40 100 true 75160 200000 38 false)")
assert_contains "$OUT" "credits "         "5h exhaustion engages credit mode"
assert_contains "$OUT" "plan back "       "countdown targets the session reset"

echo
print_info "Exhausted credits are called out as a hard block"
OUT=$(render "$(mk_cache 100 14 true 200000 200000 100 true)" "$((NOW-3600)) 190000
")
assert_contains "$OUT" "credits spent"    "exhaustion flagged"
assert_contains "$OUT" "plan back "       "countdown is the only remaining signal"

echo
print_info "Credits disabled keeps plan mode even at 100%"
OUT=$(render "$(mk_cache 100 14 false 0 0 0 false)")
assert_contains "$OUT" "all "             "plan meters retained"
assert_missing  "$OUT" "credits "         "no credit segment without credits enabled"

echo
print_info "Sample history is discarded when leaving credit mode"
TESTS_RUN=$((TESTS_RUN + 1))
render "$(mk_cache 62 45 true 75160 200000 38 false)" "$((NOW-3600)) 70000
" >/dev/null
if [[ -f "$LAST_HOME/.claude/.credit_samples" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "stale samples cleared on return to plan mode"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "stale samples cleared on return to plan mode"
fi

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
