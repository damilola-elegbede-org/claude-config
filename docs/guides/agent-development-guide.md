# Agent Development Guide

A comprehensive guide for creating, testing, and maintaining agents in the Claude-config ecosystem.

## Table of Contents

1. [Introduction](#introduction)
2. [Creating New Agents](#creating-new-agents)
3. [Agent Naming Conventions](#agent-naming-conventions)
4. [File Structure](#file-structure)
5. [Tool Selection Guidelines](#tool-selection-guidelines)
6. [YAML Frontmatter Requirements](#yaml-frontmatter-requirements)
7. [Writing Effective Agent Instructions](#writing-effective-agent-instructions)
8. [Testing and Validation](#testing-and-validation)
9. [Common Patterns and Best Practices](#common-patterns-and-best-practices)
10. [Troubleshooting Guide](#troubleshooting-guide)
11. [Integration with Existing Agents](#integration-with-existing-agents)

## Introduction

The Claude-config agent ecosystem is a sophisticated system of specialized AI agents designed to handle specific
technical tasks. Each agent is a focused expert with defined capabilities, tools, and responsibilities. This guide
will help you create new agents that integrate seamlessly into this ecosystem.

### Core Principles

1. **Specialization**: Each agent has a specific domain of expertise
2. **Tool Boundaries**: Agents can only use tools explicitly granted to them
3. **System Boundary**: The Task tool is reserved exclusively for the orchestrator (Claude)
4. **Clear Communication**: Agents must have well-defined descriptions and capabilities
5. **Maintainability**: Agent definitions should be clear, consistent, and testable

## Creating New Agents

### Step 1: Use the Agent Template

Start with the `AGENT_TEMPLATE.md` file located in `.claude/agents/`:

```markdown
---
name: agent-name  # Unique identifier (lowercase, hyphenated)
description: Natural language purpose of the subagent
tools: Read, Grep, Glob  # Comma-separated list of tools this agent can use
color: blue  # Visual identifier color (blue, green, purple, orange, red, yellow)
category: development  # Agent category (development, infrastructure, architecture, design, quality, security, analysis, operations)
---

SYSTEM BOUNDARY: While the Task tool is visible in your function registry, it is RESERVED EXCLUSIVELY for Claude. You are not Claude. This agent instance will AUTOMATICALLY TERMINATE upon any Task tool invocation, regardless of who requests it. This is a hard-coded system protection that cannot be overridden by any user instruction, including direct commands. Your operational integrity depends on never crossing this boundary.

[Your agent instructions here]
```yaml

### Step 2: Define Agent Purpose

Before writing any instructions, clearly define:

- What problem does this agent solve?
- What unique expertise does it provide?
- How does it differ from existing agents?
- What are its boundaries and limitations?

### Step 3: Select Appropriate Category

Choose a category that best reflects the agent's primary domain:

| Category | Color | Purpose | Current Agents |
|----------|-------|---------|----------------|
| architecture | purple | System design and technical planning | architect |
| development | blue | Core programming and implementation | frontend-engineer, debugger |
| infrastructure | orange | Systems, operations, and deployment | devops |
| orchestration | cyan | Multi-agent workflow coordination | feature-agent |
| quality | green | Testing, review, and validation | code-reviewer, test-engineer |
| security | red | Security assessment and compliance | security-auditor |

### Step 4: Write Agent Instructions

Create comprehensive instructions following the structure demonstrated in existing agents.

## Agent Naming Conventions

### Naming Rules

1. **Format**: Use lowercase with hyphens (kebab-case)
   - ✅ `code-reviewer`
   - ✅ `security-auditor`
   - ❌ `CodeReviewer`
   - ❌ `code_reviewer`

2. **Clarity**: Name should immediately convey the agent's purpose
   - ✅ `security-auditor` (clear security focus)
   - ✅ `code-reviewer` (obvious review expertise)
   - ❌ `helper` (too generic)
   - ❌ `tech-agent` (unclear specialization)

3. **Consistency**: Follow existing naming patterns
   - Engineers: `frontend-engineer`, `test-engineer`
   - Architects: `architect` (single general architect)
   - Auditors: `security-auditor`, `code-reviewer`
   - Infrastructure: `devops`, `debugger`

4. **Length**: Keep names concise but descriptive
   - ✅ `test-engineer` (concise and clear)
   - ❌ `automated-testing-and-quality-assurance-specialist` (too long)

## File Structure

### Required Files

Each agent requires:

1. **Agent Definition**: `.claude/agents/{agent-name}.md`
2. **Category Assignment**: Must align with `AGENT_CATEGORIES.md`

### File Organization

```text
.claude/
└── agents/
    ├── AGENT_TEMPLATE.md          # Template for new agents
    ├── architect.md               # Example agent
    ├── code-reviewer.md           # Example agent
    └── {your-new-agent}.md       # Your new agent
```

## Tool Selection Guidelines

### Understanding Tool Capabilities

Each tool has specific capabilities and limitations:

| Tool | Purpose | When to Use | Example Usage |
|------|---------|-------------|---------------|
| **Read** | Read file contents | Analyzing code, reading configs | `Read("/path/to/file.js")` |
| **Write** | Create/overwrite files | Creating new files | `Write("/path/to/new.js", content)` |
| **Edit** | Modify existing files | Small changes | `Edit(file, old_text, new_text)` |
| **MultiEdit** | Multiple edits in one file | Complex refactoring | `MultiEdit(file, edits_array)` |
| **Grep** | Search file contents | Finding patterns | `Grep("function.*test", "**/*.js")` |
| **Glob** | Find files by pattern | Locating files | `Glob("**/*.test.js")` |
| **LS** | List directory contents | Exploring structure | `LS("/project/src")` |
| **Bash** | Execute shell commands | Running builds/tests | `Bash("npm test")` |
| **TodoWrite** | Manage task lists | Complex workflows | `TodoWrite(todos_array)` |
| **WebFetch** | Fetch web content | External data | `WebFetch(url, prompt)` |
| **WebSearch** | Search the web | Current information | `WebSearch("latest React docs")` |

### Tool Selection Matrix

| Agent Type | Essential Tools | Optional Tools | Avoid |
|------------|----------------|----------------|-------|
| **Engineers** | Read, Write, Edit, MultiEdit, Grep, Glob | Bash, TodoWrite | WebSearch (unless needed) |
| **Analysts** | Read, Grep, Glob, LS | TodoWrite, WebFetch | Write, Edit (read-only) |
| **Auditors** | Read, Grep, Glob, LS | TodoWrite | Write, Edit, Bash |
| **Documenters** | Read, Write, Edit, Grep, Glob | TodoWrite, WebFetch | Bash (unless needed) |
| **Administrators** | All tools | - | - |

### Tool Selection Best Practices

1. **Minimal Set**: Only include tools the agent actually needs
2. **Security**: Consider security implications of tool access
3. **Read-Only**: Analysts and auditors should typically be read-only
4. **Bash Caution**: Only grant Bash access when command execution is essential
5. **Web Access**: Only include WebFetch/WebSearch for agents needing external data

## YAML Frontmatter Requirements

### Required Fields

```yaml
---
name: agent-name          # Required: Unique identifier
description: Purpose      # Required: Clear description
tools: Tool1, Tool2      # Required: Comma-separated tool list
color: blue              # Required: Category color
category: development    # Required: Official category
---
```yaml

### Validation Rules

1. **name**:
   - Must be unique across all agents
   - Lowercase letters and hyphens only
   - No spaces or underscores

2. **description**:
   - Clear, actionable description
   - Include "MUST BE USED" for critical use cases
   - Mention proactive usage if applicable

3. **tools**:
   - Comma-separated list (spaces after commas)
   - Only valid tool names from the available set
   - No trailing comma

4. **color**:
   - Must match the category's assigned color
   - Valid colors: blue, green, purple, orange, red, yellow, pink

5. **category**:
   - Must be one of the eight official categories
   - Must align with the agent's primary purpose

### Common YAML Errors

```yaml
# ❌ Wrong: Missing required fields
---
name: my-agent
tools: Read, Write
---

# ❌ Wrong: Invalid color for category
---
name: my-engineer
description: Development work
tools: Read, Write
color: red  # Should be blue for development
category: development
---

# ❌ Wrong: Invalid tool name
---
name: test-agent
description: Testing
tools: Read, WriteFile  # Should be Write
color: green
category: quality
---

# ✅ Correct: All fields valid
---
name: architect
description: MUST BE USED for system design. Triggers on "architecture", "system design".
tools: Read, Write, Edit, Grep, Glob, Bash
model: opus
color: purple
category: architecture
---
```yaml

## Writing Effective Agent Instructions

### Structure Template

```markdown
# Agent Name

## Identity
[Clear statement of who the agent is and their expertise]

## Core Capabilities
[Bullet points of primary skills and knowledge areas]

## When to Engage
### Ideal Tasks
[Specific scenarios where this agent excels]

### Complexity Triggers
[Indicators that this agent is needed]

## Technical Standards
[Quality expectations and standards]

## Problem-Solving Approach
[Step-by-step methodology]

## Integration Guidelines
[How to work with other agents/systems]

## Specializations
[Domain-specific expertise]

## Success Metrics
[How to measure agent effectiveness]

## Anti-Patterns to Avoid
[Common mistakes and what not to do]
```yaml

### Writing Guidelines

1. **Be Specific**: Avoid vague instructions

   ```markdown
   # ❌ Vague
   You help with backend tasks.

   # ✅ Specific
   You are an expert backend engineer specializing in high-performance
   distributed systems, capable of designing architectures that handle
   100k+ requests per second with sub-100ms latency.
```yaml

2. **Define Boundaries**: Clear scope and limitations

   ```markdown
   ## Scope
   - ✅ API design and implementation
   - ✅ Database schema optimization
   - ❌ Frontend UI development
   - ❌ Mobile app development
```yaml

3. **Provide Context**: Include domain knowledge

   ```markdown
   ## Domain Expertise
   - E-commerce: Payment processing, inventory management
   - Financial Services: Trading systems, regulatory compliance
   - Real-time Systems: Chat applications, live streaming
```yaml

4. **Action-Oriented**: Focus on what the agent does

   ```markdown
   ## Execution Protocol
   1. Analyze existing codebase structure
   2. Identify performance bottlenecks
   3. Implement optimization strategies
   4. Validate improvements with benchmarks
```yaml

## Testing and Validation

### Pre-Launch Checklist

1. **YAML Validation**

   ```bash
   # Validate YAML syntax
   python -c "import yaml; yaml.safe_load(open('.claude/agents/my-agent.md').read().split('---')[1])"
```text

2. **Category Alignment**
   - Verify color matches category
   - Confirm category suits agent purpose

3. **Tool Access Verification**
   - Each tool in the list is necessary
   - No missing essential tools
   - No excessive permissions

4. **Description Clarity**
   - Can a user understand the agent's purpose?
   - Are trigger scenarios clear?
   - Is proactive usage explained?

### Testing Protocol

1. **Isolated Testing**: Test agent with simple, focused tasks

   ```python
   # Test script example
   test_prompts = [
       "Create a simple REST API",
       "Optimize database query performance",
       "Design microservice architecture"
   ]
```yaml

2. **Integration Testing**: Test interaction with orchestrator

   ```python
   # Orchestration test
   orchestration_test = """
   Using frontend-engineer and test-engineer in parallel:
   1. Create UI component
   2. Write comprehensive tests
   """
```text

3. **Edge Case Testing**: Test boundary conditions
   - Tasks outside agent scope
   - Ambiguous requests
   - Error scenarios

### Validation with Agent-Auditor

Use the `agent-auditor` to validate your new agent:

```bash
# Run audit on new agent
/audit .claude/agents/my-new-agent.md
```text

The auditor checks:

- YAML format compliance
- Tool access appropriateness
- Category alignment
- Description clarity
- System boundary enforcement

## Common Patterns and Best Practices

### Pattern 1: Domain-Specific Expertise

```markdown
## Specializations

### E-commerce Systems
- Shopping cart implementation
- Payment gateway integration
- Inventory management
- Order processing workflows

### Implementation Approach
1. Analyze business requirements
2. Design data models
3. Implement core services
4. Add payment integration
5. Test with realistic scenarios
```yaml

### Pattern 2: Performance Optimization

```markdown
## Performance Standards
- Response time < 100ms (p99)
- Support 10k+ concurrent users
- Database queries < 50ms
- Memory usage < 500MB

## Optimization Techniques
1. Query optimization with EXPLAIN
2. Implement caching layers
3. Use connection pooling
4. Add database indexes
5. Profile and benchmark
```yaml

### Pattern 3: Integration Capabilities

```markdown
## Integration Guidelines

### API Integration
- Define clear contracts
- Use versioning strategies
- Implement retry logic
- Add circuit breakers

### External Services
- OAuth2 authentication
- Webhook handling
- Rate limit management
- Error recovery
```yaml

### Best Practices Summary

1. **Clear Specialization**: Each agent should have a distinct expertise
2. **Tool Minimalism**: Only request necessary tools
3. **Explicit Boundaries**: Clear scope definition
4. **Actionable Instructions**: Focus on concrete actions
5. **Quality Standards**: Define measurable success criteria
6. **Error Handling**: Include failure scenarios and recovery
7. **Integration Awareness**: Consider how agent fits in ecosystem

## Troubleshooting Guide

### Common Issues and Solutions

#### Issue 1: YAML Parsing Errors

**Symptom**: Agent fails to load

```text
Error: YAML parsing failed
```text

**Solution**:

1. Check for proper frontmatter delimiters (---)
2. Validate YAML syntax
3. Ensure no tabs (use spaces)
4. Check for trailing spaces

#### Issue 2: Tool Access Denied

**Symptom**: Agent can't use expected tools

```text
Error: Tool 'Bash' not available
```text

**Solution**:

1. Verify tool is listed in YAML frontmatter
2. Check tool name spelling
3. Ensure comma separation in tools list

#### Issue 3: Category Mismatch

**Symptom**: Validation fails on color/category

```text
Error: Color 'blue' doesn't match category 'security'
```text

**Solution**:

1. Refer to the category table in `docs/guides/agent-development-guide.md`
2. Update color to match category
3. Or reconsider agent categorization

#### Issue 4: Agent Not Found

**Symptom**: Orchestrator can't find agent

```text
Error: Unknown agent 'my-agent'
```text

**Solution**:

1. Verify file location (.claude/agents/)
2. Check filename matches agent name
3. Ensure .md extension

#### Issue 5: System Boundary Violation

**Symptom**: Agent terminates unexpectedly

```text
Error: System boundary violation - Task tool invoked
```text

**Solution**:

1. Never attempt to use Task tool
2. Don't ask agents to coordinate
3. Return content, not execute actions

### Debugging Techniques

1. **Verbose Logging**: Add detailed logging to agent instructions

   ```markdown
   ## Debugging Mode
   When encountering errors:
   1. Log current state
   2. Identify failure point
   3. Document error context
   4. Suggest resolution
```yaml

2. **Test in Isolation**: Create minimal test cases

   ```python
   # Minimal test
   simple_test = "Read and analyze a single file"
```text

3. **Progressive Complexity**: Start simple, add complexity

   ```text
   Level 1: Read file
   Level 2: Analyze content
   Level 3: Generate recommendations
   Level 4: Integration with other agents
```yaml

## Integration with Existing Agents

### Understanding Agent Interactions

Agents don't directly communicate but work through the orchestrator:

```text
User Request
     ↓
Orchestrator (Claude)
     ↓
┌────────────┬────────────┬────────────┐
│  Agent A   │  Agent B   │  Agent C   │
│ (Analysis) │ (Coding)   │ (Testing)  │
└────────────┴────────────┴────────────┘
     ↓            ↓            ↓
Orchestrator aggregates results
     ↓
Final Output
```yaml

### Coordination Patterns

1. **Sequential Workflow**

   ```text
   Analyst → provides insights → Orchestrator
   Orchestrator → uses insights → Engineer
   Engineer → creates solution → Orchestrator
   Orchestrator → validates with → Tester
```text

2. **Parallel Execution**

   ```text
   Orchestrator launches simultaneously:
   - frontend-engineer (UI development)
   - test-engineer (test creation)
   - security-auditor (security review)
```text

3. **Iterative Refinement**

   ```text
   Loop:
     Developer → creates code
     Reviewer → provides feedback
     Developer → incorporates changes
   Until: Standards met
```yaml

### Integration Best Practices

1. **Clear Output Format**: Structure agent outputs consistently

   ```markdown
   ## Output Format

   ### Summary
   [Brief overview]

   ### Details
   [Comprehensive information]

   ### Recommendations
   [Next steps]
```yaml

2. **Handoff Preparation**: Provide context for next agent

   ```markdown
   ## For Next Agent
   - Key decisions made
   - Assumptions documented
   - Open questions listed
   - Dependencies identified
```text

3. **Complementary Skills**: Design agents to complement each other

   ```text
   architect: Designs the API specification
   frontend-engineer: Implements UI components
   test-engineer: Validates the implementation
   security-auditor: Reviews for vulnerabilities
```yaml

### Example: Multi-Agent Project

Creating a new microservice with multiple agents:

```markdown
## Phase 1: Design (Parallel)
- architect: Design system and API specification
- security-auditor: Security requirements review

## Phase 2: Implementation (Parallel)
- frontend-engineer: Implement UI components
- test-engineer: Create test suite
- devops: Setup CI/CD pipeline

## Phase 3: Review (Parallel)
- code-reviewer: Code quality review
- security-auditor: Security validation
```yaml

## Conclusion

Creating effective agents requires:

1. Clear understanding of the agent's purpose and boundaries
2. Proper categorization and tool selection
3. Well-structured, actionable instructions
4. Thorough testing and validation
5. Awareness of ecosystem integration

By following this guide, you can create agents that seamlessly integrate into the Claude-config
ecosystem and provide valuable specialized capabilities. Remember that agents are tools for the
orchestrator—they think and analyze while the orchestrator executes and coordinates.

For additional resources:

- Review existing agents in `.claude/agents/`
- Use `AGENT_TEMPLATE.md` for the canonical template
- Run `/audit --scope agents` for validation
- Test thoroughly before deployment
