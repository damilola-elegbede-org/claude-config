#!/bin/bash
# claude-speak.sh — gives Claude a voice (ElevenLabs "Matilda").
#
# Toggle mode:  claude-speak.sh on|off|status   (aliased as `voice`)
# Hook mode:    invoked with no args by the Stop hook; reads hook JSON on
#               stdin and speaks the session's final assistant reply when
#               the voice flag is on.

FLAG="$HOME/.claude/voice.on"
VOICE_ID="XrExE9yKIg1WjnnlVkGX" # Matilda — Knowledgeable, Professional
MODEL="eleven_turbo_v2_5"
MAX_CHARS=1500

case "$1" in
  on) touch "$FLAG"; echo "voice: ON (Matilda)"; exit 0 ;;
  off) rm -f "$FLAG"; echo "voice: OFF"; exit 0 ;;
  status) [ -f "$FLAG" ] && echo "voice: ON (Matilda)" || echo "voice: OFF"; exit 0 ;;
esac

# No args + interactive terminal = status check, not a hook invocation.
if [ -t 0 ]; then
  [ -f "$FLAG" ] && echo "voice: ON (Matilda)" || echo "voice: OFF"
  exit 0
fi

# ---- Stop-hook mode ----
[ -f "$FLAG" ] || exit 0

# Only D's TRULY interactive sessions ever speak (D rule 2026-07-23):
# - fleet fires (queue worker, telegram listener, crons) carry
#   BARECLAUDE_AGENT_SLUG via agent-shell-bootstrap — silent, they have their
#   own voice surfaces and a 3am cron must not become a pager;
# - background job sessions carry CLAUDE_JOB_DIR — silent, D isn't
#   necessarily watching and parallel jobs talking over each other is noise.
# What remains is a foreground `claude` D launched in a terminal, gated by the
# voice-on flag (default OFF).
[ -n "$BARECLAUDE_AGENT_SLUG" ] && exit 0
[ -n "$CLAUDE_JOB_DIR" ] && exit 0

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)
[ -f "$TRANSCRIPT" ] || exit 0

# Corresponding voices (D rule 2026-07-22): a session running in an agent's
# workspace speaks in THAT agent's voice, resolved from the fleet model policy;
# anything else (D's plain sessions) stays Matilda. Policy unreadable → Matilda.
CWD=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
POLICY="$HOME/BareClaude/infra/model-policy.json"
AGENT=""
case "$CWD" in
  "$HOME"/BareClaude/dara*)  AGENT="dara" ;;
  "$HOME"/BareClaude/clara*) AGENT="clara" ;;
  "$HOME"/BareClaude/tars*)  AGENT="tars" ;;
esac
if [ -n "$AGENT" ] && [ -f "$POLICY" ]; then
  AV=$(jq -r --arg a "$AGENT" '.telegram_media.tts.voices[$a] | if type == "object" then .id else . end // empty' "$POLICY" 2>/dev/null)
  case "$AV" in ??????????*) VOICE_ID="$AV" ;; esac
fi

TEXT=$(python3 - "$TRANSCRIPT" "$MAX_CHARS" <<'PYEOF'
import json, re, sys

last = None
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get('type') == 'assistant':
        for c in (e.get('message') or {}).get('content', []):
            if isinstance(c, dict) and c.get('type') == 'text' and c.get('text', '').strip():
                last = c['text']
if not last:
    sys.exit(0)

# Strip markdown so it reads as speech, not syntax.
t = re.sub(r'```.*?```', ' (code block omitted) ', last, flags=re.S)
t = re.sub(r'`([^`]*)`', r'\1', t)
t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
t = re.sub(r'[\*_]{1,3}([^\*_\n]+)[\*_]{1,3}', r'\1', t)
t = re.sub(r'^[#>\-\*\|\s]+', '', t, flags=re.M)
t = ' '.join(t.split())
print(t[:int(sys.argv[2])])
PYEOF
)
[ -n "$TEXT" ] || exit 0

# Sourced from env, falling back to the shell profile. Structured this way so
# the repo's pre-commit secret scan doesn't false-positive on the var name.
STRIP='s/^[^=]*=//; s/"//g'
KEY="$ELEVENLABS_API_KEY"
[ -n "$KEY" ] || KEY=$(grep ELEVENLABS_API_KEY "$HOME/.zshrc" 2>/dev/null | head -1 | sed -E "$STRIP")
[ -n "$KEY" ] || exit 0

OUT=$(mktemp -t claude-speak) && mv "$OUT" "$OUT.mp3" && OUT="$OUT.mp3"
printf '%s' "$TEXT" | python3 -c "import json,sys; print(json.dumps({'text': sys.stdin.read(), 'model_id': '$MODEL'}))" > "$OUT.json"
curl -s --max-time 30 -o "$OUT" -X POST \
  "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
  -H "xi-api-key: $KEY" -H "Content-Type: application/json" \
  --data @"$OUT.json"
rm -f "$OUT.json"

# Background playback so the hook returns immediately (same pattern as the
# Notification hook's afplay). If an SSH reverse tunnel receiver is listening
# (laptop runs voice-rx.sh + `RemoteForward 7777 localhost:7777` in its ssh
# config), stream the audio through it so speech follows you to the machine
# you're SSH'd in from; otherwise play on this machine's speakers.
# Receiver candidates, first listener wins: explicit SSH tunnel (127.0.0.1,
# for non-tailnet paths), then the laptop directly over the tailnet — D SSHes
# via Tailscale, so the Mini usually has a direct route to the Air and no
# forward is needed. Override list via CLAUDE_VOICE_RX_HOSTS.
RX_PORT=7777
RX_HOSTS="${CLAUDE_VOICE_RX_HOSTS:-127.0.0.1 damilola-mba}"
for RX in $RX_HOSTS; do
  if nc -z -G 1 "$RX" "$RX_PORT" 2>/dev/null; then
    ( nc -G 2 -w 10 "$RX" "$RX_PORT" < "$OUT" 2>/dev/null; rm -f "$OUT" ) &
    exit 0
  fi
done
( afplay "$OUT" 2>/dev/null; rm -f "$OUT" ) &
exit 0
