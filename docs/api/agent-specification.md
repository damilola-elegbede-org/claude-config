# Agent Specification API

## Overview

The Agent Specification API defines the interface and capabilities for Claude Code CLI agents. This document provides the complete specification for agent definitions, tool access, coordination patterns, and execution models.

## Agent Definition Schema

### Core Schema (YAML Front-matter)

```yaml
---
name: "agent-name"
category: "development|infrastructure|architecture|design|quality|security|analysis|operations"
model: "claude-sonnet-4-6|claude-haiku-4-5-20251001|claude-opus-4-6"
capabilities:
  - "Primary capability"
  - "Secondary capability"
  - "Specialized skill"
tools:
  - Read
  - Write
  - Bash
  - TodoWrite
description: "Brief description of agent purpose and expertise"
coordination_notes: "How this agent works with others"
system_boundary: "SYSTEM BOUNDARY: This agent cannot invoke the Task tool."
quality_gates:
  - "Quality requirement 1"
  - "Quality requirement 2"
performance_tier: "Standard|Premium|Critical"
---
```

### Required Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `name` | string | Unique agent identifier | "backend-engineer" |
| `category` | string | Functional domain | "development" |
| `model` | string | Claude model version | "claude-sonnet-4-6" |
| `capabilities` | array | Core competencies | ["API development", "Database design"] |
| `tools` | array | Allowed tool access | ["Read", "Write", "Bash"] |
| `description` | string | Agent purpose and context | "Server-side development specialist" |
| `system_boundary` | string | Security boundary statement | Required exact text |

### Optional Fields

| Field | Type | Description | Default |
|-------|------|-------------|---------|
| `coordination_notes` | string | Multi-agent patterns | Empty |
| `quality_gates` | array | Quality requirements | Empty |
| `performance_tier` | string | Performance classification | "Standard" |
| `specializations` | array | Domain-specific expertise | Empty |
| `dependencies` | array | Required external tools | Empty |

## Tool Access Levels

### Full Access (Development Agents)

- **Tools**: Read, Write, Edit, MultiEdit, Grep, Glob, LS, Bash, TodoWrite
- **Purpose**: Complete development and implementation
- **Agents**: backend-engineer, frontend-architect, mobile-engineer, etc.
- **Security**: Comprehensive access for implementation tasks

```yaml
tools:
  - Read
  - Write
  - Edit
  - MultiEdit
  - Grep
  - Glob
  - LS
  - Bash
  - TodoWrite
```

### Read & Analysis (Analysis Agents)

- **Tools**: Read, Grep, Glob, LS, TodoWrite
- **Purpose**: Code analysis and assessment
- **Agents**: codebase-analyst, code-reviewer, security-auditor
- **Security**: Read-only with analysis capabilities

```yaml
tools:
  - Read
  - Grep
  - Glob
  - LS
  - TodoWrite
```

### Documentation & Writing

- **Tools**: Read, Write, Edit, MultiEdit, Grep, Glob, LS, TodoWrite
- **Purpose**: Documentation and content creation
- **Agents**: tech-writer, api-documenter
- **Security**: File modification for documentation only

```yaml
tools:
  - Read
  - Write
  - Edit
  - MultiEdit
  - Grep
  - Glob
  - LS
  - TodoWrite
```

### Infrastructure & Operations

- **Tools**: Read, Write, Edit, Bash, Grep, Glob, LS, TodoWrite
- **Purpose**: System operations and infrastructure
- **Agents**: devops, platform-engineer, kubernetes-admin
- **Security**: System access for infrastructure management

```yaml
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - LS
  - TodoWrite
```

### Quality & Testing

- **Tools**: Read, Write, Edit, Bash, Grep, Glob, LS, TodoWrite
- **Purpose**: Quality assurance and testing
- **Agents**: test-engineer, performance-engineer
- **Security**: Execution access for testing

```yaml
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - LS
  - TodoWrite
```

### Strategic & Planning

- **Tools**: Read, Write, TodoWrite, Grep, Glob, LS
- **Purpose**: Planning and coordination
- **Agents**: principal-architect, project-orchestrator
- **Security**: Planning tools without system execution

```yaml
tools:
  - Read
  - Write
  - TodoWrite
  - Grep
  - Glob
  - LS
```

## Agent Categories

### Development Category (Blue)

```yaml
category: "development"
color: "#0066CC"
purpose: "Core programming and implementation"
typical_tools: ["Read", "Write", "Edit", "MultiEdit", "Bash", "TodoWrite"]
coordination: "Parallel execution for independent components"
```

**Members**: backend-engineer, frontend-architect, mobile-engineer, ml-engineer, test-engineer, etc.

