# Installation and Setup Guide

## Quick Installation

The fastest way to get up and running with the Claude Configuration Repository:

```bash
# 1. Clone the repository
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config

# 2. Start Claude Code CLI
claude-code

# 3. Deploy configurations with one command
/sync

# 4. Verify installation
/audit --scope agents
```

**You're done!** You now have access to 8 specialized agents and the full skill library.

## Detailed Installation Options

### Prerequisites

Before installing the Claude Configuration Repository, ensure you have:

#### Required Software

- **Claude Code CLI**: Version 1.0.0 or higher

  ```bash
  # Install via npm
  npm install -g @anthropic/claude-code

  # Or via Homebrew (macOS)
  brew install claude-code

  # Verify installation
  claude-code --version
  ```

- **Git**: For version control and configuration management

  ```bash
  # Install Git (if not already installed)
  # macOS
  brew install git

  # Ubuntu/Debian
  sudo apt install git

  # Windows
  winget install Git.Git
  ```

- **Node.js**: For package management and dependency operations

  ```bash
  # Install Node.js (recommended: v18+ LTS)
  # macOS
  brew install node

  # Ubuntu/Debian
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt-get install -y nodejs

  # Windows
  winget install OpenJS.NodeJS
  ```

#### Optional Dependencies (Recommended)

- **Python 3.8+**: For validation scripts and data processing agents

  ```bash
  # macOS
  brew install python

  # Ubuntu/Debian
  sudo apt install python3 python3-pip

  # Windows
  winget install Python.Python.3
  ```

- **Go**: For Go-based projects and dependency analysis

  ```bash
  # macOS
  brew install go

  # Ubuntu/Debian
  sudo apt install golang-go

  # Windows
  winget install GoLang.Go
  ```

### Installation Methods

#### Method 1: Quick Setup (Recommended)

For most users, the quick setup provides everything needed:

```bash
# Clone the repository
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config

# Launch Claude Code CLI
claude-code

# Deploy all configurations at once
/sync

# Verify everything is working
/audit --scope agents
/prime --lite    # Quick repository analysis
/test --quick   # Quick test validation
```

##### Advantages:

- Complete setup in under 2 minutes
- All 8 agents and skill library available immediately
- Includes audio notifications and quality gates
- Automatic backup of existing configurations

#### Method 2: Custom Installation

For users who want to selectively install components:

```bash
# Clone repository
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config

# Create Claude configuration directory
mkdir -p ~/.claude

# Option A: Core configuration only
cp system-configs/CLAUDE.md ~/.claude/CLAUDE.md

# Option B: Add specific agent categories
cp -r system-configs/.claude/agents ~/.claude/agents

# Option C: Add command system
cp -r system-configs/.claude/commands ~/.claude/commands

# Option D: Add audio notifications (macOS)
cp system-configs/.claude/settings.json ~/.claude/settings.json

# Verify installation
claude-code
/audit --scope agents
```

#### Method 3: Development Installation

For contributors and advanced users:

```bash
# Fork and clone your fork
git clone https://github.com/YOUR-USERNAME/claude-config.git
cd claude-config

# Add upstream remote
git remote add upstream https://github.com/damilola-elegbede/claude-config.git

# Install development dependencies
npm install  # If package.json exists
pip install -r requirements.txt  # If Python dependencies exist

# Run validation tests
./tests/test.sh
./scripts/validate-agent-yaml.py

# Deploy development configuration
/sync

# Run comprehensive validation
/audit --scope agents
/audit --scope skills
```

### Configuration Structure

After installation, your configuration structure will be:

```text
~/.claude/
├── CLAUDE.md                    # Core Claude configuration
├── agents/                      # 8 specialized agents
│   ├── architect.md
│   ├── code-reviewer.md
│   ├── debugger.md
│   ├── devops.md
│   ├── feature-agent.md
│   ├── frontend-engineer.md
│   ├── security-auditor.md
│   └── test-engineer.md
├── skills/                      # Skill library (slash commands)
│   ├── commit/
│   ├── debug/
│   ├── deps/
│   ├── docs/
│   ├── fix-ci/
│   ├── plan/
│   ├── prime/
│   ├── push/
│   ├── resolve-comments/
│   ├── review/
│   ├── ship-it/
│   ├── sync/
│   ├── test/
│   └── ... (more skills)
└── settings.json               # Audio notifications and preferences
```

## Verification and Testing

### Basic Verification

After installation, verify that all components are working correctly:

```bash
# 1. Check Claude configuration
claude-code
/prime --lite

# 2. Verify agent ecosystem
/audit --scope agents

# 3. Test command execution
/test --quick

# 4. Validate quality gates
/review README.md

# 5. Test orchestration
/docs --update
```

### Advanced Validation

For comprehensive system validation:

