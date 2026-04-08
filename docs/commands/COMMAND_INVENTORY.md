# Skills Inventory

Complete inventory of 34 skills across 6 categories.

## Summary

| Category | Count | Examples |
|----------|-------|---------|
| Orchestration | 7 | `/ship-it`, `/review`, `/fix-ci`, `/implement` |
| Agent-Routed | 4 | `/debug`, `/plan`, `/prime`, `/docs` |
| Git Workflow | 6 | `/branch`, `/commit`, `/push`, `/pr` |
| Utility | 4 | `/test`, `/audit`, `/prompt`, `/verify` |
| Agent-Preloaded Reference | 5 | `git-conventions`, `security-checklist` |
| Imported (Anthropic) | 8 | `pdf`, `docx`, `webapp-testing` |
| **Total** | **34** | |

All 21 former commands have been migrated to skills. There are **0 commands** remaining.

## Orchestration Skills (7)

Multi-phase workflows with task tracking, parallel execution, and agent routing.

| Skill | Description | Execution Model | Flags |
|-------|-------------|-----------------|-------|
| `/ship-it` | Development workflow orchestration | Orchestrator | `-d`, `-t`, `-c`, `-r`, `-p`, `-pr`, `--dry-run` |
| `/review` | Comprehensive code review | Wave-based | `--full` |
| `/fix-ci` | CI failure diagnosis and fix | Wave-based | `--learn` |
| `/deps` | Dependency management | Wave-based | `audit`, `update`, `clean`, `--quick` |
| `/resolve-comments` | CodeRabbit comment resolution | Wave-based | `--auto`, `--dry-run` |
| `/implement` | Feature implementation from specs | Wave-based | `--spec`, `--tdd` |
| `/feature-lifecycle` | End-to-end feature delivery | Orchestrator | Agent team coordination |

## Agent-Routed Skills (4)

Skills that delegate execution to specialized agents.

| Skill | Description | Routed Agent | Flags |
|-------|-------------|--------------|-------|
| `/debug` | Root cause analysis | debugger | `--performance`, `--issue` |
| `/plan` | PRD and task file generation | architect | `--no-execute`, `--simple` |
| `/prime` | Repository understanding | Claude directly | `--lite`, `--full` |
| `/docs` | Documentation generation | Claude directly | `--audit`, `--audit-and-fix`, `--clean` |

## Git Workflow Skills (6)

Direct-execution skills for common git operations.

| Skill | Description | Execution Model |
|-------|-------------|-----------------|
| `/branch` | Create branches with intelligent naming | Direct |
| `/commit` | Git commits with message generation | Direct |
| `/push` | Push with validation | Direct |
| `/rebase` | Rebase on target branch | Direct |
| `/merge` | Merge branches with conflict handling | Direct |
| `/pr` | Create PRs with smart descriptions | Direct |

## Utility Skills (4)

| Skill | Description | Execution Model | Flags |
|-------|-------------|-----------------|-------|
| `/test` | Test discovery and execution | Hybrid | `--create`, `--framework`, `--coverage` |
| `/audit` | Unified agent/skill validation | Wave-based | `--scope agents\|skills\|all`, `--fix` |
| `/prompt` | Prompt optimization | Direct | `--file` |
| `/verify` | Skill verification | Hybrid | `--last`, `--command`, `--depth` |

## Agent-Preloaded Reference Skills (5)

Reference material injected into agent contexts. Not user-invocable (`user-invocable: false`).

| Skill | Preloaded By | Purpose |
|-------|-------------|---------|
| `git-conventions` | code-reviewer, devops | Git best practices, commit conventions |
| `security-checklist` | code-reviewer, security-auditor | OWASP checks, secure coding patterns |
| `testing-patterns` | test-engineer | TDD/BDD patterns, test organization |
| `api-design-patterns` | architect | REST/GraphQL patterns, OpenAPI |
| `markdown-linting` | (reference only — tech-writer removed) | Markdownlint rules, documentation formatting |

## Imported Anthropic Skills (8)

Skills imported from Anthropic's official skill library via `/skills-import`.

| Skill | Description | Source |
|-------|-------------|--------|
| `pdf` | PDF file reading and analysis | Anthropic |
| `docx` | Word document reading and analysis | Anthropic |
| `xlsx` | Excel spreadsheet reading and analysis | Anthropic |
| `pptx` | PowerPoint presentation reading and analysis | Anthropic |
| `webapp-testing` | Web application testing with browser automation | Anthropic |
| `skill-creator` | Create new skills from templates | Anthropic |
| `mcp-builder` | Build MCP server integrations | Anthropic |
| `frontend-design` | Frontend design patterns and implementation | Anthropic |

## Removed Commands (3)

The following commands were consolidated prior to the skills migration:

| Removed | Replacement | Migration |
|---------|-------------|-----------|
| `/implementation-plan` | `/plan --no-execute` | Use `--no-execute` flag |
| `/agent-audit` | `/audit --scope agents` | Use `--scope agents` |
| `/command-audit` | `/audit --scope commands` | Use `--scope commands` |

## Execution Models

### Direct

- Single-step execution
- No agent delegation
- Fast, deterministic

### Wave-based

- Multi-step orchestration
- Agent delegation
- Parallel execution support

### Hybrid

- Direct execution with optional agent delegation
- Streaming output
- Context-aware escalation

### Orchestrator

- Calls other skills
- Workflow coordination
- Sequential/parallel skill execution

## Usage Examples

### Development Workflow

```bash
# Plan without execution
/plan "Add user authentication" --no-execute

# Implement from spec
/implement auth-spec.md --tdd

# Debug with performance focus
/debug "Login fails silently" --performance

# End-to-end feature delivery
/feature-lifecycle "Add OAuth support"
```

### Quality Workflow

```bash
# Full audit
/audit --scope all

# Code review with full analysis
/review --full

# Test with coverage
/test --coverage
```

### Git Workflow

```bash
# Create feature branch
/branch add-oauth-support

# Merge main into current branch
/merge

# Merge specific branch with conflict strategy
/merge develop --theirs

# Commit changes
/commit

# Create PR
/pr main

# Push safely
/push
```

### Ship-It Workflow

```bash
# Full pipeline: test, commit, review, push, PR
/ship-it -t -c -r -p -pr

# Dry run to preview
/ship-it -t -c -p --dry-run
```
