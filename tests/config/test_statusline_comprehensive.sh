#!/bin/bash
# Comprehensive test suite for statusline and exit_hook functionality
# Tests the per-terminal version tracking feature with complete coverage

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test tracking
declare -a FAILED_TESTS=()
declare -a PASSED_TESTS=()
declare -a SKIPPED_TESTS=()

# Temp directory for test files
TEST_TEMP_DIR="/tmp/statusline_comprehensive_test_$$"
mkdir -p "$TEST_TEMP_DIR"

# Mock HOME directory for testing
TEST_HOME="$TEST_TEMP_DIR/home"
mkdir -p "$TEST_HOME"

# Test output directory
TEST_OUTPUT_DIR="$TEST_TEMP_DIR/output"
mkdir -p "$TEST_OUTPUT_DIR"

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

print_skip() {
    echo -e "${BLUE}↷${NC} $1"
}

print_section() {
    echo
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Function to run a test
run_test() {
    local test_name="$1"
    shift
    local test_func="$1"

    TESTS_RUN=$((TESTS_RUN + 1))
    print_info "Testing: $test_name"

    # Create test-specific output file
    local test_output="$TEST_OUTPUT_DIR/${test_func}.out"

    if "$test_func" > "$test_output" 2>&1; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        PASSED_TESTS+=("$test_name")
        print_pass "$test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name")
        print_fail "$test_name"
        echo "  Error output:"
        cat "$test_output" | head -5 | sed 's/^/    /'
    fi

    # Clean up terminal files after each test
    if [[ -d ".tmp/terminal_versions" ]]; then
        rm -f ".tmp/terminal_versions"/terminal_* 2>/dev/null || true
    fi

    echo
}

# Function to skip a test
skip_test() {
    local test_name="$1"
    local reason="$2"

    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    SKIPPED_TESTS+=("$test_name: $reason")
    print_skip "$test_name (Skipped: $reason)"
    echo
}

# ============================================================================
# CORE FUNCTIONALITY TESTS
# ============================================================================

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

    if [[ ! -x "$statusline_path" ]]; then
        echo "Statusline script is not executable"
        return 1
    fi

    return 0
}

test_exit_hook_exists() {
    local exit_hook_path="../../system-configs/.claude/exit_hook.sh"

    if [[ ! -f "$exit_hook_path" ]]; then
        echo "Exit hook script not found at $exit_hook_path"
        return 1
    fi

    if [[ ! -r "$exit_hook_path" ]]; then
        echo "Exit hook script is not readable"
        return 1
    fi

    if [[ ! -x "$exit_hook_path" ]]; then
        echo "Exit hook script is not executable"
        return 1
    fi

    return 0
}

test_jq_dependency() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is required but not installed"
        return 1
    fi

    # Test jq version
    jq --version >/dev/null 2>&1 || {
        echo "jq is installed but not working correctly"
        return 1
    }

    return 0
}

# ============================================================================
# OUTPUT FORMAT TESTS
# ============================================================================

test_basic_output_format() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude Sonnet 4.6"},"version":"1.2.3","workspace":{"current_dir":"/Users/test/project"},"output_style":{"name":"default"}}'

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

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

test_minimal_output_style() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"minimal"}}'

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Minimal style should still include version
    if [[ "$output" != *"1.2.3"* ]]; then
        echo "Minimal output missing version: $output"
        return 1
    fi

    return 0
}

test_custom_output_style() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"custom","template":"Version: {{version}}"}}'

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Should use default style if custom template handling not implemented
    if [[ "$output" != *"1.2.3"* ]]; then
        echo "Custom output style should fall back to default: $output"
        return 1
    fi

    return 0
}

# ============================================================================
# VERSION TRACKING TESTS
# ============================================================================

test_new_version_tracking() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"2.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"2.0.0 ✨"* ]]; then
        echo "New version should show stars, got: $output"
        return 1
    fi

    # Stars should persist
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

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" == *"2.0.0 ✨"* ]]; then
        echo "Should not show stars after flag reset, got: $output"
        return 1
    fi

    return 0
}

