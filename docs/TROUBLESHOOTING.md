# Troubleshooting Guide

This guide covers common issues and solutions for the Claude Configuration
Repository, including installation problems, agent execution errors, and
performance issues.

## Quick Diagnostics

### Health Check Commands

```bash
# Check if configurations are properly synced
/sync

# Validate all agent configurations
/audit --scope agents

# Run comprehensive system tests
/test

# Check repository context and structure
/prime
```

## Installation and Setup Issues

### Configuration Sync Problems

#### Issue: `/sync` command not found

```bash
Error: Command '/sync' not recognized
```

**Cause**: Claude configurations not properly deployed to user directory.

**Solution**:

```bash
# Ensure you're in the claude-config repository
cd /path/to/claude-config

# Manually copy configurations
cp -r system-configs/.claude ~/.claude
cp system-configs/CLAUDE.md ~/.claude/CLAUDE.md

# Verify deployment
ls -la ~/.claude/
```

#### Issue: Configurations not updating after sync

```bash
Warning: Existing configurations detected, backup created
```

**Cause**: Existing configurations preventing updates.

**Solution**:

```bash
# Remove existing configurations (backup automatically created)
rm -rf ~/.claude/

# Force fresh sync
/sync

# Verify new configurations
/audit --scope agents
```

### Permission Issues

#### Issue: Unable to create ~/.claude directory

```bash
Error: Permission denied: mkdir ~/.claude
```

**Solution**:

```bash
# Fix home directory permissions
sudo chmod 755 ~
mkdir ~/.claude
chmod 755 ~/.claude

# Retry sync
/sync
```

## Agent Execution Problems

### SYSTEM BOUNDARY Violations

#### Issue: "SYSTEM BOUNDARY: operation not permitted"

```bash
Error: SYSTEM BOUNDARY violation - agent attempted unauthorized invocation
```

**Cause**: An agent tried to invoke itself or another agent (security protection).

**This is NOT an error** - it's a security feature working correctly.

**Understanding**:

- Agents cannot invoke themselves or other agents
- Only Claude has orchestration authority
- This prevents infinite loops and security breaches
- Always let Claude handle agent coordination

**Solution**:

- No action needed - system is working correctly
- If you need multiple agents, ask Claude to coordinate them
- Never try to bypass SYSTEM BOUNDARY protection

### Agent Not Found Errors

#### Issue: "Agent not found: [agent-name]"

```bash
Error: Agent 'code-reviewer' not found in ~/.claude/agents/
```

**Diagnosis Steps**:

```bash
# 1. Check if agent files exist
ls ~/.claude/agents/ | grep code-reviewer

# 2. Validate agent YAML format
./scripts/validate-agent-yaml.py

# 3. Re-sync configurations
/sync

# 4. Verify with audit
/audit --scope agents
```

**Common Causes & Solutions**:

1. **Missing Agent File**:

   ```bash
   # Re-sync to restore missing agents
   /sync
   ```

2. **Invalid YAML Format**:

   ```bash
   # Validate and fix YAML issues
   ./scripts/validate-agent-yaml.py
   # Check specific agent
   cat ~/.claude/agents/code-reviewer.md
   ```

3. **Corrupted Configuration**:

   ```bash
   # Fresh installation
   rm -rf ~/.claude
   /sync
   ```

### Agent Capability Issues

#### Issue: Agent refusing to perform expected tasks

```bash
Agent response: "I don't have access to that functionality"
```

**Cause**: Agent lacking proper tool access or role definition.

**Diagnosis**:

```bash
# Check agent capabilities
cat ~/.claude/agents/[agent-name].md | grep -A 10 "capabilities:"

# Review tool access levels
cat ~/.claude/agents/[agent-name].md | grep -A 5 "tools:"
```

**Solution**:

- Verify agent has appropriate tools for the task
- Check [Agent Selection Guide](docs/development/AGENT_SELECTION_GUIDE.md) for proper agent choice
- Consider using different agent with required capabilities

## Command-Specific Issues

### Test Execution Problems

#### Issue: `/test` command fails or times out

```bash
Error: Test execution failed after 10 minutes
```

**Diagnosis**:

```bash
# Run specific test categories
./tests/test.sh commands
./tests/test.sh config
./tests/test.sh integration

# Check test framework availability
which pytest npm go test
```

