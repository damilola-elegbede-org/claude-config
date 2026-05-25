---
name: docs
description: Documentation generation and updates. Use when creating or updating documentation.
argument-hint: "[scope|--audit|--full|--clean]"
context: fork
metadata:
  category: workflow
---

# /docs

## Usage

```bash
/docs                    # Update docs based on recent changes
/docs --audit            # Analyze documentation gaps
/docs --full             # Comprehensive scan and update of all docs
/docs --clean            # Organize temp docs to .tmp/
/docs api                # API documentation only
/docs readme             # README.md refresh
/docs architecture       # System design docs
/docs setup              # Installation/setup docs
```

## Description

Generate and update documentation using tech-writer agent. Simple updates handled directly; comprehensive docs delegated to agent.

## Protected Files

**NEVER** touches CLAUDE.md files at any location.

## Behavior

### Analysis Phase

1. **Branch Comparison**: Run `git diff main..HEAD` to identify all changes on this branch
2. **Include Staged/Unstaged**: Also check `git diff` and `git diff --staged` for uncommitted work
3. **Cross-Reference Docs**: Compare changes against existing documentation to identify gaps
4. **Determine Scope**: Prioritize undocumented new functionality, API changes, and configuration updates

### Generation Phase

1. **Generate**: Create new documentation for gaps identified
2. **Update**: Refresh existing docs affected by changes
3. **Organize**: Place docs in appropriate locations

### Skip Conditions

Documentation is skipped when ALL of these are true:

- No changes detected on branch vs main
- No uncommitted changes
- Existing documentation covers current functionality

### Modes

| Mode | Action |
|------|--------|
| Default | Update docs for recent changes |
| `--audit` | Report gaps without changes |
| `--full` | Comprehensive scan - generate/update all documentation |
| `--clean` | Move temp docs to .tmp/ |
| Focused | Update specific scope only |

## When Docs Are Skipped

| Condition | Result |
|-----------|--------|
| No branch changes AND no uncommitted changes | Skip - nothing to document |
| Changes exist but all are already documented | Skip - docs are current |
| `--audit` mode | Never skips - always reports |
| `--full` mode | Never skips - scans entire codebase |
| Focused scope (e.g., `/docs readme`) | Runs for that scope regardless |

## Expected Output

```text
User: /docs readme

Analyzing README.md...

Deploying tech-writer agent...

README.md updated:
  - Updated installation steps for Node 18+
  - Added new API endpoint examples
  - Fixed 3 broken links
```

### Audit Mode

```text
User: /docs --audit

Documentation Gap Analysis

Missing:
  - 5 API endpoints undocumented
  - Architecture diagrams missing
  - No deployment guide

Outdated:
  - README installation steps (Node 16 → 18)
  - API auth docs reference old OAuth flow

Run `/docs api` or `/docs readme` to fix
```

### Full Scan Mode

For comprehensive documentation, `/docs --full` can leverage parallel execution:

```yaml
Parallel Execution Strategy:
  # When multiple doc sections need updates, deploy tech-writers in parallel

  Phase 1 - Analysis (sequential):
    - Scan codebase for documentation gaps
    - Identify sections: API, Architecture, Setup, README

  Phase 2 - Generation (parallel):
    # Launch multiple tech-writers in SINGLE message for parallel execution
    - tech-writer: "Generate API documentation"
    - tech-writer: "Generate architecture documentation"
    - tech-writer: "Update setup guides"

  Phase 3 - Synthesis (sequential):
    - Verify consistency across docs
    - Update cross-references
    - Report summary
```

```text
User: /docs --full

Comprehensive documentation scan...

Deploying tech-writer agents in parallel...

Analysis complete:
  - 12 source files scanned
  - 3 new docs to create
  - 5 existing docs to update

Documentation updated:
  - Created docs/api/endpoints.md
  - Created docs/architecture/overview.md
  - Created docs/setup/configuration.md
  - Updated README.md
  - Updated docs/api/authentication.md
  - Updated CONTRIBUTING.md
  - Updated docs/commands/overview.md
  - Updated docs/agents/overview.md
```

### Comprehensive Update

```text
User: /docs api

Analyzing API documentation needs...
  Found 8 undocumented endpoints

Deploying tech-writer agent...

Generated:
  - docs/api/README.md (endpoint overview)
  - docs/api/authentication.md (auth flows)
  - docs/api/openapi.yaml (OpenAPI 3.0 spec)
```

## Notes

- Uses tech-writer agent for comprehensive docs
- Simple updates (typos, versions) handled directly
- CLAUDE.md files explicitly protected
- Typical execution: 1-5 minutes