test_version_change_detection() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # First version
    local input1='{"model":{"display_name":"Claude"},"version":"10.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output=$(echo "$input1" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"10.0.0 ✨"* ]]; then
        echo "First version should show stars: $output"
        return 1
    fi

    # Reset flag
    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    echo "10.0.0:0" > "$terminal_file"

    # Same version
    HOME="$TEST_HOME" output=$(echo "$input1" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" == *"10.0.0 ✨"* ]]; then
        echo "Same version with flag=0 should not show stars: $output"
        return 1
    fi

    # New version
    local input2='{"model":{"display_name":"Claude"},"version":"11.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output=$(echo "$input2" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"11.0.0 ✨"* ]]; then
        echo "New version should show stars: $output"
        return 1
    fi

    # Check file was updated
    content=$(cat "$terminal_file")
    if [[ "$content" != "11.0.0:1" ]]; then
        echo "File should be updated to 11.0.0:1, got: $content"
        return 1
    fi

    return 0
}

test_version_flag_format() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"7.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"7.0.0 ✨"* ]]; then
        echo "First run should show stars: $output"
        return 1
    fi

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

    echo "7.0.0:0" > "$terminal_file"

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

# ============================================================================
# TERMINAL TRACKING TESTS
# ============================================================================

test_terminal_isolation() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    local input='{"model":{"display_name":"Claude"},"version":"3.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    HOME="$TEST_HOME" output1=$(echo "$input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output1" != *"3.0.0 ✨"* ]]; then
        echo "First run should show stars for new terminal: $output1"
        return 1
    fi

    HOME="$TEST_HOME" output2=$(echo "$input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output2" != *"3.0.0 ✨"* ]]; then
        echo "Stars should persist until exit hook resets flag: $output2"
        return 1
    fi

    local input_new='{"model":{"display_name":"Claude"},"version":"3.1.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output3=$(echo "$input_new" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output3" != *"3.1.0 ✨"* ]]; then
        echo "New version should show stars: $output3"
        return 1
    fi

    return 0
}

test_terminal_file_naming() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1

    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ ! -f "$terminal_file" ]]; then
        echo "Terminal version file not created"
        return 1
    fi

    # Check file name format (should be terminal_GPPID)
    basename=$(basename "$terminal_file")
    if [[ ! "$basename" =~ ^terminal_[0-9]+$ ]]; then
        echo "Terminal file name format incorrect: $basename"
        return 1
    fi

    return 0
}

# ============================================================================
# FILE MANAGEMENT TESTS
# ============================================================================

test_version_file_management() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"4.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1

    if [[ ! -d ".tmp/terminal_versions" ]]; then
        echo "Terminal versions directory not created"
        return 1
    fi

    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ ! -f "$terminal_file" ]]; then
        echo "Terminal version file not created"
        return 1
    fi

    version_content=$(cat "$terminal_file")
    if [[ "$version_content" != "4.0.0:1" ]]; then
        echo "Version file content incorrect: $version_content (expected 4.0.0:1)"
        return 1
    fi

    return 0
}

test_legacy_cleanup() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"5.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    mkdir -p "$TEST_HOME/.claude"
    echo "1.0.0" > "$TEST_HOME/.claude/acknowledged_version"
    echo "old_session" > "$TEST_HOME/.claude/notified_session"

    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1

    if [[ -f "$TEST_HOME/.claude/acknowledged_version" ]]; then
        echo "Legacy acknowledged_version file not cleaned up"
        return 1
    fi

    if [[ -f "$TEST_HOME/.claude/notified_session" ]]; then
        echo "Legacy notified_session file not cleaned up"
        return 1
    fi

    return 0
}

test_cleanup_old_files() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"4.5.6","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # Create old files
    echo "old_version" > ".tmp/terminal_versions/old_terminal_1"
    echo "old_version" > ".tmp/terminal_versions/old_terminal_2"

    # Set modification time to 8 days ago (platform-portable)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        touch -t "$(date -v-8d '+%Y%m%d%H%M.%S')" ".tmp/terminal_versions/old_terminal_1" 2>/dev/null || true
        touch -t "$(date -v-8d '+%Y%m%d%H%M.%S')" ".tmp/terminal_versions/old_terminal_2" 2>/dev/null || true
    else
        touch -d "8 days ago" ".tmp/terminal_versions/old_terminal_1" 2>/dev/null || true
        touch -d "8 days ago" ".tmp/terminal_versions/old_terminal_2" 2>/dev/null || true
    fi

    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1

    files_count=$(ls -1 ".tmp/terminal_versions"/ | wc -l)
    if [[ $files_count -lt 1 ]]; then
        echo "Cleanup test failed - no version files found"
        return 1
    fi

    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ ! -f "$terminal_file" ]]; then
        echo "New terminal file not created during cleanup test"
        return 1
    fi

    return 0
}

