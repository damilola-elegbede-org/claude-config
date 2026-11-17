#!/bin/bash
# claude-speak.sh — gives Claude a voice (ElevenLabs "Matilda").
#
# Toggle mode:  claude-speak.sh on|off|status   (aliased as `voice`)
#               ~/.claude/voice.on is the one switch for this machine. While it
#               exists every Claude session here speaks, foreground or
#               background job; removing it silences all of them, including
#               replies still waiting their turn to play.
# Hook mode:    invoked with no args by the Stop hook; reads hook JSON on
#               stdin and speaks the session's final assistant reply when
#               the voice flag is on and the reply needs D.
# Play mode:    claude-speak.sh play <file>   (used by voice-rx.sh) plays one
#               audio file under the playback lock, then deletes it.

FLAG="$HOME/.claude/voice.on"
LOCK="$HOME/.claude/voice.lock"
VOICE_ID="XrExE9yKIg1WjnnlVkGX" # Matilda — Knowledgeable, Professional
MODEL="eleven_turbo_v2_5"
MAX_CHARS=1500
# Longest a finished reply waits for its turn to play. Past this it is dropped,
# because speech that arrives minutes late is noise.
MAX_WAIT="${CLAUDE_VOICE_MAX_WAIT:-300}"

# One playback at a time across every session on this machine, so parallel
# sessions never talk over each other. Takes an exclusive lock on fd 9 and
# returns 1 if the wait runs out. The caller's shell holds the lock until it
# exits, so a crashed session can never leave a stale lock behind.
voice_lock() {
  exec 9>>"$LOCK" || return 1
  python3 -c '
import fcntl, sys, time

deadline = time.monotonic() + float(sys.argv[1])
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except OSError:
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.2)
' "$MAX_WAIT"
}

case "$1" in
  on) touch "$FLAG"; echo "voice: ON (Matilda)"; exit 0 ;;
  off) rm -f "$FLAG"; echo "voice: OFF"; exit 0 ;;
  status) [ -f "$FLAG" ] && echo "voice: ON (Matilda)" || echo "voice: OFF"; exit 0 ;;
  play)
    [ -f "$2" ] || exit 0
    voice_lock && afplay "$2" 9>&- 2>/dev/null
    rm -f "$2"
    exit 0
    ;;
esac

# No args + interactive terminal = status check, not a hook invocation.
if [ -t 0 ]; then
  [ -f "$FLAG" ] && echo "voice: ON (Matilda)" || echo "voice: OFF"
  exit 0
fi

# ---- Stop-hook mode ----
[ -f "$FLAG" ] || exit 0

# The voice flag governs every session on this machine (D, 2026-11-16):
# foreground sessions and background job sessions (CLAUDE_JOB_DIR) alike.
# The one exception is fleet fires (queue worker, telegram listener, crons),
# which carry BARECLAUDE_AGENT_SLUG via agent-shell-bootstrap: they stay silent
# (D rule 2026-07-23), because they have their own voice surfaces and a 3am
# cron must not become a pager.
[ -n "$BARECLAUDE_AGENT_SLUG" ] && exit 0

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
  "$HOME"/BareClaude/clara*) AGENT="clara" ;;
esac
if [ -n "$AGENT" ] && [ -f "$POLICY" ]; then
  AV=$(jq -r --arg a "$AGENT" '.telegram_media.tts.voices[$a] | if type == "object" then .id else . end // empty' "$POLICY" 2>/dev/null)
  case "$AV" in ??????????*) VOICE_ID="$AV" ;; esac
fi

TEXT=$(python3 - "$TRANSCRIPT" "$MAX_CHARS" "$CWD" "$HOME" <<'PYEOF'
import json, os, re, sys

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

# Speak only when line 1 carries a tag that needs D (D rule 2026-09-30). FYI and
# untagged replies stay silent. Checked before the markdown stripping below
# removes the ** around the tag.
first = next((l for l in last.splitlines() if l.strip()), '')
if not re.match(r'^[\s*_#>]*(ACTION|DECISION|APPROVAL|INPUT|BLOCKED)\b', first):
    sys.exit(0)

# Strip markdown so it reads as speech, not syntax.
t = re.sub(r'```.*?```', ' (code block omitted) ', last, flags=re.S)
t = re.sub(r'`([^`]*)`', r'\1', t)
t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
t = re.sub(r'[\*_]{1,3}([^\*_\n]+)[\*_]{1,3}', r'\1', t)
t = re.sub(r'^[#>\-\*\|\s]+', '', t, flags=re.M)
t = ' '.join(t.split())

# With every session speaking, say which one this is: the project folder name,
# taken from the session's working directory (the repository for a worktree).
# A session started in the home folder has no project, so it gets no prefix.
cwd = sys.argv[3].rstrip('/').split('/.claude/worktrees/')[0]
name = ''
if cwd and cwd != sys.argv[4].rstrip('/'):
    name = ' '.join(re.sub(r'[^A-Za-z0-9]+', ' ', os.path.basename(cwd)).split())
if name:
    t = name + '. ' + t
print(t[:int(sys.argv[2])])
PYEOF
)
[ -n "$TEXT" ] || exit 0

# Key resolution: the environment first, which is where D's laptop sessions get
# it, background jobs included. The fallback is the fleet age vault, which
# exists only on the Mac mini; on a machine without it this block is skipped.
# Never a plaintext shell profile (D ruling 2026-07-23; any process can read
# ~/.zshrc, and the vault is the single rotation point).
KEY="$ELEVENLABS_API_KEY"
if [ -z "$KEY" ]; then
  VAULT="$HOME/BareClaude/infra/credentials/shared/elevenlabs-api.age"
  AGEKEY="$HOME/BareClaude/infra/credentials/age-key.txt"
  AGEBIN=$(command -v age || echo /opt/homebrew/bin/age)
  [ -f "$VAULT" ] && [ -f "$AGEKEY" ] && KEY=$("$AGEBIN" -d -i "$AGEKEY" "$VAULT" 2>/dev/null)
fi
[ -n "$KEY" ] || exit 0

OUT=$(mktemp -t claude-speak) && mv "$OUT" "$OUT.mp3" && OUT="$OUT.mp3"
printf '%s' "$TEXT" | python3 -c "import json,sys; print(json.dumps({'text': sys.stdin.read(), 'model_id': '$MODEL'}))" > "$OUT.json"
curl -s --max-time 30 -o "$OUT" -X POST \
  "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID?enable_logging=false" \
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

# Send or play one reply while holding the playback lock, so replies from
# parallel sessions play one after another. The receiver queues what it gets
# under the same lock (voice-rx.sh).
deliver() {
  local rx
  voice_lock || return 0
  [ -f "$FLAG" ] || return 0 # `voice off` arrived while this reply waited
  for rx in $RX_HOSTS; do
    if nc -z -G 1 "$rx" "$RX_PORT" 9>&- 2>/dev/null; then
      nc -G 2 -w 10 "$rx" "$RX_PORT" < "$1" 9>&- 2>/dev/null
      return 0
    fi
  done
  afplay "$1" 9>&- 2>/dev/null
}
(
  deliver "$OUT"
  rm -f "$OUT"
) > /dev/null 2>&1 < /dev/null &
exit 0
