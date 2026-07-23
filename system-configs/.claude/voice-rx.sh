#!/bin/bash
# voice-rx.sh — run on the machine whose speakers should play Claude's voice
# (e.g. the MacBook Air you SSH from). Pairs with claude-speak.sh's remote
# playback: the sender tries the SSH tunnel (127.0.0.1) then this machine's
# tailnet name, first listener wins.
#
# Bind address (trust boundary):
#   1. $2 / $VOICE_RX_BIND if given
#   2. this machine's Tailscale IP — reachable ONLY by authenticated tailnet
#      peers (the primary path: Tailscale SSH has no RemoteForward, the sender
#      streams to <this-host>:7777 directly over the tailnet)
#   3. 127.0.0.1 — no tailscale present; pair with
#      `RemoteForward 7777 localhost:7777` in the ssh config instead
PORT="${1:-7777}"
BIND="${2:-${VOICE_RX_BIND:-}}"
if [ -z "$BIND" ]; then
  TS_BIN=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
  BIND=$("$TS_BIN" ip -4 2>/dev/null | head -1)
  [ -n "$BIND" ] || BIND=127.0.0.1
fi
echo "voice-rx: listening on $BIND:$PORT (ctrl-c to stop)"
while :; do
  T=$(mktemp -t voice-rx) || exit 1
  nc -l "$BIND" "$PORT" > "$T" 2>/dev/null || { rm -f "$T"; sleep 1; continue; }
  [ -s "$T" ] && afplay "$T" 2>/dev/null
  rm -f "$T"
done
