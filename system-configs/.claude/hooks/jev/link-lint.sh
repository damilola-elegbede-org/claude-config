#!/bin/bash
# Stop — everything in the final reply that can be a hyperlink is one.
#
# Regex check (mode "link-lint", default ENFORCE) for INTERACTIVE main-agent sessions.
# Background jobs (CLAUDE_JOB_DIR) run in SHADOW only: logged as would-block, never blocks.
# Fleet (BARECLAUDE_AGENT_SLUG) and subagents (agent_id on stdin) are skipped. Flags, outside
# code spans, code fences and existing markdown links:
#   1. bare URLs                 -> [descriptive text](url)
#   2. bare PR/issue numbers     -> "PR #12", "(#12)", "#123", "owner/repo#12" -> link to the PR/issue
#   3. bare commit SHAs          -> "commit 940f2ae", "(940f2ae)" -> link to the commit
# Linear IDs are checked by executive-lint.sh. link-validate.sh checks that the links are right.
# stop_hook_active is respected: never blocks twice in a row.

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
SESSION_SCOPE=$(re_scope)
case "$SESSION_SCOPE" in interactive | bgjob) ;; *) exit 0 ;; esac
[ -z "$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null)" ] || exit 0

MSG=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$MSG" ] || exit 0
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)

MODE=$(re_mode link-lint enforce)
[ "$SESSION_SCOPE" = bgjob ] && [ "$MODE" = enforce ] && MODE=shadow
[ "$MODE" = off ] && exit 0

PROBLEMS=$(printf '%s' "$MSG" | python3 -c '
import re, sys
msg = sys.stdin.read()
body = re.sub(r"```.*?```", " ", msg, flags=re.S)
body = re.sub(r"~~~.*?~~~", " ", body, flags=re.S)
body = re.sub(r"`[^`\n]*`", " ", body)
body = re.sub(r"\[[^\]]*\]\([^)]*\)", " ", body)
body = re.sub(r"<https?://[^>]+>", " ", body)
problems = []
urls = sorted(set(u.rstrip(".,;:") for u in re.findall(r"https?://[^\s)>\]*]+", body)))
if urls:
    problems.append("bare URL(s) " + ", ".join(urls[:4]) + " — wrap each as [descriptive text](url)")
refs = set(re.findall(r"(?<![\w/&#])(?:PRs?|pull requests?|issues?|MR)\s+(#\d{1,5})\b", body, flags=re.I))
refs |= set(re.findall(r"\((#\d{1,5})\)", body))
refs |= set(re.findall(r"(?<![\w/&#])(#\d{3,5})(?![0-9A-Za-z])", body))
refs |= set(re.findall(r"[\w.-]+/[\w.-]+(#\d{1,5})\b", body))
if refs:
    problems.append("bare PR/issue ref(s) " + ", ".join(sorted(refs)[:5]) + " — link each: [PR #N](https://github.com/<owner>/<repo>/pull/N); get the repo with `gh repo view --json url`")
def sha_ok(s):
    return re.search(r"[0-9]", s) and re.search(r"[a-f]", s)
shas = set(s for s in re.findall(r"(?i:commit|sha)\s+([0-9a-f]{7,40})\b", body) if sha_ok(s))
shas |= set(s for s in re.findall(r"\(([0-9a-f]{7,40})\)", body) if sha_ok(s))
if shas:
    problems.append("bare commit SHA(s) " + ", ".join(sorted(shas)[:4]) + " — link each: [sha](https://github.com/<owner>/<repo>/commit/<sha>)")
print("\n".join(problems))
' 2>/dev/null)
[ -n "$PROBLEMS" ] || exit 0

if [ "$MODE" = shadow ]; then
  re_log link-lint shadow-would-block "$(printf '%s' "$PROBLEMS" | head -1)"
  exit 0
fi
if [ "$ACTIVE" = true ]; then
  re_log link-lint allow-stop-hook-active "$(printf '%s' "$PROBLEMS" | head -1)"
  exit 0
fi
re_log link-lint block "$(printf '%s' "$PROBLEMS" | head -1)"
REASON="Unlinked references in your last reply (everything that can be a hyperlink is one; fix and send the corrected reply, do not mention this check):"$'\n'"$(printf '%s' "$PROBLEMS" | sed 's/^/- /')"
re_block "$REASON"
exit 0
