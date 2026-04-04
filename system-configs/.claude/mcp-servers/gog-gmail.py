#!/usr/bin/env /Users/daelegbe/.claude/mcp-servers/.venv/bin/python3
"""Gmail MCP server wrapping gog CLI for multi-account email access."""
import subprocess
import os
from mcp.server.fastmcp import FastMCP

GOG = "/opt/homebrew/bin/gog"
DEFAULT_ACCOUNT = "damilola.elegbede@gmail.com"
GOG_CLIENT = "openclaw"

mcp = FastMCP("gog-gmail")

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
def gmail_search(query: str, account: str = DEFAULT_ACCOUNT, limit: int = 10) -> str:
    """Search Gmail inbox using Gmail query syntax.

    Args:
        query: Gmail search query (e.g., 'is:unread', 'from:alice@example.com', 'subject:invoice')
        account: Email account to search (default: damilola.elegbede@gmail.com).
                 Options: damilola.elegbede@gmail.com, clara.nova.cos@gmail.com,
                 dara.fox.ai@gmail.com, tars.cortex@gmail.com
        limit: Max results to return (default: 10)
    """
    return _run([
        "gmail", "search", query,
        "--account", account, "--client", GOG_CLIENT,
        "--json", "--no-input",
    ], timeout=60)


@mcp.tool()
def gmail_read(message_id: str, account: str = DEFAULT_ACCOUNT) -> str:
    """Read a specific email message by ID.

    Args:
        message_id: Gmail message ID (from search results)
        account: Email account
    """
    return _run([
        "gmail", "messages", "get", message_id,
        "--account", account, "--client", GOG_CLIENT,
        "--json", "--no-input",
    ])


@mcp.tool()
def gmail_send(to: str, subject: str, body: str, account: str = DEFAULT_ACCOUNT) -> str:
    """Send an email via Gmail.

    Args:
        to: Recipient email address
        subject: Email subject line
        body: Email body (plain text or HTML)
        account: Sender account (default: damilola.elegbede@gmail.com)
    """
    return _run([
        "gmail", "messages", "send",
        "--to", to, "--subject", subject, "--body", body,
        "--account", account, "--client", GOG_CLIENT,
        "--no-input", "--force",
    ], timeout=30)


@mcp.tool()
def gmail_labels(account: str = DEFAULT_ACCOUNT) -> str:
    """List Gmail labels for an account.

    Args:
        account: Email account
    """
    return _run([
        "gmail", "labels", "list",
        "--account", account, "--client", GOG_CLIENT,
        "--json", "--no-input",
    ])


if __name__ == "__main__":
    mcp.run()