```bash
# Repository validation
./tests/test.sh

# Agent YAML validation
./scripts/validate-agent-yaml.py

# Command behavioral testing
./tests/test.sh commands

# Integration testing
./tests/test.sh integration

# Performance benchmarking
time /audit --scope agents
time /test
time /prime
```

### Expected Performance Metrics

After successful installation, you should see these performance improvements:

| Command | Expected Time | Performance Gain |
|---------|---------------|------------------|
| `/audit --scope agents` | 30-45 seconds | 5-6x faster |
| `/test` | 30-40 seconds | 4-5x faster |
| `/docs` | 1-2 minutes | 3-4x faster |
| `/prime focused` | 15-20 seconds | 4-6x faster |

## Platform-Specific Setup

### macOS Setup

```bash
# Install dependencies via Homebrew
brew install claude-code git node python go

# Clone and setup
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config
claude-code
/sync

# Enable audio notifications (already included in settings.json)
# Test audio
afplay /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Swish.m4r
```

### Linux Setup (Ubuntu/Debian)

```bash
# Update package lists
sudo apt update

# Install Claude Code CLI
npm install -g @anthropic/claude-code

# Install dependencies
sudo apt install git nodejs npm python3 python3-pip golang-go

# Clone and setup
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config
claude-code
/sync

# Verify installation
/audit --scope agents
```

### Windows Setup

```shell
# Install dependencies via Winget
winget install OpenJS.NodeJS
winget install Git.Git
winget install Python.Python.3
winget install GoLang.Go

# Install Claude Code CLI
npm install -g @anthropic/claude-code

# Clone and setup
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config
claude-code
/sync

# Verify installation
/audit --scope agents
```

## Configuration Options

### Audio Notifications (macOS)

Audio notifications are automatically configured on macOS. The system uses high-quality audio cues
for command completion:

```json
{
  "hooks": {
    "command_completion": {
      "sound": "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Swish.m4r"
    },
    "agent_deployment": {
      "sound": "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Note.m4r"
    },
    "quality_gate_pass": {
      "sound": "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/Bell.m4r"
    },
    "quality_gate_fail": {
      "sound": "/System/Library/Sounds/Sosumi.aiff"
    }
  }
}
```

To customize audio notifications:

```bash
# Test available sounds
ls /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/
ls /System/Library/Sounds/

# Test a sound
afplay /System/Library/Sounds/Glass.aiff

# Edit settings
code ~/.claude/settings.json
```

### Git Quality Gates

The system includes comprehensive quality gates that prevent bad commits:

```bash
# Quality gates are automatically active after installation
# They include:

# Pre-commit hooks:
# - Markdown quality validation
# - Basic syntax checking
# - Security scan basics
# - Agent YAML validation

# Pre-push hooks:
# - Full test suite execution
# - Comprehensive quality validation
# - Agent ecosystem health check
# - Command behavioral testing

# To temporarily disable (NOT recommended):
# git commit --no-verify  # NEVER DO THIS

# Instead, fix the issues:
./scripts/validate-markdown-quality.sh fix
/audit --scope agents
/test
```

### MCP Server Integration

The system supports Model Context Protocol (MCP) servers for enhanced functionality:

#### ElevenLabs Integration (Optional)

For text-to-speech and voice cloning capabilities:

```bash
# Set API key
export ELEVENLABS_API_KEY="your-api-key-here"

# Add to shell profile
echo 'export ELEVENLABS_API_KEY="your-api-key"' >> ~/.bashrc
# or
echo 'export ELEVENLABS_API_KEY="your-api-key"' >> ~/.zshrc

# Test integration
claude-code
# ElevenLabs functionality available via MCP integration
```

#### Context7 Integration (Optional)

For enhanced documentation and library lookups:

```bash
# Set API key
export CONTEXT7_API_KEY="your-context7-key"

# Add to shell profile
echo 'export CONTEXT7_API_KEY="your-key"' >> ~/.bashrc

# Test integration
claude-code
# Enhanced documentation capabilities now available
```

#### GitHub Integration (Recommended)

For GitHub operations and PR management:

```bash
# Set GitHub token
export GITHUB_TOKEN="your-github-token"

# Add to shell profile
echo 'export GITHUB_TOKEN="your-token"' >> ~/.bashrc

# Test integration
/pr --help  # Enhanced PR capabilities
/resolve-comments 123  # PR comment resolution
```

## Updating and Maintenance

### Regular Updates

Keep your configuration current with the latest improvements:

```bash
# Update repository (monthly recommended)
cd /path/to/claude-config
git pull origin main

# Re-sync configurations
/sync

# Validate updates
/audit --scope agents
/test
```

### Backup and Restore

The system automatically creates backups during sync operations:

