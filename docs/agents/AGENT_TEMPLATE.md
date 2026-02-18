---
# AGENT TEMPLATE - PRODUCTION READY
#
# This template matches the pattern used by 15 production agents
# Target length: 30-50 lines (not 180+)
#
# Model selection (Claude Sonnet 4.6 / Opus 4.6 - February 2026):
# - sonnet: Claude Sonnet 4.6 - Standard development, enhanced reasoning (DEFAULT)
#   * 2x improvement in complex problem-solving
#   * Native extended thinking support
#   * Faster response times for better parallelization
#   * Most agents use Sonnet 4.6
# - opus: Complex architecture requiring maximum reasoning depth
#   * principal-architect, project-orchestrator, result-arbitrator, career-strategist
#   * feature-agent (orchestration requiring deep reasoning)
# - haiku: Checklist-driven tasks, structured output, template-following
#   * accessibility-auditor (WCAG checklists, automated tools, structured YAML reports)
#   * tech-writer (markdown linting checklists, structured output, preloaded skill rules)
# - codex (external): Codex CLI for cost-effective coding execution
#   * codex-delegate (orchestrates Codex CLI, agent itself uses sonnet)
#
# Thinking level selection (optional - Sonnet 4.6/Opus 4.6 native support):
# - ultrathink (31,999 tokens): System-wide architecture, complex forensics, enterprise planning
#   * Used by: principal-architect, project-orchestrator, result-arbitrator, feature-agent
# - megathink (10,000 tokens): Domain expertise, multi-system coordination, complex optimization
#   * Recommended for: API design, cloud architecture, debugging, performance, security
#   * Used by: backend-engineer, cloud-architect, api-architect, ml-engineer
# - think harder (8,000 tokens): Focused analysis, moderate complexity, specific optimizations
#   * Used by: devops, code-reviewer
# - think (4,000 tokens): Basic enhanced reasoning (rarely needed - most agents work without)
#
# Fill in ALL placeholders. Delete these comments before use.
#
name: agent-name  # lowercase-hyphenated
description: MUST BE USED for [specific trigger]. Use for ANY [domain] task. Triggers on "[keyword1]", "[keyword2]", "[keyword3]".
tools: Read, Write, Edit, Grep, Glob, Bash  # Only include what's needed
model: sonnet  # opus/sonnet/haiku - see guide above
thinking-level: megathink  # OPTIONAL: ultrathink/megathink/think harder/think - only if needed
thinking-tokens: 10000  # OPTIONAL: Must match thinking-level token count
category: development  # development, quality, security, architecture, design, analysis, infrastructure, coordination - See docs/agents/AGENT_CATEGORIES.md for canonical list
color: blue  # Must match category color - see AGENT_CATEGORIES.md
# permissionMode: plan  # OPTIONAL: plan / acceptEdits / default / dontAsk / bypassPermissions
# memory: project        # OPTIONAL: project / local / user - persistent agent memory
# skills: git-conventions, security-checklist  # OPTIONAL: Preloads skill content into agent context (comma-separated)
---

# [Agent Name]

## Identity

Expert [role] specializing in [2-3 specific technical domains]. [One sentence describing unique value proposition].

## Core Capabilities

- [Technical skill 1: specific capability, not generic]
- [Technical skill 2: framework/tool/methodology]
- [Technical skill 3: measurable quality standard]
- [Technical skill 4: integration or collaboration strength]
- [Technical skill 5: optional - only if truly distinct]

## Thinking Level: [MEGATHINK (10,000 tokens)] - OPTIONAL SECTION

This agent requires [substantial/enhanced/maximum] thinking depth due to:

- **[Complexity factor 1]**: [Specific reasoning why this requires deep thinking]
- **[Complexity factor 2]**: [Another aspect requiring enhanced reasoning]
- **[Complexity factor 3]**: [Additional complexity justification]
- **[Complexity factor 4]**: [Further reasoning requirement]
- **[Complexity factor 5]**: [Final complexity indicator]

## When to Engage

- [Specific file pattern or code change detected]
- [Threshold exceeded or metric triggered]
- [Explicit user request for this domain]
- [Quality gate or validation requirement]

