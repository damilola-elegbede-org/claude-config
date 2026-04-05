#!/usr/bin/env /Users/daelegbe/.claude/mcp-servers/.venv/bin/python3
"""Slack multi-agent posting MCP server.

Wraps slack-post.sh to support posting as Clara or Dara bot identities.
"""
import subprocess
from mcp.server.fastmcp import FastMCP

SLACK_POST_SH = "/Users/daelegbe/.openclaw-dara/workspace/scripts/slack-post.sh"

mcp = FastMCP("slack-multipost")


def _run(args: list[str]) -> str:
    result = subprocess.run(
        [SLACK_POST_SH] + args,
        capture_output=True, text=True, timeout=30,
        env={"HOME": "/Users/daelegbe", "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
             "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
    )
    if result.returncode != 0:
        return f"ERROR (exit {result.returncode}): {result.stderr.strip()}"
    return result.stdout.strip() or "OK"


@mcp.tool()
def slack_post(channel: str, text: str, agent: str = "clara") -> str:
    """Post a message to a Slack channel as the specified agent.

    Args:
        channel: Slack channel name (e.g., '#engineering', '#alerts', '#briefs')
        text: Message text (supports Slack mrkdwn formatting)
        agent: Agent identity to post as — 'clara' or 'dara' (default: clara)
    """
    return _run(["post", channel, text, agent])


@mcp.tool()
def slack_thread(channel: str, thread_ts: str, text: str, agent: str = "clara") -> str:
    """Reply in a Slack thread as the specified agent.

    Args:
        channel: Slack channel name
        thread_ts: Thread timestamp to reply to
        text: Reply text
        agent: Agent identity — 'clara' or 'dara'
    """
    return _run(["thread", channel, thread_ts, text, agent])


@mcp.tool()
def slack_history(channel: str, agent: str = "clara", limit: int = 20) -> str:
    """Read recent messages from a Slack channel.

    Args:
        channel: Slack channel name
        agent: Agent identity for auth — 'clara' or 'dara'
        limit: Number of messages to retrieve (default: 20)
    """
    return _run(["history", agent, channel, str(limit)])


@mcp.tool()
def slack_channels(agent: str = "clara") -> str:
    """List available Slack channels.

    Args:
        agent: Agent identity for auth — 'clara' or 'dara'
    """
    return _run(["channels", agent])


if __name__ == "__main__":
    mcp.run()
