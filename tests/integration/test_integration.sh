#!/bin/bash
# Integration tests for Claude configuration

# Source test utilities
source "$(dirname "$0")/../utils.sh"

# Test sync skill simulation
test_sync_simulation() {
    # Setup test environment
    setup_test_env

    # Create mock source structure with skills
    mkdir -p system-configs/.claude/skills/test
    mkdir -p system-configs/.claude/skills/plan
    create_mock_claude_md
    echo "# /test" > "system-configs/.claude/skills/test/SKILL.md"
    echo "# /plan" > "system-configs/.claude/skills/plan/SKILL.md"

    # Create mock destination
    mkdir -p mock_home/.claude/skills

    # Simulate sync operation - copying from system-configs
    cp system-configs/CLAUDE.md mock_home/CLAUDE.md 2>/dev/null || cp CLAUDE.md mock_home/CLAUDE.md
    cp -r system-configs/.claude/skills/* mock_home/.claude/skills/ 2>/dev/null || echo "No skills to copy"

    # Verify sync results
    assert_file_exists "mock_home/CLAUDE.md" \
        "CLAUDE.md should be synced"

    assert_file_exists "mock_home/.claude/skills/test/SKILL.md" \
        "Skill files should be synced"

    cleanup_test_env
}

# Test skill consistency
test_skill_consistency() {
    local skills_in_readme
    local skills_in_dir

    skills_in_readme=$(grep -c "^\s*- \`/[a-z]*\`" "$ORIGINAL_DIR/README.md" 2>/dev/null || echo 0)
    skills_in_dir=$(find "$ORIGINAL_DIR/system-configs/.claude/skills" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')

    # Ensure numeric values
    skills_in_readme=${skills_in_readme:-0}
    skills_in_dir=${skills_in_dir:-0}

    # Basic check - skills directory should have content
    if [ "$skills_in_dir" -lt 10 ]; then
        echo "Too few skills found: $skills_in_dir"
        return 1
    fi

    return 0
}

# Test CLAUDE.md consistency - Check both project and system configs
test_claude_md_consistency() {
    local project_claude="$ORIGINAL_DIR/CLAUDE.md"
    local system_claude="$ORIGINAL_DIR/system-configs/CLAUDE.md"

    # Check project CLAUDE.md exists and has repository info
    assert_file_exists "$project_claude" \
        "Project CLAUDE.md should exist"

    assert_file_contains "$project_claude" "Configuration Repository" \
        "Project CLAUDE.md should describe configuration repository"

    # Check system CLAUDE.md exists and has orchestration rules
    assert_file_exists "$system_claude" \
        "System CLAUDE.md should exist in system-configs/"

    # Check for key behavioral directives (require all three)
    if grep -q "^## Quality Standards" "$system_claude" \
       && grep -qi "verify\|verification" "$system_claude" \
       && grep -qi "helpful\|communication" "$system_claude"; then
        echo "✓ System CLAUDE.md defines behavioral directives"
    else
        echo "❌ System CLAUDE.md should define behavioral directives"
        return 1
    fi

    return 0
}

# Test repository structure integrity
test_repo_structure() {
    # Check all expected directories exist
    assert_dir_exists "$ORIGINAL_DIR/system-configs/.claude" \
        "system-configs/.claude directory should exist"

    assert_dir_exists "$ORIGINAL_DIR/system-configs/.claude/skills" \
        "system-configs skills directory should exist"

    assert_dir_exists "$ORIGINAL_DIR/tests" \
        "tests directory should exist"

    # Check all expected files exist
    assert_file_exists "$ORIGINAL_DIR/README.md" \
        "README.md should exist"

    assert_file_exists "$ORIGINAL_DIR/CLAUDE.md" \
        "CLAUDE.md should exist"

    assert_file_exists "$ORIGINAL_DIR/tests/test.sh" \
        "tests/test.sh should exist"
}

# Test that sync command works for Claude configs
# Note: sync is project-local (.claude/commands/), not in system-configs
test_sync_functionality() {
    local sync_file="$ORIGINAL_DIR/.claude/skills/sync/SKILL.md"

    # Verify sync SKILL.md exists in project-local location
    assert_file_exists "$sync_file" \
        "sync/SKILL.md should exist in project-local .claude/skills/"

    # Verify it mentions Claude configuration sync
    assert_file_contains "$sync_file" "system-configs/.claude/" \
        "sync SKILL.md should mention source directory"

    assert_file_contains "$sync_file" "rsync" \
        "sync SKILL.md should mention rsync usage"

    assert_file_contains "$sync_file" "statusline.sh" \
        "sync SKILL.md should mention statusline.sh"
}

# Run all tests
echo "Running integration tests..."

test_sync_simulation || exit 1
test_skill_consistency || exit 1
test_claude_md_consistency || exit 1
test_repo_structure || exit 1
test_sync_functionality || exit 1

echo "All integration tests passed!"
