#!/usr/bin/env bash
# Hermetic coverage for the runtime papercut log, its concurrent writer, and
# the monthly retention policy. Nothing here addresses the caller's real HOME.
set -euo pipefail

ORIGINAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC_SCRIPT="${PAPERCUT_SYNC_SCRIPT:-$ORIGINAL_DIR/scripts/sync.sh}"
HELPER="${PAPERCUT_HELPER:-$ORIGINAL_DIR/system-configs/.claude/papercut.sh}"
ARCHIVER="${PAPERCUT_ARCHIVER:-$ORIGINAL_DIR/system-configs/.claude/archive-papercuts.sh}"
TEST_DIR="$(mktemp -d /tmp/claude-config-papercuts.XXXXXX)"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

hash_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

assert_equals() {
    if [ "$1" != "$2" ]; then
        printf 'assertion failed: %s\nexpected: %s\nactual: %s\n' "$3" "$1" "$2" >&2
        exit 1
    fi
}

assert_contains() {
    if ! grep -F -q -- "$2" "$1"; then
        printf 'assertion failed: %s\nmissing: %s\n' "$3" "$2" >&2
        exit 1
    fi
}

header() {
    printf '%s\n' '# Papercuts'
    printf '%s\n' 'A factual log of small tooling failures and their fixes.'
    printf '%s\n' 'Format: date (UTC) · source · symptom · fix · project/path'
    printf '%s\n' 'Append via ~/.claude/papercut.sh; never edit or reorder entries.'
}

test_sync_preserves_runtime_data() {
    local home="$TEST_DIR/sync-home"
    local log="$home/.claude/papercuts.md"
    local archive="$home/.claude/papercuts/archive/2000-01.md"
    mkdir -p "$(dirname "$archive")"
    header >"$log"
    printf '%s\n' '2000-01-02 · test-agent · existing symptom · fixed · project/path' >>"$log"
    header >"$archive"
    printf '%s\n' '1999-12-02 · test-agent · archived symptom · fixed · project/path' >>"$archive"
    local log_before archive_before
    log_before="$(hash_file "$log")"
    archive_before="$(hash_file "$archive")"

    HOME="$home" "$SYNC_SCRIPT" --force >/dev/null
    assert_equals "$log_before" "$(hash_file "$log")" 'sync must not overwrite papercuts.md'
    assert_equals "$archive_before" "$(hash_file "$archive")" 'sync must not alter papercuts archives'

    local fresh_home="$TEST_DIR/fresh-home"
    mkdir -p "$fresh_home"
    HOME="$fresh_home" "$SYNC_SCRIPT" --force >/dev/null
    [ -f "$fresh_home/.claude/papercuts.md" ] || { echo 'sync did not initialise papercuts.md' >&2; exit 1; }
    assert_equals "$(header)" "$(cat "$fresh_home/.claude/papercuts.md")" 'new sync log must contain only the required header'
}

test_helper_concurrent_append() {
    local log="$TEST_DIR/concurrent/.claude/papercuts.md"
    local i
    local -a pids=()
    for i in $(seq 1 20); do
        PAPERCUT_LOG="$log" PAPERCUT_DATE=2026-09-22 "$HELPER" "writer-$i" "symptom-$i" fixed "project/$i" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    assert_equals 20 "$(grep -c '^2026-09-22 · writer-' "$log")" 'twenty concurrent writers must retain every entry'
    assert_equals 1 "$(grep -c '^# Papercuts$' "$log")" 'the helper creates one header before its first entry'
    for i in $(seq 1 20); do
        assert_contains "$log" "2026-09-22 · writer-$i · symptom-$i · fixed · project/$i" "missing writer $i"
    done
}

