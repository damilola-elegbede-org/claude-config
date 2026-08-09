#!/usr/bin/env python3
"""
Orphan Reference Checker
========================

Checks for orphaned references in the Claude Code configuration:
- Agent references in commands that don't exist
- Skill references that don't exist
- Circular or self-references

Usage:
    python scripts/check-orphans.py
    python scripts/check-orphans.py --verbose
"""

import os
import re
import sys
from pathlib import Path

# Get project root
SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
AGENTS_DIR = PROJECT_ROOT / "system-configs" / ".claude" / "agents"
COMMANDS_DIR = PROJECT_ROOT / "system-configs" / ".claude" / "commands"
SKILLS_DIR = PROJECT_ROOT / "system-configs" / ".claude" / "skills"
CLAUDE_MD = PROJECT_ROOT / "system-configs" / "CLAUDE.md"

# Files to skip
NON_AGENT_FILES = [
    "README.md", "AGENT_CATEGORIES.md", "AGENT_TEMPLATE.md",
    "AUDIT_VERIFICATION_PROTOCOL.md", "AGENT_SELECTION_GUIDE.md",
    "ENHANCEMENT_SUMMARY.md"
]
NON_COMMAND_FILES = ["README.md", "COMMAND_TEMPLATE.md"]
NON_SKILL_FILES = ["README.md", "SKILL_TEMPLATE.md"]


def get_valid_agents():
    """Get set of valid agent names."""
    if not AGENTS_DIR.exists():
        return set()
    return {f.stem for f in AGENTS_DIR.glob("*.md") if f.name not in NON_AGENT_FILES}


def get_valid_skills():
    """Get set of valid skill names."""
    if not SKILLS_DIR.exists():
        return set()
    return {f.stem for f in SKILLS_DIR.glob("*.md") if f.name not in NON_SKILL_FILES}


def extract_agent_references(content):
    """Extract potential agent references from content."""
    references = set()

    # Common agent reference patterns
    patterns = [
        # YAML style: agent-name:
        r"^\s*(\w+-\w+(?:-\w+)?):\s*$",
        # Task style: Task: agent-name
        r"Task:\s*(\w+-\w+(?:-\w+)?)",
        # Assignee style: Assignee: [agent-name]
        r"Assignee:\s*\[?(\w+-\w+(?:-\w+)?)\]?",
        # Inline reference: + agent-name
        r"\+\s*(\w+-\w+(?:-\w+)?)",
        # List item: - agent-name
        r"^\s*-\s*(\w+-\w+(?:-\w+)?)\s*$",
        # Reference in prose: the agent-name agent
        r"the\s+(\w+-\w+(?:-\w+)?)\s+agent",
        # Use agent: use agent-name
        r"\buse\s+(\w+-\w+(?:-\w+)?)",
    ]

    for pattern in patterns:
        matches = re.findall(pattern, content, re.MULTILINE | re.IGNORECASE)
        for match in matches:
            # Filter out common non-agent patterns
            skip_patterns = [
                "front-matter", "pre-commit", "auto-fix", "non-agent",
                "wave-based", "pr-based", "file-path", "cli-tool",
                "end-to-end", "self-reference", "code-block",
                "cross-validation", "dry-run", "shadcn-ui", "think-harder",
                "argument-hint", "thinking-level", "thinking-tokens",
                "mcp-server", "multi-cloud", "multi-agent", "multi-step",
                "high-performance", "open-ended", "real-time", "well-formed",
                # CI/CD and testing patterns (not agent names)
                "skip-ci", "integration-test", "unit-test", "paths-ignore",
                # Technical compound terms (not agent names)
                "docx-js", "low-contrast", "scroll-triggering", "read-only",
                "high-level", "low-level", "built-in", "opt-in", "opt-out",
                "run-time", "compile-time", "type-safe", "type-check",
                "hot-reload", "hot-module", "tree-shaking",
            ]
            # Skip numbered agent references (e.g., debugger-2, test-engineer-4)
            if re.match(r"^[\w-]+-\d+$", match.lower()):
                continue
            if not any(skip in match.lower() for skip in skip_patterns):
                references.add(match.lower())

    return references


def check_skills_for_orphans(valid_agents, verbose=False):
    """Check skill files for orphaned agent references."""
    orphans = []

    if not SKILLS_DIR.exists():
        return orphans

    for skill_dir in SKILLS_DIR.iterdir():
        if not skill_dir.is_dir() or skill_dir.name.startswith('.'):
            continue
        skill_file = skill_dir / "SKILL.md"
        if not skill_file.exists():
            continue

        content = skill_file.read_text()
        references = extract_agent_references(content)

        for ref in references:
            if ref not in valid_agents and len(ref) > 3:
                # Additional filtering for false positives
                if ref not in ["debug", "test", "build", "deploy", "review"]:
                    orphans.append({
                        "file": f"skills/{skill_dir.name}/SKILL.md",
                        "reference": ref,
                        "type": "agent"
                    })

        if verbose and references:
            print(f"  {skill_dir.name}: found {len(references)} agent references")

    # Legacy: Check commands directory if it still exists
    if COMMANDS_DIR.exists():
        for cmd_file in COMMANDS_DIR.glob("*.md"):
            if cmd_file.name in NON_COMMAND_FILES:
                continue

            content = cmd_file.read_text()
            references = extract_agent_references(content)

            for ref in references:
                if ref not in valid_agents and len(ref) > 3:
                    if ref not in ["debug", "test", "build", "deploy", "review"]:
                        orphans.append({
                            "file": f"commands/{cmd_file.name}",
                            "reference": ref,
                            "type": "agent"
                        })

            if verbose and references:
                print(f"  {cmd_file.name}: found {len(references)} agent references")

    # Legacy: Check flat-file skills (skills/*.md) in addition to directory-based skills
    for skill_file in SKILLS_DIR.glob("*.md"):
        if skill_file.name.startswith('.') or skill_file.name in NON_SKILL_FILES:
            continue

        content = skill_file.read_text()
        references = extract_agent_references(content)

        for ref in references:
            if ref not in valid_agents and len(ref) > 3:
                if ref not in ["debug", "test", "build", "deploy", "review"]:
                    orphans.append({
                        "file": f"skills/{skill_file.name}",
                        "reference": ref,
                        "type": "agent"
                    })

        if verbose and references:
            print(f"  {skill_file.name}: found {len(references)} agent references")

    return orphans


