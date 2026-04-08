#!/bin/bash
# Unit tests for YAML validation in agent files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_SCRIPT="$SCRIPT_DIR/validate_yaml.sh"
TEST_DIR="$SCRIPT_DIR/test_yaml_files"
PASSED=0
FAILED=0

# Color codes
# Detect if we're in a CI environment or if output is not a terminal
if [ -n "$CI" ] || [ ! -t 1 ]; then
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
fi

echo "Running YAML Validation Unit Tests"
echo "===================================="

# Create test directory
mkdir -p "$TEST_DIR"

# Function to run test
run_test() {
    local test_name="$1"
    local file_content="$2"
    local expected_result="$3"  # "pass" or "fail"
    local test_file="$TEST_DIR/test_$test_name.md"

    echo -n "Testing $test_name... "

    # Create test file
    echo "$file_content" > "$test_file"

    # Run validation on specific file
    if bash "$VALIDATION_SCRIPT" "$test_file" > /dev/null 2>&1; then
        result="pass"
    else
        result="fail"
    fi

    # Check result
    if [ "$result" = "$expected_result" ]; then
        printf "${GREEN}PASSED${NC}\n"
        PASSED=$((PASSED + 1))
    else
        printf "${RED}FAILED (expected %s, got %s)${NC}\n" "$expected_result" "$result"
        FAILED=$((FAILED + 1))
    fi

    # Cleanup
    rm -f "$test_file"
}

# Test 1: Valid YAML front-matter
run_test "valid_yaml" "---
name: test-agent
description: A test agent for validation
color: blue
category: development
tools:
  - Read
  - Write
---

# Test Agent Content" "pass"

# Test 2: Missing opening delimiter
run_test "missing_opening" "name: test-agent
description: Missing opening delimiter
---

# Content" "fail"

# Test 3: Missing closing delimiter
run_test "missing_closing" "---
name: test-agent
description: Missing closing delimiter
color: green
tools:
  - Read

# Content without closing ---" "fail"

# Test 4: Missing name field
run_test "missing_name" "---
description: Agent without name
color: red
tools:
  - Read
---

# Content" "fail"

# Test 5: Missing description field
run_test "missing_description" "---
name: test-agent
color: green
tools:
  - Read
---

# Content" "fail"

# Test 6: Empty YAML block
run_test "empty_yaml" "---
---

# Content" "fail"

# Test 7: Multiline description (valid)
run_test "multiline_description" "---
name: test-agent
description: |
  This is a multiline
  description that should
  be valid
color: purple
category: development
tools:
  - Read
  - Write
---

# Content" "pass"

# Test 8: Very long description (should warn but pass)
run_test "long_description" "---
name: test-agent
description: $(printf 'x%.0s' {1..300})
color: orange
category: development
tools:
  - Read
---

# Content" "pass"

# Test 9: Complex valid YAML
run_test "complex_valid" "---
name: complex-agent
description: An agent with complex YAML structure
color: purple
category: development
tools:
  - Read
  - Write
  - Grep
  - Glob
---

# Complex Agent Content" "pass"

# Test 10: Execution evaluator agent
run_test "execution_evaluator" "---
name: execution-evaluator
description: MUST BE USED for verifying command execution success. Use PROACTIVELY after any command to validate outputs, check side effects, and ensure intended goals were achieved
tools: Read, Grep, Glob, LS, Bash
model: haiku
color: green
category: quality
---

# Execution Evaluator Content" "pass"

# Cleanup test directory
rm -rf "$TEST_DIR"

# Summary
echo ""
echo "===================================="
echo "Test Summary:"
printf "  Passed: ${GREEN}%d${NC}\n" "$PASSED"
printf "  Failed: ${RED}%d${NC}\n" "$FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    printf "${GREEN}SUCCESS: All tests passed!${NC}\n"
    exit 0
else
    printf "${RED}FAILED: Some tests failed${NC}\n"
    exit 1
fi
