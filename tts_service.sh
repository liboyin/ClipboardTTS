#!/bin/bash
# This script is called by the macOS Automator Service.
# It receives selected text via stdin and forwards it to the TTS daemon.
#
# The Automator workflow should:
#   Action: "Run Shell Script"
#   Shell: /bin/bash
#   Pass input: as stdin

# ── Config ─────────────────────────────────────────────────────────────────
# Update these paths after installation:
PYTHON="$HOME/.tts-service/venv/bin/python3"
CLIENT="$HOME/.tts-service/daemon/tts_client.py"
DAEMON="$HOME/.tts-service/daemon/tts_daemon.py"
SOCKET="/tmp/tts_daemon.sock"
VOICE="${TTS_VOICE:-alloy}"

# ── Read selected text from stdin ──────────────────────────────────────────
TEXT=$(cat)

if [ -z "$TEXT" ]; then
    osascript -e 'display notification "No text selected" with title "TTS"'
    exit 0
fi

# ── Ensure daemon is running ───────────────────────────────────────────────
if ! [ -S "$SOCKET" ]; then
    nohup "$PYTHON" "$DAEMON" \
        >> "$HOME/Library/Logs/TTSDaemon.log" 2>&1 &
    sleep 1.5
fi

# ── Send speak command ─────────────────────────────────────────────────────
"$PYTHON" "$CLIENT" speak "$TEXT" "$VOICE"

osascript -e "display notification \"Speaking selected text…\" with title \"TTS\" subtitle \"Voice: $VOICE\""