test_archive_partition_and_idempotence() {
    local home="$TEST_DIR/archive-home"
    local log="$home/.claude/papercuts.md"
    local archive_dir="$home/.claude/papercuts/archive"
    local current_month
    current_month="$(date -u +%Y-%m)"
    mkdir -p "$archive_dir"
    header >"$log"
    printf '%s\n' 'this is a non-entry line and must remain live' >>"$log"
    printf '%s\n' '2000-01-02 · old-agent · rare old symptom · fixed · project/rare' >>"$log"
    printf '%s\n' '2000-01-03 · old-agent · recurring symptom · fixed · project/repeated-old' >>"$log"
    printf '%s\n' "$current_month-01 · current-agent · recurring symptom · fixed · project/repeated-current" >>"$log"
    header >"$archive_dir/1999-12.md"
    printf '%s\n' '1999-12-02 · archive-agent · archive recurring symptom · fixed · project/archive-old' >>"$archive_dir/1999-12.md"
    printf '%s\n' '2000-01-04 · old-agent · archive recurring symptom · fixed · project/archive-live' >>"$log"

    PAPERCUT_LOG="$log" PAPERCUT_ARCHIVE_DIR="$archive_dir" "$ARCHIVER"
    local january="$archive_dir/2000-01.md"
    [ -f "$january" ] || { echo 'prior-month archive was not created' >&2; exit 1; }
    assert_contains "$january" '2000-01-02 · old-agent · rare old symptom · fixed · project/rare' 'unique old entry must move to its month archive'
    assert_contains "$log" '2000-01-03 · old-agent · recurring symptom · fixed · project/repeated-old' 'repeated live symptom must remain live'
    assert_contains "$log" "$current_month-01 · current-agent · recurring symptom · fixed · project/repeated-current" 'current-month entry must remain live'
    assert_contains "$log" '2000-01-04 · old-agent · archive recurring symptom · fixed · project/archive-live' 'symptom repeated across an archive must remain live'
    assert_contains "$log" 'this is a non-entry line and must remain live' 'non-entry line must remain live'
    assert_equals 1 "$(grep -R -F -h -- '2000-01-02 · old-agent · rare old symptom · fixed · project/rare' "$home/.claude" | wc -l | tr -d ' ')" 'moved entry must appear exactly once'
    assert_equals 1 "$(grep -R -F -h -- '2000-01-03 · old-agent · recurring symptom · fixed · project/repeated-old' "$home/.claude" | wc -l | tr -d ' ')" 'retained entry must appear exactly once'

    local log_after archive_after
    log_after="$(hash_file "$log")"
    archive_after="$(hash_file "$january")"
    PAPERCUT_LOG="$log" PAPERCUT_ARCHIVE_DIR="$archive_dir" "$ARCHIVER"
    assert_equals "$log_after" "$(hash_file "$log")" 'a second archive run must not change the live log'
    assert_equals "$archive_after" "$(hash_file "$january")" 'a second archive run must not duplicate the month archive'
    assert_equals "$(header)" "$(head -n 4 "$january")" 'archive must begin with the standard header'
}

test_archive_recovers_interrupted_run() {
    # A run killed between an archive rename and the live-log rename leaves
    # the same line in both files. The retry must count it once, drop it from
    # the live log, and not append it to the archive a second time.
    local home="$TEST_DIR/archive-interrupted"
    local log="$home/.claude/papercuts.md"
    local archive_dir="$home/.claude/papercuts/archive"
    local line='2000-02-02 · old-agent · half-moved symptom · fixed · project/interrupted'
    mkdir -p "$archive_dir"
    header >"$log"
    printf '%s\n' "$line" >>"$log"
    header >"$archive_dir/2000-02.md"
    printf '%s\n' "$line" >>"$archive_dir/2000-02.md"

    PAPERCUT_LOG="$log" PAPERCUT_ARCHIVE_DIR="$archive_dir" "$ARCHIVER"
    assert_equals 0 "$(grep -c -F -x -- "$line" "$log" | tr -d ' ')" 'interrupted entry must leave the live log on retry'
    assert_equals 1 "$(grep -c -F -x -- "$line" "$archive_dir/2000-02.md" | tr -d ' ')" 'interrupted entry must appear once in its archive'
}

test_monthly_launchagent_wiring() {
    local template="$ORIGINAL_DIR/system-configs/.claude/launchagents/com.damilola.claude-archive-papercuts.plist.template"
    [ -f "$template" ] || { echo 'papercut LaunchAgent template is missing' >&2; exit 1; }
    assert_contains "$template" '__HOME__/.claude/archive-papercuts.sh' 'LaunchAgent must invoke the deployed archiver'
    assert_contains "$template" '<key>Day</key>' 'LaunchAgent must schedule the first day of the month'
    assert_contains "$template" '<integer>17</integer>' 'LaunchAgent must schedule minute 17'
    assert_contains "$ORIGINAL_DIR/scripts/install-session-resume-agents.sh" 'com.damilola.claude-archive-papercuts' 'installer must install the papercut LaunchAgent'
}

make_lock() {
    local log="$1"
    mkdir -p "$(dirname "$log")"
    printf '%s\n%s\n' "$$" "$2" >"$(dirname "$log")/.papercuts.md.papercut.lock/owner"
}