**Solutions**:

1. **Missing Test Dependencies**:

   ```bash
   # Install required dependencies
   npm install
   pip install -r requirements.txt
   go mod tidy
   ```

2. **Test Framework Issues**:

   ```bash
   # Update test frameworks
   npm update
   pip install --upgrade pytest
   ```

3. **Parallel Execution Problems**:

   ```bash
   # Run tests sequentially for debugging
   ./tests/test.sh --sequential
   ```

### Performance Issues

#### Issue: Commands running slower than expected

```bash
/audit --scope agents taking 5+ minutes (expected: 30-45 seconds)
```

**Performance Diagnostics**:

```bash
# Check system resources
top -n 1

# Monitor memory usage
free -h

# Check disk I/O
iostat 1 5

# Network connectivity
ping -c 3 github.com
```

**Common Performance Solutions**:

1. **Resource Constraints**:

   ```bash
   # Free up memory
   # Close unnecessary applications
   # Check available disk space: df -h
   ```

2. **Network Issues**:

   ```bash
   # Test connectivity
   curl -I https://api.github.com
   # Check for proxy issues
   echo $HTTP_PROXY $HTTPS_PROXY
   ```

3. **Parallelization Disabled**:

   ```bash
   # Verify parallel execution is working
   /audit --scope agents --debug
   # Look for "Creating X parallel instances"
   ```

## Configuration Issues

### YAML Validation Errors

#### Issue: Agent YAML validation failures

```bash
Error: Invalid YAML in agent definition
```

**Diagnosis & Fix**:

```bash
# Run YAML validator
./scripts/validate-agent-yaml.py

# Fix common YAML issues
./scripts/validate-agent-yaml.py --fix

# Check specific agent format
yamllint ~/.claude/agents/[agent-name].md
```

**Common YAML Problems**:

1. **Missing Front-matter**:

   ```yaml
   # Add to top of agent file
   ---
   name: agent-name
   category: development
   capabilities: [...]
   tools: [...]
   ---
   ```

2. **Invalid YAML Syntax**:

   - Check indentation (use spaces, not tabs)
   - Ensure colons have spaces after them
   - Quote strings with special characters

3. **Required Fields Missing**:

   ```yaml
   # Ensure these fields exist
   name: "agent-name"
   category: "development|infrastructure|quality|etc"
   capabilities: ["list", "of", "capabilities"]
   description: "Clear description"
   ```

### Audio Notifications Not Working

#### Issue: No sound feedback from commands

```bash
Commands complete silently, no audio notification
```

**macOS Specific Diagnostics**:

```bash
# Test system audio
afplay /System/Library/Sounds/Glass.aiff

# Check audio settings file
cat ~/.claude/settings.json | jq '.hooks'

# Verify audio files exist
ls -la /System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Classic/
```

**Solutions**:

1. **Missing Audio Configuration**:

   ```bash
   # Re-sync settings
   /sync
   # Verify settings.json was copied
   cat ~/.claude/settings.json
   ```

2. **Audio Files Missing**:

   ```bash
   # Test alternative sound
   afplay /System/Library/Sounds/Ping.aiff
   # Update settings to use available sounds
   ```

3. **Permissions Issue**:

   ```bash
   # Check audio system permissions
   # System Preferences > Security & Privacy > Privacy > Microphone
   # Ensure Terminal/iTerm has audio access
   ```

## Git and Quality Gates

### Pre-commit Hook Failures

#### Issue: Commits blocked by quality gates

```bash
Error: Pre-commit hook failed, commit aborted
```

**Never bypass with `--no-verify`** - Fix the underlying issues.

**Diagnosis & Solutions**:

1. **Markdown Quality Issues**:

   ```bash
   # Run markdown fixer
   ./scripts/validate-markdown-quality.sh fix
   # Re-run validation
   ./scripts/validate-markdown-quality.sh
   ```

2. **Test Failures**:

   ```bash
   # Run tests to see failures
   ./tests/test.sh
   # Fix failing tests
   # Re-run: ./tests/test.sh
   ```

3. **Security Issues**:

   ```bash
   # Run security checks
   ./scripts/security-check.sh
   # Address security findings
   ```

### CI/CD Pipeline Failures

