# Claude-Config Documentation Index

**Last Updated**: 2026-04-08

---

## Documentation Structure

```text
docs/
├── setup/          # Installation and configuration guides
├── development/    # Development standards and YAML requirements
├── performance/    # Parallelization and performance guides
├── quality/        # Quality gates and validation
├── integrations/   # External integrations (MCP, ElevenLabs, ShadCN)
├── architecture/   # System architecture documentation
├── agents/         # Agent template and authoring guide
├── commands/       # Skill/command inventory
├── guides/         # Development and agent guides
├── skills/         # Skills reference
├── ux/             # UX and interface guidelines
├── platform/       # Platform engineering
└── specs/          # (empty after cleanup)
```

---

## Core Documentation

- **[index.md](index.md)** - Documentation entry point
- **[QUICKSTART.md](QUICKSTART.md)** - Get productive in 2 minutes
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - System architecture overview
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Common issues

## Setup & Installation

- **[Installation Guide](setup/INSTALLATION.md)**
- **[Audio Hook README](setup/AUDIO_HOOK_README.md)**
- **[Configuration Management](setup/CONFIGURATION_MANAGEMENT.md)**
- **[Developer Environment Setup](setup/DEVELOPER_ENVIRONMENT_SETUP.md)**
- **[Deployment Pipelines](setup/DEPLOYMENT_PIPELINES.md)**
- **[Container Infrastructure](setup/CONTAINER_INFRASTRUCTURE.md)**
- **[Platform Setup Guide](setup/PLATFORM_SETUP_GUIDE.md)**
- **[Dashboard Service Setup](setup/DASHBOARD_SERVICE_SETUP.md)**
- **[Ngrok Setup](setup/NGROK_SETUP.md)**

## Agent System

- **[Agent Template](agents/AGENT_TEMPLATE.md)** - Template for new agents
- **[Agent Development Guide](guides/agent-development-guide.md)** - Authoring guide

### Current Agents (8)

| Agent | Model | Domain |
|-------|-------|--------|
| architect | opus | System design, technical roadmaps |
| code-reviewer | sonnet | Code quality, security review |
| debugger | sonnet | Bug investigation |
| devops | sonnet | CI/CD, infrastructure |
| feature-agent | opus | End-to-end feature orchestration |
| frontend-engineer | sonnet | UI, React, CSS |
| security-auditor | sonnet | Security audits, OWASP |
| test-engineer | sonnet | Testing strategy, coverage |

## Skills

- **[Skills Guide](skills/SKILLS_GUIDE.md)**
- **[Command/Skill Inventory](commands/COMMAND_INVENTORY.md)**
- **[Orchestration Skill Template](skills/ORCHESTRATION_SKILL_TEMPLATE.md)**
- **[Skill Template](skills/SKILL_TEMPLATE.md)**

## Development Standards

- **[YAML Requirements](development/YAML_REQUIREMENTS.md)**
- **[Security Access Patterns](development/SECURITY_ACCESS_PATTERNS.md)**
- **[Tool Access Guide](development/TOOL_ACCESS_GUIDE.md)**
- **[Schema Version Migration](development/SCHEMA_VERSION_MIGRATION.md)**

## Performance

- **[Performance Guide](performance/PERFORMANCE.md)**
- **[Parallel Execution Guide](performance/PARALLEL_EXECUTION_GUIDE.md)**
- **[Parallelization Architecture](performance/PARALLELIZATION_ARCHITECTURE.md)**

## Quality

- **[Quality Gate Implementation](quality/QUALITY_GATE_IMPLEMENTATION.md)**
- **[Markdown Validation Environment](quality/MARKDOWN_VALIDATION_ENVIRONMENT.md)**
- **[CodeRabbit Pre-Commit Checklist](quality/CODERABBIT_PRECOMMIT_CHECKLIST.md)**

## Architecture

- **[Agent Ecosystem Architecture](architecture/agent-ecosystem-architecture.md)**
- **[Data Flows Architecture](architecture/data-flows-architecture.md)**
- **[Deployment Architecture](architecture/deployment-architecture.md)**
- **[Infrastructure Patterns](architecture/infrastructure-patterns.md)**
- **[MCP Dashboard Service Architecture](architecture/mcp-dashboard-service-architecture.md)**
- **[System Interaction Diagrams](architecture/system-interaction-diagrams.md)**
- **[Tool Router Service Implementation](architecture/tool-router-service-implementation.md)**

## Integrations

- **[MCP Configuration](integrations/MCP_CONFIGURATION.md)**
- **[ElevenLabs MCP Integration](integrations/ELEVENLABS_MCP_INTEGRATION.md)**
- **[ShadCN MCP Integration](integrations/SHADCN_MCP_INTEGRATION.md)**

## API Documentation

- **[Agent API](api/agent-api.md)**
- **[Agent Ecosystem API](api/agent-ecosystem-api.md)**
- **[Agent Management API](api/agent-management-api.md)**
- **[Agent Specification](api/agent-specification.md)**
- **[API Index](api/index.md)**

## UX & Platform

- **[Accessibility Standards](ux/accessibility-standards.md)**
- **[Interface Guidelines](ux/interface-guidelines.md)**
- **[User-Centered Design Guide](ux/user-centered-design-guide.md)**
- **[Platform Engineering](platform/PLATFORM_ENGINEERING.md)**

## Troubleshooting

- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**
- **[Dependency Troubleshooting](troubleshooting/DEPENDENCY_TROUBLESHOOTING.md)**
