# Aggressive Delegation Compliance

## Overview

This document defines the aggressive delegation model introduced with Opus 4.6 updates. The core principle is
**delegate by default** - Claude should only handle tasks directly when ALL Level 1 criteria are met.

## The 37-Agent Ecosystem

### Model Distribution

| Model | Count | Agents | Use Case |
|-------|-------|--------|----------|
| Opus 4.6 | 4 | principal-architect, project-orchestrator, result-arbitrator, career-strategist | Maximum reasoning depth |
| Sonnet 4.6 | 33 | All others | Standard development with enhanced reasoning |

### Extended Thinking Distribution

| Level | Tokens | Agents | Use Case |
|-------|--------|--------|----------|
| ultrathink | 31,999 | principal-architect, project-orchestrator, result-arbitrator | System-wide architecture, enterprise planning |
| megathink | 10,000 | backend-engineer, cloud-architect, api-architect | Domain expertise, complex optimization |
| think harder | 8,000 | devops, code-reviewer | Focused analysis, specific optimizations |

## Key Delegation Rules

### Rule 1: Delegate by Default

Only handle directly if ALL of these are true:

- Task has clear, deterministic steps
- Can be completed in under 5 minutes
- Requires no specialized domain expertise
- Involves fewer than 3 files with simple changes
- No exploration or discovery needed

### Rule 2: Deploy 2+ Agents in Parallel

For ANY task beyond trivial:

- Never deploy a single agent for complex work
- Include at least 1 quality agent (reviewer/tester/auditor)
- When in doubt, delegate - cost of missing expertise > cost of delegation

### Rule 3: Use the Routing Table

Keywords in the user's request should trigger specific agent combinations:

| Keywords | Deploy |
|----------|--------|
| debug, fix, broken, error, bug | debugger + test-engineer |
| slow, performance, optimize | performance-engineer + backend-engineer |
| review, check, audit | code-reviewer + security-auditor |
| test, coverage, spec | test-engineer + code-reviewer |
| deploy, ci, pipeline, docker | devops + platform-engineer |
| api, endpoint, graphql | api-architect + backend-engineer |
| database, query, migration | database-admin + backend-engineer |
| security, vulnerability | security-auditor + code-reviewer |
| architecture, design, scale | principal-architect + codebase-analyst |

### Rule 4: Auto-Triggers

Deploy agents automatically when conditions are met:

- **After ANY code change**: code-reviewer
- **3+ files touched**: + codebase-analyst
- **Security-sensitive files** (.env, auth, crypto): + security-auditor
- **New feature implementation**: principal-architect + relevant engineers
- **Bug report or error**: debugger + test-engineer
- **Performance-related code**: + performance-engineer

## Validation Checklist

Run these checks to verify compliance:

- [ ] CLAUDE.md contains Agent Routing table
- [ ] CLAUDE.md contains Auto-Triggers section
- [ ] Agent descriptions use "Triggers on" keyword patterns
- [ ] Commands reference correct 37-agent ecosystem size
- [ ] Thinking-level values match thinking-tokens counts
- [ ] All 37 agents are listed in AGENT_CATEGORIES.md

## Testing Compliance

### Automated Validation

```bash
# Validate agent YAML and trigger patterns
python3 scripts/validate-agent-yaml.py

# Run agent audit for ecosystem health
/agent-audit

# Run command audit for ecosystem references
/command-audit
```

### Manual Verification

1. Check CLAUDE.md has the routing table in system-configs/CLAUDE.md
2. Verify agent count is 37 in all documentation
3. Confirm model distribution: 4 Opus, 33 Sonnet
4. Check all "MUST BE USED" agents have "Triggers on" patterns

## Reference Files

| File | Purpose |
|------|---------|
| `system-configs/CLAUDE.md` | Core routing table and delegation rules |
| `docs/agents/AGENT_SELECTION_GUIDE.md` | Detailed agent selection guidance |
| `docs/agents/AGENT_CATEGORIES.md` | Category definitions and counts |
| `docs/agents/AGENT_TEMPLATE.md` | Agent creation template |
| `scripts/validate-agent-yaml.py` | Automated validation script |

## Change History

- **February 2026**: Updated model references for Opus 4.6
- **November 2025**: Introduced aggressive delegation model with Opus 4.5 updates
- Added result-arbitrator agent for multi-agent conflict resolution
- Updated thinking levels on backend-engineer, devops, code-reviewer
- Added natural language "Triggers on" patterns to all agent descriptions