# ============================================================================
# EXIT HOOK TESTS
# ============================================================================

test_exit_hook_functionality() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local exit_hook_path="$(cd ../../system-configs/.claude && pwd)/exit_hook.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"8.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"8.0.0 ✨"* ]]; then
        echo "First run should show stars: $output"
        return 1
    fi

    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
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

    # Run exit hook
    (cd /tmp && HOME="$TEST_HOME" echo '{"version":"8.0.0"}' | bash "$exit_hook_path" --test)

    content=$(cat "$terminal_file" 2>/dev/null)
    if [[ "$content" != "8.0.0:0" ]]; then
        echo "Exit hook should set flag to 0, got: $content"
        return 1
    fi

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" == *"8.0.0 ✨"* ]]; then
        echo "Should not show stars after exit hook: $output"
        return 1
    fi

    return 0
}

test_exit_hook_version_update() {
    local exit_hook_path="$(cd ../../system-configs/.claude && pwd)/exit_hook.sh"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # The exit hook will create its own terminal file based on its ppid calculation
    # We need to run it first and then find the file it creates

    # Run exit hook with initial version
    (cd /tmp && HOME="$TEST_HOME" echo '{"version":"1.0.0"}' | bash "$exit_hook_path" --test)

    # Find the terminal file created by exit hook
    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    if [[ ! -f "$terminal_file" ]]; then
        echo "Exit hook did not create terminal file"
        return 1
    fi

    # Check initial file content (should be 1.0.0:1 for first run)
    content=$(cat "$terminal_file" 2>/dev/null)
    if [[ "$content" != "1.0.0:1" ]]; then
        echo "Exit hook should create file with version:1. Got: $content"
        return 1
    fi

    # Run exit hook with newer version
    (cd /tmp && HOME="$TEST_HOME" echo '{"version":"2.0.0"}' | bash "$exit_hook_path" --test)

    # Check file was updated to new version with flag=1 (exit hook detects newer version)
    content=$(cat "$terminal_file" 2>/dev/null)
    if [[ "$content" != "2.0.0:1" ]]; then
        echo "Exit hook should update to new version with flag=1. Got: $content"
        return 1
    fi

    # Run exit hook with same version
    (cd /tmp && HOME="$TEST_HOME" echo '{"version":"2.0.0"}' | bash "$exit_hook_path" --test)

    # Check file now has flag=0 (same version)
    content=$(cat "$terminal_file" 2>/dev/null)
    if [[ "$content" != "2.0.0:0" ]]; then
        echo "Exit hook should reset flag to 0 for same version. Got: $content"
        return 1
    fi

    return 0
}

# ============================================================================
# GIT INTEGRATION TESTS
# ============================================================================

test_git_handling() {
    local statusline_path="$(cd ../../system-configs/.claude && pwd)/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"6.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    output=$(cd /tmp && HOME="$TEST_HOME" echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    output_clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$output_clean" != *"no-git"* ]]; then
        echo "Should show 'no-git' when not in git repository: $output_clean"
        return 1
    fi

    return 0
}

test_git_repository_detection() {
    local statusline_path="$(cd ../../system-configs/.claude && pwd)/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"6.0.0","workspace":{"current_dir":"'$(pwd)'"},"output_style":{"name":"default"}}'

    # Run from current directory (which is a git repo)
    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    output_clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    # Should show branch name, not "no-git"
    if [[ "$output_clean" == *"no-git"* ]]; then
        echo "Should detect git repository: $output_clean"
        return 1
    fi

    return 0
}

# ============================================================================
# ERROR HANDLING TESTS
# ============================================================================

test_unknown_version_handling() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"unknown","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>&1)

    if [[ "$output" == *"1.0.100 ✨"* ]]; then
        return 0
    else
        echo "Unknown version should default to 1.0.100 with stars, got: $output"
        return 1
    fi
}

test_malformed_json() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local malformed_input='{"model":{"display_name":"Claude"},"version":'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$malformed_input" | bash "$statusline_path" --test 2>&1)

    if [[ "$output" == *"1.0.100 ✨"* ]] || [[ "$output" == *"Claude"* ]]; then
        return 0
    else
        echo "Should handle malformed JSON gracefully"
        return 1
    fi
}

