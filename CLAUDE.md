This is a Claude Code CLI Configuration Repository - a clean, organized system for managing Claude
configurations, specialized agents, and custom skills with the Claude Code CLI.

The core Claude configurations live in the system-configs directory, which contains all
system settings. This directory contains the main CLAUDE.md configuration file, the .claude subdirectory with agents
and skills definitions, and a settings.json file for audio notification preferences. All agent definitions are
stored as Markdown files with YAML front-matter in system-configs/.claude/agents/, while skills reside in
system-configs/.claude/skills/. These configurations are designed to be synced to your home directory for use with
the Claude Code CLI.

The sync skill is the primary mechanism for deploying configurations from this repository to your local Claude
setup. Running /sync copies all configurations from system-configs/ to ~/.claude/, validating agent YAML compliance
before deployment and creating automatic backups of existing configurations. The sync process intelligently excludes
documentation and template files, ensuring only active configurations are deployed. This skill should be run
whenever you modify agents or skills in this repository to update your local Claude environment.

Agent definitions now support additional frontmatter fields beyond the basics: `permissionMode` (plan/acceptEdits/default),
`memory` (project/local/user for persistent agent memory), and `skills` (preloads skill content into agent context).
The settings.json file also includes hook-based quality gates (pre-commit validation, post-push CI checks) alongside
audio notification preferences.

To create new agents or skills, use the provided templates located in the docs directory. For agents, follow the
template at docs/agents/AGENT_TEMPLATE.md, ensuring proper YAML front-matter syntax and including the required SYSTEM
BOUNDARY protection that prevents agents from invoking themselves or other agents. For skills, use the template at
docs/commands/COMMAND_TEMPLATE.md to maintain consistency with existing skill patterns. After creating new
configurations, run the validation scripts like ./scripts/validate-agent-yaml.py to ensure compliance before syncing
changes to your local environment.