### Infrastructure Category (Orange)

```yaml
category: "infrastructure"
color: "#FF6600"
purpose: "Systems, operations, and deployment"
typical_tools: ["Read", "Write", "Edit", "Bash", "Grep", "LS", "TodoWrite"]
coordination: "Sequential for deployment pipelines"
```

**Members**: devops, platform-engineer, kubernetes-admin, cloud-architect, etc.

### Architecture Category (Purple)

```yaml
category: "architecture"
color: "#9900CC"
purpose: "System design and technical planning"
typical_tools: ["Read", "Write", "TodoWrite", "Grep", "Glob", "LS"]
coordination: "Design-first, then implementation coordination"
```

**Members**: principal-architect, api-architect, cloud-architect, etc.

### Design Category (Pink)

```yaml
category: "design"
color: "#FF66CC"
purpose: "User experience and interface design"
typical_tools: ["Read", "Write", "Edit", "TodoWrite", "Grep", "LS"]
coordination: "Design systems and consistency focus"
```

**Members**: ui-designer, ux-researcher

### Quality Category (Green)

```yaml
category: "quality"
color: "#00CC66"
purpose: "Testing, review, and validation"
typical_tools: ["Read", "Write", "Edit", "Bash", "Grep", "TodoWrite"]
coordination: "Parallel quality gates"
```

**Members**: test-engineer, code-reviewer, performance-engineer, accessibility-auditor

### Security Category (Red)

```yaml
category: "security"
color: "#CC0000"
purpose: "Security assessment and compliance"
typical_tools: ["Read", "Bash", "Grep", "Glob", "LS", "TodoWrite"]
coordination: "Security-first validation"
```

**Members**: security-auditor, security-auditor, supply-chain-security-engineer

### Analysis Category (Cyan)

```yaml
category: "analysis"
color: "#00CCCC"
purpose: "Research, documentation, and analysis"
typical_tools: ["Read", "Grep", "Glob", "LS", "TodoWrite"]
coordination: "Parallel analysis with synthesis"
```

**Members**: codebase-analyst, tech-writer, dependency-analyst, metrics-analyst

### Operations Category (Yellow)

```yaml
category: "operations"
color: "#CCCC00"
purpose: "Support, coordination, and strategic planning"
typical_tools: ["Read", "Write", "Bash", "Grep", "TodoWrite"]
coordination: "Incident response and operational support"
```

**Members**: debugger, incident-commander, production-reliability-engineer, project-orchestrator

## Model Selection Guidelines

### Claude Opus 4.6 (Strategic & Complex)

```yaml
model: "claude-opus-4-6"
use_cases:
  - Strategic architecture decisions
  - Complex system design
  - Multi-agent coordination
  - Critical incident response
agents:
  - principal-architect
  - project-orchestrator
  - incident-commander
  - performance-engineer
cost: "High - use for strategic decisions"
```

### Claude Sonnet 4.6 (Standard Implementation)

```yaml
model: "claude-sonnet-4-6"
use_cases:
  - Standard development tasks
  - Code review and analysis
  - Documentation creation
  - Quality assurance
agents: "Majority of agents (80%+)"
cost: "Balanced - standard choice"
```

### Claude Haiku 4.5 (Simple & Fast)

```yaml
model: "claude-haiku-4-5-20251001"
use_cases:
  - Simple validation tasks
  - Quick analysis
  - Basic documentation updates
  - Rule-based operations
agents:
  - execution-evaluator
  - simple validators
cost: "Low - use for simple tasks"
```

## Agent Coordination Patterns

### Parallel Execution Pattern

```yaml
execution_pattern: "parallel"
use_case: "Independent tasks that can run simultaneously"
examples:
  - Multiple backend-engineer instances for different microservices
  - Quality gates (code-reviewer + security-auditor + test-engineer)
  - Multi-platform development (iOS + Android + Web)
coordination_method: "Result aggregation after completion"
```

**Implementation**:
```yaml
agents:
  - name: backend-engineer
    instance: service-1
    task: authentication_service
  - name: backend-engineer
    instance: service-2
    task: payment_service
  - name: backend-engineer
    instance: service-3
    task: notification_service
aggregation: project-orchestrator
```

### Sequential Pipeline Pattern

```yaml
execution_pattern: "sequential"
use_case: "Dependent tasks requiring ordered execution"
examples:
  - Architecture design → Implementation → Testing
  - Database migration planning → Execution → Validation
  - Security assessment → Remediation → Compliance verification
coordination_method: "Hand-off between stages"
```

