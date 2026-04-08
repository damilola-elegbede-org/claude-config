# Tool Access Justification Guide

## Overview

This guide explains the rationale behind tool access restrictions for each of the
8 current agents, ensuring appropriate capabilities while maintaining security and
role boundaries.

## Current Agent Tool Access

| Agent | Access Level | Key Tools | Forbidden |
|-------|-------------|-----------|-----------|
| architect | Full | Read, Write, Edit, Grep, Glob, Bash, TodoWrite | - |
| code-reviewer | Read + Analysis | Read, Grep, Glob, Bash (read-only) | Write, Edit |
| debugger | Read + Analysis | Read, Grep, Glob, Bash (read-only) | Write, Edit |
| devops | Full | Read, Write, Edit, Grep, Glob, Bash, TodoWrite | - |
| feature-agent | Full | Read, Write, Edit, Grep, Glob, Bash, TodoWrite | - |
| frontend-engineer | Full | Read, Write, Edit, Grep, Glob, Bash, TodoWrite | - |
| security-auditor | Read + Analysis | Read, Grep, Glob, Bash (read-only) | Write, Edit |
| test-engineer | Full | Read, Write, Edit, Grep, Glob, Bash, TodoWrite | - |

## Tool Access Categories

### Full Access Agents

**Agents**: architect, devops, feature-agent, frontend-engineer, test-engineer

**Justification**: These agents build, configure, and deploy. They must modify code,
manage infrastructure, and create artifacts to deliver working solutions. Full tool
access is required to fulfill their core responsibilities.

**Agent-specific rationale**:

- **architect**: Full access needed to create comprehensive implementation plans, write
  specs, and guide technical decisions across files

- **devops**: Manages CI/CD pipelines, infrastructure code, and deployment scripts;
  requires system execution and file modification

- **feature-agent**: Orchestrates end-to-end feature delivery; requires full access to
  coordinate implementation across the codebase

- **frontend-engineer**: Implements UI components, configures build systems, and writes
  tests; requires complete implementation toolset

- **test-engineer**: Creates test infrastructure, automation scripts, and CI integration;
  requires full implementation capabilities

### Read + Analysis Access Agents

**Agents**: code-reviewer, debugger, security-auditor

**Tools**: Read, Grep, Glob, Bash (read-only commands), TodoWrite
**Forbidden**: Write, Edit

**Justification**: Analysis agents must remain objective and focused on assessment
rather than implementation. Read-only access ensures thorough analysis without
bias toward immediate fixes, and prevents accidental modifications during review.

**Agent-specific rationale**:

- **code-reviewer**: Reviews code quality and patterns; read-only access ensures
  review findings are independent of implementation decisions

- **debugger**: Investigates root causes through analysis; read-only prevents
  accidental production modifications during investigation. Fixes happen separately.

- **security-auditor**: Performs vulnerability assessment; read-only is a hard
  requirement for audit integrity — auditors cannot modify the systems they assess

## Security Principles

### Principle of Least Privilege

Each agent receives the minimum access required for their core responsibilities.
Analysis agents cannot accidentally modify code. Implementation agents have full
access only when building solutions.

### Role Separation

Clear boundaries between analysis and implementation:

- **Analysis Phase**: Read-only agents (code-reviewer, debugger, security-auditor)
  investigate and report
- **Implementation Phase**: Full-access agents build solutions based on findings
- **Quality Phase**: test-engineer (full) validates; code-reviewer (read-only) reviews

### Audit Trail

Tool restrictions enable clear audit trails:

- Read-only agents produce analysis reports only
- Write-access agents create implementation artifacts
- Clear responsibility attribution for all changes

## Tool-Specific Justifications

### Bash Access

- **Full (devops, frontend-engineer, test-engineer)**: System execution needed for
  builds, tests, deployments, and infrastructure
- **Read-Only (code-reviewer, debugger, security-auditor)**: Can run non-destructive
  commands (grep, ls, cat) but cannot modify systems

### File Modification (Edit, Write)

- **Allowed**: architect, devops, feature-agent, frontend-engineer, test-engineer
- **Forbidden**: code-reviewer, debugger, security-auditor — to maintain objectivity
  and role separation

## Escalation Patterns

### When Analysis Agents Need Modifications

1. analysis agent completes review and documents findings
2. Findings handed to appropriate implementation agent
3. Implementation agent applies changes
4. Analysis agent re-reviews if needed

### When Implementation Agents Need Analysis

1. Pause implementation
2. Engage code-reviewer or security-auditor
3. Receive analysis results
4. Resume implementation with new context
