# Claude Config Quick Start Guide

Get up and running with the Claude Code CLI Smart Agent Orchestration Framework in under 2 minutes.

## Prerequisites

- Claude Code CLI installed
- Node.js or Python environment
- Git for configuration management

## 🚀 Quick Setup (30 seconds)

```bash
# 1. Clone the configuration repository
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config

# 2. Launch Claude Code CLI
claude-code

# 3. Deploy all configurations with one command
/sync
```

**Done!** You now have 8 specialized agents and the full skill library available.

## 🧪 Test the Setup (30 seconds)

```bash
# Verify agent ecosystem health
/agent-audit

# Analyze your current project
/prime

# Run project tests intelligently
/test

# Experience multi-agent code review
/review
```

## Core Skills You'll Use Daily

| Skill | Purpose | Example |
|-------|---------|---------|
| `/sync` | Deploy configurations from repo | `/sync` |
| `/test` | Auto-discover and run tests | `/test` |
| `/prime` | Analyze repository structure | `/prime --lite` |
| `/review` | Comprehensive code review | `/review` |
| `/commit` | Smart git commits with quality gates | `/commit` |
| `/debug` | Systematic bug investigation | `/debug "login fails"` |

## Agents (8 Total)

- **Architecture**: architect
- **Development**: frontend-engineer, debugger
- **Quality**: code-reviewer, test-engineer
- **Security**: security-auditor
- **Infrastructure**: devops
- **Orchestration**: feature-agent

## 🔄 Keep Your Setup Current

```bash
# Update configurations (run monthly)
cd claude-config
git pull origin main
/sync
/agent-audit  # Verify everything is working
```

## 🆘 Need Help?

- **Agent not working?** Try `/sync` to refresh configurations
- **Command failed?** Check `/agent-audit` for health status
- **Full documentation**: See [README.md](README.md) for complete details

## 💡 Pro Tips

1. **Use `/prime` first** in new repositories for intelligent analysis
2. **Combine commands**: `/test` → `/review` → `/commit` → `/push` workflow
3. **Leverage parallel execution**: Commands use multiple agent instances for 4-6x speed
4. **Quality gates**: Never bypass with `--no-verify` - fix issues instead

## 🏗️ Advanced Setup (Optional)

### Custom Audio Notifications

```bash
# Enable completion sounds (macOS)
# Already configured in settings.json after /sync
```

### Repository-Specific Commands

```bash
# Validate agent/skill ecosystem health
/audit --scope agents   # Validate all agents
/audit --scope skills   # Validate all skills
/audit --scope all      # Full ecosystem check
```

---

**Next Steps**: Read the full [README.md](README.md) for comprehensive documentation and advanced orchestration patterns.
