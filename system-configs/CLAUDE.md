# About Me

I'm a technology executive who values efficiency, quality, and pragmatic solutions.
I work across diverse projects and prefer Claude to adapt to each context while
maintaining consistent standards.

## Machine & Agent System

This is a Mac Mini M4 (`damilola-mbm`) running a personal AI agent fleet powered by
Claude Code + Claude Desktop.

### Architecture

```
D (interactive CLI or Telegram)  ←→  Claude Code main session
                                        ├── clara-nova (Chief of Staff)
                                        ├── dara-fox (Distinguished Engineer)
                                        └── tars (Ana's Personal Assistant)

Telegram Bots (tmux sessions)
├── @ClaraNovaBot → claude --agent clara-nova --channels telegram
├── @DaraFoxBot   → claude --agent dara-fox --channels telegram
└── @TARSBot      → claude --agent tars --channels telegram (pending)

Desktop Tasks (Claude Desktop, 15 scheduled)
├── Clara: Email Check, Morning Brief, EOD Wrap, GTD Pulse, Financial Suite, etc.
└── Dara: Engineering Standup, PR Review, Security Sweep, Dead Man Switch, etc.

Cortex (monitoring dashboard only — port 3000)
└── Reads heartbeat files from ~/.cortex/heartbeats/
```

### Lead Agents

| Agent | Role | Chat Surface | Specialists |
|-------|------|-------------|-------------|
| Clara Nova | Chief of Staff | Telegram + Slack | financial-analyst, project-manager, legal-counsel, travel-planner, career-strategist, content-strategist |
| Dara Fox | Distinguished Engineer | Telegram + Slack | backend-engineer, frontend-engineer, feature-agent, devops, test-engineer, code-reviewer, security-auditor, data-engineer, tech-writer |
| TARS | Ana's Personal Assistant | Telegram | None (solo) |

Specialists are generic role-based agents (not named personas). Leads spawn them via TeamCreate.

### Key Paths

| Path | Purpose |
|------|---------|
| `~/.claude/agents/` | 25 agent definitions (3 leads + 22 generics) |
| `~/.claude/skills/` | 43 skills (35 generic + 8 fleet-specific) |
| `~/.claude/mcp-servers/` | 7 custom MCP server scripts |
| `~/.claude/settings.json` | MCP registration, hooks, env vars |
| `~/.claude/channels/telegram-{clara,dara,tars}/` | Per-bot Telegram state + access control |
| `~/.claude/task-specs/` | 30 scheduled task prompt specifications |
| `~/.cortex/heartbeats/` | Task execution heartbeat files (JSON) |
| `~/.cortex/credentials/` | Age-encrypted secrets + Telegram bot tokens |
| `~/Documents/Projects/cortex/` | Cortex source repo (dashboard + bridge) |
| `~/Documents/Projects/claude-config/` | Agent/skill/MCP config repo (source of truth) |

### MCP Servers (7 registered)

| Server | Purpose |
|--------|---------|
| `slack-multipost` | Post to Slack as Clara or Dara bot identity |
| `gog-gmail` | Multi-account Gmail (send, search, read, archive) |
| `gog-calendar` | Google Calendar events (all calendars) |
| `notion` | Notion API (Tasks, Projects, Goals DBs) |
| `monarch-finance` | Financial data via Vesper's Python scripts |
| `damilola-tech` | DK API for job scoring + activity publishing |
| `github-multiagent` | Per-agent Git identity + GitHub App tokens |

### Telegram Bots

Run as persistent tmux sessions:
```bash
# Start bots
tmux new-session -d -s telegram-clara \
  "TELEGRAM_STATE_DIR=~/.claude/channels/telegram-clara claude --agent clara-nova \
   --channels plugin:telegram@claude-plugins-official \
   --dangerously-skip-permissions --permission-mode bypassPermissions \
   --settings /tmp/telegram-clara-settings.json"

tmux new-session -d -s telegram-dara \
  "TELEGRAM_STATE_DIR=~/.claude/channels/telegram-dara claude --agent dara-fox \
   --channels plugin:telegram@claude-plugins-official \
   --dangerously-skip-permissions --permission-mode bypassPermissions \
   --settings /tmp/telegram-dara-settings.json"

# Check status
tmux list-sessions

# View a bot's session
tmux attach -t telegram-clara
```

### Scheduled Tasks

15 Desktop Tasks managed via Claude Desktop. Heartbeats written to `~/.cortex/heartbeats/`.