**Implementation**:
```yaml
pipeline:
  stage_1:
    agent: principal-architect
    task: system_design
    output: architecture_specifications
  stage_2:
    agent: backend-engineer
    task: implementation
    input: architecture_specifications
    output: implemented_system
  stage_3:
    agent: test-engineer
    task: validation
    input: implemented_system
    output: test_results
```

### Hub-and-Spoke Pattern

```yaml
execution_pattern: "coordinated"
use_case: "Complex multi-agent scenarios requiring orchestration"
central_coordinator: project-orchestrator
spoke_agents:
  - Multiple specialists working on related tasks
  - Regular coordination and synchronization
  - Conflict resolution through coordinator
```

**Implementation**:
```yaml
coordinator: project-orchestrator
agents:
  - backend-engineer: API development
  - frontend-architect: UI implementation
  - mobile-engineer: Mobile app
  - test-engineer: Quality validation
  - security-auditor: Security assessment
coordination_frequency: "After each major milestone"
```

## Command Integration API

### Direct Command Mapping

Commands can directly invoke specific agents:

```yaml
command_mappings:
  "/test": "test-engineer"
  "/review": "code-reviewer"
  "/security": "security-auditor"
  "/perf": "performance-engineer"
  "/docs": "tech-writer"
  "/debug": "debugger"
  "/prime": "codebase-analyst"
```

### Multi-Agent Command Patterns

Commands can trigger multi-agent workflows:

```yaml
complex_commands:
  "/agent-audit":
    pattern: parallel
    agents:
      - type: code-reviewer
        instances: 8
        distribution: by_category
    aggregation: comprehensive_report

  "/resolve-comments":
    pattern: sequential
    pipeline:
      - codebase-analyst: analyze_pr_context
      - appropriate_specialist: implement_changes
      - test-engineer: validate_changes
      - code-reviewer: final_review
```

## Quality Gates API

### Pre-Commit Quality Gates

```yaml
pre_commit_gates:
  code_quality:
    agent: code-reviewer
    criteria:
      - style_compliance: ">= 8.5/10"
      - complexity_score: "< 10"
      - maintainability: ">= 8/10"

  security_check:
    agent: security-auditor
    criteria:
      - vulnerability_scan: "zero_critical"
      - dependency_scan: "zero_high_risk"

  test_validation:
    agent: test-engineer
    criteria:
      - coverage: ">= 80%"
      - passing_tests: "100%"
```

### Deployment Quality Gates

```yaml
deployment_gates:
  performance_validation:
    agent: performance-engineer
    criteria:
      - response_time: "< 200ms P95"
      - throughput: ">= baseline"
      - memory_usage: "< 80% capacity"

  security_clearance:
    agent: security-auditor
    criteria:
      - penetration_test: "passed"
      - compliance_check: "100%"
      - audit_trail: "complete"

  production_readiness:
    agent: production-reliability-engineer
    criteria:
      - monitoring_coverage: "100%"
      - alerting_configured: "yes"
      - runbook_complete: "yes"
```

## Agent Lifecycle Management

### Agent Registration

```yaml
registration_process:
  1. schema_validation: "Validate YAML front-matter"
  2. capability_verification: "Confirm stated capabilities"
  3. tool_access_validation: "Verify tool permissions"
  4. integration_testing: "Test with existing agents"
  5. deployment_approval: "Production readiness check"
```

### Agent Updates

```yaml
update_process:
  version_control: "Git-based versioning"
  backward_compatibility: "Maintain interface compatibility"
  migration_path: "Clear upgrade instructions"
  rollback_capability: "Quick rollback if issues arise"
  testing_requirements: "Comprehensive testing before deployment"
```

### Agent Deprecation

```yaml
deprecation_process:
  advance_notice: "30 days minimum"
  migration_guide: "Clear path to replacement"
  transition_period: "Gradual phase-out"
  support_timeline: "Extended support during transition"
  removal_date: "Fixed date after transition period"
```

## Error Handling and Recovery

### Agent Failure Patterns

```yaml
failure_types:
  timeout:
    detection: "30-second timeout"
    recovery: "Retry once, then fallback"
    fallback: "Claude handles directly"

  invalid_output:
    detection: "Output validation failure"
    recovery: "Request clarification"
    fallback: "Claude intervention"

  tool_access_denied:
    detection: "Permission error"
    recovery: "Escalate to Claude"
    fallback: "Manual override with user consent"

  resource_exhaustion:
    detection: "Memory or CPU limits exceeded"
    recovery: "Reduce scope, retry"
    fallback: "Sequential execution"
```

### Recovery Strategies

```yaml
recovery_levels:
  automatic:
    - Simple retry logic
    - Alternative agent deployment
    - Scope reduction

  semi_automatic:
    - User notification with options
    - Fallback suggestions
    - Manual approval for changes

  manual:
    - Full Claude intervention
    - User decision required
    - Detailed error reporting
```

