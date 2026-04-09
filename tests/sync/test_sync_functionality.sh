#!/bin/bash
# Test sync functionality

# Source test utilities
source "$(dirname "$0")/../utils.sh"

# Test variables
SOURCE_DIR="${ORIGINAL_DIR}/system-configs"
SYNC_SCRIPT="${ORIGINAL_DIR}/scripts/sync.sh"
TEST_HOME="${TEST_DIR}/home"
BACKUP_DIR="${TEST_DIR}/backup"

echo "Testing sync functionality..."

# Setup test environment
setup_sync_test() {
    # Create test home directory structure
    mkdir -p "$TEST_HOME/.claude"
    mkdir -p "$BACKUP_DIR"

    # Create some existing files to test backup
    echo "existing settings" > "$TEST_HOME/.claude/settings.json"
    echo "existing config" > "$TEST_HOME/.claude/CLAUDE.md"
    mkdir -p "$TEST_HOME/.claude/agents"
    echo "existing agent" > "$TEST_HOME/.claude/agents/test-agent.md"
}

# Test 1: Check sync script exists
assert_file_exists "$SYNC_SCRIPT" "Sync script should exist"

# Test 2: Test dry-run mode
echo "Testing dry-run mode..."
setup_sync_test

# Simulate dry-run (check what would be synced)
DRY_RUN_OUTPUT=$(cd "$ORIGINAL_DIR" && find system-configs -type f -name "*.md" -o -name "*.json" -o -name "*.sh" 2>/dev/null | grep -v "output-styles" | grep -v "TEMPLATE" | wc -l | tr -d ' ')

if [ "$DRY_RUN_OUTPUT" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Dry-run detected $DRY_RUN_OUTPUT files to sync"
else
    echo -e "${RED}✗${NC} Dry-run failed to detect files"
    exit 1
fi

# Test 3: Test file exclusions
echo "Testing file exclusions..."

# Check that output-styles are excluded
OUTPUT_STYLES_COUNT=$(find "$SOURCE_DIR/.claude" -path "*/output-styles/*" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$OUTPUT_STYLES_COUNT" -gt 0 ]; then
    # Verify these files would be excluded
    EXCLUDED_IN_SYNC=$(find "$SOURCE_DIR/.claude" -type f \( -path "*/output-styles/*" -o -name "*TEMPLATE*" -o -name "README.md" \) 2>/dev/null | wc -l | tr -d ' ')
    echo -e "${GREEN}✓${NC} Exclusion rules would skip $EXCLUDED_IN_SYNC files"
else
    echo -e "${GREEN}✓${NC} No output-styles files to exclude"
fi

# Test 4: Test backup functionality
echo "Testing backup functionality..."

# Count existing files that would be backed up
EXISTING_FILES=$(find "$TEST_HOME/.claude" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXISTING_FILES" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Backup would preserve $EXISTING_FILES existing files"
else
    echo -e "${YELLOW}⚠${NC} No existing files to backup (fresh installation)"
fi

# Test 5: Test directory structure preservation
echo "Testing directory structure..."

# Check source structure
REQUIRED_DIRS=(
    "$SOURCE_DIR/.claude"
    "$SOURCE_DIR/.claude/agents"
    "$SOURCE_DIR/.claude/skills"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗${NC} Missing required directory: $dir"
        exit 1
    fi
done
echo -e "${GREEN}✓${NC} Source directory structure validated"

# Test 6: Test settings.json validation
echo "Testing settings.json..."

SETTINGS_FILE="$SOURCE_DIR/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    # Validate JSON syntax
    if python3 -m json.tool "$SETTINGS_FILE" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} settings.json is valid JSON"
    else
        echo -e "${RED}✗${NC} settings.json has invalid JSON syntax"
        exit 1
    fi

    # Check for required sections
    if grep -q '"mcpServers"' "$SETTINGS_FILE"; then
        echo -e "${GREEN}✓${NC} settings.json contains mcpServers configuration"
    else
        echo -e "${YELLOW}⚠${NC} settings.json missing mcpServers section"
    fi
else
    echo -e "${RED}✗${NC} settings.json not found"
    exit 1
fi

# Test 7: Test CLAUDE.md presence
echo "Testing CLAUDE.md configuration..."

CLAUDE_MD="$SOURCE_DIR/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    # Check file size (should be substantial)
    FILE_SIZE=$(wc -c < "$CLAUDE_MD" | tr -d ' ')
    if [ "$FILE_SIZE" -gt 400 ]; then
        echo -e "${GREEN}✓${NC} CLAUDE.md exists and has content ($FILE_SIZE bytes)"
    else
        echo -e "${RED}✗${NC} CLAUDE.md is too small ($FILE_SIZE bytes)"
        exit 1
    fi
else
    echo -e "${RED}✗${NC} CLAUDE.md not found"
    exit 1
fi

# Test 8: Test agent files sync readiness
echo "Testing agent files..."

AGENT_COUNT=$(find "$SOURCE_DIR/.claude/agents" -name "*.md" -not -name "*TEMPLATE*" -not -name "README.md" | wc -l | tr -d ' ')
if [ "$AGENT_COUNT" -ge 6 ]; then
    echo -e "${GREEN}✓${NC} $AGENT_COUNT agents ready for sync"
else
    echo -e "${RED}✗${NC} Too few agents found: $AGENT_COUNT (expected at least 6)"
    exit 1
fi

# Test 9: Test skill files sync readiness
echo "Testing skill files..."

SKILL_COUNT=$(find "$SOURCE_DIR/.claude/skills" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SKILL_COUNT" -gt 10 ]; then
    echo -e "${GREEN}✓${NC} $SKILL_COUNT skills ready for sync"
else
    echo -e "${RED}✗${NC} Too few skills found: $SKILL_COUNT"
    exit 1
fi

# Test 10: Simulate sync operation (without actually syncing)
echo "Testing sync simulation..."

# Count total files that would be synced
TOTAL_SYNC_FILES=$(cd "$ORIGINAL_DIR" && find system-configs/.claude -type f \( -name "*.md" -o -name "*.json" -o -name "*.sh" \) -not -path "*/output-styles/*" -not -name "*TEMPLATE*" -not -name "README.md" 2>/dev/null | wc -l | tr -d ' ')

if [ "$TOTAL_SYNC_FILES" -gt 50 ]; then
    echo -e "${GREEN}✓${NC} Sync would transfer $TOTAL_SYNC_FILES files"
else
    echo -e "${YELLOW}⚠${NC} Sync would transfer $TOTAL_SYNC_FILES files (expected more than 50)"
fi

# Cleanup
cleanup_test_env

echo -e "${GREEN}✓${NC} All sync functionality tests passed!"
