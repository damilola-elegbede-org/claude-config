#!/bin/bash
# Claude Configuration Test Suite
# Runs all tests for Claude commands and configurations

set -e  # Exit on error (reverted from -Eeuo pipefail for compatibility)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test results array
declare -a FAILED_TESTS

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

# Function to run a test with timeout protection
run_test() {
    local test_name=$1
    local test_file=$2
    local timeout_duration=${3:-300}  # Default 5-minute timeout

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ -f "$test_file" ]; then
        print_info "Running $test_name..."

        # Check for CI environment and adjust timeout
        if [[ "${CI:-}" == "true" ]] && [[ "$test_name" == *"Verify"* ]]; then
            timeout_duration=180  # 3-minute timeout for verify tests in CI
        fi

        # Run test with timeout (using background job approach for compatibility)
        (
            trap 'exit 1' TERM
            bash "$test_file"
        ) &

        local test_pid=$!
        local timer=0

        # Monitor test execution
        while kill -0 "$test_pid" 2>/dev/null; do
            if [ $timer -ge $timeout_duration ]; then
                kill -TERM "$test_pid" 2>/dev/null || true
                wait "$test_pid" 2>/dev/null || true
                TESTS_FAILED=$((TESTS_FAILED + 1))
                FAILED_TESTS+=("$test_name (timeout after ${timeout_duration}s)")
                print_fail "$test_name timed out after ${timeout_duration} seconds"
                echo
                return 1
            fi
            sleep 2
            timer=$((timer + 2))
        done

        # Wait for test to complete and get exit code (disable set -e temporarily)
        set +e
        wait "$test_pid"
        local test_exit_code=$?
        set -e

        if [ $test_exit_code -eq 0 ]; then
            TESTS_PASSED=$((TESTS_PASSED + 1))
            print_pass "$test_name passed"
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            FAILED_TESTS+=("$test_name")
            print_fail "$test_name failed"
        fi
    else
        print_fail "Test file not found: $test_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$test_name (file not found)")
    fi
    echo
}

# Pre-test environment validation
validate_test_environment() {
    local validation_failed=false

    # Check if we're in CI and add specific checks
    if [[ "${CI:-}" == "true" ]]; then
        echo "=== CI Environment Validation ==="

        # Check Python
        if ! command -v python3 > /dev/null; then
            echo "❌ Python3 not found in CI environment"
            validation_failed=true
        else
            echo "✓ Python3 available: $(python3 --version)"
        fi

        # Check PyYAML
        if ! python3 -c "import yaml" 2>/dev/null; then
            echo "❌ PyYAML not available in CI environment"
            validation_failed=true
        else
            echo "✓ PyYAML available"
        fi

        # Check temp directory
        if [[ -z "${TMPDIR:-}" ]]; then
            export TMPDIR="/tmp"
        fi

        if [[ ! -d "$TMPDIR" ]] || [[ ! -w "$TMPDIR" ]]; then
            echo "❌ Temp directory not writable: $TMPDIR"
            validation_failed=true
        else
            echo "✓ Temp directory available: $TMPDIR"
        fi

        echo "=============================="
    fi

    if [[ "$validation_failed" == "true" ]]; then
        echo "❌ Environment validation failed. Cannot proceed with tests."
        exit 1
    fi
}

# Main test execution
echo "==================================="
echo "Claude Configuration Test Suite"
echo "==================================="
echo

# Run pre-test validation
validate_test_environment

# Change to tests directory
cd "$(dirname "$0")"
BASE_DIR=$(pwd)

# Source test utilities if available
if [ -f "utils.sh" ]; then
    source "utils.sh"
fi

# Run command tests
echo "Running Command Tests..."
echo "------------------------"
run_test "Plan Command" "commands/test_plan.sh"
# NOTE: implementation-plan.md merged into plan.md with --no-execute flag
# run_test "Implementation Plan Command" "commands/test_implementation_plan.sh"
run_test "Commit Command" "commands/test_commit.sh"
run_test "Push Command" "commands/test_push.sh"
run_test "Test Command" "commands/test_test.sh"
run_test "Prime Command" "commands/test_prime.sh"
run_test "Sync Command" "commands/test_sync.sh"
run_test "Verify Command" "commands/test_verify.sh"
# NOTE: command-audit.md merged into audit.md with --scope flag
# run_test "Command Audit" "commands/test_command_audit.sh"

# Run configuration tests
echo "Running Configuration Tests..."
echo "------------------------------"
run_test "CLAUDE.md Validation" "config/test_claude_md.sh"
run_test "Command Files Validation" "config/test_command_files.sh"
run_test "Command YAML Validation" "validate_command_yaml.sh"
run_test "Statusline Functionality" "config/test_statusline.sh"
run_test "Statusline Edge Cases" "config/test_statusline_edge_cases.sh"

# Run quality tests
echo "Running Quality Tests..."
echo "------------------------"
run_test "Markdown Quality Gates" "markdown/test_markdown_quality.sh"

# Run agent system tests
echo "Running Agent System Tests..."
echo "------------------------------"
run_test "Agent System Validation" "agents/test_agent_system.sh"
run_test "Hook Guards" "hooks/test_hooks.sh"
run_test "File Organization" "config/test_file_org.sh"

# Run sync functionality tests
echo "Running Sync Tests..."
echo "--------------------"
run_test "Sync Functionality" "sync/test_sync_functionality.sh"

# Run script health tests
echo "Running Script Health Tests..."
echo "------------------------------"
run_test "Script Validation" "scripts/test_script_health.sh"

# Run comprehensive system health test
echo "Running System Health Tests..."
echo "------------------------------"
run_test "System Health" "comprehensive/test_system_health.sh"

# Run MCP tests
echo "Running MCP Tests..."
echo "------------------"
# NOTE: ElevenLabs MCP removed during optimization (unused)
# run_test "ElevenLabs MCP Integration" "mcp/test_elevenlabs_integration.sh"

# Run integration tests
echo "Running Integration Tests..."
echo "----------------------------"
run_test "Command Integration" "integration/test_integration.sh"
run_test "Command Template Compliance" "integration/test_command_template_compliance.sh"

# Print summary
echo "==================================="
echo "Test Summary"
echo "==================================="
echo "Tests run: $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo
    echo "Failed tests:"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
fi

echo

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    print_pass "All tests passed!"
    exit 0
else
    print_fail "Some tests failed!"
    exit 1
fi
