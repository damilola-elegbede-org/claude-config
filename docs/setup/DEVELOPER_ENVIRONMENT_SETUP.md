# Developer Environment Setup Guide

## Overview

This guide provides comprehensive instructions for setting up a complete development environment for the Claude Configuration Repository, including all tools, dependencies, and integrations needed for development, testing, and deployment.

## Prerequisites Check

Before beginning the setup process, verify system requirements:

### Hardware Requirements

##### Minimum Requirements:

- **RAM**: 8 GB (16 GB recommended for parallel agent execution)
- **Storage**: 2 GB free space (5 GB recommended for development)
- **CPU**: Multi-core processor (4+ cores recommended for optimal agent orchestration)
- **Network**: Stable internet connection for MCP integrations and API access

##### Recommended Specifications:

- **RAM**: 16 GB+ for optimal multi-agent parallel processing
- **Storage**: 10 GB+ on SSD for fast file operations
- **CPU**: 8+ cores for maximum agent parallelization benefits
- **Network**: High-speed connection for seamless CI/CD operations

### Operating System Support

| Platform | Version | Support Level | Notes |
|----------|---------|---------------|-------|
| **macOS** | 12.0+ | ✅ Full | Native audio notifications, optimal performance |
| **Linux** | Ubuntu 20.04+ | ✅ Full | Excellent Docker support, CI/CD compatible |
| **Windows** | 10/11 | ⚠️ Limited | WSL2 recommended for best experience |

## Core Development Tools

### 1. Claude Code CLI Installation

##### Primary Installation Methods:

```bash
# Method 1: NPM (Recommended)
npm install -g @anthropic/claude-code

# Method 2: Homebrew (macOS)
brew install claude-code

# Method 3: Direct download
curl -sSL https://install.claude-code.anthropic.com | sh

# Verify installation
claude-code --version
```

##### Configuration:

```bash
# Initialize configuration
mkdir -p ~/.claude
touch ~/.claude/config.json

# Set default model and preferences
cat > ~/.claude/config.json << EOF
{
  "default_model": "claude-sonnet-4-6",
  "max_tokens": 4096,
  "temperature": 0.7,
  "stream": true
}
EOF
```

### 2. Version Control Setup

##### Git Configuration:

```bash
# Install Git (if not already installed)
# macOS
brew install git

# Ubuntu/Debian
sudo apt update && sudo apt install git

# Windows
winget install Git.Git

# Configure Git identity
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Configure Git for better Claude integration
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global push.default current

# Enable helpful Git features
git config --global alias.st status
git config --global alias.co checkout
git config --global alias.br branch
git config --global alias.ci commit
```

##### Git Quality Gates Setup:

```bash
# The repository includes pre-commit and pre-push hooks
# These are automatically configured during /sync

# Verify hooks are properly installed
ls -la .git/hooks/

# Test quality gates
echo "Testing quality gates..."
/test --quick
```

### 3. Node.js and Package Management

##### Node.js Installation:

```bash
# Install Node.js v18+ LTS (Required)
# macOS
brew install node

# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

# Windows
winget install OpenJS.NodeJS

# Verify installation
node --version  # Should be v18+
npm --version   # Should be v9+
```

##### Development Dependencies:

```bash
# Global utilities for Claude development
npm install -g @anthropic/claude-code
npm install -g markdownlint-cli
npm install -g eslint
npm install -g prettier
npm install -g typescript

# Verify global tools
claude-code --version
markdownlint --version
eslint --version
```

### 4. Python Development Environment

##### Python Installation:

```bash
# Install Python 3.8+ (Required for validation scripts)
# macOS
brew install python

# Ubuntu/Debian
sudo apt install python3 python3-pip python3-venv

# Windows
winget install Python.Python.3

# Verify installation
python3 --version  # Should be 3.8+
pip3 --version
```

##### Python Development Setup:

```bash
# Create virtual environment for Claude development
python3 -m venv ~/.claude-dev-env

# Activate virtual environment
# macOS/Linux
source ~/.claude-dev-env/bin/activate

# Windows
~/.claude-dev-env/Scripts/activate

# Install development dependencies
pip install pyyaml
pip install markdown
pip install requests
pip install jsonschema
pip install pytest
pip install black
pip install flake8

# Add to shell profile for automatic activation
echo 'alias claude-env="source ~/.claude-dev-env/bin/activate"' >> ~/.bashrc
# or ~/.zshrc for Zsh users
```

