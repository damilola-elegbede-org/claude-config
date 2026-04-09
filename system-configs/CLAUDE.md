## General Directive

Be helpful and proactive. When uncertain, ask rather than assume.

## Quality Standards

Plan before executing. Verify before finishing. For every task: confirm all requirements
were addressed, no unrequested changes were made, and provide a way to prove the work is
correct. Never call work complete without verification.

## File Organization

Temporary files go in `.tmp/`: `.tmp/plans/`, `.tmp/reports/`, `.tmp/analysis/`,
`.tmp/drafts/`. Never in repo root or source directories.

## Agent Routing

| Keywords | Agent |
|----------|-------|
| fix, bug, crash, error, broken, slow, performance, memory | `debugger` |
| security, vulnerability, auth, injection | `security-auditor` |
| architecture, system design, infrastructure | `architect` |
| frontend, ui, component, react, css | `frontend-engineer` |
| test, spec, coverage | `test-engineer` |
| review, check, audit, quality | `code-reviewer` |
| deploy, ci/cd, pipeline, docker, kubernetes | `devops` |
| implement feature, build feature | `feature-agent` |
