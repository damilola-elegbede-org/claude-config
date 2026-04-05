---
name: slack-ops
description: Post messages, thread replies, and react in Slack via slack-post.sh. Use this skill for ALL Slack outbound communication — new posts, thread replies, reactions, and @mention dispatch. Never use the native message tool for Slack; it bypasses agent dispatch and threading. Triggers on any intent to post, reply, or send to Slack.
user-invocable: false
---

# slack-ops

All Slack communication routes through `slack-post.sh`. The native `message` tool is blocked on Slack at the gateway policy layer — use it only for Signal/webchat.

## Script

```text
~/.openclaw-dara/workspace/scripts/slack-post.sh
```

## Commands

```bash
# New top-level post
~/.openclaw-dara/workspace/scripts/slack-post.sh post <channel> "<text>" <agent>

# Reply in existing thread (ALWAYS use when responding to a Slack @mention)
~/.openclaw-dara/workspace/scripts/slack-post.sh thread <channel> <thread_ts> "<text>" <agent>

# React to a message
~/.openclaw-dara/workspace/scripts/slack-post.sh react <channel> <message_ts> <emoji> <agent>
```

Agent name must match token filename in `~/.cortex/slack_tokens/`. Dara uses `dara`.

## Channel Names

Pass channel name (e.g. `coordination`, `alerts`, `engineering`) or raw channel ID (e.g. `C0AN9840JLW`).
Run `slack-post.sh channels dara` to list all resolved names and IDs.

## Thread vs Post — Rule (D explicit, 2026-03-30)

- **Responding to an @mention or existing thread** → always use `thread` with the originating `thread_ts`
- **Starting a new topic with no prior thread** → use `post`

The `thread_ts` is provided in the dispatch message when `slack-mention-router.sh` fires. Never drop it.

## @Mention Dispatch

When Dara posts via `slack-post.sh post` or `thread`, `auto_dispatch_mentions` fires
automatically in the background. It detects `<@SLACK_ID>` patterns and calls
`slack-mention-router.sh`, which sends each mentioned specialist a `sessions_send` with
the message and the correct reply instruction (thread or post).

No manual dispatch needed — just include `<@ID>` mentions in the message text and `slack-post.sh` handles the rest.

## Quoting Safety

For messages with backticks, newlines, or special characters, write to a temp file first:

```bash
cat > /tmp/slack-msg.txt << 'EOF'
Your message here — backticks `fine`, newlines fine
EOF
MSG=$(cat /tmp/slack-msg.txt)
~/.openclaw-dara/workspace/scripts/slack-post.sh post coordination "$MSG" dara
```

Never use raw Python urllib or curl to post to Slack — this bypasses `normalize_mentions` and `auto_dispatch_mentions`.