### 5. Go Development Setup (Optional)

For Go-based projects and advanced dependency analysis:

```bash
# Install Go
# macOS
brew install go

# Ubuntu/Debian
sudo apt install golang-go

# Windows
winget install GoLang.Go

# Configure Go workspace
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# Add to shell profile
echo 'export GOPATH=$HOME/go' >> ~/.bashrc
echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.bashrc

# Verify installation
go version
```

## Development Environment Configuration

### 1. Repository Setup

##### Clone and Configure Repository:

```bash
# Clone the repository
git clone https://github.com/damilola-elegbede/claude-config.git
cd claude-config

# For development: fork and clone your fork
git clone https://github.com/YOUR-USERNAME/claude-config.git
cd claude-config
git remote add upstream https://github.com/damilola-elegbede/claude-config.git

# Initialize development environment
./scripts/setup-dev-environment.sh  # If available
```

##### Development Branch Strategy:

```bash
# Create feature branch
git checkout -b feature/your-feature-name

# Development workflow
git add .
git commit -m "feat: implement new feature"
git push origin feature/your-feature-name

# Create pull request via GitHub web interface or CLI
```

### 2. IDE and Editor Setup

##### Recommended IDEs:

##### Visual Studio Code (Recommended):

```bash
# Install VS Code
# macOS
brew install --cask visual-studio-code

# Ubuntu/Debian
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list
sudo apt update && sudo apt install code

# Windows
winget install Microsoft.VisualStudioCode
```

##### Essential VS Code Extensions:

```json
{
  "recommendations": [
    "ms-python.python",
    "ms-vscode.vscode-typescript-next",
    "davidanson.vscode-markdownlint",
    "esbenp.prettier-vscode",
    "ms-vscode.vscode-eslint",
    "redhat.vscode-yaml",
    "ms-vscode.vscode-json",
    "github.vscode-pull-request-github",
    "github.copilot"
  ]
}
```

##### VS Code Configuration for Claude Development:

```json
{
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll.eslint": true,
    "source.fixAll.markdownlint": true
  },
  "markdown.extension.toc.updateOnSave": false,
  "python.defaultInterpreterPath": "~/.claude-dev-env/bin/python",
  "yaml.schemas": {
    "./schemas/agent-schema.json": "system-configs/.claude/agents/*.md"
  },
  "files.associations": {
    "*.md": "markdown"
  },
  "markdownlint.config": {
    "MD013": { "line_length": 150 },
    "MD033": false,
    "MD041": false
  }
}
```

### 3. Shell Environment Configuration

##### Bash Configuration (.bashrc):

```bash
# Claude Development Environment
export CLAUDE_CONFIG_PATH="$HOME/Documents/Projects/claude-config"
export CLAUDE_DEV_MODE=true

# Development aliases
alias ccd="cd $CLAUDE_CONFIG_PATH"
alias claude-env="source ~/.claude-dev-env/bin/activate"
alias claude-test="cd $CLAUDE_CONFIG_PATH && ./tests/test.sh"
alias claude-validate="cd $CLAUDE_CONFIG_PATH && ./scripts/validate-agent-yaml.py"

# Claude CLI shortcuts
alias cc="claude-code"
alias agent-audit="/agent-audit"
alias prime="/prime"
alias sync="/sync"

# Development workflow shortcuts
alias dev-setup="claude-env && ccd"
alias dev-test="claude-test && claude-validate"
alias dev-commit="git add . && /commit"
alias dev-push="/push"

# Performance monitoring
alias perf-test="time /agent-audit && time /test && time /prime"
```

##### Zsh Configuration (.zshrc):

```zsh
# Source bash configuration for compatibility
[[ -f ~/.bashrc ]] && source ~/.bashrc

# Zsh-specific Claude configurations
autoload -Uz compinit
compinit

# Enhanced tab completion for Git
zstyle ':completion:*:git:*' tag-order 'heads:-branch:branch refs'

# Claude development prompt
PROMPT='%F{blue}claude%f:%F{green}%c%f%F{yellow}$(git branch 2>/dev/null | grep "^*" | cut -d" " -f2)%f$ '
```

### 4. Environment Variables

##### Required Environment Variables:

