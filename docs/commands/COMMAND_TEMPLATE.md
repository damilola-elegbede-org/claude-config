---
description: Template for creating new Claude Code commands
argument-hint: [command-name]
---

# Command Template

This template defines the standard format for all Claude Code slash commands.
Each command is a skill at `system-configs/.claude/skills/<name>/SKILL.md` and should follow this structure.

## New Command Template Structure

Use this template to create new commands:

```markdown
---
description: Brief description under 60 chars
argument-hint: [options]
---

# /command-name Command

## Usage

```bash
/command-name              # Basic usage
/command-name --flag       # With options
/command-name argument     # With arguments
```text

## Description

Brief explanation of what this command does and when to use it. Keep it concise.

## Expected Output

```texttext
Example of what successful execution looks like
Including success indicators and common variations
```text

## Behavior (optional)

Detailed behavior, workflows, agent strategies if needed for complex commands.

## Frontmatter Fields
### Required Fields

- **description**: A concise, clear description of the command's purpose (shown in autocomplete)

### Optional Fields

- **argument-hint**: Shows users what arguments to provide (e.g., `[branch-name]`, `[file-path]`)
- **allowed-tools**: Specify which tools can be used (e.g., `Bash(git add:*)`)
- **model**: Override the default model with an alias (e.g., `haiku`)

## Best Practices

1. **Description**: Keep it under 60 characters for clean autocomplete display
2. **Argument Hints**: Use square brackets for optional args: `[file-path]`
3. **Usage Section**: Show common invocation patterns with clear examples
4. **Expected Output**: Include concrete examples of successful execution
5. **Behavior Section**: Only include for complex commands requiring detailed workflow explanation

## Template Examples

### Simple Command (no arguments)

```markdown
---
description: Run all project tests and report results
---

# /test Command

## Usage

```bash
/test                      # Run all tests
```text

## Test Description

Runs all project tests and provides a comprehensive summary of results including pass/fail counts and coverage metrics.

## Test Expected Output

```texttext
Running test suite...
✓ Unit tests: 45/45 passed
✓ Integration tests: 12/12 passed
✓ Coverage: 87%
All tests completed successfully
```text

## Command with Arguments

```markdown
---
description: Fix a specific GitHub issue
argument-hint: [issue-number]
---

# /fix-issue Command

## Usage

```bash
/fix-issue 123            # Fix specific issue
/fix-issue 123 --review   # Fix with peer review
```text

## Fix-Issue Description

Analyzes the specified GitHub issue and implements a solution following project coding standards.

## Fix-Issue Expected Output

```texttext
Analyzing issue #123...
✓ Issue understood: Authentication timeout bug
✓ Solution implemented in src/auth.js
✓ Tests updated and passing
✓ Ready for review
```text

```text

## Markdown Linting Compliance

This template follows all critical linting rules:

- Line length under 150 characters (MD013)
- Headings surrounded by blank lines (MD022, MD031, MD032)
- Lists surrounded by blank lines (MD032)
- Tables surrounded by blank lines (MD058)
- Single H1 heading (MD025)
- Sequential heading levels (MD001)
- Language-specified code blocks (MD040)
- File ends with single newline (MD047)
