# Claude Configuration Repository Documentation

Portable Claude Code configuration with 8 specialized agents and a full skill library.

## Quick Start

New to the system? Start here:

- **[Quick Start Guide](QUICKSTART.md)** - Up and running in under 2 minutes
- **[Agent Template](agents/AGENT_TEMPLATE.md)** - Template for creating new agents
- **[Skills Guide](skills/SKILLS_GUIDE.md)** - Complete skill reference
- **[Architecture](ARCHITECTURE.md)** - System design overview

### Essential Skills

```bash
# Deploy the complete framework
/sync

# Validate ecosystem health
/audit --scope all

# Analyze any repository
/prime --lite

# Run tests
/test

# Code review
/review
```

## Documentation Structure

### Setup & Configuration

- **[Installation Guide](setup/INSTALLATION.md)** - Complete installation instructions
- **[Audio Hook README](setup/AUDIO_HOOK_README.md)** - Audio notification setup
- **[Configuration Management](setup/CONFIGURATION_MANAGEMENT.md)** - Managing configurations

### Agent System (8 Agents)

| Agent | Model | Domain |
|-------|-------|--------|
| architect | opus | System design, technical roadmaps |
| code-reviewer | sonnet | Code quality, security review |
| debugger | sonnet | Bug investigation, root cause analysis |
| devops | sonnet | CI/CD, infrastructure, deployment |
| feature-agent | opus | End-to-end feature orchestration |
| frontend-engineer | sonnet | UI, React, CSS, accessibility |
| security-auditor | sonnet | Security audits, OWASP compliance |
| test-engineer | sonnet | Testing strategy, coverage, automation |

- **[Agent Template](agents/AGENT_TEMPLATE.md)** - Create custom agents
- **[Agent Development Guide](guides/agent-development-guide.md)** - Agent authoring guide

### Skills

- **[Skills Guide](skills/SKILLS_GUIDE.md)** - All 34 skills documented
- **[Command Inventory](commands/COMMAND_INVENTORY.md)** - Skill reference

### Architecture & Performance

- **[Architecture](ARCHITECTURE.md)** - System design
- **[Parallel Execution Guide](performance/PARALLEL_EXECUTION_GUIDE.md)** - Multi-agent coordination
- **[Parallelization Architecture](performance/PARALLELIZATION_ARCHITECTURE.md)** - Execution model

### Quality & Development

- **[YAML Requirements](development/YAML_REQUIREMENTS.md)** - Agent frontmatter spec
- **[Security Access Patterns](development/SECURITY_ACCESS_PATTERNS.md)** - Tool permissions
- **[Quality Gate Implementation](quality/QUALITY_GATE_IMPLEMENTATION.md)** - Quality gates

### Integrations

- **[MCP Configuration](integrations/MCP_CONFIGURATION.md)** - Model Context Protocol
- **[ElevenLabs Integration](integrations/ELEVENLABS_MCP_INTEGRATION.md)** - Voice synthesis
- **[ShadCN Integration](integrations/SHADCN_MCP_INTEGRATION.md)** - UI components

---

*For the latest changes, check the commit history.*