def check_claude_md_for_orphans(valid_agents, verbose=False):
    """Check CLAUDE.md for orphaned agent references."""
    orphans = []

    if not CLAUDE_MD.exists():
        return orphans

    content = CLAUDE_MD.read_text()

    # Extract agents from routing table - look for lines with agent patterns
    # Format: | keywords | agent-name + agent-name |
    routing_pattern = r"\|\s*[^|]+\s*\|\s*([^|]+)\s*\|"
    for match in re.finditer(routing_pattern, content):
        agents_cell = match.group(1).strip()
        # Skip header rows, separator rows, and non-agent content
        if not agents_cell or agents_cell == "Agents":
            continue
        if agents_cell.startswith("-") or agents_cell.startswith("="):
            continue
        # Skip non-agent table cells (like "Use Skill", "Use Agent Instead")
        if "skill" in agents_cell.lower() or "agent instead" in agents_cell.lower():
            continue
        # Skip cells that look like examples or descriptions (longer text)
        if len(agents_cell) > 50:
            continue
        # Split by + to get individual agents
        for agent in agents_cell.split("+"):
            agent = agent.strip().lower()
            # Must look like an agent name (word-word format)
            if agent and "-" in agent and agent not in valid_agents:
                # Additional filter: must be a valid agent-style name
                if re.match(r"^[a-z]+-[a-z]+(?:-[a-z]+)?$", agent):
                    orphans.append({
                        "file": "CLAUDE.md",
                        "reference": agent,
                        "type": "routing-table"
                    })

    return orphans


def check_agent_self_references(verbose=False):
    """Check agents for self-references or Task tool usage."""
    issues = []

    if not AGENTS_DIR.exists():
        return issues

    for agent_file in AGENTS_DIR.glob("*.md"):
        if agent_file.name in NON_AGENT_FILES:
            continue

        content = agent_file.read_text()
        agent_name = agent_file.stem

        # Check for self-reference
        if f"Task: {agent_name}" in content.lower() or f"invoke {agent_name}" in content.lower():
            issues.append({
                "file": f"agents/{agent_file.name}",
                "reference": agent_name,
                "type": "self-reference"
            })

        # Check for Task tool access (should be blocked)
        if re.search(r"tools:.*Task", content, re.IGNORECASE):
            issues.append({
                "file": f"agents/{agent_file.name}",
                "reference": "Task",
                "type": "forbidden-tool"
            })

    return issues


def main():
    """Main function."""
    verbose = "--verbose" in sys.argv or "-v" in sys.argv

    print("Checking for Orphaned References...\n")

    valid_agents = get_valid_agents()
    valid_skills = get_valid_skills()

    if verbose:
        print(f"Valid agents ({len(valid_agents)}): {sorted(valid_agents)}\n")

    all_issues = []

    # Check skills (and legacy commands if they exist)
    print("Checking skills...")
    skill_orphans = check_skills_for_orphans(valid_agents, verbose)
    all_issues.extend(skill_orphans)

    # Check CLAUDE.md
    print("Checking CLAUDE.md...")
    claude_orphans = check_claude_md_for_orphans(valid_agents, verbose)
    all_issues.extend(claude_orphans)

    # Check agent self-references
    print("Checking agent boundaries...")
    agent_issues = check_agent_self_references(verbose)
    all_issues.extend(agent_issues)

    # Report results
    print(f"\n{'='*50}")

    if not all_issues:
        print("No orphaned references found")
        print(f"\nValidated:")
        print(f"  - {len(valid_agents)} agents")
        print(f"  - {len([d for d in SKILLS_DIR.iterdir() if d.is_dir() and not d.name.startswith('.')]) if SKILLS_DIR.exists() else 0} skills")
        return 0

    print(f"Found {len(all_issues)} issues:\n")

    # Group by type
    by_type = {}
    for issue in all_issues:
        issue_type = issue["type"]
        if issue_type not in by_type:
            by_type[issue_type] = []
        by_type[issue_type].append(issue)

    for issue_type, issues in by_type.items():
        print(f"  {issue_type.upper()} ({len(issues)}):")
        for issue in issues:
            print(f"    - {issue['file']}: {issue['reference']}")
        print()

    print("Fix these issues before deployment.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
