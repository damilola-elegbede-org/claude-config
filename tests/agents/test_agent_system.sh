#!/bin/bash
# Test agent system validation

# Source test utilities
source "$(dirname "$0")/../utils.sh"

# Test variables
AGENTS_DIR="${ORIGINAL_DIR}/system-configs/.claude/agents"
AGENT_COUNT=0
FAILED_AGENTS=()
SYSTEM_BOUNDARY_MISSING=()
YAML_INVALID=()

echo "Testing agent system validation..."

# Test 1: Check agent directory exists
assert_directory_exists "$AGENTS_DIR" "Agents directory should exist"

# Test 2: Count and validate all agent files
echo "Validating all agent configurations..."
for agent_file in "$AGENTS_DIR"/*.md; do
    [ -f "$agent_file" ] || continue

    # Skip template and README files
    basename=$(basename "$agent_file")
    if [[ "$basename" == "AGENT_TEMPLATE.md" ]] || [[ "$basename" == "README.md" ]]; then
        continue
    fi

    AGENT_COUNT=$((AGENT_COUNT + 1))
    agent_name=$(basename "$agent_file" .md)

    # Check for YAML frontmatter
    if ! grep -q "^---" "$agent_file"; then
        YAML_INVALID+=("$agent_name")
        continue
    fi

    # Extract YAML content
    yaml_content=$(sed -n '/^---$/,/^---$/p' "$agent_file" | sed '1d;$d')

    # Check for required fields
    if ! echo "$yaml_content" | grep -q "^name:"; then
        FAILED_AGENTS+=("$agent_name: missing 'name' field")
    fi

    if ! echo "$yaml_content" | grep -q "^category:"; then
        FAILED_AGENTS+=("$agent_name: missing 'category' field")
    fi

    if ! echo "$yaml_content" | grep -q "^tools:"; then
        FAILED_AGENTS+=("$agent_name: missing 'tools' field")
    fi

    # Check for SYSTEM BOUNDARY protection (critical security feature)
    if ! grep -q "SYSTEM BOUNDARY" "$agent_file"; then
        SYSTEM_BOUNDARY_MISSING+=("$agent_name")
    fi

    # Check that agents don't have Task tool (they can't invoke other agents)
    if echo "$yaml_content" | grep -q -- "- Task"; then
        FAILED_AGENTS+=("$agent_name: has unauthorized 'Task' tool access")
    fi
done

# Test 3: Verify agent count is reasonable (8 core agents after cleanup)
if [ $AGENT_COUNT -lt 6 ]; then
    echo -e "${RED}✗${NC} Too few agents found: $AGENT_COUNT (expected at least 6)"
    exit 1
elif [ $AGENT_COUNT -gt 30 ]; then
    echo -e "${RED}✗${NC} Too many agents found: $AGENT_COUNT (expected less than 30)"
    exit 1
else
    echo -e "${GREEN}✓${NC} Agent count validation passed: $AGENT_COUNT agents"
fi

# Test 4: Report YAML validation issues
if [ ${#YAML_INVALID[@]} -gt 0 ]; then
    echo -e "${RED}✗${NC} Agents with invalid YAML structure:"
    for agent in "${YAML_INVALID[@]}"; do
        echo "  - $agent"
    done
    exit 1
else
    echo -e "${GREEN}✓${NC} All agents have valid YAML frontmatter"
fi

# Test 5: Report SYSTEM BOUNDARY issues (critical)
if [ ${#SYSTEM_BOUNDARY_MISSING[@]} -gt 0 ]; then
    echo -e "${RED}✗${NC} CRITICAL: Agents missing SYSTEM BOUNDARY protection:"
    for agent in "${SYSTEM_BOUNDARY_MISSING[@]}"; do
        echo "  - $agent"
    done
    exit 1
else
    echo -e "${GREEN}✓${NC} All agents have SYSTEM BOUNDARY protection"
fi

# Test 6: Report other validation failures
if [ ${#FAILED_AGENTS[@]} -gt 0 ]; then
    echo -e "${RED}✗${NC} Agent validation failures:"
    for failure in "${FAILED_AGENTS[@]}"; do
        echo "  - $failure"
    done
    exit 1
else
    echo -e "${GREEN}✓${NC} All agents pass structure validation"
fi

# Test 7: Validate agent categories
echo "Validating agent categories..."
CATEGORIES=$(find "$AGENTS_DIR" -name "*.md" -exec grep -h "^category:" {} + 2>/dev/null | sed 's/category: *//' | sort -u)
CATEGORY_COUNT=$(echo "$CATEGORIES" | wc -l | tr -d ' ')

if [ "$CATEGORY_COUNT" -lt 3 ]; then
    echo -e "${RED}✗${NC} Too few agent categories: $CATEGORY_COUNT"
    exit 1
else
    echo -e "${GREEN}✓${NC} Agent categories validated: $CATEGORY_COUNT categories found"
fi

echo -e "${GREEN}✓${NC} All agent system tests passed!"
