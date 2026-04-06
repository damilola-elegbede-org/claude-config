# Skills Guide

## Overview

Skills are the unified extension mechanism for the Claude Code framework. All 21 former commands
have been migrated to skills, joined by 5 agent-preloaded reference skills and 8 imported
Anthropic skills, for a total of **34 skills and 0 commands**.

Skills range from lightweight git operations to sophisticated multi-phase orchestration workflows,
agent-routed domain expertise, and background reference material preloaded into agent contexts.

## Four-Tier Execution Framework

```text
Level 1: Direct Execution
├─ Simple, deterministic tasks
├─ < 5 minutes completion
└─ Example: Fix typos, add imports

Level 2: Skills
├─ All slash-command invocations
├─ Git workflows, utilities, orchestration
├─ Agent-routed domain expertise
├─ Reference material preloaded into agents
└─ Example: /commit, /review, /ship-it, /debug

Level 3: Agents
├─ Complex specialists with deep context
├─ Multi-step orchestration
└─ Example: backend-engineer, architect, debugger

Level 4: Agent Teams
├─ Multiple Claude instances coordinated
├─ Parallel implementation, competing hypotheses
└─ Example: Full-stack feature, deep review
```

## Skill Categories (34 Total)

### Orchestration Skills (7)

Complex multi-phase workflows with task tracking, parallel execution, and agent routing.

| Skill | Description | Key Features |
|-------|-------------|--------------|
| `/ship-it` | Development workflow orchestration | Flags: `-d`, `-t`, `-c`, `-r`, `-p`, `-pr`, `--dry-run` |
| `/review` | Comprehensive code review | Assertive analysis, `--full` |
| `/fix-ci` | CI failure diagnosis and fix | `--learn` |
| `/deps` | Dependency management | `audit`, `update`, `clean`, `--quick` |
| `/resolve-comments` | CodeRabbit comment resolution | `--auto`, `--dry-run` |
| `/implement` | Feature implementation from specs | `--spec`, `--tdd` |
| `/feature-lifecycle` | End-to-end feature delivery | Agent team coordination |

### Agent-Routed Skills (4)

Skills that route to specialized agents for domain-specific work.

| Skill | Description | Routed Agent | Flags |
|-------|-------------|--------------|-------|
| `/debug` | Root cause analysis | debugger | `--performance`, `--issue` |
| `/plan` | PRD and task file generation | architect | `--no-execute`, `--simple` |
| `/prime` | Repository understanding | researcher | `--lite`, `--full` |
| `/docs` | Documentation generation | tech-writer | `--audit`, `--audit-and-fix`, `--clean` |

### Git Workflow Skills (6)

Direct-execution skills for common git operations.

| Skill | Description |
|-------|-------------|
| `/branch` | Create branches with intelligent naming |
| `/commit` | Git commits with message generation |
| `/push` | Push with validation |
| `/rebase` | Rebase on target branch |
| `/merge` | Merge branches with conflict handling |
| `/pr` | Create PRs with smart descriptions |

### Utility Skills (4)

| Skill | Description | Flags |
|-------|-------------|-------|
| `/test` | Test discovery and execution | `--create`, `--framework`, `--coverage` |
| `/audit` | Unified agent/skill validation | `--scope agents\|skills\|all`, `--fix` |
| `/prompt` | Prompt optimization | `--file` |
| `/verify` | Skill verification | `--last`, `--command`, `--depth` |

### Agent-Preloaded Reference Skills (5)

Reference material preloaded into agent contexts via the `skills` frontmatter field.
These are not user-invocable (`user-invocable: false`).

| Skill | Preloaded By | Purpose |
|-------|-------------|---------|
| `git-conventions` | code-reviewer, devops | Git best practices, commit conventions, branching strategies |
| `security-checklist` | code-reviewer, security-auditor | OWASP checks, vulnerability patterns, secure coding |
| `testing-patterns` | test-engineer | TDD/BDD patterns, test organization, coverage strategies |
| `api-design-patterns` | architect, backend-engineer | REST/GraphQL patterns, OpenAPI, versioning |
| `markdown-linting` | tech-writer | Markdownlint rules, documentation formatting |

### Imported Anthropic Skills (8)

Skills imported from Anthropic's official skill library via `/skills-import`.

| Skill | Description |
|-------|-------------|
| `pdf` | PDF file reading and analysis |
| `docx` | Word document reading and analysis |
| `xlsx` | Excel spreadsheet reading and analysis |
| `pptx` | PowerPoint presentation reading and analysis |
| `webapp-testing` | Web application testing with browser automation |
| `skill-creator` | Create new skills from templates |
| `mcp-builder` | Build MCP server integrations |
| `frontend-design` | Frontend design patterns and implementation |

## Claude Code Skill Features

Skills support advanced features from Claude Code's skill system:

| Feature | Description | Use Case |
|---------|-------------|----------|
| `context: fork` | Run in isolated context | Complex workflows, reviews |
| `agent: <type>` | Route to specific agent | Domain-specific work |
| `allowed-tools` | Restrict available tools | Security, focus |
| `user-invocable` | Control manual invocation | Reference skills set to `false` |

## `context: fork` Convention

The `context: fork` frontmatter field runs a skill in an isolated subagent context. This provides
clean separation but **prevents interactive prompts (`ASK_USER`) from reaching the user**.

### When to Use `context: fork`

- Skills that perform autonomous work without user interaction
- Complex workflows where context isolation prevents side effects
- Skills invoked by orchestrators that should not block on prompts

