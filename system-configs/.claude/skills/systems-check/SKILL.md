---
name: systems-check
description: Fleet-wide health check of Claude agent infrastructure — scheduled tasks, MCP servers, Slack connectivity, and critical services. Produces GREEN/YELLOW/RED report. Use when D asks for a 'systems check', 'status check', 'health check', or 'how is everything running'.
argument-hint: "[--brief]"
category: workflow
user-invocable: false
---

# Systems Check — Claude Fleet

Run a comprehensive health check across the Claude agent fleet infrastructure.

## Usage

```bash
/systems-check           # Full health report
/systems-check --brief   # One-line per section, no details
```

## Report Format

Always produce these sections, even if empty:

```text
## Shared Infrastructure     ← Node, Git, disk, gog, Slack connectivity
## MCP Servers               ← All registered MCP servers responding
## Scheduled Tasks           ← Heartbeat freshness check
## Agent Definitions         ← All .md files loadable
## Self-Healing Steps        ← Include only if YELLOW or RED items exist
## Fleet Read                ← Observations, patterns, risks
```

Each item uses traffic light status:

- **GREEN**: System reachable, healthy, data correct.
- **YELLOW**: Reachable but degraded, stale data, auth needs attention.
- **RED**: Unreachable, broken, data missing.

Never suppress a section to look good. Honest > clean.

## Check Procedures

### 1. Shared Infrastructure

```bash
# Node.js
node --version

# Git
git --version

# Disk space
df -h / | tail -1

# gog CLI
GOG_KEYRING_PASSWORD=openclaw gog gmail search "is:unread" --account damilola.elegbede@gmail.com --client openclaw --json --no-input --max 1 2>&1 | head -1

# Slack connectivity
/Users/daelegbe/.openclaw-dara/workspace/scripts/slack-post.sh channels clara 2>&1 | head -3

# Claude Desktop
pgrep -f "Claude.app" >/dev/null && echo "GREEN: Claude Desktop running" || echo "RED: Claude Desktop not running"
```

### 2. MCP Servers

Check each registered MCP server in `~/.claude/settings.json`:

```bash
# Parse mcpServers from settings
python3 -c "
import json
with open('$HOME/.claude/settings.json') as f:
    d = json.load(f)
for name, cfg in d.get('mcpServers', {}).items():
    cmd = cfg.get('command', '')
    print(f'{name}: {cmd}')
"
```

For each server, verify the executable exists and is runnable.

### 3. Scheduled Tasks (Heartbeat Freshness)

```bash
for f in ~/.cortex/heartbeats/*.json; do
  [ -f "$f" ] && echo "$(basename $f .json): $(cat $f)"
done
```

Check each heartbeat's `lastRun` against expected intervals:

| Task | Expected Interval | YELLOW if older than | RED if older than |
|------|------------------|---------------------|-------------------|
| email-check | 6 hours | 12 hours | 24 hours |
| morning-brief | 24 hours | 30 hours | 48 hours |
| eod-wrap | 24 hours | 30 hours | 48 hours |
| engineering-standup | 24 hours (weekdays) | 48 hours | 72 hours |
| security-sweep | 24 hours | 48 hours | 72 hours |
| dead-man-switch | 1 hour | 2 hours | 4 hours |

### 4. Agent Definitions

```bash
# Verify all expected agents exist
for agent in clara-nova dara-fox tars financial-analyst project-manager legal-counsel travel-planner career-strategist content-strategist; do
  [ -f "$HOME/.claude/agents/$agent.md" ] && echo "GREEN: $agent" || echo "RED: $agent MISSING"
done
```

### 5. Skills

```bash
# Verify fleet skills exist
for skill in clara-briefing email-triage email-formatting calendar-management recruiter-inbox slack-ops security-ops; do
  [ -f "$HOME/.claude/skills/$skill/SKILL.md" ] && echo "GREEN: $skill" || echo "RED: $skill MISSING"
done
```

## Self-Healing Protocol

For every YELLOW or RED item, include a concrete proposed fix:

| Issue | Self-Healing Action |
|-------|-------------------|
| Claude Desktop not running | `open /Applications/Claude.app` |
| MCP server executable missing | Reinstall: `pip install mcp` in venv |
| Heartbeat stale | Check if cron job is still registered |
| gog auth expired | `GOG_KEYRING_PASSWORD=openclaw gog auth login --account <email>` |
| Slack token expired | Check `~/.cortex/slack_tokens/` |
| Agent definition missing | Run `/sync` from claude-config repo |
| Disk space low | Clear `~/.openclaw-*/scratch/` archives |

Where self-healing is automatable, offer to execute immediately.
Where it requires D's input, say so explicitly.

## Fleet Read (Required Section)

After the structured report, always include a brief observation:

- Infrastructure health trends
- Risks that aren't broken yet but are trending toward it
- One recommended next action, prioritized

Keep it punchy, technical, and actionable. This is the "what D actually needs to know" section.

## Delivery

Post the full report to Slack #status:

```bash
/Users/daelegbe/.openclaw-dara/workspace/scripts/slack-post.sh post status "<report>" dara
```

Write heartbeat:

```bash
echo '{"task":"systems-check","agent":"dara","lastRun":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"ok"}' > ~/.cortex/heartbeats/dara-systems-check.json
```
