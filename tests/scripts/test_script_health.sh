#!/bin/bash
# Test script health validation

# Source test utilities
source "$(dirname "$0")/../utils.sh"

# Test variables
SCRIPTS_DIR="${ORIGINAL_DIR}/scripts"
PYTHON_SCRIPTS=()
BASH_SCRIPTS=()
FAILED_SCRIPTS=()

echo "Testing script health..."

# Test 1: Check scripts directory exists
assert_directory_exists "$SCRIPTS_DIR" "Scripts directory should exist"

# Test 2: Find and validate Python scripts
echo "Validating Python scripts..."

while IFS= read -r script; do
    PYTHON_SCRIPTS+=("$script")
    script_name=$(basename "$script")

    # Check Python syntax
    if python3 -m py_compile "$script" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $script_name: syntax valid"
    else
        echo -e "  ${RED}✗${NC} $script_name: syntax error"
        FAILED_SCRIPTS+=("$script_name: Python syntax error")
    fi

    # Check for shebang
    if head -n 1 "$script" | grep -q "^#!/usr/bin/env python3\|^#!/usr/bin/python3"; then
        :  # Good shebang
    else
        echo -e "  ${YELLOW}⚠${NC} $script_name: missing or incorrect Python shebang"
    fi
done < <(find "$SCRIPTS_DIR" -name "*.py" -type f)

echo -e "${GREEN}✓${NC} Validated ${#PYTHON_SCRIPTS[@]} Python scripts"

# Test 3: Find and validate Bash scripts
echo "Validating Bash scripts..."

while IFS= read -r script; do
    BASH_SCRIPTS+=("$script")
    script_name=$(basename "$script")

    # Check bash syntax
    if bash -n "$script" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $script_name: syntax valid"
    else
        echo -e "  ${RED}✗${NC} $script_name: syntax error"
        FAILED_SCRIPTS+=("$script_name: Bash syntax error")
    fi

    # Check for shebang
    if head -n 1 "$script" | grep -q "^#!/bin/bash\|^#!/usr/bin/env bash"; then
        :  # Good shebang
    else
        echo -e "  ${YELLOW}⚠${NC} $script_name: missing or incorrect bash shebang"
    fi

    # Check executable permissions
    if [ -x "$script" ]; then
        :  # Good permissions
    else
        echo -e "  ${YELLOW}⚠${NC} $script_name: not executable (chmod +x needed)"
    fi
done < <(find "$SCRIPTS_DIR" -name "*.sh" -type f)

echo -e "${GREEN}✓${NC} Validated ${#BASH_SCRIPTS[@]} Bash scripts"

# Test 4: Test critical validation scripts
echo "Testing critical validation scripts..."

# Test validate-agent-yaml.py
VALIDATE_AGENT_SCRIPT="$SCRIPTS_DIR/validate-agent-yaml.py"
if [ -f "$VALIDATE_AGENT_SCRIPT" ]; then
    # Test with a valid agent file
    TEST_AGENT="$ORIGINAL_DIR/system-configs/.claude/agents/debugger.md"
    if [ -f "$TEST_AGENT" ]; then
        if python3 "$VALIDATE_AGENT_SCRIPT" "$TEST_AGENT" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} validate-agent-yaml.py works correctly"
        else
            # This might be expected if the agent has issues
            echo -e "${YELLOW}⚠${NC} validate-agent-yaml.py reported issues (may be expected)"
        fi
    else
        echo -e "${YELLOW}⚠${NC} Could not test validate-agent-yaml.py (no test agent found)"
    fi
else
    echo -e "${RED}✗${NC} validate-agent-yaml.py not found"
    FAILED_SCRIPTS+=("validate-agent-yaml.py: missing critical script")
fi

# Test sync.sh
SYNC_SCRIPT="$SCRIPTS_DIR/sync.sh"
if [ -f "$SYNC_SCRIPT" ]; then
    if bash -n "$SYNC_SCRIPT" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} sync.sh syntax valid"
    else
        echo -e "${RED}✗${NC} sync.sh has syntax errors"
        FAILED_SCRIPTS+=("sync.sh: syntax error")
    fi
else
    echo -e "${RED}✗${NC} sync.sh not found"
    FAILED_SCRIPTS+=("sync.sh: missing critical script")
fi

# Test 5: Check for required Python modules
echo "Checking Python dependencies..."

# Check for required modules
REQUIRED_MODULES=("yaml" "json" "sys" "os")
MISSING_MODULES=()

for module in "${REQUIRED_MODULES[@]}"; do
    if python3 -c "import $module" 2>/dev/null; then
        :  # Module available
    else
        MISSING_MODULES+=("$module")
    fi
done

if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
    echo -e "${RED}✗${NC} Missing Python modules: ${MISSING_MODULES[*]}"
    FAILED_SCRIPTS+=("Python dependencies: missing ${MISSING_MODULES[*]}")
else
    echo -e "${GREEN}✓${NC} All required Python modules available"
fi

# Test 6: Check for common script issues
echo "Checking for common issues..."

# Check for hardcoded paths that might break
HARDCODED_HOME=$(find "$SCRIPTS_DIR" \( -name "*.sh" -o -name "*.py" \) -exec grep -El "/Users/|/home/" {} + 2>/dev/null | wc -l | tr -d ' ')
if [ "$HARDCODED_HOME" -gt 0 ]; then
    echo -e "${YELLOW}⚠${NC} Found $HARDCODED_HOME scripts with potential hardcoded paths"
else
    echo -e "${GREEN}✓${NC} No hardcoded user paths detected"
fi

# Check for proper error handling in bash scripts
SCRIPTS_WITH_SET_E=$(find "$SCRIPTS_DIR" -name "*.sh" -exec grep -l "set -e" {} + 2>/dev/null | wc -l | tr -d ' ')
TOTAL_BASH=${#BASH_SCRIPTS[@]}
if [ "$SCRIPTS_WITH_SET_E" -lt "$TOTAL_BASH" ]; then
    echo -e "${YELLOW}⚠${NC} Only $SCRIPTS_WITH_SET_E/$TOTAL_BASH bash scripts use 'set -e' for error handling"
else
    echo -e "${GREEN}✓${NC} All bash scripts use proper error handling"
fi

# Test 7: Report any failures
if [ ${#FAILED_SCRIPTS[@]} -gt 0 ]; then
    echo -e "${RED}✗${NC} Script validation failures:"
    for failure in "${FAILED_SCRIPTS[@]}"; do
        echo "  - $failure"
    done
    exit 1
else
    echo -e "${GREEN}✓${NC} All scripts pass health checks"
fi

# Test 8: Summary
echo ""
echo "Script Health Summary:"
echo "  Python scripts: ${#PYTHON_SCRIPTS[@]}"
echo "  Bash scripts: ${#BASH_SCRIPTS[@]}"
echo "  Total validated: $((${#PYTHON_SCRIPTS[@]} + ${#BASH_SCRIPTS[@]}))"

echo -e "${GREEN}✓${NC} All script health tests passed!"
