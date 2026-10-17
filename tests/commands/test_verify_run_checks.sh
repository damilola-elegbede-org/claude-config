#!/usr/bin/env bash
# Gate detection for /verify's run-checks.mjs. Uses --list --json only, so no
# gate actually runs and nothing touches the network.
set -euo pipefail

ORIGINAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_CHECKS="${VERIFY_RUN_CHECKS:-$ORIGINAL_DIR/system-configs/.claude/skills/verify/scripts/run-checks.mjs}"
TEST_DIR="$(mktemp -d /tmp/claude-config-verify-checks.XXXXXX)"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_equals() {
    if [ "$1" != "$2" ]; then
        printf 'assertion failed: %s\nexpected: %s\nactual: %s\n' "$3" "$1" "$2" >&2
        exit 1
    fi
}

# Print the markdownlint gate of a project dir as "cmd arg arg ...", or "none".
markdownlint_gate() {
    node "$RUN_CHECKS" --list --json --dir "$1" | node -e '
        let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
            const c = JSON.parse(s).checks.find((x) => x.id === "markdownlint");
            console.log(c ? [c.cmd, ...c.args].join(" ") : "none");
        });'
}

# A repo-defined markdown script is the gate; the repo-wide glob is not used.
mkdir -p "$TEST_DIR/script"
echo '{}' >"$TEST_DIR/script/.markdownlint.json"
echo '{"scripts":{"lint:markdown":"markdownlint *.md --ignore node_modules"}}' >"$TEST_DIR/script/package.json"
assert_equals "npm run lint:markdown" "$(markdownlint_gate "$TEST_DIR/script")" "lint:markdown script preferred"

mkdir -p "$TEST_DIR/md-script"
echo '{"scripts":{"lint:md":"markdownlint-cli2 docs/*.md"}}' >"$TEST_DIR/md-script/package.json"
touch "$TEST_DIR/md-script/pnpm-lock.yaml"
assert_equals "pnpm run lint:md" "$(markdownlint_gate "$TEST_DIR/md-script")" "lint:md script via the repo's runner"

# Config-only fallback must exclude dependencies, nested worktrees and scratch.
mkdir -p "$TEST_DIR/config"
echo '{}' >"$TEST_DIR/config/.markdownlint.json"
assert_equals 'npx -y markdownlint-cli2 **/*.md #**/node_modules #.claude/worktrees #.tmp' \
    "$(markdownlint_gate "$TEST_DIR/config")" "fallback glob ignores node_modules, worktrees, .tmp"

# No config and no script: no markdown gate.
mkdir -p "$TEST_DIR/none"
assert_equals "none" "$(markdownlint_gate "$TEST_DIR/none")" "no opt-in, no gate"

echo "verify run-checks gate detection: all assertions passed"
