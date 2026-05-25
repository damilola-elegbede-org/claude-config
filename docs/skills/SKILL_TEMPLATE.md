---
# SKILL TEMPLATE - CLAUDE CODE SKILLS SYSTEM
#
# Skills provide focused expertise and complex workflows with optional context isolation.
#
# Two formats supported:
# 1. Directory-based (recommended): skills/<name>/SKILL.md
# 2. Flat file (legacy): skills/<name>.md
#
# Skill categories:
# - language: Programming language expertise (python, typescript)
# - format: File format expertise (yaml, markdown)
# - framework: Framework patterns (react, fastapi)
# - infrastructure: DevOps tools (docker, kubernetes)
# - workflow: Process expertise (git-workflows, cicd)
# - orchestration: Complex multi-step workflows (ship-it, review)
#
# Fill in ALL placeholders. Delete these comments before use.
#
name: skill-name  # lowercase-hyphenated, must match directory name
description: Brief description under 60 chars
metadata:
  category: workflow  # language, format, framework, infrastructure, workflow, orchestration
---

# /skill-name Skill

Brief description of what this skill does.

## Usage

```bash
/skill-name              # Basic usage
/skill-name --flag       # With options
/skill-name argument     # With arguments
```

## Domain Focus

[2-3 sentences describing the expertise area and primary use cases]

## Core Capabilities

- [Capability 1: specific technical skill]
- [Capability 2: pattern or best practice]
- [Capability 3: common operation or technique]
- [Capability 4: validation or quality standard]

## When to Use This Skill

- [Specific file type or pattern detected]
- [Particular task or question about domain]
- [Quality check or validation needed]

## Execution

### Step 1: [Phase Name]

```text
[Execution steps in pseudocode format]
```

### Step 2: [Phase Name]

```text
[More execution steps]
```

## Expected Output

```text
Example of successful execution output
```

## Notes

- [Important implementation detail]
- [Integration notes]
- [Limitations or caveats]
