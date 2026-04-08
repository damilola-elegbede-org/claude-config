#!/bin/bash
# Markdown Quality Test Script
# Integrates into the main test suite for automated quality gates

set -e

# Source test utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors for output
if [ -n "${CI:-}" ] || [ ! -t 1 ]; then
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

echo -e "${YELLOW}Running Markdown Quality Tests...${NC}"

# Test 1: Basic markdownlint validation
echo -n "Testing basic markdownlint validation... "
cd "$BASE_DIR"

# Count initial violations - use exact same command as validation script
initial_violations=$(npx markdownlint-cli2 "**/*.md" --config .markdownlint-cli2.jsonc 2>&1 | grep -E "^.+:[0-9]+(:([0-9]+))?[[:space:]]+" | wc -l | tr -d ' ')

# Allow reasonable number of violations for auto-generated files
MAX_ALLOWED_VIOLATIONS=100
if [[ $initial_violations -le $MAX_ALLOWED_VIOLATIONS ]]; then
    echo -e "${GREEN}PASS${NC} ($initial_violations violations ≤ $MAX_ALLOWED_VIOLATIONS max)"
    BASIC_TEST_PASS=true
else
    echo -e "${RED}FAIL${NC} ($initial_violations violations > $MAX_ALLOWED_VIOLATIONS max)"
    BASIC_TEST_PASS=false
fi

# Test 2: Configuration validation
echo -n "Testing markdownlint configuration validity... "
if npx markdownlint-cli2 --config .markdownlint-cli2.jsonc /dev/null 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}"
    CONFIG_TEST_PASS=true
else
    echo -e "${RED}FAIL${NC} (invalid configuration)"
    CONFIG_TEST_PASS=false
fi

# Test 3: Critical file standards
echo -n "Testing critical documentation files... "
critical_files=(
    "README.md"
    "CLAUDE.md"
    "system-configs/CLAUDE.md"
    "docs/index.md"
)

CRITICAL_TEST_PASS=true
for file in "${critical_files[@]}"; do
    if [[ -f "$file" ]]; then
        file_violations=$(npx markdownlint-cli2 "$file" --config .markdownlint-cli2.jsonc 2>&1 | grep -E "^.+:[0-9]+(:([0-9]+))?[[:space:]]+" | wc -l | tr -d ' ')
        if [[ $file_violations -gt 0 ]]; then
            echo -e "${RED}FAIL${NC} ($file has $file_violations violations)"
            CRITICAL_TEST_PASS=false
            break
        fi
    fi
done

if [[ $CRITICAL_TEST_PASS == true ]]; then
    echo -e "${GREEN}PASS${NC}"
fi

# Test 4: Markdownlint CLI availability
echo -n "Testing markdownlint-cli2 availability... "
if command -v npx >/dev/null 2>&1 && npx markdownlint-cli2 --help 2>&1 | grep -q "markdownlint-cli2"; then
    echo -e "${GREEN}PASS${NC}"
    SCRIPT_TEST_PASS=true
else
    echo -e "${RED}FAIL${NC} (markdownlint-cli2 not available)"
    SCRIPT_TEST_PASS=false
fi

# Test 5: Trend analysis
echo -n "Testing violation trends... "
TREND_TEST_PASS=true

# Create baseline if it doesn't exist
baseline_file="$BASE_DIR/tests/markdown/.baseline_violations"
if [[ ! -f "$baseline_file" ]]; then
    echo "$initial_violations" > "$baseline_file"
    echo -e "${YELLOW}BASELINE${NC} (created baseline: $initial_violations violations)"
else
    baseline_violations=$(cat "$baseline_file")
    if [[ $initial_violations -le $baseline_violations ]]; then
        echo -e "${GREEN}PASS${NC} (violations: $initial_violations ≤ baseline: $baseline_violations)"
        # Update baseline if we've improved
        if [[ $initial_violations -lt $baseline_violations ]]; then
            echo "$initial_violations" > "$baseline_file"
        fi
    else
        echo -e "${RED}FAIL${NC} (violations: $initial_violations > baseline: $baseline_violations)"
        TREND_TEST_PASS=false
    fi
fi

# Overall test result
echo
echo "=== Markdown Quality Test Results ==="
echo -e "Basic Validation: $(if [[ $BASIC_TEST_PASS == true ]]; then echo "${GREEN}PASS${NC}"; else echo "${RED}FAIL${NC}"; fi)"
echo -e "Configuration: $(if [[ $CONFIG_TEST_PASS == true ]]; then echo "${GREEN}PASS${NC}"; else echo "${RED}FAIL${NC}"; fi)"
echo -e "Critical Files: $(if [[ $CRITICAL_TEST_PASS == true ]]; then echo "${GREEN}PASS${NC}"; else echo "${RED}FAIL${NC}"; fi)"
echo -e "Quality Script: $(if [[ $SCRIPT_TEST_PASS == true ]]; then echo "${GREEN}PASS${NC}"; else echo "${RED}FAIL${NC}"; fi)"
echo -e "Trend Analysis: $(if [[ $TREND_TEST_PASS == true ]]; then echo "${GREEN}PASS${NC}"; else echo "${RED}FAIL${NC}"; fi)"

# Set exit code based on results
if [[ $BASIC_TEST_PASS == true && $CONFIG_TEST_PASS == true && $CRITICAL_TEST_PASS == true && $SCRIPT_TEST_PASS == true && $TREND_TEST_PASS == true ]]; then
    echo -e "\n${GREEN}All markdown quality tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some markdown quality tests failed!${NC}"
    echo
    echo "To fix violations:"
    echo "1. Run: npx markdownlint-cli2 '**/*.md' --config .markdownlint-cli2.jsonc"
    echo "2. Fix reported issues manually or with markdownlint-cli2 --fix"
    exit 1
fi
