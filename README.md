# TTS Service for macOS

Stream OpenAI TTS on selected text with real-time playback — accessible from the right-click context menu or the menu bar app. Supports pause/resume, stop, voice selection, and playback speed control.

---

## Architecture

```
Selected Text
     │
     ├─► Right-click → Services → "Speak with TTS"   (Automator Quick Action)
     └─► Menu Bar App → "Speak Selected Text"         (rumps + AppleScript)
          │
          ▼
   tts_client.py  ──── Unix socket (/tmp/tts_daemon.sock) ────►  tts_daemon.py
                                                                       │
                                                              OpenAI /v1/audio/speech
                                                              (streaming PCM, 24kHz)
                                                                       │
                                                              sounddevice RawOutputStream
                                                              (chunk-by-chunk playback)
```

**Key design decisions:**
- **Streaming PCM** — `response_format: pcm` gives raw 16-bit audio with no container overhead; playback starts within ~300ms of the first chunk arriving.
- **Unix socket IPC** — lightweight, low-latency communication between the client, menu bar app, and daemon.
- **Pause via Event** — the playback loop calls `pause_event.wait()` between chunks; clearing the event freezes audio immediately without dropping buffered data.
- **Stop via Event** — sets `stop_event` and unblocks the pause event so the thread exits cleanly.
- **Playback speed via sample rate** — speed is applied by opening `sounddevice.RawOutputStream` at `24000 × speed` Hz. Speed changes take effect within one chunk (~170ms) mid-playback, with no re-encoding required.

---

## Installation

```bash
# Copy this folder somewhere, then:
bash install.sh
```

You'll be prompted for your OpenAI API key. The script:
1. Copies files to `~/.tts-service/`
2. Locates your conda installation and creates a `tts-service` env (Python 3.13)
3. Installs all dependencies (most via conda-forge, PyObjC framework via pip)
4. Registers a launchd agent that auto-starts the menu bar app on login
5. Prints instructions for the one manual step (Automator)

### Manual step — Automator Service

1. Open **Automator** → File → New → **Quick Action**
2. Set "Workflow receives current" = **text** in **any application**
3. Add action: **Run Shell Script** — shell `/bin/bash`, pass input **as stdin**
4. Script body:
   ```bash
   bash ~/.tts-service/service/tts_service.sh
   ```
5. Save as **"Speak with TTS"**

After saving, it appears in **right-click → Services → Speak with TTS**.

> You may need to grant the service permission under **System Settings → Privacy & Security → Automation**.

---

## Controls

| Action | Trigger |
|---|---|
| Speak selected text | Right-click → Services → Speak with TTS |
| Speak selected text | Menu bar → Speak Selected Text |
| Pause / Resume | Menu bar → Pause / Resume |
| Stop | Menu bar → Stop |
| Change speed | Menu bar → Speed → [0.5× / 0.75× / 1× / 1.25× / 1.5× / 2×] |
| Change voice | Menu bar → Voice → [alloy / echo / fable / onyx / nova / shimmer] |

The menu bar icon reflects current state (🔊 playing, ⏸ paused, 🔇 idle) and shows the active speed when it is not 1×, e.g. `🔊 1.5×`.

---

## File Layout

```
~/.tts-service/
├── daemon/
│   ├── tts_daemon.py        Streaming TTS engine + Unix socket server
│   └── tts_client.py        CLI client for sending commands to the daemon
├── menubar/
│   └── tts_menubar.py       Menu bar app (rumps): status, controls, voice & speed
└── service/
    └── tts_service.sh       Shell script invoked by the Automator Quick Action

~/miniconda3/envs/tts-service/   Conda environment (path varies by conda install)

~/Library/LaunchAgents/
└── com.tts-service.menubar.plist   Launches menu bar app on login via launchd

~/Library/Logs/
├── TTSDaemon.log
└── TTSMenuBar.log
```

---

## Troubleshooting

**No audio / daemon not starting**
```bash
tail -f ~/Library/Logs/TTSDaemon.log
```

**Service not appearing in right-click menu**
→ System Settings → Privacy & Security → **Extensions → Finder** — ensure "Speak with TTS" is enabled.
→ Or verify: `ls ~/Library/Services/`

**Restart the menu bar app**
```bash
launchctl kickstart -k gui/$(id -u)/com.tts-service.menubar
```

**Stop everything**
```bash
launchctl unload ~/Library/LaunchAgents/com.tts-service.menubar.plist
conda run -n tts-service python ~/.tts-service/daemon/tts_client.py quit
```

---

## Dependencies

| Package | Purpose |
|---|---|
| `portaudio` | Audio I/O backend |
| `rumps` | macOS menu bar app framework |
| `sounddevice` | Real-time audio output (PortAudio bindings) |
| `soundfile` | Audio format support |
| `pyobjc-framework-Cocoa` | macOS native APIs |

All installed automatically into the `tts-service` conda environment by `install.sh`.

To manage the environment manually:
```bash
conda activate tts-service
conda env remove -n tts-service   # to uninstall
```
