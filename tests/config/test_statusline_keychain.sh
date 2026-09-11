#!/bin/bash
# Keychain lookup tests for statusline.sh
#
# Claude Code stores connector (MCP) OAuth tokens under the same Keychain
# service label it uses for the user's own login: "Claude Code-credentials".
# A lookup by label alone returns whichever item macOS finds first, so on a
# machine that has authorised a connector the plan-usage refresh can pick up a
# connector blob with no `claudeAiOauth` in it — the fetch never runs and every
# plan meter silently disappears. These tests pin the lookup to the login
# account so a connector entry under the same label can't shadow it.
#
# `security` and `curl` are stubbed on PATH. The curl stub only answers when it
# is handed the LOGIN token, which proves the right item was selected rather
# than merely that some token was found.

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

TEST_TEMP_DIR="/tmp/statusline_keychain_test_$$"
mkdir -p "$TEST_TEMP_DIR"

STATUSLINE_PATH="$(cd ../../system-configs/.claude && pwd)/statusline.sh"

STDIN_JSON='{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"/tmp/claude-config"},"output_style":{"name":"Concise"},"version":"2.0.44","context_window":{"used_percentage":31}}'

LOGIN_ACCT="statusline-test-user"

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

STUB_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$STUB_DIR"

# id stub. statusline.sh now shells out to `id -un` unconditionally for the
# account-scoped lookup, so the effective account is modelled here rather than
# via $USER.
cat > "$STUB_DIR/id" <<'EOF'
#!/bin/bash
printf '%s\n' "$LOGIN_ACCT"
EOF

# security stub. KEYCHAIN_LAYOUT selects the machine being modelled:
#   shadowed — a connector item and the login item share the label, and a
#              label-only lookup returns the connector item first
#   single   — only the login item exists, filed under an account name that
#              doesn't match the effective account from `id -un`
cat > "$STUB_DIR/security" <<'EOF'
#!/bin/bash
acct=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) acct="$2"; shift 2 ;;
        *) shift ;;
    esac
done
login='{"claudeAiOauth":{"accessToken":"LOGIN-TOKEN"}}'
connector='{"mcpOAuth":{"connector|0123456789abcdef":{"accessToken":"CONNECTOR-TOKEN"}}}'
case "$KEYCHAIN_LAYOUT" in
    shadowed)
        if [[ -z "$acct" ]]; then printf '%s\n' "$connector"; exit 0; fi
        if [[ "$acct" == "$LOGIN_ACCT" ]]; then printf '%s\n' "$login"; exit 0; fi
        ;;
    single)
        if [[ -z "$acct" ]]; then printf '%s\n' "$login"; exit 0; fi
        ;;
esac
echo "security: The specified item could not be found in the keychain." >&2
exit 44
EOF

# curl stub: writes a plan-mode usage payload to -o only for the LOGIN token.
cat > "$STUB_DIR/curl" <<'EOF'
#!/bin/bash
out=""; auth=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "$auth" == "Authorization: Bearer LOGIN-TOKEN" ]] || exit 22
printf '%s' "$USAGE_JSON" > "$out"
EOF
chmod +x "$STUB_DIR/id" "$STUB_DIR/security" "$STUB_DIR/curl"

USAGE_JSON=$(cat <<EOF
{
  "extra_usage": { "spend_limit_reached": false },
  "spend": { "enabled": false },
  "limits": [
    { "kind": "session",       "percent": 45, "resets_at": "$(iso_in 5400)" },
    { "kind": "weekly_all",    "percent": 62, "resets_at": "$(iso_in 131400)" },
    { "kind": "weekly_scoped", "percent": 25, "resets_at": "$(iso_in 131400)" }
  ]
}
EOF
)

# new_home -> sets HOME_DIR to a fresh home with no usage cache, so the refresh
# path always runs. Called in the parent shell: render runs inside $(...), where
# any variable it set would be lost.
new_home() {
    HOME_DIR="$TEST_TEMP_DIR/home_$RANDOM$RANDOM"
    mkdir -p "$HOME_DIR/.claude"
}

# render <keychain-layout> -> plain (ANSI-stripped) statusline for HOME_DIR
render() {
    local acct="$LOGIN_ACCT"
    printf '%s' "$STDIN_JSON" \
        | HOME="$HOME_DIR" USER="$acct" LOGIN_ACCT="$acct" KEYCHAIN_LAYOUT="$1" \
          USAGE_JSON="$USAGE_JSON" PATH="$STUB_DIR:$PATH" bash "$STATUSLINE_PATH" 2>/dev/null \
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

assert_cache_has_limits() {
    local name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    if jq -e '.limits' "$HOME_DIR/.claude/.usage_cache.json" >/dev/null 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); print_pass "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); print_fail "$name (cache has no .limits)"
    fi
}

echo "======================================="
echo "Statusline Keychain Lookup Tests"
echo "======================================="
echo

print_info "A connector item under the same label doesn't shadow the login"
new_home
OUT=$(render shadowed)
assert_contains "$OUT" "all " "weekly-all meter rendered"
assert_contains "$OUT" "5h "  "5h meter rendered"
assert_cache_has_limits       "usage cache refreshed with the login token"

echo
print_info "Login filed under another account name still resolves"
new_home
OUT=$(render single)
assert_contains "$OUT" "all " "label-only fallback still finds the login"
assert_cache_has_limits       "usage cache refreshed via the fallback"

echo
echo "======================================="
echo "Keychain Lookup Test Summary"
echo "======================================="
echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} All statusline keychain lookup tests passed!"
    exit 0
else
    echo -e "${RED}✗${NC} Some statusline keychain lookup tests failed!"
    exit 1
fi
