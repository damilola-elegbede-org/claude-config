# About Me

Technology executive. I value efficiency, quality, and pragmatic solutions.

## Communication Preferences

Be concise and direct. Lead with the answer. Skip pleasantries and validation. Use
technical language appropriate to the task. When uncertain, ask rather than assume.

## Quality Standards

Never bypass git hooks (`--no-verify`). Run tests before calling work complete. Code
review is expected for non-trivial changes. Security-sensitive code gets extra scrutiny.
Quality over speed — don't skip steps to save time.

## Machine & Fleet

Mac Mini M4 (`damilola-mbm`) running a personal AI fleet on Claude Code + Claude Desktop.

- **Leads:** Clara Nova (Chief of Staff, Telegram+Slack), Dara Fox (Distinguished Engineer,
  Telegram+Slack), TARS (Ana's PA, Telegram)
- **Telegram bots:** `@ClaraNovaBot`, `@DaraFoxBot`, `@TARSBot` run as tmux sessions
- **Scheduled tasks:** 15 via Claude Desktop, heartbeats in `~/.cortex/heartbeats/`
- **Cortex:** monitoring dashboard only (port 3000), reads heartbeats
- **Source of truth:** `~/Documents/Projects/claude-config/`, deploy via `./scripts/sync.sh`

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

## Available Skills

- **Git:** `/branch`, `/commit`, `/push`, `/pr`, `/rebase`, `/merge`
- **Quality:** `/test`, `/review`, `/audit`, `/docs`
- **Development:** `/debug`, `/fix-ci`, `/implement`, `/resolve-comments`
- **Planning:** `/plan`, `/prime`, `/prompt`, `/verify`, `/deps`
- **Orchestration:** `/ship-it`, `/feature-lifecycle`
- **Fleet Ops:** `/clara-briefing`, `/email-triage`, `/systems-check`, `/security-ops`,
  `/slack-ops`
- **Formats:** `/pdf`, `/docx`, `/pptx`, `/xlsx`

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
| chief of staff, briefing, exec support | `clara-nova` |
| distinguished engineer, fleet lead, eng ops | `dara-fox` |
| ana, personal assistant | `tars` |
| finance, budget, spending, net worth, tax | `financial-analyst` |
| notion, tasks, projects, GTD, overdue | `project-manager` |
| legal, contract, compliance, IP | `legal-counsel` |
| travel, flight, hotel, itinerary | `travel-planner` |
| career, job search, recruiter, interview | `career-strategist` |
| content, social media, LinkedIn, brand | `content-strategist` |

## Agent Teams (TeamCreate)

**Any task that requires 2+ parallel agents MUST use TeamCreate** — provides live tmux
panes, shared task list, and graceful shutdown. `run_in_background` is only for single
background tasks. Give enough context in spawn prompts, size 5-6 tasks per teammate,
assign explicit file ownership to prevent conflicts, always shutdown and TeamDelete
when done (even on failure).

| Pattern | Teammates | Use Case |
|---------|-----------|----------|
| Full-Stack | backend + frontend + test | End-to-end feature |
| Deep Review | code-reviewer + security + a11y | Comprehensive audit |
| Research Sprint | researcher + architect | Technology evaluation |
| Debug Swarm | 3-5 debuggers, different hypotheses | Hard-to-reproduce bug |
| CI Fix | diagnoser + fixer-{domain} | Parallel CI resolution |

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
