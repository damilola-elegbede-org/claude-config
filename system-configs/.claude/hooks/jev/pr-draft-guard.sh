#!/bin/bash
# PreToolUse(Bash) — memory pr-ready-not-draft: PRs are opened ready for review.
#
# Denies `gh pr create` carrying --draft / -d. Quoted strings and heredoc bodies
# are stripped first so a commit message or PR body that merely MENTIONS
# `gh pr create --draft` is not a violation. Override when D explicitly asks for
# a draft: prefix the command with ALLOW_DRAFT_PR=1.
# Mode: rules.d/rules-events.json "pr-draft-guard" (default enforce).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
MODE=$(re_mode pr-draft-guard enforce)
[ "$MODE" = off ] && exit 0

VERDICT=$(printf '%s' "$INPUT" | python3 -c '
import json, re, sys
try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "") or ""
except ValueError:
    sys.exit(0)
if "ALLOW_DRAFT_PR=1" in cmd:
    sys.exit(0)
s = re.sub(r"<<-?\s*([\"\x27]?)(\w+)\1.*?\n\s*\2\s*(\n|$)", " ", cmd, flags=re.S)
s = re.sub(r"\"(?:[^\"\\]|\\.)*\"|\x27[^\x27]*\x27", "\"\"", s, flags=re.S)
for seg in re.split(r"&&|\|\||[;|\n]", s):
    if re.search(r"(^|\s)gh\s+(?:.*\s)?pr\s+create(\s|$)", seg) and \
       re.search(r"(^|\s)(--draft(?!=false)|-d)(\s|$)", seg):
        print("draft")
        break
' 2>/dev/null)

[ "$VERDICT" = draft ] || exit 0

if re_is_exempt_agent; then
  re_log pr-draft-guard allow-exempt-agent ""
  exit 0
fi
if [ "$MODE" = shadow ]; then
  re_log pr-draft-guard shadow-would-deny ""
  exit 0
fi
re_log pr-draft-guard deny ""
re_deny "PRs are opened ready for review, not draft (D, 2026-08-06; memory pr-ready-not-draft). Re-run without --draft. Only when D explicitly asks for a draft, prefix the command with ALLOW_DRAFT_PR=1."
exit 0