#### Issue: GitHub Actions failing

```bash
CI Status: Failed - Quality gates not met
```

**Use the automated fix command**:

```bash
/fix-ci
```

**Manual Diagnosis**:

```bash
# Check recent commits for issues
git log --oneline -5

# Run local quality checks
./tests/test.sh
./scripts/validate-agent-yaml.py
./scripts/validate-markdown-quality.sh
```

## MCP Integration Issues

### ElevenLabs Integration Problems

#### Issue: ElevenLabs voice synthesis not working

```bash
Error: ElevenLabs API connection failed
```

**Solution**:

```bash
# Check API key is set
echo $ELEVENLABS_API_KEY

# Set API key if missing
export ELEVENLABS_API_KEY="your-api-key"

# Add to shell profile for persistence
echo 'export ELEVENLABS_API_KEY="your-key"' >> ~/.bashrc
```

### Context7 Integration Issues

#### Issue: Documentation lookups failing

```bash
Error: Context7 API unavailable
```

**Solution**:

```bash
# Check API key
echo $CONTEXT7_API_KEY

# Set API key
export CONTEXT7_API_KEY="your-context7-key"

# Verify MCP server
npx -y @upstash/context7-mcp --help
```

## Advanced Diagnostics

### System Health Check

```bash
#!/bin/bash
# Complete system diagnostic script

echo "=== Claude Config Health Check ==="

# 1. Repository Status
echo "Repository Status:"
pwd
git status --porcelain

# 2. Configuration Files
echo "Configuration Files:"
ls -la ~/.claude/
ls ~/.claude/agents/ | wc -l
ls ~/.claude/commands/ | wc -l

# 3. YAML Validation
echo "YAML Validation:"
./scripts/validate-agent-yaml.py --quiet

# 4. Test Status
echo "Test Status:"
./tests/test.sh --quick

# 5. Performance Check
echo "Performance Check:"
time /audit --scope agents --dry-run 2>&1 | grep "parallel instances"

# 6. System Resources
echo "System Resources:"
free -h | head -2
df -h / | tail -1
```

### Debug Mode Execution

Most commands support debug mode for detailed troubleshooting:

```bash
# Enable debug output
export CLAUDE_DEBUG=1

# Run commands with verbose output
/audit --scope agents --debug
/test --verbose
/sync --debug
```

## Getting Help

### When to Seek Further Assistance

1. **Persistent Issues**: Problems lasting >30 minutes after trying solutions
2. **Data Loss Concerns**: Backup/restore issues affecting configurations
3. **Security Concerns**: Potential security violations or breaches
4. **Performance Degradation**: >50% performance loss from expected baselines
5. **New Error Messages**: Errors not covered in this guide

### Information to Provide

When reporting issues, include:

```bash
# System Information
uname -a
echo $SHELL
which claude-code

# Repository Status
git log --oneline -5
git status

# Configuration Status
ls -la ~/.claude/
cat ~/.claude/settings.json | jq '.'

# Recent Command Output
# Include full command output and error messages

# Performance Metrics
time /audit --scope agents --dry-run
```

### Support Channels

- **GitHub Issues**: [Repository Issues](https://github.com/damilola-elegbede/claude-config/issues)
- **Security Issues**: Use GitHub Security Advisories for private reporting
- **Documentation**: Check [Documentation Index](docs/DOCUMENTATION_INDEX.md)
- **Community**: Discussions on GitHub repository

---

## Preventive Maintenance

### Regular Health Checks

```bash
# Weekly maintenance routine
/sync                    # Sync latest configurations
/audit --scope agents            # Validate agent ecosystem
/test                   # Run comprehensive tests
git pull                # Update repository
```

### Performance Monitoring

```bash
# Monitor command performance
time /audit --scope agents       # Should be ~30-45 seconds
time /test             # Should be ~30-40 seconds
time /docs             # Should be ~1-2 minutes
```

### Configuration Backup

```bash
# Backup current configurations
cp -r ~/.claude ~/.claude.backup.$(date +%Y%m%d)

# Verify backup
ls -la ~/.claude.backup.*
```

---

*This troubleshooting guide is continuously updated based on user feedback and
common issues. For the latest troubleshooting information, check the repository
documentation and recent issues.*