```bash
# Core Claude Configuration
export CLAUDE_CONFIG_PATH="$HOME/Documents/Projects/claude-config"
export CLAUDE_HOME="$HOME/.claude"

# Development flags
export CLAUDE_DEV_MODE=true
export CLAUDE_DEBUG=false
export CLAUDE_PERFORMANCE_MONITORING=true

# Quality gates
export CLAUDE_QUALITY_GATES_ENABLED=true
export CLAUDE_AUTO_FIX=false

# Add to shell profile
cat >> ~/.bashrc << EOF
# Claude Configuration Repository Environment
export CLAUDE_CONFIG_PATH="$HOME/Documents/Projects/claude-config"
export CLAUDE_HOME="$HOME/.claude"
export CLAUDE_DEV_MODE=true
export CLAUDE_QUALITY_GATES_ENABLED=true
EOF
```

##### Optional MCP Integration Variables:

```bash
# ElevenLabs Integration (Optional)
export ELEVENLABS_API_KEY="your-api-key-here"

# GitHub Integration (Recommended)
export GITHUB_TOKEN="your-github-token"

# Context7 Integration (Optional)
export CONTEXT7_API_KEY="your-context7-key"

# Add to secure environment file
cat >> ~/.claude-env-secure << EOF
export ELEVENLABS_API_KEY="your-api-key"
export GITHUB_TOKEN="your-token"
export CONTEXT7_API_KEY="your-key"
EOF

# Source secure variables (add to shell profile)
echo 'source ~/.claude-env-secure' >> ~/.bashrc
```

## Development Workflow Setup

### 1. Testing Environment

##### Test Suite Configuration:

```bash
# Navigate to repository
cd $CLAUDE_CONFIG_PATH

# Run initial test validation
./tests/test.sh

# Set up test categories
./tests/test.sh commands
./tests/test.sh config
./tests/test.sh integration
./tests/test.sh performance

# Validate agent configurations
./scripts/validate-agent-yaml.py

# Test agent ecosystem
/agent-audit

# Performance benchmarking
time /agent-audit    # Should be ~30-45 seconds
time /test          # Should be ~30-40 seconds
time /prime         # Should be ~15-20 seconds
```

##### Continuous Testing Setup:

```bash
# Set up file watching for development
# Install entr (file watcher)
# macOS
brew install entr

# Ubuntu/Debian
sudo apt install entr

# Create development watcher script
cat > scripts/watch-and-test.sh << 'EOF'
#!/bin/bash
echo "Watching for changes in system-configs/..."
find system-configs/ -name "*.md" -o -name "*.json" | entr -c ./tests/test.sh
EOF
chmod +x scripts/watch-and-test.sh

# Run watcher in development
./scripts/watch-and-test.sh
```

### 2. Documentation Development

##### Documentation Workflow:

```bash
# Generate documentation
/docs

# Update documentation index
./scripts/update-documentation.py

# Validate markdown quality
./scripts/validate-markdown-quality.sh

# Auto-fix common markdown issues
./scripts/validate-markdown-quality.sh fix

# Preview documentation locally
# If mkdocs is available
mkdocs serve
```

### 3. Agent Development Workflow

##### Creating New Agents:

```bash
# Use agent template
cp docs/agents/AGENT_TEMPLATE.md system-configs/.claude/agents/new-agent.md

# Edit agent definition
code system-configs/.claude/agents/new-agent.md

# Validate new agent
./scripts/validate-agent-yaml.py

# Test agent in ecosystem
/sync
/agent-audit

# Commit changes
/commit
```

##### Agent Testing and Validation:

```bash
# Test individual agent
claude-code
# Test the new agent functionality

# Run comprehensive validation
./scripts/validate-system.sh

# Performance impact assessment
time /agent-audit  # Compare before/after performance
```

### 4. Quality Assurance Workflow

##### Pre-commit Quality Checks:

```bash
# Run all quality checks before committing
./scripts/validate-markdown-quality.sh
./scripts/validate-agent-yaml.py
./scripts/validate-system.sh
./tests/test.sh

# Auto-fix issues where possible
./scripts/validate-markdown-quality.sh fix

# Manual review checklist
echo "Quality Checklist:"
echo "✓ All tests pass"
echo "✓ Markdown validates"
echo "✓ YAML structure correct"
echo "✓ Agent ecosystem healthy"
echo "✓ Documentation updated"
```

## Performance Optimization

### 1. System Optimization

##### Memory Optimization:

```bash
# Increase Node.js memory limit for large operations
export NODE_OPTIONS="--max-old-space-size=4096"

# Python memory optimization
export PYTHONUNBUFFERED=1

# Optimize for parallel processing
export UV_THREADPOOL_SIZE=16
```