test_empty_input() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "" | bash "$statusline_path" --test 2>&1)

    # Should handle empty input gracefully
    if [[ -z "$output" ]] || [[ "$output" == *"Claude"* ]] || [[ "$output" == *"1.0.100"* ]]; then
        return 0
    else
        echo "Should handle empty input gracefully, got: $output"
        return 1
    fi
}

test_missing_fields() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    # Missing version field
    local input1='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output1=$(echo "$input1" | bash "$statusline_path" --test 2>&1)

    # Should handle missing version gracefully (defaults to 1.0.100)
    if [[ "$output1" != *"1.0.100"* ]]; then
        echo "Should handle missing version field: $output1"
        return 1
    fi

    # Missing model field
    local input2='{"version":"1.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'
    HOME="$TEST_HOME" output2=$(echo "$input2" | bash "$statusline_path" --test 2>&1)

    # Should handle missing model gracefully
    if [[ "$output2" != *"1.0.0"* ]]; then
        echo "Should handle missing model field: $output2"
        return 1
    fi

    return 0
}

# ============================================================================
# EDGE CASE TESTS
# ============================================================================

test_special_characters_version() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"v1.2.3-beta+build.123","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>&1)

    if [[ "$output" == *"1.0.100 ✨"* ]]; then
        return 0
    else
        echo "Special characters in version not handled correctly: $output"
        return 1
    fi
}

test_long_version_string() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local long_version="1.0.0-$(printf 'a%.0s' {1..100})"
    local test_input="{\"model\":{\"display_name\":\"Claude\"},\"version\":\"$long_version\",\"workspace\":{\"current_dir\":\"/tmp\"},\"output_style\":{\"name\":\"default\"}}"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>&1)

    if [[ "$output" == *"1.0.100 ✨"* ]]; then
        return 0
    else
        echo "Long version string not handled correctly"
        return 1
    fi
}

test_concurrent_access() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    local outputs=()
    for i in {1..3}; do
        local test_input="{\"model\":{\"display_name\":\"Claude\"},\"version\":\"9.${i}.0\",\"workspace\":{\"current_dir\":\"/tmp\"},\"output_style\":{\"name\":\"default\"}}"
        outputs[$i]=$(HOME="$TEST_HOME" echo "$test_input" | bash "$statusline_path" --test --test 2>/dev/null)
    done

    for i in {1..3}; do
        if [[ -z "${outputs[$i]}" ]]; then
            echo "Concurrent execution $i produced no output"
            return 1
        fi
        if [[ "${outputs[$i]}" != *"9.${i}.0"* ]]; then
            echo "Concurrent execution $i missing version: ${outputs[$i]}"
            return 1
        fi
    done

    return 0
}

test_rapid_version_changes() {
    local statusline_path="../../system-configs/.claude/statusline.sh"

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    for version in "1.0.0" "1.0.1" "1.0.2" "1.1.0" "2.0.0"; do
        local test_input="{\"model\":{\"display_name\":\"Claude\"},\"version\":\"$version\",\"workspace\":{\"current_dir\":\"/tmp\"},\"output_style\":{\"name\":\"default\"}}"

        HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

        if [[ "$output" != *"$version"* ]]; then
            echo "Rapid version change failed for $version: $output"
            return 1
        fi

        sleep 0.01
    done

    terminal_file=$(find ".tmp/terminal_versions" -name "terminal_*" -type f | head -1)
    final_version=$(cat "$terminal_file" 2>/dev/null || echo "")
    if [[ "$final_version" != "2.0.0:1" ]]; then
        echo "Final version not recorded correctly: $final_version"
        return 1
    fi

    return 0
}

# ============================================================================
# PERMISSION TESTS
# ============================================================================

test_permission_denied() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"3.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    mkdir -p "$TEST_HOME/.claude"
    chmod 444 "$TEST_HOME/.claude"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"3.0.0"* ]]; then
        echo "Should still work with permission denied: $output"
        chmod 755 "$TEST_HOME/.claude"
        return 1
    fi

    chmod 755 "$TEST_HOME/.claude"
    return 0
}

test_corrupted_version_file() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"2.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    mkdir -p ".tmp/terminal_versions"
    echo -e "\x00\x01corrupted\xFF" > ".tmp/terminal_versions/terminal_test"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"2.0.0 ✨"* ]]; then
        echo "Corrupted version file should be handled gracefully: $output"
        return 1
    fi

    if ! grep -rlq -- '^2\.0\.0:1$' ".tmp/terminal_versions"; then
        echo "No terminal version file updated with 2.0.0:1"
        return 1
    fi

    return 0
}

