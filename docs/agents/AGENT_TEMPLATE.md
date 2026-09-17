---
# AGENT TEMPLATE - PRODUCTION READY
#
# This template matches the pattern used by 15 production agents
# Target length: 30-50 lines (not 180+)
#
# Model selection — `model:` is OPTIONAL. Precedence: model named in the spawn
# call > agent `model:` > settings.json env.CLAUDE_CODE_SUBAGENT_MODEL > session model.
# - omit it (DEFAULT): uses the settings.json subagent model (sonnet today), so
#   one settings line moves every such agent
#   * code-reviewer, debugger, devops, frontend-engineer, test-engineer
# - inherit: follows the session's model (sonnet by default)
#   * architect (system-wide design), feature-agent (orchestration),
#     security-auditor (adversarial review)
# - opus/sonnet/haiku/fable: a fixed pin that ignores settings.json — only for a
#   deliberate cost or capability pin
#
# Reasoning depth is controlled by model + effort now (settings.json
# modelSettings.<model>.effortLevel, or --effort per session), not per-agent
# frontmatter. There is no per-agent thinking-level/thinking-tokens field.
#
# Fill in ALL placeholders. Delete these comments before use.
#
name: agent-name # lowercase-hyphenated
description: Use for [specific trigger], [domain] tasks. Triggers on "[keyword1]", "[keyword2]", "[keyword3]".
tools: Read, Write, Edit, Grep, Glob, Bash # Only include what's needed
# model: inherit # OPTIONAL: omit for the settings.json subagent model - see guide above
category: development # development, quality, security, architecture, design, analysis, infrastructure, coordination - See docs/agents/AGENT_CATEGORIES.md for canonical list
color: blue # Must match category color - see AGENT_CATEGORIES.md
# permissionMode: plan  # OPTIONAL: plan / acceptEdits / default / dontAsk / bypassPermissions
# memory: project        # OPTIONAL: project / local / user - persistent agent memory
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

## Complexity Factors - OPTIONAL SECTION

This agent requires deep reasoning due to:

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

| Field         | Description                       | Example                               |
| ------------- | --------------------------------- | ------------------------------------- |
| `name`        | Lowercase-hyphenated identifier   | `code-reviewer`                       |
| `description` | Trigger description with keywords | `Use for...`                          |
| `tools`       | Comma-separated tool list         | `Read, Write, Edit, Grep, Glob, Bash` |
| `category`    | Agent category                    | `development`, `quality`, `security`  |
| `color`       | Category color                    | `blue`, `green`, `red`                |

### Optional Fields

| Field            | Description                                          | Values                                                           | Example   |
| ---------------- | ---------------------------------------------------- | ---------------------------------------------------------------- | --------- |
| `permissionMode` | Permission behavior                                  | `plan`, `acceptEdits`, `default`, `dontAsk`, `bypassPermissions` | `plan`    |
| `memory`         | Persistent memory scope                              | `project`, `local`, `user`                                       | `project` |
| `model`          | Model (omit to use the settings.json subagent model) | `inherit`, `opus`, `sonnet`, `haiku`, `fable`                    | `inherit` |

### The `skills` Field

The `skills` field preloads reference skill content into the agent's context at startup. This gives
the agent immediate access to domain-specific guidelines, checklists, and patterns without requiring
the user to invoke those skills separately.

**Syntax:**

```yaml
skills: feature-lifecycle
```

**How it works:**

1. When the agent is spawned, Claude Code reads the SKILL.md files for each listed skill
2. The skill content is injected into the agent's system prompt
3. The agent can reference this knowledge throughout its session

**Current agent-skill mappings:**

| Agent | Preloaded Skills |
| ----- | ---------------- |

**Available reference skills** (all have `user-invocable: false`):

- `markdown-linting` - Markdownlint rules, documentation formatting

**Best practices:**

- Only preload skills relevant to the agent's core domain
- Keep the list short (1-2 skills) to avoid context bloat
- Reference skills should have `user-invocable: false` in their frontmatter
- User-invocable skills can also be listed but will add to context size

## Production Agents (8)

| Agent             | Model   | Category      | Skills              |
| ----------------- | ------- | ------------- | ------------------- |
| debugger          | default | development   | -                   |
| feature-agent     | inherit | orchestration | `feature-lifecycle` |
| frontend-engineer | default | development   | -                   |