test_stale_live_owner_recovery() {
    local home="$TEST_DIR/stale-live-owner"
    local log="$home/.claude/papercuts.md"
    local lock="$home/.claude/.papercuts.md.papercut.lock"
    mkdir -p "$lock"
    make_lock "$log" "$(( $(date -u +%s) - 120 ))"
    PAPERCUT_LOG="$log" PAPERCUT_DATE=2026-09-22 PAPERCUT_LOCK_STALE_SECONDS=60 "$HELPER" stale-owner symptom fixed project/stale
    assert_contains "$log" '2026-09-22 · stale-owner · symptom · fixed · project/stale' 'old owner timestamp with a live PID must be reclaimed'
}

test_fresh_live_owner_is_not_reclaimed() {
    local home="$TEST_DIR/fresh-live-owner"
    local log="$home/.claude/papercuts.md"
    local lock="$home/.claude/.papercuts.md.papercut.lock"
    mkdir -p "$lock"
    make_lock "$log" "$(date -u +%s)"
    if PAPERCUT_LOG="$log" PAPERCUT_DATE=2026-09-22 PAPERCUT_LOCK_STALE_SECONDS=60 PAPERCUT_LOCK_ATTEMPTS=3 "$HELPER" fresh-owner symptom fixed project/fresh >/dev/null 2>&1; then
        echo 'fresh live owner was incorrectly reclaimed' >&2
        exit 1
    fi
}

test_stale_reclaim_marker_recovery() {
    local home="$TEST_DIR/stale-reclaim-marker"
    local log="$home/.claude/papercuts.md"
    local lock="$home/.claude/.papercuts.md.papercut.lock"
    mkdir -p "$lock" "$lock.reclaiming"
    make_lock "$log" "$(( $(date -u +%s) - 120 ))"
    touch -t 200001010000 "$lock.reclaiming"
    PAPERCUT_LOG="$log" PAPERCUT_DATE=2026-09-22 PAPERCUT_LOCK_STALE_SECONDS=60 "$HELPER" stale-marker symptom fixed project/marker
    assert_contains "$log" '2026-09-22 · stale-marker · symptom · fixed · project/marker' 'a stale reclaim marker must be removed'
}

test_ownerless_lock_recovery() {
    local home="$TEST_DIR/ownerless-lock"
    local log="$home/.claude/papercuts.md"
    local lock="$home/.claude/.papercuts.md.papercut.lock"
    mkdir -p "$lock"
    touch -t 200001010000 "$lock"
    PAPERCUT_LOG="$log" PAPERCUT_DATE=2026-09-22 PAPERCUT_LOCK_STALE_SECONDS=60 "$HELPER" ownerless symptom fixed project/ownerless
    assert_contains "$log" '2026-09-22 · ownerless · symptom · fixed · project/ownerless' 'an old ownerless lock directory must be reclaimed'
}

test_age_check_mutation_fails() {
    local home="$TEST_DIR/age-check-mutation"
    local log="$home/.claude/papercuts.md"
    local lock="$home/.claude/.papercuts.md.papercut.lock"
    local mutant="$TEST_DIR/papercut-without-age-check.sh"
    mkdir -p "$lock"
    make_lock "$log" "$(( $(date -u +%s) - 120 ))"
    cp "$HELPER" "$mutant"
    /usr/bin/perl -0pi -e 's/if \[ "\$\(\(now - acquired_at\)\)" -ge "\$PAPERCUT_LOCK_STALE_SECONDS" \]; then\n    return 0\n  fi\n//' "$mutant"
    if PAPERCUT_LOG="$log" PAPERCUT_DATE=2026-09-22 PAPERCUT_LOCK_STALE_SECONDS=60 PAPERCUT_LOCK_ATTEMPTS=3 "$mutant" mutated symptom fixed project/mutated >/dev/null 2>&1; then
        echo 'removing the age check unexpectedly reclaimed a live PID lock' >&2
        exit 1
    fi
}

echo 'Testing papercut sync preservation...'
test_sync_preserves_runtime_data
echo 'Testing papercut concurrent append...'
test_helper_concurrent_append
echo 'Testing papercut monthly archive...'
test_archive_partition_and_idempotence
echo 'Testing papercut interrupted-archive recovery...'
test_archive_recovers_interrupted_run
echo 'Testing papercut monthly LaunchAgent wiring...'
test_monthly_launchagent_wiring
echo 'Testing stale live-owner lock recovery...'
test_stale_live_owner_recovery
echo 'Testing fresh live-owner lock safety...'
test_fresh_live_owner_is_not_reclaimed
echo 'Testing stale reclaim-marker recovery...'
test_stale_reclaim_marker_recovery
echo 'Testing ownerless lock recovery...'
test_ownerless_lock_recovery
echo 'Testing age-check mutation...'
test_age_check_mutation_fails
echo 'Papercut tests passed.'