### When NOT to Use `context: fork`

- Skills that use `ASK_USER` prompts for interactive triage or confirmation
- Skills where user decision-making is part of the core workflow

### Calling Interactive Skills from Forked Contexts

If an orchestrator (`context: fork`) invokes a skill that has interactive prompts, the caller
MUST pass a flag (e.g., `--auto`) to bypass those prompts. Otherwise the skill will hang
waiting for user input that can never be delivered.

```text
# Bad: /review (context: fork) calls /resolve-comments without --auto → hangs
Skill tool: skill="resolve-comments", args="--code-rabbit --local"

# Good: --auto bypasses unreachable prompts
Skill tool: skill="resolve-comments", args="--code-rabbit --local --auto"
```

## Directory Structure

Skills use a directory-based structure:

```text
system-configs/.claude/skills/
├── ship-it/
│   └── SKILL.md
├── review/
│   └── SKILL.md
├── commit/
│   └── SKILL.md
├── git-conventions/
│   └── SKILL.md
├── pdf/
│   └── SKILL.md
└── ...
```

Each skill directory contains:

```text
skills/<name>/
  SKILL.md          # Required: skill definition
  templates/        # Optional: supporting files
  examples/         # Optional: reference material
```

## Using Skills

### Invocation

Skills are invoked as slash commands in Claude Code CLI:

```text
/commit              # Git commit with message generation
/review --full       # Full comprehensive code analysis
/ship-it -t -c -p    # Test, commit, push workflow
/debug --performance  # Performance-focused root cause analysis
/branch add-oauth    # Create feature branch
```

### Integration with Agents

Skills complement agents in the execution hierarchy:

```text
User requests → Claude analyzes complexity

Simple task      → Direct execution (Level 1)
Workflow/tool    → Skill invocation (Level 2)
Complex task     → Agent delegation (Level 3)
Multi-perspective → Agent team (Level 4)
```

Agent-routed skills bridge Levels 2 and 3 by accepting slash-command invocation
while delegating execution to specialized agents.

Agent-preloaded reference skills enhance Level 3 by injecting domain knowledge
into agent contexts automatically.

## Creating New Skills

### Skill Template

Use `docs/skills/SKILL_TEMPLATE.md` as the foundation:

```markdown
---
name: skill-name
description: Expertise in [domain]
---

# [Skill Name]

## When to Use
- [3-4 specific triggers]

## Steps
1. [Step-by-step execution instructions]

## Common Patterns
[Code examples with explanations]
```

### Reference Skill Template

For agent-preloaded reference skills:

```markdown
---
name: reference-name
description: Reference material for [domain]
user-invocable: false
---

# [Reference Name]

## Guidelines
- [Domain-specific rules and patterns]

## Checklist
- [ ] [Validation item 1]
- [ ] [Validation item 2]
```

### Validation

Validate new skills before syncing:

```bash
./scripts/validate-skills.py
```

### Deployment

Add skills to the framework via `/sync`:

```bash
# 1. Create skill in system-configs/.claude/skills/<name>/SKILL.md
# 2. Validate
./scripts/validate-skills.py

# 3. Sync to ~/.claude/
/sync

# 4. Verify
ls ~/.claude/skills/
```

## Mutual Exclusivity Rule

**Skills and commands are mutually exclusive.** Since all commands have been migrated to skills,
there should be no command definitions remaining. The validation script enforces this:

```bash
./scripts/validate-skills.py
```

If a command file is found with the same name as a skill, validation fails. This ensures:

- No duplicate entries in search/autocomplete
- Clear routing for each operation
- Single canonical implementation for each workflow

## Best Practices

### When to Create a Skill

Create a skill when:

- A reusable workflow needs slash-command invocation
- Domain expertise should be preloaded into agent contexts
- Multi-phase orchestration benefits from task tracking
- Agent routing enables domain-specific execution

### When NOT to Create a Skill

Don't create a skill when:

- Task is a one-off operation (use direct execution)
- Better suited as a full agent (deep domain specialist)
- One-time or project-specific knowledge
- No clear reuse pattern

### Skill Size and Scope

**Good:** Focused, clear purpose

```text
/commit - Single responsibility: stage, generate message, commit
/review - Clear phases: lint, security, quality, summary
git-conventions - Reference: branching, commits, PR patterns
```

**Bad:** Too broad, overlaps with agents

```text
# "Backend Development" skill
# → This should be the backend-engineer agent
```

## Troubleshooting

### Skill Not Available

```bash
# Check if skills are synced
ls ~/.claude/skills/

# Re-sync if needed
/sync

# Verify sync output includes skills
```

### Validation Errors

```bash
# Run validation
./scripts/validate-skills.py

# Common issues:
# - Invalid name format (must be lowercase-hyphenated)
# - Missing required fields (name, description)
# - Duplicate skill/command name
```

### Skill vs Agent Confusion

**Use skill when:**

- Slash-command invocation needed
- Defined workflow with clear steps
- Reference material for agent context
- Quick, repeatable operation

**Use agent when:**

- Complex multi-step task requiring judgment
- Deep domain expertise with tool orchestration
- Strategic decisions across multiple files/systems
- Investigation requiring iterative exploration

## Resources

- **Skill Template**: `docs/skills/SKILL_TEMPLATE.md`
- **Validation Script**: `scripts/validate-skills.py`
- **Skills Directory**: `system-configs/.claude/skills/`
- **Sync Skill**: `/sync` deploys skills to `~/.claude/skills/`
- **Import Skill**: `/skills-import` imports Anthropic skills