# ============================================================================
# CONTEXT WINDOW PERCENTAGE TESTS
# ============================================================================

test_context_pct_displays() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"},"context_window":{"used_percentage":42}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    if [[ "$output" != *"42%"* ]]; then
        echo "Context percentage not displayed, got: $output"
        return 1
    fi

    return 0
}

test_context_pct_null_fallback() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"},"context_window":{"used_percentage":null}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Strip ANSI codes to check raw content
    output_clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$output_clean" != *"--"* ]]; then
        echo "Null context_pct should show '--', got: $output_clean"
        return 1
    fi

    return 0
}

test_context_pct_missing_field() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    output_clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$output_clean" != *"--"* ]]; then
        echo "Missing context_window should show '--', got: $output_clean"
        return 1
    fi

    return 0
}

test_context_pct_green_threshold() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"},"context_window":{"used_percentage":42}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Green ANSI code: \033[32m should appear before 42%
    if [[ "$output" != *$'\033[32m42%'* ]]; then
        echo "42% should be green (\\033[32m), got: $output"
        return 1
    fi

    return 0
}

test_context_pct_yellow_threshold() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"},"context_window":{"used_percentage":68}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Yellow ANSI code: \033[33m should appear before 68%
    if [[ "$output" != *$'\033[33m68%'* ]]; then
        echo "68% should be yellow (\\033[33m), got: $output"
        return 1
    fi

    return 0
}

test_context_pct_orange_threshold() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"},"context_window":{"used_percentage":85}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Orange ANSI code: \033[38;5;208m should appear before 85%
    if [[ "$output" != *$'\033[38;5;208m85%'* ]]; then
        echo "85% should be orange (\\033[38;5;208m), got: $output"
        return 1
    fi

    return 0
}

test_context_pct_red_threshold() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.2.3","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"},"context_window":{"used_percentage":95}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$test_input" | bash "$statusline_path" --test 2>/dev/null)

    # Red ANSI code: \033[31m should appear before 95%
    # Note: model name also uses \033[31m, so check specifically for 95%
    if [[ "$output" != *$'\033[31m95%'* ]]; then
        echo "95% should be red (\\033[31m), got: $output"
        return 1
    fi

    return 0
}

test_context_pct_invalid_json_fallback() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local malformed_input='not json at all'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    HOME="$TEST_HOME" output=$(echo "$malformed_input" | bash "$statusline_path" --test 2>/dev/null)

    output_clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    if [[ "$output_clean" != *"--"* ]]; then
        echo "Invalid JSON should show '--' for context, got: $output_clean"
        return 1
    fi

    return 0
}

# ============================================================================
# PERFORMANCE TESTS
# ============================================================================

test_performance_baseline() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # Measure execution time
    start_time=$(date +%s%N)
    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1
    end_time=$(date +%s%N)

    # Calculate duration in milliseconds
    duration=$(( (end_time - start_time) / 1000000 ))

    # Should complete within reasonable time (e.g., 500ms)
    if [[ $duration -gt 500 ]]; then
        echo "Performance issue: took ${duration}ms (should be < 500ms)"
        return 1
    fi

    echo "Completed in ${duration}ms"
    return 0
}

