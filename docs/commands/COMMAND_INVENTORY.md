# Skills Inventory

Complete inventory of 34 skills across 6 categories.

## Summary

| Category | Count | Examples |
|----------|-------|---------|
| Orchestration | 3 | `/deps`, `/resolve-comments`, `/land` |
| Git Workflow | 6 | `/branch`, `/commit`, `/push`, `/pr` |
| Utility | 2 | `/audit`, `/verify` |
| Imported (Anthropic) | 8 | `pdf`, `docx`, `webapp-testing` |
| **Total** | **37** | counting vendored and shared skill folders |

All 21 former commands have been migrated to skills. There are **0 commands** remaining.

## Orchestration Skills

Multi-phase workflows with task tracking, parallel execution, and agent routing.

| Skill | Description | Execution Model | Flags |
|-------|-------------|-----------------|-------|
| `/deps` | Dependency management | Wave-based | `audit`, `update`, `clean`, `--quick` |
| `/resolve-comments` | CodeRabbit comment resolution | Wave-based | `--auto`, `--dry-run` |

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

## Utility Skills

| Skill | Description | Execution Model | Flags |
|-------|-------------|-----------------|-------|
| `/audit` | Unified agent/skill validation | Wave-based | `--scope agents\|skills\|all`, `--fix` |
| `/verify` | Skill verification | Hybrid | `--last`, `--command`, `--depth` |

## Agent-Preloaded Reference Skills (5)

Reference material injected into agent contexts. Not user-invocable (`user-invocable: false`).

| Skill | Preloaded By | Purpose |
|-------|-------------|---------|
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
| `/implementation-plan` | none (`/plan` was removed too) | Ask in plain language |
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
# Branch, commit, open the PR and follow it to mergeable
/branch add-oauth
/commit
/pr
```

### Quality Workflow

```bash
# Full audit
/audit --scope all
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
