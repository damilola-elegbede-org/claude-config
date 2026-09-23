#!/usr/bin/env bash
# papercut.sh — atomically append one factual tooling papercut.
#
# Usage: papercut.sh SOURCE SYMPTOM FIX PROJECT/PATH
#
# Each writer snapshots the existing log plus one complete new line into a
# temporary file in the log directory, then atomically renames that snapshot.
# The directory lock prevents two writers from both snapshotting the same old
# version and losing one entry. The log's existing bytes are always copied; the
# helper never regenerates, reorders, or removes prior entries.
set -euo pipefail

LOG="${PAPERCUT_LOG:-$HOME/.claude/papercuts.md}"
# A symlinked log (sync preserves one) must be updated at its target: the
# atomic rename below would otherwise replace the link and sever it.
if [ -L "$LOG" ]; then
  resolved="$(/usr/bin/perl -MCwd -e 'my $p = Cwd::abs_path($ARGV[0]); print $p if defined $p' "$LOG")"
  [ -n "$resolved" ] || { printf 'papercut: cannot resolve symlinked log %s\n' "$LOG" >&2; exit 2; }
  LOG="$resolved"
fi
DATE_UTC="${PAPERCUT_DATE:-$(/bin/date -u +%F)}"
SEPARATOR=' · '

usage() {
  printf 'usage: %s SOURCE SYMPTOM FIX PROJECT/PATH\n' "${0##*/}" >&2
  exit 2
}

reject() {
  printf 'papercut: %s\n' "$1" >&2
  exit 2
}

write_header() {
  printf '%s\n' '# Papercuts'
  printf '%s\n' 'A factual log of small tooling failures and their fixes.'
  printf '%s\n' 'Format: date (UTC) · source · symptom · fix · project/path'
  printf '%s\n' 'Append via ~/.claude/papercut.sh; never edit or reorder entries.'
}

[ "$#" -eq 4 ] || usage
source_name="$1"
symptom="$2"
fix="$3"
project_path="$4"

[[ "$DATE_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || reject 'date must be YYYY-MM-DD UTC'
# “source” deliberately retains the established agent-name grammar so that
# BareClaude's existing date · agent · ... entries remain parseable.
[[ "$source_name" =~ ^[a-z][a-z0-9-]*$ ]] || reject 'source must be lowercase letters, digits, or hyphens'

for field_name in symptom fix project/path; do
  case "$field_name" in
    symptom) field="$symptom" ;;
    fix) field="$fix" ;;
    project/path) field="$project_path" ;;
  esac
  case "$field" in
    ''|*$'\n'*|*$'\r'*|*"$SEPARATOR"*)
      reject "$field_name must be non-empty, one line, and contain no field separator"
      ;;
  esac
done

log_parent="$(dirname "$LOG")"
/bin/mkdir -p "$log_parent"
log_dir="$(cd "$log_parent" && pwd)" || reject "log directory does not exist: $log_parent"
log_name="$(basename "$LOG")"
lock_dir="$log_dir/.${log_name}.papercut.lock"
PAPERCUT_LOCK_STALE_SECONDS="${PAPERCUT_LOCK_STALE_SECONDS:-300}"
PAPERCUT_LOCK_ATTEMPTS="${PAPERCUT_LOCK_ATTEMPTS:-3000}"
tmp=''
lock_held=0