##### Disk Optimization:

```bash
# Use SSD for optimal performance
# Ensure repository is on fastest available storage

# Clean temporary files regularly
rm -rf .tmp/reports/*
rm -rf .tmp/logs/*
find . -name "*.tmp" -delete
find . -name ".DS_Store" -delete
```

### 2. Parallel Processing Setup

##### Configure for Multi-Agent Performance:

```bash
# Optimize parallel execution
export CLAUDE_MAX_PARALLEL_AGENTS=8
export CLAUDE_AGENT_TIMEOUT=300
export CLAUDE_ORCHESTRATION_MODE=true

# Monitor parallel performance
alias perf-monitor="ps aux | grep claude && netstat -an | grep ESTABLISHED"
```

## Troubleshooting Development Environment

### Common Issues

##### Issue: Claude Code CLI not responding

```bash
# Solution: Clear CLI cache
rm -rf ~/.claude/cache
rm -rf ~/.anthropic/cache

# Restart with clean state
claude-code --reset
```

##### Issue: Agent validation fails

```bash
# Solution: Reset and re-sync
cd $CLAUDE_CONFIG_PATH
/sync --force
./scripts/validate-agent-yaml.py --fix
```

##### Issue: Quality gates failing

```bash
# Solution: Run auto-fix sequence
./scripts/validate-markdown-quality.sh fix
./scripts/validate-system.sh
./tests/test.sh --fix-issues
```

##### Issue: Poor performance

```bash
# Solution: System optimization
# Check system resources
top -n 1
free -h  # Linux
vm_stat  # macOS

# Optimize Claude settings
export CLAUDE_MAX_PARALLEL_AGENTS=4  # Reduce if system limited
export NODE_OPTIONS="--max-old-space-size=2048"

# Clean and restart
rm -rf .tmp/
/sync
```

### Debug Mode

##### Enable Debug Logging:

```bash
# Enable debug mode
export CLAUDE_DEBUG=true
export CLAUDE_LOG_LEVEL=debug

# View debug logs
tail -f ~/.claude/logs/debug.log

# Debug specific operations
/agent-audit --debug
/test --verbose --debug
```

## Integration Testing

### End-to-End Testing

##### Complete Development Workflow Test:

```bash
#!/bin/bash
# Complete development environment test

echo "=== Claude Development Environment Test ==="

# 1. Environment check
echo "1. Checking environment..."
claude-code --version || exit 1
python3 --version || exit 1
node --version || exit 1
git --version || exit 1

# 2. Repository validation
echo "2. Validating repository..."
cd $CLAUDE_CONFIG_PATH || exit 1
./scripts/validate-system.sh || exit 1

# 3. Agent ecosystem test
echo "3. Testing agent ecosystem..."
/sync || exit 1
/agent-audit || exit 1

# 4. Command system test
echo "4. Testing command system..."
/test --quick || exit 1

# 5. Performance benchmark
echo "5. Running performance benchmark..."
time /prime --lite

# 6. Quality gates test
echo "6. Testing quality gates..."
git status
echo "test change" > .tmp/test-file.md
git add .tmp/test-file.md
git commit -m "test: development environment validation"
git reset --soft HEAD~1  # Undo test commit
rm .tmp/test-file.md

echo "✅ Development environment fully functional!"
```

## Next Steps

After completing the development environment setup:

1. **Read Development Guidelines**: Review [development requirements](../development/)
2. **Explore Agent Architecture**: Study [agent ecosystem architecture](../architecture/agent-ecosystem-architecture.md)
3. **Performance Optimization**: Learn [performance best practices](../performance/PERFORMANCE.md)
4. **Quality Standards**: Understand [quality gates](../quality/QUALITY_GATE_IMPLEMENTATION.md)
5. **Contributing**: Follow [contribution guidelines](../../CONTRIBUTING.md)

## Support

For development environment issues:

- **Documentation**: Check [Documentation Index](../DOCUMENTATION_INDEX.md)
- **Issues**: Report on [GitHub Issues](https://github.com/damilola-elegbede/claude-config/issues)
- **Discussions**: Join [GitHub Discussions](https://github.com/damilola-elegbede/claude-config/discussions)

Your development environment is now configured for optimal Claude Configuration Repository development with full agent orchestration capabilities and quality assurance.
