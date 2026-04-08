# Parallel Execution Optimization Guide

## Overview

This guide covers strategies for maximizing parallel agent execution with the current
8-agent ecosystem. The principle is parallel-first: independent tasks run concurrently,
quality gates run alongside implementation, and wave-based workflows minimize wait time.

## Core Agents (8)

| Agent | Model | Domain |
|-------|-------|--------|
| architect | opus | System design, technical roadmaps |
| code-reviewer | sonnet | Code quality, security review |
| debugger | sonnet | Bug investigation, performance |
| devops | sonnet | CI/CD, infrastructure, deployment |
| feature-agent | opus | End-to-end feature orchestration |
| frontend-engineer | sonnet | UI, React, CSS, accessibility |
| security-auditor | sonnet | Security audits, OWASP compliance |
| test-engineer | sonnet | Testing strategy, coverage, automation |

## Parallel Execution Patterns

### 1. Feature Development

```yaml
Wave 1 - Design (if complex):
  - architect: System design and API contracts

Wave 2 - Parallel Implementation:
  - frontend-engineer: UI implementation
  - devops: CI/CD pipeline preparation

Wave 3 - Parallel Quality Gates:
  - code-reviewer: Code quality review
  - security-auditor: Security assessment
  - test-engineer: Test coverage validation
```

### 2. Code Review

All quality agents can run fully in parallel — no dependencies between them:

```yaml
Parallel Group: Quality Assessment
  - code-reviewer: Style, patterns, best practices
  - security-auditor: Vulnerability assessment, OWASP
  - test-engineer: Coverage analysis, missing test scenarios
```

### 3. Bug Investigation

```yaml
Wave 1 - Parallel Investigation:
  - debugger: Root cause analysis
  - security-auditor: Security implications (if relevant)

Wave 2 - Fix & Validate:
  - frontend-engineer OR devops: Implement fix
  - test-engineer: Write regression test
```

### 4. Security Audit

```yaml
Wave 1 - Assessment:
  - security-auditor: Vulnerability scan and OWASP analysis
  - code-reviewer: Code quality and pattern review

Wave 2 - Remediation:
  - frontend-engineer / devops: Fix vulnerabilities
  - test-engineer: Add security tests

Wave 3 - Validation:
  - security-auditor: Verify remediation
```

### 5. CI/CD Issue

```yaml
Wave 1 - Parallel Diagnosis:
  - debugger: Root cause investigation
  - devops: Infrastructure and pipeline analysis

Wave 2 - Fix:
  - devops: Apply fix
  - test-engineer: Validate fix in CI
```

## Agent Compatibility Matrix

### Highly Compatible (Parallel)

| Primary Agent | Compatible Parallel Agents | Benefit |
|---|---|---|
| frontend-engineer | test-engineer, code-reviewer | Parallel implementation + quality |
| devops | security-auditor, test-engineer | Infrastructure with security + validation |
| code-reviewer | security-auditor, test-engineer | Full quality gate in parallel |
| debugger | security-auditor | Multi-angle problem analysis |

### Sequential Dependencies (Require Handoffs)

| Sequence | Dependency Reason |
|---|---|
| architect → implementation agents | Design specs needed before coding |
| implementation agents → test-engineer | Code needed for meaningful tests |
| devops (build) → test-engineer (e2e) | Deployment needed for integration tests |

## Optimization Strategies

### Decompose Large Features

```yaml
# Large Feature: User Authentication

Wave 1 (1-2h):
  architect: Design auth flow, API contracts

Wave 2 (parallel, 4-8h):
  frontend-engineer: Login/signup UI
  devops: Auth service infrastructure

Wave 3 (parallel, 2-4h):
  code-reviewer: Code quality review
  security-auditor: Auth security audit
  test-engineer: Auth test suite
```

### Continuous Quality Integration

Run quality agents early and in parallel — not after implementation is complete:

```yaml
# Good: Quality runs alongside implementation
Wave 1: frontend-engineer + test-engineer (parallel)
Wave 2: code-reviewer + security-auditor (parallel review)

# Bad: Sequential quality bottleneck
Step 1: frontend-engineer (complete)
Step 2: test-engineer (complete)
Step 3: code-reviewer (complete)
Step 4: security-auditor (complete)
```

## Performance Metrics

| Metric | Target |
|---|---|
| Parallel utilization | 80%+ agents working simultaneously |
| Quality gate cycle | < 24 hours for complete review |
| Feature velocity improvement | 50%+ vs sequential |

## Best Practices

1. **Parallel-first**: Default to parallel execution for independent tasks
2. **Wave-based**: Organize by dependencies, not by domain
3. **Quality early**: Include code-reviewer and test-engineer from Wave 1 when possible
4. **Security always**: Add security-auditor to any feature touching auth, data, or APIs
5. **Clear handoffs**: Use explicit artifacts (specs, PRs, reports) between waves

## Anti-Patterns

### Sequential when Parallel is Possible

```text
Wrong: code-reviewer → wait → security-auditor → wait → test-engineer
Right: [code-reviewer + security-auditor + test-engineer] (parallel)
```

### Missing Quality Gates

```text
Wrong: frontend-engineer only
Right: frontend-engineer + test-engineer + code-reviewer
```

### Over-coordination Overhead

```text
Wrong: architect reviews every PR (bottleneck)
Right: architect designs upfront, code-reviewer handles PRs
```
