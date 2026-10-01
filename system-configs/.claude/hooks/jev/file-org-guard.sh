#!/bin/bash
# PreToolUse(Write) — CLAUDE.md "File Organization": temporary files go in .tmp/.
#
# Denies Write of a NEW scratch-named document (plan|draft|report|analysis|notes|
# scratch) directly in a git repo's root. Coverage is deliberately narrow: repo
# root only, doc-like extensions only, Write only (not Edit). Source
# directories are NOT covered, so the CLAUDE.md prose stays (see registry.json).
# Mode: rules.d/rules-events.json "file-org-guard" (default enforce).

# shellcheck source-path=SCRIPTDIR source=rules-events-lib.sh
. "$(dirname "$0")/rules-events-lib.sh"
re_need_jq || exit 0

INPUT=$(cat)
FILE=$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$FILE" ] || exit 0

MODE=$(re_mode file-org-guard enforce)
[ "$MODE" = off ] && exit 0

# Only NEW files: overwriting an existing file is an edit of something already there.
[ -e "$FILE" ] && exit 0

DIR=$(dirname "$FILE")
BASE=$(basename "$FILE")
[ -d "$DIR" ] || exit 0
TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
DIR_P=$(cd "$DIR" && pwd -P) || exit 0
TOP_P=$(cd "$TOP" && pwd -P) || exit 0
# Only the repo root itself (never .tmp/, docs/, or any subdirectory).
[ "$DIR_P" = "$TOP_P" ] || exit 0

LC=$(printf '%s' "$BASE" | tr '[:upper:]' '[:lower:]')
case "$LC" in
  *.md | *.txt | *.json | *.html | *.csv | *.log | *.yaml | *.yml | *.rst) ;;
  *.*) exit 0 ;;
esac
STEM="${LC%.*}"
case "$STEM" in release-notes | release_notes | readme | changelog) exit 0 ;; esac
if ! [[ "$STEM" =~ (^|[^a-z])(plan|draft|report|analysis|notes|scratch)([^a-z]|$) ]]; then
  exit 0
fi

REASON="Temp files go in .tmp/ (CLAUDE.md File Organization): .tmp/plans/, .tmp/reports/, .tmp/analysis/, .tmp/drafts/ — never the repo root. Write ${TOP}/.tmp/<subdir>/${BASE} instead. If this is a real project document, give it a non-scratch name or put it under docs/."

if re_is_exempt_agent; then
  re_log file-org-guard allow-exempt-agent "$BASE"
  exit 0
fi
if [ "$MODE" = shadow ]; then
  re_log file-org-guard shadow-would-deny "$BASE"
  exit 0
fi
re_log file-org-guard deny "$BASE"
re_deny "$REASON"
exit 0
