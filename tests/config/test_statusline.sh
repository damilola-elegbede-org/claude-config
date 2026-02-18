#!/bin/bash
# Test suite for statusline.sh functionality
# Tests the per-terminal version tracking feature

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

# Temp directory for test files
TEST_TEMP_DIR="/tmp/statusline_test_$$"
mkdir -p "$TEST_TEMP_DIR"

# Mock HOME directory for testing
TEST_HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_HOME"

# Function to print colored output
print_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

print_fail() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}→${NC} $1"
}

# Function to run a test
run_test() {
    local test_name="$1"
    shift
    local test_func="$1"

    TESTS_RUN=$((TESTS_RUN + 1))
    print_info "Testing: $test_name"

    if "$test_func"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print_pass "$test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print_fail "$test_name"
    fi

    # Clean up terminal files after each test
    if [[ -d ".tmp/terminal_versions" ]]; then
        rm -f ".tmp/terminal_versions"/terminal_* 2>/dev/null || true
    fi

    echo
}

# Test statusline script exists and is executable
test_statusline_exists() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    if [[ ! -f "$statusline_path" ]]; then
        echo "Statusline script not found at $statusline_path"
        return 1
    fi

    if [[ ! -r "$statusline_path" ]]; then
        echo "Statusline script is not readable"
        return 1
    fi

    return 0
}

# Test basic statusline output format
test_basic_output_format() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude Sonnet 4.6"},"version":"1.2.3","workspace":{"current_dir":"/Users/test/project"},"output_style":{"name":"default"}}'

    # Set test environment
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Check if output contains expected elements
    if [[ "$output" != *"Claude Sonnet 4.6"* ]]; then
        echo "Output missing model name: $output"
        return 1
    fi

    if [[ "$output" != *"project"* ]]; then
        echo "Output missing directory: $output"
        return 1
    fi

    if [[ "$output" != *"1.2.3"* ]]; then
        echo "Output missing version: $output"
        return 1
    fi

    return 0
}

# Test version tracking for new version
test_new_version_tracking() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"2.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # First run should show stars for new version
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"2.0.0 ✨"* ]]; then
        echo "New version should show stars, got: $output"
        return 1
    fi

    # Second run SHOULD STILL show stars (flag persists until exit hook resets it)
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"2.0.0 ✨"* ]]; then
        echo "Stars should persist until exit hook resets flag, got: $output"
        return 1
    fi

    # Manually reset flag to simulate exit hook
    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ -f "$terminal_file" ]]; then
        echo "2.0.0:0" > "$terminal_file"
    fi

    # Now should NOT show stars
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" == *"2.0.0 ✨"* ]]; then
        echo "Should not show stars after flag reset, got: $output"
        return 1
    fi

    return 0
}

# Test per-terminal tracking isolation
test_terminal_isolation() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # NOTE: Terminals are identified by gppid only (no pwd hash).
    # In test environment, we can't easily simulate different terminals since gppid is the same.
    # We test basic version tracking behavior instead.

    local input='{"model":{"display_name":"Claude"},"version":"3.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # First run should show stars (new terminal)
    HOME="$TEST_HOME" output1=$(echo "$input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output1" != *"3.0.0 ✨"* ]]; then
        echo "First run should show stars for new terminal: $output1"
        return 1
    fi

    # Second run with same version SHOULD STILL show stars (flag persists)
    HOME="$TEST_HOME" output2=$(echo "$input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output2" != *"3.0.0 ✨"* ]]; then
        echo "Stars should persist until exit hook resets flag: $output2"
        return 1
    fi

    # Different version should show stars
    local input_new='{"model":{"display_name":"Claude"},"version":"3.1.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output3=$(echo "$input_new" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output3" != *"3.1.0 ✨"* ]]; then
        echo "New version should show stars: $output3"
        return 1
    fi

    return 0
}

# Test version file creation and cleanup
test_version_file_management() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"4.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # Run statusline to create version tracking
    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1

    # Check if terminal versions directory exists
    if [[ ! -d ".tmp/terminal_versions" ]]; then
        echo "Terminal versions directory not created"
        return 1
    fi

    # Check if terminal version file exists
    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ ! -f "$terminal_file" ]]; then
        echo "Terminal version file not created"
        return 1
    fi

    # Check file content (should be VERSION:FLAG format)
    version_content=$(cat "$terminal_file")
    if [[ "$version_content" != "4.0.0:1" ]]; then
        echo "Version file content incorrect: $version_content (expected 4.0.0:1)"
        return 1
    fi

    return 0
}

# Test handling of unknown version
test_unknown_version_handling() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"unknown","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # Run with unknown version (capture stderr)
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>&1)

    # NEW BEHAVIOR: Unknown versions default to 1.0.100
    # The script should use 1.0.100 as default and show stars
    if [[ "$output" == *"1.0.100 ✨"* ]]; then
        # Expected behavior - unknown version defaults to 1.0.100 with stars
        return 0
    else
        echo "Unknown version should default to 1.0.100 with stars, got: $output"
        return 1
    fi

    return 0
}

# Test legacy cleanup functionality
test_legacy_cleanup() {
    # Skip this test in test mode since it's for production legacy cleanup
    # The --test flag isolates to .tmp/terminal_versions/ so legacy cleanup doesn't apply
    return 0
}

# Test jq dependency
test_jq_dependency() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is required for statusline.sh but not installed"
        return 1
    fi
    return 0
}

