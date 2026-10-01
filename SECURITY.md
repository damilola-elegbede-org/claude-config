# Security Policy

## Supported Versions

This project maintains security updates for the following versions:

| Version    | Supported          |
| ---------- | ------------------ |
| main       | :white_check_mark: |
| feature/\* | :x:                |
| < 1.0      | :x:                |

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue, please follow these steps:

### 1. Do Not Create Public Issues

**IMPORTANT**: Please do not create public GitHub issues for security vulnerabilities. This helps protect users until a fix is available.

### 2. Report Privately

Send security vulnerability reports to:

- Open a private security advisory on GitHub (preferred)
- Contact repository maintainers directly through secure channels

### 3. Include in Your Report

Please provide:

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact assessment
- Suggested fix (if available)
- Your contact information for follow-up

### 4. Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 5 business days
- **Resolution Target**: Based on severity
  - Critical: 24-48 hours
  - High: 3-5 days
  - Medium: 1-2 weeks
  - Low: Next release cycle

## Security Best Practices

### For Contributors

1. **Never commit secrets**: API keys, tokens, passwords
2. **Use environment variables**: For sensitive configuration
3. **Validate input**: All user inputs must be validated
4. **Follow least privilege**: Request minimal permissions
5. **Update dependencies**: Keep all dependencies current

### For Users

1. **Keep configurations secure**: Never share your `.claude/` directory
2. **Review agent permissions**: Understand what each agent can access
3. **Use official sources**: Only install from official repositories
4. **Regular updates**: Keep your installation current
5. **Report suspicious behavior**: Contact us if you notice unusual activity

## Security Features

### Built-in Protections

- **SYSTEM BOUNDARY Protection**: Prevents unauthorized agent invocations
- **Sole Executor Model**: Only Claude has execution authority
- **Tool Access Control**: Granular tool permissions per agent
- **Audit Logging**: All agent actions are logged
- **Input Validation**: All inputs validated before processing

### Decision Gates: What They Do and Don't Stop

The decision gates (`hooks/gate.sh` + `gate-rules.json`) and the Jev gates match on the text of each
tool call. They catch mistakes: a recursive `rm` outside scratch space, a production deploy, an
unpinned `vercel env pull`, or a direct edit of the live gate files. They are **not** a sandbox
against a session that is deliberately trying to get around them. Under `bypassPermissions` the
session runs as your user and can write anything you can, so text matching cannot follow every
indirection: a path held in a shell variable, a name assembled at run time, or a script file the
command runs. The gate files and the fleet identity variable (`BARECLAUDE_AGENT_SLUG`) are guarded
only by that text matching.

Known residuals (reported in PR #268 review, accepted):

- Writes to live hooks, `settings.json` or transcripts through a variable-held or computed path.
- A fleet identity assigned with escapes inside the name or from a script file.

Planned hardening: make the enforcement files owned by root (written only by `scripts/sync.sh`
through `sudo`), so a session cannot change them at all.

### Configuration Security

```bash
# Secure your configuration directory
chmod 700 ~/.claude
chmod 600 ~/.claude/settings.json

# Never share these files
~/.claude/settings.json     # Contains personal configurations
~/.claude/api_keys.json     # Contains API keys (if used)
```

## Vulnerability Disclosure Policy

### Coordinated Disclosure

We follow a coordinated disclosure model:

1. Security issues are fixed in private
2. Patches are released to all supported versions
3. Public disclosure happens after patches are available
4. Credit is given to security researchers (with permission)

### Security Advisories

Security advisories are published through:

- GitHub Security Advisories
- Release notes for security updates
- Direct notification to affected users (when possible)

## Security Checklist for Releases

Before each release:

- [ ] Dependency vulnerability scan
- [ ] Static code analysis
- [ ] Security-focused code review
- [ ] Permission audit for new features
- [ ] Update security documentation

## Contact

For security-related questions that are not vulnerabilities:

- Open a discussion on GitHub
- Tag with `security-question` label

## Acknowledgments

We thank the following security researchers for responsible disclosure:

- (List will be updated as reports are received and resolved)

---

_Last updated: 2025-08-26_
_This security policy is subject to change. Check regularly for updates._