```bash
# Manual backup
cp -r ~/.claude ~/.claude.backup.$(date +%Y%m%d)

# Restore from backup
# (Sync automatically creates backups, so just use /sync)
/sync

# List available backups
ls -la ~/.claude.backup.*
```

### Health Monitoring

Regular health checks ensure optimal performance:

```bash
# Weekly health check routine
/sync                    # Update configurations
/audit --scope agents            # Validate agent ecosystem
/test                   # Run comprehensive tests
git pull                # Update repository

# Monthly performance monitoring
time /audit --scope agents       # Should be ~30-45 seconds
time /test             # Should be ~30-40 seconds
time /docs             # Should be ~1-2 minutes
```

## Troubleshooting Common Issues

### Installation Problems

#### Issue: Claude Code CLI not found

```bash
# Solution 1: Install via npm
npm install -g @anthropic/claude-code

# Solution 2: Check PATH
echo $PATH
which claude-code

# Solution 3: Restart terminal
# Close and reopen terminal, then try again
```

#### Issue: `/sync` command not found

```bash
# Solution: Ensure you're in the claude-config repository
pwd  # Should show path ending in claude-config
cd /path/to/claude-config
claude-code
/sync
```

#### Issue: Permission denied during sync

```bash
# Solution: Fix home directory permissions
chmod 755 ~
mkdir -p ~/.claude
chmod 755 ~/.claude
/sync
```

### Agent Problems

#### Issue: Agent not found errors

```bash
# Solution: Re-sync configurations
/sync

# Validate agents
/audit --scope agents

# Check specific agent
ls ~/.claude/agents/ | grep agent-name
```

#### Issue: SYSTEM BOUNDARY violations

This is a security feature, not an error:

- Agents cannot invoke themselves or other agents
- Only Claude has orchestration authority
- No action needed - system working correctly

### Performance Issues

#### Issue: Commands running slowly

```bash
# Check system resources
top -n 1
free -h  # Linux
vm_stat  # macOS

# Run performance diagnostics
time /audit --scope agents --debug
time /test --verbose
```

#### Issue: Quality gates failing

```bash
# Fix common issues
./scripts/validate-markdown-quality.sh fix
./scripts/validate-agent-yaml.py --fix

# Re-run tests
/test

# Never bypass with --no-verify
```

## Advanced Configuration

### Custom Agent Development

For advanced users who want to create custom agents:

```bash
# Use agent template
cp docs/agents/AGENT_TEMPLATE.md ~/.claude/agents/custom-agent.md

# Edit agent definition
code ~/.claude/agents/custom-agent.md

# Validate new agent
./scripts/validate-agent-yaml.py

# Test agent
/audit --scope agents
```

### Command Customization

Modify existing commands or create new ones:

```bash
# Copy command template
cp docs/commands/COMMAND_TEMPLATE.md ~/.claude/commands/custom-command.md

# Edit command definition
code ~/.claude/commands/custom-command.md

# Test command
/custom-command

# Validate all commands
/audit --scope skills
```

### Integration Testing

Set up comprehensive integration testing:

```bash
# Run all test categories
./tests/test.sh commands
./tests/test.sh config
./tests/test.sh integration
./tests/test.sh performance

# Set up continuous testing
# Add to cron (Linux/macOS)
crontab -e
# Add line: 0 2 * * * cd /path/to/claude-config && ./tests/test.sh

# Windows Task Scheduler
# Create task to run ./tests/test.sh daily
```

## Support and Community

### Getting Help

- **Documentation**: Check [Documentation Index](../DOCUMENTATION_INDEX.md)
- **Issues**: Report problems on [GitHub Issues](https://github.com/damilola-elegbede/claude-config/issues)
- **Discussions**: Join conversations on GitHub Discussions
- **Security**: Use GitHub Security Advisories for security issues

### Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for:

- Development setup
- Code standards
- Testing requirements
- Review process

### Version Compatibility

| Claude Config Version | Claude Code CLI Version | Compatibility |
|-----------------------|-------------------------|---------------|
| 2.1.x | 1.0.x | ✅ Full compatibility |
| 2.0.x | 1.0.x | ✅ Full compatibility |
| 1.x.x | 0.9.x | ⚠️ Limited compatibility |

---

## Next Steps

After successful installation:

1. **Read the Quick Start**: [QUICKSTART.md](../../QUICKSTART.md)
2. **Explore Agents**: [Agent Ecosystem](../agents/README.md)
3. **Learn Commands**: [Command Reference](../commands/README.md)
4. **Performance Guide**: [Performance Optimization](../performance/PERFORMANCE.md)
5. **Best Practices**: [Development Guidelines](../development/AGENT_SELECTION_GUIDE.md)

Welcome to the Claude Configuration Repository ecosystem! You now have access to a production-ready
Smart Agent Orchestration Framework with 8 specialized agents and full skill library.