cleanup() {
  [ -n "$tmp" ] && /bin/rm -f "$tmp"
  if [ "$lock_held" -eq 1 ]; then
    /bin/rm -f "$lock_dir/owner"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A lock holder that dies (SIGKILL, host restart) leaves lock_dir behind
# forever, since only a live holder's own cleanup trap ever removes it. Each
# holder records its pid and acquisition time in lock_dir/owner so a later
# waiter can distinguish a dead holder from one still legitimately in use and
# reclaim it instead of only ever timing out.
lock_directory_mtime() {
  /usr/bin/perl -e 'my @stat = stat $ARGV[0]; exit 1 unless @stat; print "$stat[9]\n"' "$1"
}

lock_is_reclaimable() {
  local owner_file="$lock_dir/owner" pid="" acquired_at="" now mtime
  now="$(/bin/date -u +%s)"
  if [ ! -f "$owner_file" ]; then
    mtime="$(lock_directory_mtime "$lock_dir")" || return 1
    [ "$((now - mtime))" -ge "$PAPERCUT_LOCK_STALE_SECONDS" ]
    return
  fi
  # Direct stderr before opening the owner file: another holder can release
  # the lock after the -f check, which is an ordinary non-reclaimable race.
  if ! { read -r pid && read -r acquired_at; } 2>/dev/null <"$owner_file" \
    || ! [[ "$pid" =~ ^[0-9]+$ ]] || ! [[ "$acquired_at" =~ ^[0-9]+$ ]]; then
    mtime="$(lock_directory_mtime "$lock_dir")" || return 1
    [ "$((now - mtime))" -ge "$PAPERCUT_LOCK_STALE_SECONDS" ]
    return
  fi
  # A reused PID can be alive even though its short-lived former owner is not.
  if [ "$((now - acquired_at))" -ge "$PAPERCUT_LOCK_STALE_SECONDS" ]; then
    return 0
  fi
  if /bin/kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  return 0
}

reclaim_marker_is_stale() {
  local now mtime
  now="$(/bin/date -u +%s)"
  mtime="$(lock_directory_mtime "$lock_dir.reclaiming")" || return 1
  [ "$((now - mtime))" -ge 60 ]
}

# mkdir is an atomic portable lock primitive on both the macOS host and Ubuntu
# CI. Bound the wait so a stale lock cannot hold an agent session indefinitely.
for attempt in $(/usr/bin/seq 1 "$PAPERCUT_LOCK_ATTEMPTS"); do
  if /bin/mkdir "$lock_dir" 2>/dev/null; then
    lock_held=1
    printf '%s\n%s\n' "$$" "$(/bin/date -u +%s)" >"$lock_dir/owner"
    break
  fi
  if lock_is_reclaimable; then
    # Two waiters can both observe the same stale lock and both decide to
    # reclaim it; deleting unconditionally would let a slow waiter destroy a
    # brand-new legitimate lock that a third process acquired in between.
    # Serialize the reclaim itself through its own mkdir gate and re-check
    # staleness once inside it, against whatever is actually there now.
    reclaim_marker="$lock_dir.reclaiming"
    if [ -d "$reclaim_marker" ] && reclaim_marker_is_stale; then
      /bin/rmdir "$reclaim_marker" 2>/dev/null || true
      continue
    fi
    if /bin/mkdir "$reclaim_marker" 2>/dev/null; then
      if lock_is_reclaimable; then
        /bin/rm -rf "$lock_dir"
      fi
      /bin/rmdir "$reclaim_marker" 2>/dev/null || true
    fi
  fi
  /bin/sleep 0.01
done
[ "$lock_held" -eq 1 ] || { printf 'papercut: timed out waiting for append lock: %s\n' "$lock_dir" >&2; exit 1; }

tmp="$(/usr/bin/mktemp "$log_dir/.${log_name}.papercut.XXXXXX")" || reject 'could not create temporary log entry'
if [ -e "$LOG" ]; then
  /bin/cat "$LOG" >"$tmp"
else
  write_header >"$tmp"
fi
printf '%s%s%s%s%s%s%s%s%s\n' \
  "$DATE_UTC" "$SEPARATOR" "$source_name" "$SEPARATOR" "$symptom" "$SEPARATOR" "$fix" "$SEPARATOR" "$project_path" >>"$tmp"

# Both paths are in log_dir, so mv is an atomic rename. No reader sees a
# truncated line or a partially updated log.
/bin/mv -f "$tmp" "$LOG"
tmp=''
