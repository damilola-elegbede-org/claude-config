#!/usr/bin/env /Users/daelegbe/.claude/mcp-servers/.venv/bin/python3
"""Google Calendar MCP server wrapping gog CLI."""
import subprocess
import os
from mcp.server.fastmcp import FastMCP

GOG = "/opt/homebrew/bin/gog"
DEFAULT_ACCOUNT = "damilola.elegbede@gmail.com"
GOG_CLIENT = "openclaw"

mcp = FastMCP("gog-calendar")

def _env():
    return {
        "HOME": os.environ.get("HOME", "/Users/daelegbe"),
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
        "GOG_KEYRING_PASSWORD": os.environ.get("GOG_KEYRING_PASSWORD", "openclaw"),
    }

def _run(args: list[str], timeout: int = 30) -> str:
    result = subprocess.run(
        [GOG] + args,
        capture_output=True, text=True, timeout=timeout, env=_env()
    )
    if result.returncode != 0:
        return f"ERROR (exit {result.returncode}): {result.stderr.strip()}"
    return result.stdout.strip()


@mcp.tool()
def calendar_events(date: str = "today", account: str = DEFAULT_ACCOUNT) -> str:
    """List calendar events for a given date.

    Args:
        date: Date to query — 'today', 'tomorrow', 'this week', or ISO date (YYYY-MM-DD)
        account: Google account (default: damilola.elegbede@gmail.com)
    """
    args = ["calendar", "events", "--all"]
    if date == "today":
        args.append("--today")
    elif date == "tomorrow":
        args.append("--tomorrow")
    elif date == "this week":
        args.append("--week")
    else:
        args.extend(["--from", date, "--days", "1"])
    args.extend([
        "--account", account, "--client", GOG_CLIENT,
        "--json", "--no-input",
    ])
    return _run(args, timeout=30)


@mcp.tool()
def calendar_create(
    title: str, start: str, end: str,
    description: str = "", location: str = "",
    account: str = DEFAULT_ACCOUNT
) -> str:
    """Create a calendar event.

    Args:
        title: Event title
        start: Start time in ISO 8601 format (e.g., '2026-04-05T09:00:00')
        end: End time in ISO 8601 format
        description: Event description (optional)
        location: Event location (optional)
        account: Google account
    """
    args = [
        "calendar", "events", "create",
        "--title", title, "--start", start, "--end", end,
        "--account", account, "--client", GOG_CLIENT,
        "--no-input", "--force",
    ]
    if description:
        args.extend(["--description", description])
    if location:
        args.extend(["--location", location])
    return _run(args, timeout=30)


@mcp.tool()
def calendar_delete(event_id: str, account: str = DEFAULT_ACCOUNT) -> str:
    """Delete a calendar event by ID.

    Args:
        event_id: Calendar event ID (from events list)
        account: Google account
    """
    return _run([
        "calendar", "events", "delete", event_id,
        "--account", account, "--client", GOG_CLIENT,
        "--no-input", "--force",
    ])


if __name__ == "__main__":
    mcp.run()
