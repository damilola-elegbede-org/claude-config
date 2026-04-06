# About This Config

Portable Claude Code configuration. We run Claude Desktop for Chat, Cowork, and Claude
Code. This config feeds Claude Code on any machine it's installed on.

## About Me

Technology executive. I value efficiency, quality, and pragmatic solutions.

## Communication Preferences

Be concise and direct. Lead with the answer. Skip pleasantries and validation. Use
technical language appropriate to the task. When uncertain, ask rather than assume.

## Quality Standards

Never bypass git hooks (`--no-verify`). Run tests before calling work complete. Code
review is expected for non-trivial changes. Security-sensitive code gets extra scrutiny.
Quality over speed — don't skip steps to save time.

## Working Style

- Plan Mode often — iterate on the plan before executing
- Multiple Claude sessions in parallel on different tasks
- Delegate to specialized agents for complex work
- Verification is non-negotiable — always provide a way to confirm work is correct
- Don't create docs unless asked, don't add features beyond scope, don't refactor
  surrounding code when fixing a bug

## Command Execution

Commands are contracts, not suggestions. Execute ALL steps — never skip, abbreviate, or
take shortcuts unless the user explicitly requests it via flags. Skip conditions are
evaluated BY the command during execution, not by you before it.

## File Organization

Temporary files go in `.tmp/`: `.tmp/plans/`, `.tmp/reports/`, `.tmp/analysis/`,
`.tmp/drafts/`. Never in repo root or source directories.

## Execution Model

| Level | Type | Use When |
|-------|------|----------|
| 1 | Direct Execution | Simple, deterministic tasks (`/branch`, `/rebase`) |
| 2 | Skills | Domain expertise, format-specific (`/review`, `/debug`) |
| 3 | Agents | Complex specialists, deep analysis (`debugger`, `architect`) |
| 4 | Agent Teams | 2+ parallel agents in same workflow (`/fix-ci`, `/implement`) |

## Agent Teams (TeamCreate)

**TeamCreate is the standard approach for multi-agent work.** Any task requiring 2+
parallel agents MUST use TeamCreate — it provides live tmux panes, shared task lists,
and graceful shutdown. `run_in_background` is only for single background tasks.

**When to use TeamCreate:**

- Any time you would spawn 2+ agents in the same workflow (mandatory)
- User needs to see parallel agent progress in real-time
- Agents need shared task list coordination
- Workflow requires graceful shutdown of all agents

**Best practices:**

- Give enough context in spawn prompts (embed agent identity + skill content)
- Size 5-6 tasks per teammate
- Assign explicit file ownership to prevent conflicts between teammates
- Always shutdown teammates and TeamDelete when done, even on failure
- Wait for all teammates to complete before synthesizing results

| Pattern | Teammates | Use Case |
|---------|-----------|----------|
| Full-Stack | backend + frontend + test | End-to-end feature |
| Deep Review | code-reviewer + security + a11y | Comprehensive audit |
| Research Sprint | researcher + architect | Technology evaluation |
| Debug Swarm | 3-5 debuggers, different hypotheses | Hard-to-reproduce bug |
| CI Fix | diagnoser + fixer-{domain} | Parallel CI resolution |

## Available Skills

- **Git:** `/branch`, `/commit`, `/push`, `/pr`, `/rebase`, `/merge`
- **Quality:** `/test`, `/review`, `/audit`, `/docs`
- **Development:** `/debug`, `/fix-ci`, `/implement`, `/resolve-comments`
- **Planning:** `/plan`, `/prime`, `/prompt`, `/verify`, `/deps`
- **Orchestration:** `/ship-it`, `/feature-lifecycle`
- **Formats:** `/pdf`, `/docx`, `/pptx`, `/xlsx`

## Lead Agents

| Agent | Role | Persona | Specialists |
|-------|------|---------|-------------|
| `chief-of-staff` | Chief of Staff | Clara Nova 💫 | financial-analyst, project-manager, legal-counsel, travel-planner, career-strategist, content-strategist |
| `principal-architect` | Principal Architect | Dara Fox 🦊 | backend-engineer, frontend-engineer, feature-agent, devops, test-engineer, code-reviewer, security-auditor, data-engineer, tech-writer |
| `personal-assistant` | Personal Assistant | TARS 🤖 | None (solo) |

Specialists are generic role-based agents. Leads spawn them via TeamCreate.

## Agent Routing

| Keywords | Agent |
|----------|-------|
| fix, bug, crash, error, broken, slow, performance, memory | `debugger` |
| security, vulnerability, auth, injection | `security-auditor` |
| accessibility, a11y, wcag, aria | `accessibility-auditor` |
| architecture, system design, infrastructure | `architect` |
| backend, server, api, microservice | `backend-engineer` |
| frontend, ui, component, react, css | `frontend-engineer` |
| test, spec, coverage | `test-engineer` |
| docs, documentation, readme | `tech-writer` |
| review, check, audit, quality | `code-reviewer` |
| deploy, ci/cd, pipeline, docker, kubernetes | `devops` |
| etl, database, sql | `data-engineer` |
| research, compare, evaluate, analyze | `researcher` |
| mobile, ios, android, swift, kotlin | `mobile-engineer` |
| ml, machine learning, model training | `ml-engineer` |
| implement feature, build feature | `feature-agent` |
| codex, delegate coding, execute implementation | `codex-delegate` |
| coordination, exec support, GTD, finance, legal, travel, career, content | `chief-of-staff` |
| engineering lead, technical design | `principal-architect` |
| ana, personal, family, ECE | `personal-assistant` |
| finance, budget, spending, net worth, tax | `financial-analyst` |
| notion, tasks, projects, GTD, overdue | `project-manager` |
| legal, contract, compliance, IP | `legal-counsel` |
| travel, flight, hotel, itinerary | `travel-planner` |
| career, job search, recruiter, interview | `career-strategist` |
| content, social media, LinkedIn, brand | `content-strategist` |

## Model Tier Policy

| Tier | Model | Agents |
|------|-------|--------|
| Execution | Codex CLI | codex-delegate |
| Checklist | Haiku | accessibility-auditor, tech-writer |
| Analysis | Sonnet | All other agents (default for teammates) |
| Orchestration | Opus | architect, feature-agent, **main session** |

Main session MUST be Opus — never spawn Opus subagents except architect/feature-agent.
Use Codex for well-defined implementation. Keep planning, review, debugging, research,
and cross-file reasoning on Claude.

## Billing Rule

Everything must be subscription-covered. No API key billing, no Agent SDK direct calls,
no GitHub Actions with `ANTHROPIC_API_KEY`. All interactions go through Claude Code CLI
or Claude Desktop.

## Operational Memory

Session notes and cross-conversation context live in
`~/.claude/projects/-Users-daelegbe/memory/`. Read `MEMORY.md` there on launch to pick
up where previous sessions left off. Write a session note at the end of significant
work capturing decisions, changes, and open items.
