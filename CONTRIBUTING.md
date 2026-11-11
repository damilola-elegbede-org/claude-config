# Contributing to Claude Configuration Repository

Welcome! This guide helps you contribute effectively to the Claude Code CLI configuration ecosystem.

## Quick Start

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes following our standards
4. Run tests with `/verify`
5. Submit a pull request

## Development Standards

### Agent Development

When creating agents, use the template in `docs/agents/AGENT_TEMPLATE.md`:

- Include valid YAML front-matter
- Add SYSTEM BOUNDARY protection
- Define clear capabilities
- Run validation (mandatory): `./scripts/validate-agent-yaml.py`
- Keep the agents reference up to date: `docs/agents/README.md`

### Command Development

Commands go in `system-configs/.claude/commands/`:

- Use clear, descriptive names
- Include comprehensive documentation
- Add usage examples
- Test thoroughly before committing
- Perform behavioral testing for commands in `system-configs/.claude/commands/*` prior to PR (dry-run and happy-path runs)

### Code Standards

- **Clarity over cleverness**: Write readable code
- **Consistent formatting**: Follow existing patterns
- **Error handling**: Graceful failure modes
- **Security first**: Consider security implications

## Testing

Run all tests before submitting (GitHub CLI and required tools installed):

```bash
/verify
./tests/test.sh
```

## Git Workflow

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```bash
feat(agents): add performance monitoring agent
fix(sync): resolve file permission issues
docs(commands): update test documentation
```

### Pull Request Process

1. Create focused PRs (one feature per PR)
2. Update documentation as needed
3. Ensure all tests pass
4. Write descriptive PR descriptions

## Quality Gates

All contributions must pass the following gates:

- Agent YAML schema validation
- Full test suite execution
- Documentation consistency checks
- Security boundary checks (SYSTEM BOUNDARY present and correct)

## Getting Help

- Check existing documentation first
- Create detailed bug reports with `/bug`
- Ask questions in GitHub discussions

## Code of Conduct

- Be respectful and constructive
- Help others learn and grow
- Share knowledge openly
- Focus on solutions

Thank you for contributing!
