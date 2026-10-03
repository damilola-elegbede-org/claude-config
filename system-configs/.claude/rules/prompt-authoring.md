---
paths:
  - "**/.claude/agents/**/*.md"
  - "**/.claude/skills/**/*.md"
  - "**/.claude/output-styles/*.md"
  - "**/.claude/rules/**/*.md"
  - "**/CLAUDE.md"
---

# Writing prompt files

- State each constraint plainly with its reason. Reserve caps or CRITICAL for one instruction a test showed is underweighted.
- Describe the goal, constraints and how to verify. Number steps only where order matters.
- Write current rules only: no PR numbers, incident stories, dates, or "previously / no longer".
- Don't pin model IDs in prose; name the setting that controls the model.
- Before naming an agent, skill, script, flag or path, confirm it exists in this repo or ~/.claude.
- Example outputs get copied: label them illustrative and keep them consistent with the rules (questions to D go through AskUserQuestion).
- Delegate a retired specialist role to general-purpose with an inline role prompt; the subagent tool is Agent.
- Context and reasons are never cruft. Don't shorten a prompt for length alone.
