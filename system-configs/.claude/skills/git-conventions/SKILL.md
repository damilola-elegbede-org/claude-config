---
name: git-conventions
description: Branch naming conventions, conventional commit standards, and PR best practices for consistent git workflows.
user-invocable: false
metadata:
  category: workflow
---

# Git Conventions Reference

## Branch Naming

### Prefix Rules

| Prefix | Use When |
|--------|----------|
| `feature/` | New functionality, ticket implementations, component additions |
| `fix/` | Bug fixes, issue resolutions, error corrections |
| `hotfix/` | Critical production fixes requiring immediate deployment |
| `chore/` | Maintenance tasks, dependency updates, tooling changes |
| `docs/` | Documentation-only changes |
| `refactor/` | Code restructuring without behavior changes |
| `enhancement/` | Performance improvements, optimizations |
| `experiment/` | Prototypes, spikes, proof-of-concept work |

### Naming Format

- Use **kebab-case** for descriptions: `feature/user-dashboard`, `fix/auth-token-refresh`
- Lowercase only, no special characters except hyphens
- Limit branch name to 50 characters
- Include ticket numbers when available: `feature/jira-1234-user-management`

### Pattern Detection Examples

```text
"user-dashboard"       -> feature/user-dashboard
"fix-auth-bug"         -> fix/auth-bug
"JIRA-123"             -> feature/jira-123
"hotfix-data-loss"     -> hotfix/data-loss
"refactor-api-layer"   -> refactor/api-layer
"poc-new-auth"         -> experiment/new-auth
```

## Conventional Commits

### Format

```text
<type>(<scope>): <subject>

<body>

<footer>
```

### Valid Types

| Type | Purpose | Example |
|------|---------|---------|
| `feat` | New feature | `feat(auth): add OAuth2 login` |
| `fix` | Bug fix | `fix(api): resolve null pointer in validation` |
| `docs` | Documentation only | `docs(readme): update installation steps` |
| `style` | Formatting, no logic change | `style(lint): fix ESLint warnings` |
| `refactor` | Code change, no new feature or fix | `refactor(db): extract query builder` |
| `test` | Adding or updating tests | `test(auth): add JWT refresh tests` |
| `chore` | Maintenance, tooling | `chore(deps): update dependencies` |
| `perf` | Performance improvement | `perf(query): add database index` |
| `ci` | CI/CD changes | `ci(actions): add caching to build` |

### Subject Rules

- Maximum **72 characters**
- Use **imperative mood**: "add feature" not "added feature" or "adds feature"
- No period at the end
- Lowercase first letter after type prefix
- Clear and specific: describe what changed, not how

### Body Guidelines

- Separate from subject with blank line
- Wrap at 72 characters
- Explain **what** and **why**, not how
- Use bullet points for multiple changes

### Footer

- Reference issues: `Closes #123`, `Fixes #456`
- Note breaking changes: `BREAKING CHANGE: removed legacy endpoint`
- Claude Code attribution (always include):

```text
Co-Authored-By: Claude <noreply@anthropic.com>
```

## Pull Request Standards

### Title Format

- Follow conventional commit format: `type(scope): description`
- Keep under **70 characters**
- Use the primary change type when commits are mixed

### Description Template

```markdown
## Summary
[1-2 sentence overview of the changes]

## Changes
- [Key change 1]
- [Key change 2]
- [Key change 3]

## Context
[Why these changes were made]

## Testing
[What testing was done or tests added]

## Related Issues
Closes #123
```

### PR Workflow

- Use `--draft` for work-in-progress PRs
- Target `main` branch by default
- Check for existing PRs before creating duplicates
- Include test plan in description

### CodeRabbit Acknowledgment

When local review identifies issues that are intentionally deferred:

- Track in `.tmp/coderabbit-ignored.json`
- Post acknowledgment comment on PR creation
- Format: grouped by category with location, issue, and reason columns
- Tag `@coderabbitai` to signal reviewed status

## Co-Author Attribution

All Claude-assisted commits include:

```text
Co-Authored-By: Claude <noreply@anthropic.com>
```

This goes in the commit message footer, after any body content and issue references.
