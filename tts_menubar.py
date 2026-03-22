#!/usr/bin/env python3
"""
TTS Menu Bar App
- Lives in the macOS menu bar (🔊 icon)
- Shows current state (Idle / Playing / Paused) and active speed
- Provides Speak selected text, Pause/Resume, Stop menu items
- Speed submenu: 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×

Requirements:
  pip install rumps pyobjc-framework-Cocoa pyobjc-framework-AppKit
"""

import json
import socket
import subprocess
import sys
import time
from pathlib import Path

import rumps

# ── Path resolution ───────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.resolve()
CLIENT_PATH = SCRIPT_DIR.parent / "daemon" / "tts_client.py"
DAEMON_PATH = SCRIPT_DIR.parent / "daemon" / "tts_daemon.py"
PYTHON_BIN = sys.executable
SOCKET_PATH = "/tmp/tts_daemon.sock"


# ── Daemon IPC ────────────────────────────────────────────────────────────────
def send_cmd(cmd: dict) -> dict:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall((json.dumps(cmd) + "\n").encode())
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        sock.close()
        return json.loads(data.strip())
    except Exception as e:
        return {"status": "error", "message": str(e)}


def get_selected_text() -> str:
    """Use AppleScript to grab the current selection via clipboard."""
    script = """
    tell application "System Events"
        keystroke "c" using {command down}
    end tell
    delay 0.15
    return the clipboard
    """
    try:
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip()
    except Exception:
        return ""


def ensure_daemon_running():
    """Start the daemon if not already running."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1)
        sock.connect(SOCKET_PATH)
        sock.close()
    except Exception:
        subprocess.Popen(
            [PYTHON_BIN, str(DAEMON_PATH)],
            stdout=open(Path.home() / "Library/Logs/TTSDaemon.log", "a"),
            stderr=subprocess.STDOUT,
        )
        time.sleep(1.5)


# ── Menu bar app ──────────────────────────────────────────────────────────────
class TTSMenuBar(rumps.App):
    def __init__(self):
        super().__init__(
            name="TTS",
            title="🔊",
            quit_button=rumps.MenuItem("Quit TTS Service"),
        )
        self.voice = "alloy"
        self.speed = 1.0

        # ── Menu items ────────────────────────────────────────────────────────
        self.speak_item = rumps.MenuItem("Speak Selected Text", callback=self.on_speak)
        self.pause_item = rumps.MenuItem("Pause / Resume", callback=self.on_pause)
        self.stop_item = rumps.MenuItem("Stop", callback=self.on_stop)
        self.status_item = rumps.MenuItem("◼ Idle")
        self.status_item.set_callback(None)

        voice_menu = rumps.MenuItem("Voice")
        for v in ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]:
            item = rumps.MenuItem(v, callback=self.on_voice)
            voice_menu.add(item)

        SPEEDS = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        self.speed_menu = rumps.MenuItem("Speed")
        for s in SPEEDS:
            label = f"{'✓' if s == 1.0 else '   '} {s}×"
            item = rumps.MenuItem(label, callback=self.on_speed)
            item._speed_value = s
            self.speed_menu.add(item)

        self.menu = [
            self.status_item,
            None,
            self.speak_item,
            self.pause_item,
            self.stop_item,
            None,
            voice_menu,
            self.speed_menu,
            None,
        ]

        ensure_daemon_running()

        # Poll daemon for status
        self._poll_timer = rumps.Timer(self._update_status, 1)
        self._poll_timer.start()

    # ── Callbacks ─────────────────────────────────────────────────────────────
    def on_speak(self, _):
        text = get_selected_text()
        if text:
            ensure_daemon_running()
            send_cmd({"cmd": "speak", "text": text, "voice": self.voice})
        else:
            rumps.alert("No text selected", "Please select some text first.")

    def on_pause(self, _):
        send_cmd({"cmd": "toggle_pause"})

    def on_stop(self, _):
        send_cmd({"cmd": "stop"})

    def on_voice(self, sender):
        self.voice = sender.title
        rumps.notification("TTS", f"Voice set to: {self.voice}", "")

    def on_speed(self, sender):
        new_speed = sender._speed_value
        self.speed = new_speed
        send_cmd({"cmd": "set_speed", "speed": new_speed})
        # Update checkmarks in speed submenu
        for item in self.speed_menu.values():
            s = getattr(item, "_speed_value", None)
            if s is not None:
                item.title = f"{'✓' if s == new_speed else '   '} {s}×"

    def _update_status(self, _):
        resp = send_cmd({"cmd": "status"})
        state = resp.get("state", "idle")
        speed = resp.get("speed", self.speed)
        icons = {
            "idle": ("🔇", "◼ Idle"),
            "playing": ("🔊", "▶ Playing"),
            "paused": ("⏸", "⏸ Paused"),
        }
        bar_icon, label = icons.get(state, ("🔊", state))
        speed_tag = f"  {speed}×" if speed != 1.0 else ""
        self.title = bar_icon + speed_tag
        self.status_item.title = label + (f"  —  {speed}×" if speed != 1.0 else "")


if __name__ == "__main__":
    TTSMenuBar().run()