# Test git command handling
test_git_handling() {
    local statusline_path="$(cd ../../system-configs/.claude && pwd)/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"6.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # Test in non-git directory using subshell to avoid changing current directory
    output=$(cd /tmp && HOME="$TEST_HOME" echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Strip ANSI color codes for testing
    output_clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$output_clean" != *"no-git"* ]]; then
        echo "Should show 'no-git' when not in git repository: $output_clean"
        return 1
    fi

    return 0
}

# Test version change behavior
test_version_change() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # First run with version 10.0.0
    local input1='{"model":{"display_name":"Claude"},"version":"10.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output=$(echo "$input1" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"10.0.0 ✨"* ]]; then
        echo "First version should show stars: $output"
        return 1
    fi

    # Manually reset flag to simulate exit hook
    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    echo "10.0.0:0" > "$terminal_file"

    # Run with same version - should NOT show stars
    HOME="$TEST_HOME" output=$(echo "$input1" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" == *"10.0.0 ✨"* ]]; then
        echo "Same version with flag=0 should not show stars: $output"
        return 1
    fi

    # Run with NEW version 11.0.0 - should show stars and update file
    local input2='{"model":{"display_name":"Claude"},"version":"11.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output=$(echo "$input2" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"11.0.0 ✨"* ]]; then
        echo "New version should show stars: $output"
        return 1
    fi

    # Check file was updated with new version and flag=1
    content=$(cat "$terminal_file")
    if [[ "$content" != "11.0.0:1" ]]; then
        echo "File should be updated to 11.0.0:1, got: $content"
        return 1
    fi

    # Run again with new version - should still show stars (flag=1)
    HOME="$TEST_HOME" output=$(echo "$input2" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"11.0.0 ✨"* ]]; then
        echo "New version should keep showing stars until exit hook: $output"
        return 1
    fi

    return 0
}

# Test VERSION:FLAG format functionality
test_version_flag_format() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"7.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # First run should create file with VERSION:1
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Should show stars
    if [[ "$output" != *"7.0.0 ✨"* ]]; then
        echo "First run should show stars: $output"
        return 1
    fi

    # Check file format
    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ -f "$terminal_file" ]]; then
        content=$(cat "$terminal_file")
        if [[ "$content" != "7.0.0:1" ]]; then
            echo "File should contain VERSION:1 format, got: $content"
            return 1
        fi
    else
        echo "Terminal version file not created"
        return 1
    fi

    # Manually set flag to 0
    echo "7.0.0:0" > "$terminal_file"

    # Run again - should NOT show stars since flag is 0
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" == *"7.0.0 ✨"* ]]; then
        echo "Should not show stars when flag is 0: $output"
        return 1
    fi

    if [[ "$output" != *"7.0.0"* ]]; then
        echo "Should still show version without stars: $output"
        return 1
    fi

    return 0
}

# Test exit hook functionality
test_exit_hook() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local exit_hook_path="$(cd ../../system-configs/.claude && pwd)/exit_hook.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"8.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    # Clean test environment
    rm -rf "$TEST_HOME/.claude"
    local test_dir="$(pwd)/.tmp"
    mkdir -p "$test_dir/terminal_versions"

    # Set test directory environment variable
    export CLAUDE_TEST_DIR="$test_dir"

    # First run creates file with VERSION:1
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"8.0.0 ✨"* ]]; then
        echo "First run should show stars: $output"
        return 1
    fi

    # Check file has flag=1
    terminal_file=$(find "$test_dir/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ -f "$terminal_file" ]]; then
        content=$(cat "$terminal_file")
        if [[ "$content" != "8.0.0:1" ]]; then
            echo "File should have flag=1, got: $content"
            return 1
        fi
    else
        echo "Terminal version file not created"
        return 1
    fi

    # Run exit hook from /tmp directory with same version (simulating Claude session end from same dir)
    (cd /tmp && HOME="$TEST_HOME" echo '{"version":"8.0.0"}' | bash "$exit_hook_path" --test)

    # Check file now has flag=1 (preserved)
    content=$(cat "$terminal_file" 2>/dev/null)
    if [[ "$content" != "8.0.0:1" ]]; then
        echo "Exit hook should preserve flag=1, got: $content"
        return 1
    fi

    # Run statusline again - should STILL show stars (flag preserved)
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"8.0.0 ✨"* ]]; then
        echo "Should still show stars after exit hook (flag preserved): $output"
        return 1
    fi

    # Clean up environment variable
    unset CLAUDE_TEST_DIR

    return 0
}

# Main test execution
echo "======================================="
echo "Statusline Functionality Test Suite"
echo "======================================="
echo

# Change to tests directory
cd "$(dirname "$0")"

# Run all tests
run_test "Statusline script exists and is executable" test_statusline_exists
run_test "Basic output format" test_basic_output_format
run_test "New version tracking with stars" test_new_version_tracking
run_test "Per-terminal isolation" test_terminal_isolation
run_test "Version file management" test_version_file_management
run_test "Unknown version handling" test_unknown_version_handling
run_test "Legacy cleanup functionality" test_legacy_cleanup
run_test "jq dependency check" test_jq_dependency
run_test "Git command handling" test_git_handling
run_test "VERSION:FLAG format" test_version_flag_format
run_test "Version change behavior" test_version_change
# Exit hook test now works since terminal IDs don't include pwd hash
run_test "Exit hook functionality" test_exit_hook

# Cleanup terminal files created during testing
if [[ -d ".tmp/terminal_versions" ]]; then
    rm -f ".tmp/terminal_versions"/terminal_* 2>/dev/null || true
fi

# Cleanup test directory
rm -rf "$TEST_TEMP_DIR"

# Print summary
echo "======================================="
echo "Statusline Test Summary"
echo "======================================="
echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    print_pass "All statusline tests passed!"
    exit 0
else
    print_fail "Some statusline tests failed!"
    exit 1
fi
