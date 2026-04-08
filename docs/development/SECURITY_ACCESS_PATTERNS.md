# Security Access Patterns Documentation

## Agent Tool Access Security Framework

This document defines the security access patterns for the current 8-agent ecosystem,
ensuring appropriate tool restrictions while maintaining functional capabilities.

## Current Agents (8)

| Agent | Model | Access Level |
|-------|-------|-------------|
| architect | opus | Full |
| code-reviewer | sonnet | Read + Analysis |
| debugger | sonnet | Read + Analysis |
| devops | sonnet | Full |
| feature-agent | opus | Full |
| frontend-engineer | sonnet | Full |
| security-auditor | sonnet | Read + Analysis |
| test-engineer | sonnet | Full |

## Access Categories

### 1. Full Access (Implementation Agents)

**Agents**: architect, devops, feature-agent, frontend-engineer, test-engineer
**Tools**: Read, Write, Edit, Grep, Glob, Bash, TodoWrite (plus tool-specific additions)
**Security Rationale**: Implementation agents require full tool access to write code,
run tests, and manage infrastructure. They operate under "trusted implementation" with
complete system modification capability.

### 2. Read-Only Plus Analysis (Review/Audit Agents)

**Agents**: code-reviewer, debugger, security-auditor
**Tools**: Read, Grep, Glob, Bash (read-only), TodoWrite
**Forbidden**: Write, Edit
**Security Rationale**: Analysis agents assess and report without modifying production
systems. This separation ensures analysis integrity and prevents accidental modifications
during security reviews or debugging sessions.

## Security Boundaries

### Critical Security Principles

1. **Principle of Least Privilege**: Each agent receives only the minimum tools
   necessary for its role

2. **Separation of Concerns**: Analysis agents cannot modify code; implementation
   agents focus on building

3. **Defense in Depth**: Multiple layers of access control prevent privilege
   escalation

4. **Audit Trail**: All tool restrictions are documented with clear rationale

### Risk Mitigation Strategies

- **Analysis Agents** (code-reviewer, debugger, security-auditor): Forbidden from
  Write/Edit operations to prevent accidental production modifications

- **security-auditor**: Read-only access ensures security reviews don't alter the
  systems being audited

- **architect**: Full access but uses `plan` permission mode to show changes before
  executing (recommended)

## Agent-Specific Security Rationale

### Implementation Agents (Full Access)

- **architect**: Designs systems and creates implementation plans; full access needed
  for comprehensive analysis and spec writing

- **devops**: Manages infrastructure automation, CI/CD, and deployment scripts;
  requires full system access

- **feature-agent**: Orchestrates end-to-end feature delivery across multiple files;
  requires full access for coordination

- **frontend-engineer**: Implements UI components, tests, and build configuration;
  requires full implementation toolset

- **test-engineer**: Creates test infrastructure, automation, and CI integration;
  requires full implementation capabilities

### Analysis Agents (Read-Only Plus Analysis)

- **code-reviewer**: Reviews code quality and patterns without implementing changes

- **debugger**: Investigates root causes through analysis; read-only prevents
  accidental production modifications during investigation

- **security-auditor**: Performs vulnerability assessment without modifying the
  systems being audited; read-only is a hard requirement for audit integrity

## Compliance and Monitoring

### Security Monitoring

- All tool restrictions are explicitly defined in agent YAML frontmatter
- Access patterns are documented with clear business justification
- Run `/audit --scope agents` to validate all agents comply with access patterns

### Compliance Standards

- Follows principle of least privilege
- Implements separation of duties for security-critical functions
- Maintains audit trails for all access decisions

## Change Management

### Adding New Agents

1. **Risk Assessment**: Evaluate required tools against security principles
2. **Access Design**: Implement minimum necessary tool access
3. **Documentation**: Document security rationale in the agent file
4. **Validation**: Run `./scripts/validate-agent-yaml.py` before syncing

### Modifying Existing Access

1. **Justification**: Business case for access changes
2. **Testing**: Validate new access patterns before deploying
3. **Sync**: Deploy via `/sync` after validation