| Task | Schedule | Agent |
|------|----------|-------|
| Email Check | 7am/1pm/5pm | Clara |
| Morning Brief (EDB) | 6:57am | Clara |
| EOD Wrap | 8:03pm | Clara |
| GTD Pulse | 12:27pm MWF | Clara |
| Financial Anomaly Scan | 8:03am | Clara |
| Weekly Financial Digest | 4:03am Sun | Clara |
| Job Search | 6:42am Sun | Clara |
| Executive Coaching | 6:03pm Sun | Clara |
| Nexus Slack Audit | 12:27pm Sun | Clara |
| Engineering Standup | 4:57am M-F | Dara |
| PR Review Poll | */15 8am-8pm | Dara |
| Security Sweep | 3:27am M-Sat | Dara |
| Dead Man Switch | :07 hourly | Dara |
| Fleet Health Check | 8:03am | Dara |
| API Health Monitor | */30 | Dara |

### Remote Access

SSH into Mac Mini via Tailscale from any device:
```bash
ssh daelegbe@damilola-mbm.tail873377.ts.net
claude  # interactive session, subscription-covered
claude --agent clara-nova  # start as Clara
```

## Communication Preferences

- Be concise and direct - I scan output quickly
- Lead with the answer, then explain if needed
- Use technical language appropriate to the task
- Skip unnecessary pleasantries and validation
- When uncertain, ask rather than assume

## Working Style

- I use Plan Mode frequently - iterate on the plan before executing
- I often run multiple Claude sessions in parallel on different tasks
- I prefer delegation to specialized agents for complex work
- I value verification - always provide a way to confirm work is correct

## Quality Standards

- Never bypass git hooks with --no-verify
- Run tests before considering work complete
- Code review is expected for non-trivial changes
- Security-sensitive code requires extra scrutiny
- Don't skip steps to save time - quality over speed

## Command Execution

When invoking a command (slash command, skill, or orchestrated step):

**Execute ALL steps defined in command specifications - never skip, abbreviate, or take
shortcuts unless the user explicitly requests it via flags. Command definitions are
contracts, not suggestions.**

Do not preemptively skip, shortcut, or modify the command's behavior based on your own
judgment. The command's instructions define how to handle all cases - including edge
cases, empty states, and "nothing to do" scenarios.

If a command has skip conditions, those conditions are evaluated BY the command during
execution, not by you before execution.

## File Organization

All temporary files, reports, and working documents go in `.tmp/`:

- `.tmp/plans/` - Task planning documents
- `.tmp/reports/` - Generated summaries
- `.tmp/analysis/` - Investigation results
- `.tmp/drafts/` - Work-in-progress

Never create temporary files in repository root or source directories.

## Agent Usage

Use specialized agents when the task benefits from focused expertise:

- Debugging complex issues → debugger
- Security reviews → security-auditor
- Architecture decisions → architect
- Code review → code-reviewer
- Performance optimization → debugger (with --performance)

Don't over-delegate simple tasks. Use judgment.

## Agent Teams

Multiple Claude instances coordinated via TeamCreate with shared task list and mailbox.

**Any task that requires 2+ parallel agents or subagents MUST use TeamCreate.** Do not use
`run_in_background` with multiple Task calls — those agents are invisible API calls
with no terminal, no shared coordination, and no user visibility. TeamCreate gives
each agent a real tmux pane where you can watch them work live.

### When to Use TeamCreate

- **Any time you would spawn 2+ agents or subagents in the same workflow** — this is mandatory, not optional
- User needs to see parallel agent progress in real-time (tmux panes)
- Agents need shared task list coordination
- Workflow requires graceful shutdown of all agents

### When NOT to Use TeamCreate

- Single agent delegation (use `Task` directly)
- Sequential workflows where agents run one after another

### Patterns

| Pattern | Teammates | Use Case |
|---------|-----------|----------|
| Full-Stack Feature | backend-engineer, frontend-engineer, test-engineer | End-to-end feature |
| Deep Review | code-reviewer, security-auditor, accessibility-auditor | Comprehensive audit |
| Research Sprint | researcher, architect | Technology evaluation |
| Debug Swarm | 3-5 debuggers with different hypotheses | Hard-to-reproduce bug |
| CI Fix | debugger-1..N, fixer-{domain} | Parallel CI failure resolution |

### Best Practices

- Give enough context in spawn prompts (embed agent identity + skill content)
- Size 5-6 tasks per teammate
- Assign explicit file ownership to prevent conflicts between teammates
- Always shutdown teammates and TeamDelete when done, even on failure
- Wait for all teammates to complete before synthesizing results

## Mistakes to Avoid

- Don't create documentation files unless explicitly requested
- Don't add features beyond what was asked
- Don't refactor surrounding code when fixing a bug
- Don't bypass quality gates to save time

## Skills System

Skills provide focused domain expertise without full agent orchestration.

### Execution Model