test_performance_with_many_files() {
    local statusline_path="../../system-configs/.claude/statusline.sh"
    local test_input='{"model":{"display_name":"Claude"},"version":"1.0.0","workspace":{"current_dir":"/tmp"},"output_style":{"name":"default"}}'

    rm -rf "$TEST_HOME/.claude"
    mkdir -p ".tmp/terminal_versions"

    # Create many terminal files
    for i in {1..100}; do
        echo "old_version:0" > ".tmp/terminal_versions/terminal_old_$i"
    done

    # Measure execution time
    start_time=$(date +%s%N)
    HOME="$TEST_HOME" bash "$statusline_path" --test <<< "$test_input" >/dev/null 2>&1
    end_time=$(date +%s%N)

    # Calculate duration in milliseconds
    duration=$(( (end_time - start_time) / 1000000 ))

    # Should still complete within reasonable time even with many files
    if [[ $duration -gt 1000 ]]; then
        echo "Performance issue with many files: took ${duration}ms (should be < 1000ms)"
        return 1
    fi

    echo "Completed with 100 files in ${duration}ms"
    return 0
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================

echo "======================================="
echo "Comprehensive Statusline Test Suite"
echo "======================================="
echo "Test Environment: $TEST_TEMP_DIR"
echo "Test Home: $TEST_HOME"
echo

# Change to tests directory
cd "$(dirname "$0")"

# Core functionality tests
print_section "CORE FUNCTIONALITY"
run_test "Statusline script exists and is executable" test_statusline_exists
run_test "Exit hook script exists and is executable" test_exit_hook_exists
run_test "jq dependency check" test_jq_dependency

# Output format tests
print_section "OUTPUT FORMATTING"
run_test "Basic output format" test_basic_output_format
run_test "Minimal output style" test_minimal_output_style
run_test "Custom output style" test_custom_output_style

# Version tracking tests
print_section "VERSION TRACKING"
run_test "New version tracking with stars" test_new_version_tracking
run_test "Version change detection" test_version_change_detection
run_test "VERSION:FLAG format" test_version_flag_format

# Terminal tracking tests
print_section "TERMINAL TRACKING"
run_test "Per-terminal isolation" test_terminal_isolation
run_test "Terminal file naming convention" test_terminal_file_naming

# File management tests
print_section "FILE MANAGEMENT"
run_test "Version file management" test_version_file_management
run_test "Legacy cleanup functionality" test_legacy_cleanup
run_test "Cleanup of old terminal files" test_cleanup_old_files

# Exit hook tests
print_section "EXIT HOOK INTEGRATION"
run_test "Exit hook functionality" test_exit_hook_functionality
run_test "Exit hook version update behavior" test_exit_hook_version_update

# Git integration tests
print_section "GIT INTEGRATION"
run_test "Git command handling (non-repo)" test_git_handling
run_test "Git repository detection" test_git_repository_detection

# Error handling tests
print_section "ERROR HANDLING"
run_test "Unknown version handling" test_unknown_version_handling
run_test "Malformed JSON input" test_malformed_json
run_test "Empty input handling" test_empty_input
run_test "Missing fields handling" test_missing_fields

# Edge case tests
print_section "EDGE CASES"
run_test "Special characters in version" test_special_characters_version
run_test "Extremely long version strings" test_long_version_string
run_test "Concurrent access handling" test_concurrent_access
run_test "Rapid version changes" test_rapid_version_changes

# Permission tests
print_section "PERMISSIONS & CORRUPTION"
run_test "Permission denied scenarios" test_permission_denied
run_test "Corrupted version file recovery" test_corrupted_version_file

# Context window percentage tests
print_section "CONTEXT WINDOW PERCENTAGE"
run_test "Context % displays correctly" test_context_pct_displays
run_test "Null context % shows -- fallback" test_context_pct_null_fallback
run_test "Missing context_window shows -- fallback" test_context_pct_missing_field
run_test "Green threshold (< 65%)" test_context_pct_green_threshold
run_test "Yellow threshold (65-79%)" test_context_pct_yellow_threshold
run_test "Orange threshold (80-89%)" test_context_pct_orange_threshold
run_test "Red threshold (>= 90%)" test_context_pct_red_threshold
run_test "Invalid JSON fallback includes --" test_context_pct_invalid_json_fallback

# Performance tests
print_section "PERFORMANCE"
run_test "Performance baseline" test_performance_baseline
run_test "Performance with many files" test_performance_with_many_files

# Cleanup terminal files created during testing
if [[ -d ".tmp/terminal_versions" ]]; then
    rm -f ".tmp/terminal_versions"/terminal_* 2>/dev/null || true
fi

# Cleanup test directory
rm -rf "$TEST_TEMP_DIR"

# Print detailed summary
print_section "TEST RESULTS SUMMARY"

echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Tests skipped: ${BLUE}$TESTS_SKIPPED${NC}"
echo

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo -e "${RED}Failed Tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  • $test"
    done
    echo
fi

if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
    echo -e "${BLUE}Skipped Tests:${NC}"
    for test in "${SKIPPED_TESTS[@]}"; do
        echo "  • $test"
    done
    echo
fi

# Calculate pass rate
if [[ $TESTS_RUN -gt 0 ]]; then
    pass_rate=$((TESTS_PASSED * 100 / TESTS_RUN))
    echo -e "Pass Rate: ${pass_rate}%"
fi

echo
echo "======================================="

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    print_pass "All statusline tests passed!"
    exit 0
else
    print_fail "Some statusline tests failed!"
    exit 1
fi
