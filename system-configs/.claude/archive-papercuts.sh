#!/usr/bin/env bash
# archive-papercuts.sh — retain current and recurring papercuts in the live log.
set -euo pipefail

LOG="${PAPERCUT_LOG:-$HOME/.claude/papercuts.md}"
ARCHIVE_DIR="${PAPERCUT_ARCHIVE_DIR:-$HOME/.claude/papercuts/archive}"
SEPARATOR=' · '
CURRENT_MONTH="$(/bin/date -u +%Y-%m)"

write_header() {
  printf '%s\n' '# Papercuts'
  printf '%s\n' 'A factual log of small tooling failures and their fixes.'
  printf '%s\n' 'Format: date (UTC) · source · symptom · fix · project/path'
  printf '%s\n' 'Append via ~/.claude/papercut.sh; never edit or reorder entries.'
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Keep the historical grammar (whose second field was called agent) while
# naming it source in the new header. Invalid and non-entry lines are never
# interpreted as entries and therefore remain verbatim in the live file.
parse_entry() {
  [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ·\ ([a-z][a-z0-9-]*)\ ·\ (.*)\ ·\ (.*)\ ·\ (.*)$ ]]
}

log_parent="$(dirname "$LOG")"
/bin/mkdir -p "$log_parent" "$ARCHIVE_DIR"
log_dir="$(cd "$log_parent" && pwd)"
log_name="$(basename "$LOG")"
lock_dir="$log_dir/.${log_name}.papercut.lock"
PAPERCUT_LOCK_STALE_SECONDS="${PAPERCUT_LOCK_STALE_SECONDS:-300}"
PAPERCUT_LOCK_ATTEMPTS="${PAPERCUT_LOCK_ATTEMPTS:-3000}"
tmp=''
work_dir=''
lock_held=0

cleanup() {
  [ -n "$tmp" ] && /bin/rm -f "$tmp"
  [ -n "$work_dir" ] && /bin/rm -rf "$work_dir"
  if [ "$lock_held" -eq 1 ]; then
    /bin/rm -f "$lock_dir/owner"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
  ! /bin/kill -0 "$pid" 2>/dev/null
}

reclaim_marker_is_stale() {
  local now mtime
  now="$(/bin/date -u +%s)"
  mtime="$(lock_directory_mtime "$lock_dir.reclaiming")" || return 1
  [ "$((now - mtime))" -ge 60 ]
}

for attempt in $(/usr/bin/seq 1 "$PAPERCUT_LOCK_ATTEMPTS"); do
  if /bin/mkdir "$lock_dir" 2>/dev/null; then
    lock_held=1
    printf '%s\n%s\n' "$$" "$(/bin/date -u +%s)" >"$lock_dir/owner"
    break
  fi
  if lock_is_reclaimable; then
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
[ "$lock_held" -eq 1 ] || { printf 'papercut archive: timed out waiting for lock: %s\n' "$lock_dir" >&2; exit 1; }

# A direct monthly run before the first append still leaves a usable log.
if [ ! -e "$LOG" ]; then
  tmp="$(/usr/bin/mktemp "$log_dir/.${log_name}.archive.XXXXXX")"
  write_header >"$tmp"
  /bin/mv -f "$tmp" "$LOG"
  tmp=''
fi

work_dir="$(/usr/bin/mktemp -d "$log_dir/.${log_name}.archive-work.XXXXXX")"
input="$work_dir/input"
/bin/cat "$LOG" >"$input"
symptoms="$work_dir/symptoms"
: >"$symptoms"

# Repetition is deliberately measured across the live log and every archive,
# after trimming the symptom field. This preserves recurring historical
# papercuts where they remain visible to the next session.
# An identical entry line counts once: a run interrupted between an archive
# rename and the live-log rename leaves the same line in both places, and
# counting it twice would misclassify it as recurring forever.
entries_seen="$work_dir/entries"
: >"$entries_seen"
collect_symptoms() {
  collect_file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    parse_entry "$line" && printf '%s\n' "$line" >>"$entries_seen"
  done <"$collect_file"
}
collect_symptoms "$input"
for archive in "$ARCHIVE_DIR"/*.md; do
  [ -f "$archive" ] && collect_symptoms "$archive"
done
sort -u "$entries_seen" | while IFS= read -r line; do
  parse_entry "$line" && trim "${BASH_REMATCH[3]}" && printf '\n'
done >"$symptoms"
sort "$symptoms" | uniq -d >"$work_dir/repeated"

live_tmp="$(/usr/bin/mktemp "$log_dir/.${log_name}.archive.XXXXXX")"
while IFS= read -r line || [ -n "$line" ]; do
  if ! parse_entry "$line"; then
    printf '%s\n' "$line" >>"$live_tmp"
    continue
  fi
  entry_date="${BASH_REMATCH[1]}"
  symptom="$(trim "${BASH_REMATCH[3]}")"
  entry_month="${entry_date:0:7}"
  # A line its month archive already holds was moved by an interrupted run;
  # drop the live copy even if the symptom recurs, or it would persist forever.
  if [ "$entry_month" != "$CURRENT_MONTH" ] && [ -f "$ARCHIVE_DIR/$entry_month.md" ] \
    && grep -F -x -q -- "$line" "$ARCHIVE_DIR/$entry_month.md"; then
    continue
  fi
  if [ "$entry_month" = "$CURRENT_MONTH" ] || grep -F -x -- "$symptom" "$work_dir/repeated" >/dev/null; then
    printf '%s\n' "$line" >>"$live_tmp"
  else
    printf '%s\n' "$line" >>"$work_dir/$entry_month.entries"
  fi
done <"$input"

# An archive is only appended while the shared append lock is held. The live
# file is then replaced by an atomic same-directory rename, so an append can
# neither be lost nor observe a half-written live log.
for entries in "$work_dir"/*.entries; do
  [ -f "$entries" ] || continue
  month="$(basename "$entries" .entries)"
  archive="$ARCHIVE_DIR/$month.md"
  archive_tmp="$(/usr/bin/mktemp "$ARCHIVE_DIR/.${month}.archive.XXXXXX")"
  if [ -e "$archive" ]; then
    /bin/cat "$archive" >"$archive_tmp"
  else
    write_header >"$archive_tmp"
  fi
  # Skip lines a previous interrupted run already archived.
  while IFS= read -r line; do
    grep -F -x -q -- "$line" "$archive_tmp" || printf '%s\n' "$line" >>"$archive_tmp"
  done <"$entries"
  /bin/mv -f "$archive_tmp" "$archive"
done

/bin/mv -f "$live_tmp" "$LOG"
/bin/rm -rf "$work_dir"
work_dir=''