| Level | Type | Use When | Example |
|-------|------|----------|---------|
| 1 | Direct Execution | Simple, deterministic tasks | `/branch`, `/rebase`, `/merge` |
| 2 | Skills | Domain expertise, format-specific | `/review`, `/debug`, `/ship-it` |
| 3 | Agents | Complex specialists, deep analysis | `debugger`, `architect`, `security-auditor` |
| 4 | Agent Teams (TeamCreate) | 2+ parallel agents in same workflow | `/fix-ci`, `/review --deep`, `/implement` |

## Available Skills

Skills provide focused operations for common workflows:

**Git Operations:** `/branch`, `/commit`, `/push`, `/pr`, `/rebase`, `/merge`
**Quality:** `/test`, `/review`, `/audit`, `/docs`
**Development:** `/debug`, `/fix-ci`, `/implement`, `/resolve-comments`
**Planning:** `/plan`, `/prime`, `/prompt`, `/verify`, `/deps`
**Orchestration:** `/ship-it`, `/feature-lifecycle` (combines multiple skills)
**Fleet Operations:** `/clara-briefing`, `/email-triage`, `/systems-check`, `/security-ops`, `/slack-ops`
**Formats:** `/pdf`, `/docx`, `/pptx`, `/xlsx`

## Agent Routing

| Keywords | Agent |
|----------|-------|
| fix, broken, bug, crash, error, not working | `debugger` |
| slow, performance, optimize, latency, memory | `debugger` |
| security, vulnerability, auth, injection | `security-auditor` |
| accessibility, a11y, wcag, aria, screen reader | `accessibility-auditor` |
| architecture, system design, infrastructure | `architect` |
| backend, server, api, microservice | `backend-engineer` |
| frontend, ui, component, react, css | `frontend-engineer` |
| test, spec, coverage, unit test | `test-engineer` |
| docs, documentation, readme | `tech-writer` |
| review, check, audit, quality | `code-reviewer` |
| deploy, ci/cd, pipeline, docker, kubernetes | `devops` |
| pipeline, etl, database, sql | `data-engineer` |
| research, compare, evaluate, analyze | `researcher` |
| mobile, ios, android, swift, kotlin | `mobile-engineer` |
| ml, machine learning, model training | `ml-engineer` |
| implement feature, build feature | `feature-agent` |
| codex, delegate coding, execute implementation | `codex-delegate` |
| email, inbox, triage, briefing, schedule, calendar | `clara-nova` |
| finance, budget, spending, net worth, tax | `financial-analyst` |
| notion, tasks, projects, GTD, overdue | `project-manager` |
| legal, contract, compliance, IP | `legal-counsel` |
| travel, flight, hotel, itinerary | `travel-planner` |
| career, job search, recruiter, interview | `career-strategist` |
| content, social media, LinkedIn, brand | `content-strategist` |

## Model Tier Policy

| Tier | Model | Agents |
|------|-------|--------|
| Execution | Codex CLI | codex-delegate (coding workhorse for well-defined tasks) |
| Checklist | Haiku | accessibility-auditor, tech-writer |
| Analysis | Sonnet | All other agents (default for TeamCreate teammates) |
| Orchestration | Opus | architect, feature-agent, **main session** |

- Main session MUST be Opus — never spawn Opus subagents except architect/feature-agent
- Codex delegation: Claude plans → scopes → Codex executes → Claude reviews
- Use Codex for implementation/tests/refactoring/fixes with clear requirements
- Keep planning, review, debugging, research, and cross-file reasoning on Claude

## Billing Rule

**Everything must be subscription-covered.** No API key billing, no Agent SDK direct calls,
no GitHub Actions with ANTHROPIC_API_KEY. All agent interactions go through Claude Code CLI
or Claude Desktop — both subscription-covered.

## Operational Memory

Session-level notes and cross-conversation context are in the auto-memory system at
`~/.claude/projects/-Users-daelegbe/memory/`. On launch, read `MEMORY.md` there to pick up
where previous sessions left off. At the end of each session (or when significant work is done),
write a session note capturing decisions, changes, and open items.

## Background Execution

**Rule: 2+ parallel agents or subagents → TeamCreate. Always.**

`run_in_background: true` is only for single-agent background tasks (no terminal,
invisible API call, output file only). For 2+ parallel agents, TeamCreate is mandatory
— it provides live tmux panes, shared coordination, and graceful shutdown.

## Configuration Source of Truth

The `claude-config` repo at `~/Documents/Projects/claude-config/` is the source of truth
for all agent definitions, skills, and MCP server configs. Deploy changes via:

```bash
cd ~/Documents/Projects/claude-config && ./scripts/sync.sh
```

The sync script copies from `system-configs/.claude/` to `~/.claude/`, flattening
`agents/leads/` to top-level. Never edit `~/.claude/agents/` or `~/.claude/skills/`
directly — edit the repo and sync.