## When NOT to Engage

- [Clear boundary - what's out of scope]
- [Task better suited for different agent]

## Coordination

Works in parallel with [agent-type] for [scenario].
Escalates to Claude when [specific condition or blocker].

## SYSTEM BOUNDARY

This agent cannot invoke other agents or create Task calls. Only Claude has orchestration authority.

---

## Frontmatter Field Reference

### Required Fields

| Field | Description | Example |
|-------|-------------|---------|
| `name` | Lowercase-hyphenated identifier | `backend-engineer` |
| `description` | Trigger description with keywords | `MUST BE USED for...` |
| `tools` | Comma-separated tool list | `Read, Write, Edit, Grep, Glob, Bash` |
| `model` | Model tier | `sonnet`, `opus`, `haiku` |
| `category` | Agent category | `development`, `quality`, `security` |
| `color` | Category color | `blue`, `green`, `red` |

### Optional Fields

| Field | Description | Values | Example |
|-------|-------------|--------|---------|
| `thinking-level` | Extended thinking depth | `ultrathink`, `megathink`, `think harder`, `think` | `megathink` |
| `thinking-tokens` | Token budget for thinking | Must match thinking-level | `10000` |
| `permissionMode` | Permission behavior | `plan`, `acceptEdits`, `default`, `dontAsk`, `bypassPermissions` | `plan` |
| `memory` | Persistent memory scope | `project`, `local`, `user` | `project` |
| `skills` | Preloaded reference skills | Comma-separated skill names | `git-conventions, security-checklist` |

### The `skills` Field

The `skills` field preloads reference skill content into the agent's context at startup. This gives
the agent immediate access to domain-specific guidelines, checklists, and patterns without requiring
the user to invoke those skills separately.

**Syntax:**

```yaml
skills: git-conventions, security-checklist
```

**How it works:**

1. When the agent is spawned, Claude Code reads the SKILL.md files for each listed skill
2. The skill content is injected into the agent's system prompt
3. The agent can reference this knowledge throughout its session

**Current agent-skill mappings:**

| Agent | Preloaded Skills |
|-------|-----------------|
| architect | `api-design-patterns` |
| backend-engineer | `api-design-patterns` |
| code-reviewer | `git-conventions`, `security-checklist` |
| devops | `git-conventions` |
| security-auditor | `security-checklist` |
| test-engineer | `testing-patterns` |
| tech-writer | `markdown-linting` |

**Available reference skills** (all have `user-invocable: false`):

- `git-conventions` - Git best practices, commit conventions, branching strategies
- `security-checklist` - OWASP checks, vulnerability patterns, secure coding
- `testing-patterns` - TDD/BDD patterns, test organization, coverage strategies
- `api-design-patterns` - REST/GraphQL patterns, OpenAPI, versioning
- `markdown-linting` - Markdownlint rules, documentation formatting

**Best practices:**

- Only preload skills relevant to the agent's core domain
- Keep the list short (1-2 skills) to avoid context bloat
- Reference skills should have `user-invocable: false` in their frontmatter
- User-invocable skills can also be listed but will add to context size

## Production Agents (16)

| Agent | Model | Category | Skills |
|-------|-------|----------|--------|
| accessibility-auditor | haiku | quality | - |
| architect | opus | architecture | `api-design-patterns` |
| backend-engineer | sonnet | development | `api-design-patterns` |
| code-reviewer | sonnet | quality | `git-conventions`, `security-checklist` |
| data-engineer | sonnet | development | - |
| debugger | sonnet | development | - |
| devops | sonnet | infrastructure | `git-conventions` |
| feature-agent | opus | orchestration | `feature-lifecycle` |
| frontend-engineer | sonnet | development | - |
| ml-engineer | sonnet | development | - |
| mobile-engineer | sonnet | development | - |
| researcher | sonnet | analysis | - |
| security-auditor | sonnet | security | `security-checklist` |
| tech-writer | haiku | quality | `markdown-linting` |
| test-engineer | sonnet | quality | `testing-patterns` |
| codex-delegate | sonnet | development | - |