## Performance Metrics API

### Agent Performance Tracking

```yaml
performance_metrics:
  execution_time:
    measurement: "Wall clock time from invocation to completion"
    target: "< 30 seconds for standard tasks"
    monitoring: "Per-agent performance tracking"

  success_rate:
    measurement: "Percentage of successful task completions"
    target: "> 95% success rate"
    monitoring: "Trend analysis over time"

  quality_score:
    measurement: "Output quality assessment"
    target: "> 8.5/10 average quality"
    monitoring: "User feedback and automated assessment"

  resource_utilization:
    measurement: "CPU, memory, and token usage"
    target: "Efficient resource usage"
    monitoring: "Cost optimization tracking"
```

### System-Wide Metrics

```yaml
system_metrics:
  parallel_execution_rate:
    measurement: "Percentage of tasks executed in parallel"
    target: "> 70% parallelization rate"

  coordination_overhead:
    measurement: "Time spent on inter-agent coordination"
    target: "< 10% of total execution time"

  quality_gate_efficiency:
    measurement: "First-pass success rate through quality gates"
    target: "> 95% first-pass success"

  user_satisfaction:
    measurement: "User feedback and adoption metrics"
    target: "> 4.5/5.0 satisfaction score"
```

## Security Model

### Agent Isolation

```yaml
security_boundaries:
  process_isolation:
    description: "Each agent runs in isolated context"
    enforcement: "Runtime environment separation"
    monitoring: "Process boundary violations tracked"

  data_access:
    description: "Agents access only required data"
    enforcement: "Tool-level permission checking"
    monitoring: "Data access auditing"

  inter_agent_communication:
    description: "Agents cannot directly invoke others"
    enforcement: "SYSTEM BOUNDARY protection"
    monitoring: "Invocation attempt logging"
```

### Audit and Compliance

```yaml
audit_requirements:
  action_logging:
    scope: "All agent actions logged"
    retention: "90 days minimum"
    format: "Structured JSON logs"

  permission_tracking:
    scope: "Tool access and file modifications"
    retention: "1 year minimum"
    format: "Audit trail with timestamps"

  compliance_reporting:
    frequency: "Monthly compliance reports"
    scope: "Security violations, performance metrics"
    distribution: "Security and operations teams"
```

## Testing and Validation

### Agent Testing Framework

```yaml
testing_levels:
  unit_testing:
    scope: "Individual agent capabilities"
    framework: "Agent-specific test suites"
    frequency: "On every agent update"

  integration_testing:
    scope: "Multi-agent coordination"
    framework: "End-to-end workflow testing"
    frequency: "Weekly integration tests"

  performance_testing:
    scope: "Response time and resource usage"
    framework: "Automated benchmarking"
    frequency: "Continuous monitoring"

  user_acceptance_testing:
    scope: "Real-world usage scenarios"
    framework: "User feedback collection"
    frequency: "Before major releases"
```

### Validation Criteria

```yaml
validation_requirements:
  functional_correctness:
    criteria: "Agent produces expected outputs"
    measurement: "Automated test suite success rate"
    threshold: "100% critical test passage"

  performance_standards:
    criteria: "Agent meets performance targets"
    measurement: "Response time and resource usage"
    threshold: "Within 20% of baseline performance"

  security_compliance:
    criteria: "Agent follows security protocols"
    measurement: "Security audit findings"
    threshold: "Zero high-severity security issues"

  integration_compatibility:
    criteria: "Agent works with existing ecosystem"
    measurement: "Integration test results"
    threshold: "No regression in existing functionality"
```

## Future API Extensions

### Planned Enhancements

```yaml
roadmap:
  v2.0:
    features:
      - Dynamic agent capability discovery
      - Machine learning-based agent selection
      - Cross-repository agent sharing
      - Advanced orchestration patterns

  v3.0:
    features:
      - Custom agent creation API
      - Real-time collaboration features
      - Advanced analytics and insights
      - Plugin architecture for extensions
```

### Extension Points

```yaml
extension_mechanisms:
  custom_tools:
    description: "Add new tools for agents"
    interface: "Tool registration API"
    validation: "Security and capability validation"

  custom_categories:
    description: "Define new agent categories"
    interface: "Category registration API"
    validation: "Consistency and uniqueness checks"

  custom_coordination:
    description: "New coordination patterns"
    interface: "Pattern definition API"
    validation: "Performance and reliability testing"
```

---

This API specification provides the complete interface for working with Claude Code CLI agents, enabling consistent development, deployment, and management of the agent ecosystem while maintaining security, performance, and quality standards.
