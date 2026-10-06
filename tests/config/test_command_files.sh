#!/bin/bash
# Test for skill file validation (migrated from command file validation)

# Source test utilities
source "$(dirname "$0")/../utils.sh"

# Test all skill files exist
test_all_skills_exist() {
    local skills_dir="$ORIGINAL_DIR/system-configs/.claude/skills"

    assert_dir_exists "$skills_dir" \
        "Skills directory should exist"

    # Check each expected skill directory (migrated from commands)
    local expected_skills=("plan" "commit" "push" "test" "prime"
                            "fix-ci" "implement" "verify" "resolve-comments"
                            "docs" "audit" "branch" "pr" "rebase" "prompt"
                            "deps" "merge" "ship-it" "review" "debug")

    for skill in "${expected_skills[@]}"; do
        assert_file_exists "$skills_dir/${skill}/SKILL.md" \
            "Skill file ${skill}/SKILL.md should exist"
    done
}

# Test skill YAML frontmatter structure
test_skill_yaml_frontmatter() {
    local skills_dir="$ORIGINAL_DIR/system-configs/.claude/skills"

    echo "Testing YAML frontmatter in skill files..."

    for skill_dir in "$skills_dir"/*/; do
        [ -d "$skill_dir" ] || continue
        local skill_file="$skill_dir/SKILL.md"
        [ -f "$skill_file" ] || continue

        local skill_name=$(basename "$skill_dir")

        # All skills should have frontmatter
        if ! grep -q "^---$" "$skill_file"; then
            echo "Warning: ${skill_name}/SKILL.md missing YAML frontmatter"
            continue
        fi

        local temp_file
        temp_file=$(mktemp)

        # Extract YAML front-matter
        sed -n '/^---$/,/^---$/p' "$skill_file" | sed '1d;$d' > "$temp_file"

        # Check required fields
        if ! grep -q "^description:" "$temp_file"; then
            echo "${skill_name}/SKILL.md missing required 'description' field"
            rm "$temp_file"
            return 1
        fi

        echo "Valid YAML frontmatter in ${skill_name}/SKILL.md"
        rm "$temp_file"
    done

    return 0
}

# Test skill file structure (only for user-invocable skills, not reference skills)
test_skill_structure() {
    local skills_dir="$ORIGINAL_DIR/system-configs/.claude/skills"

    # Only check migrated command skills that are user-invocable
    local command_skills=("plan" "commit" "push" "test" "prime"
                          "fix-ci" "implement" "verify" "resolve-comments"
                          "docs" "audit" "branch" "pr" "rebase" "prompt"
                          "deps" "merge" "ship-it" "review" "debug")

    for skill_name in "${command_skills[@]}"; do
        local skill_file="$skills_dir/${skill_name}/SKILL.md"
        [ -f "$skill_file" ] || continue

        # Check for YAML frontmatter
        if ! grep -q "^---$" "$skill_file"; then
            continue
        fi

        # Check for required sections
        assert_file_contains "$skill_file" "## Usage" \
            "${skill_name}: Should have Usage section"
        assert_file_contains "$skill_file" "## Description" \
            "${skill_name}: Should have Description section"
        assert_file_contains "$skill_file" "## Expected Output" \
            "${skill_name}: Should have Expected Output section"

        # Check for usage example
        assert_file_contains "$skill_file" "\`\`\`" \
            "${skill_name}: Should have code block for usage"
    done
}

# Test unified audit skill
test_skill_audit_requirements() {
    local skills_dir="$ORIGINAL_DIR/system-configs/.claude/skills"
    local audit_file="$skills_dir/audit/SKILL.md"

    echo "  Testing unified audit implementation..."

    if [ ! -f "$audit_file" ]; then
        echo "    Error: audit/SKILL.md not found"
        return 1
    fi

    # Check audit has proper frontmatter
    if grep -q "^---$" "$audit_file"; then
        echo "    audit follows template format"
    fi

    # Check for scope support
    if grep -q "scope" "$audit_file"; then
        echo "    Includes scope support"
    fi

    # Check for agents validation
    if grep -q "agents" "$audit_file"; then
        echo "    Includes agents support"
    fi

    # Check for YAML validation
    if grep -q -i "yaml" "$audit_file"; then
        echo "    Includes YAML support"
    fi

    return 0
}

# Test skill count (should be 34 after migration and additions)
test_skill_count() {
    local skills_dir="$ORIGINAL_DIR/system-configs/.claude/skills"
    local skill_count=$(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')

    if [ "$skill_count" -lt 25 ] || [ "$skill_count" -gt 55 ]; then
        echo "Skill count $skill_count outside expected range (25-55)"
        return 1
    fi

    echo "Skill count: $skill_count (expected ~34)"
    return 0
}

# Test documentation completeness (only for user-invocable command-migrated skills)
test_documentation_completeness() {
    local skills_dir="$ORIGINAL_DIR/system-configs/.claude/skills"

    # Only check migrated command skills for full documentation
    local command_skills=("plan" "commit" "push" "test" "prime"
                          "fix-ci" "implement" "verify" "resolve-comments"
                          "docs" "audit" "branch" "pr" "rebase" "prompt"
                          "deps" "merge" "ship-it" "review" "debug")

    for skill_name in "${command_skills[@]}"; do
        local skill_file="$skills_dir/${skill_name}/SKILL.md"
        [ -f "$skill_file" ] || continue

        # Check file is not empty
        if [ ! -s "$skill_file" ]; then
            echo "Skill file ${skill_name}/SKILL.md is empty"
            return 1
        fi

        # Check for required sections
        if grep -q "^---$" "$skill_file"; then
            local missing_sections=()
            if ! grep -q "## Usage" "$skill_file"; then
                missing_sections+=("Usage")
            fi
            if ! grep -q "## Description" "$skill_file"; then
                missing_sections+=("Description")
            fi
            if ! grep -q "## Expected Output" "$skill_file"; then
                missing_sections+=("Expected Output")
            fi

            if [ ${#missing_sections[@]} -gt 0 ]; then
                echo "${skill_name}: Missing required sections: ${missing_sections[*]}"
                return 1
            fi
        fi
    done
}

# Test validation edge cases
test_validation_edge_cases() {
    local test_dir="$TEST_DIR/edge-cases"
    mkdir -p "$test_dir"

    echo "  Testing validation edge cases..."

    # Create test files for edge case validation
    # 1. Empty frontmatter
    cat > "$test_dir/empty-frontmatter.md" << 'EOF'
---
---
# Empty Frontmatter Skill

## Usage
```
/empty-frontmatter
```

## Description
Test skill with empty frontmatter.

## Expected Output
Test output.
EOF

    # 2. Long description
    cat > "$test_dir/long-description.md" << 'EOF'
---
description: This is a very long description that exceeds the recommended sixty character limit for skill descriptions
argument-hint: [optional]
---
# Long Description Skill

## Usage
```
/long-description
```

## Description
Test skill with long description.

## Expected Output
Test output.
EOF

    # 3. Malformed YAML
    cat > "$test_dir/malformed-yaml.md" << 'EOF'
---
description: Valid description
argument-hint [invalid format without colon]
---
# Malformed YAML Skill

## Usage
```
/malformed-yaml
```

## Description
Test skill.

## Expected Output
Test output.
EOF

    # 4. Perfect skill
    cat > "$test_dir/perfect-skill.md" << 'EOF'
---
description: Short and descriptive
argument-hint: [file-path]
---
# Perfect Skill

## Usage
```
/perfect-skill [file-path]
```

## Description
A perfectly formatted skill.

## Expected Output
Clear output description.
EOF

    # Validate each test file
    local valid_count=0
    local invalid_count=0

    for test_file in "$test_dir"/*.md; do
        local name=$(basename "$test_file" .md)
        local is_valid=true

        # Check for empty frontmatter
        local yaml_content=$(sed -n '/^---$/,/^---$/p' "$test_file" | sed '1d;$d')
        if [ -z "$yaml_content" ]; then
            echo "    $name: Empty frontmatter"
            is_valid=false
        fi

        # Check for missing description
        if ! echo "$yaml_content" | grep -q "^description:"; then
            echo "    $name: Missing description field"
            is_valid=false
        fi

        # Check for malformed YAML
        if echo "$yaml_content" | grep -qE "^[a-zA-Z-]+ [^\:]"; then
            echo "    $name: Invalid YAML syntax"
            is_valid=false
        fi

        # Check description length
        if echo "$yaml_content" | grep -q "^description:"; then
            local desc_length=$(echo "$yaml_content" | grep "^description:" | cut -d':' -f2- | sed 's/^[ \t]*//' | wc -c)
            if [ "$desc_length" -gt 65 ]; then
                echo "    Warning $name: Description too long"
            fi
        fi

        if [ "$is_valid" = true ]; then
            echo "    $name: Valid"
            valid_count=$((valid_count + 1))
        else
            invalid_count=$((invalid_count + 1))
        fi
    done

    echo "    Results: $valid_count valid, $invalid_count invalid skills"

    # Cleanup
    rm -rf "$test_dir"

    # Expect 2 valid (long-description, perfect-skill) and 2 invalid (empty-frontmatter, malformed-yaml)
    if [ "$valid_count" -eq 2 ] && [ "$invalid_count" -eq 2 ]; then
        echo "    Edge case validation working correctly"
        return 0
    else
        echo "    Edge case validation counts unexpected"
        echo "    Expected: 2 valid, 2 invalid; Got: $valid_count valid, $invalid_count invalid"
        return 1
    fi
}

# Run all tests
echo "Testing skill file validation..."

test_all_skills_exist || exit 1
test_skill_count || exit 1
test_skill_yaml_frontmatter || exit 1
test_skill_structure || exit 1
test_skill_audit_requirements || exit 1
test_documentation_completeness || exit 1
test_validation_edge_cases || exit 1

echo "All skill file validation tests passed!"
