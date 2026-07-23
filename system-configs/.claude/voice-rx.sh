#!/bin/bash
# voice-rx.sh — run on the machine whose speakers should play Claude's voice
# (e.g. the MacBook Air you SSH from). Pairs with claude-speak.sh's tunnel
# mode: add `RemoteForward 7777 localhost:7777` to the ssh config Host entry
# for the machine running Claude, keep this loop running, and spoken replies
# arrive here instead of the remote machine's speakers.
PORT="${1:-7777}"
echo "voice-rx: listening on :$PORT (ctrl-c to stop)"
while :; do
  T=$(mktemp -t voice-rx).mp3
  nc -l 127.0.0.1 "$PORT" > "$T" 2>/dev/null
  [ -s "$T" ] && afplay "$T" 2>/dev/null
  rm -f "$T"
done
