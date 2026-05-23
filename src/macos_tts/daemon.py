#!/usr/bin/env python3
"""
TTS Daemon — streams OpenAI TTS audio and plays it back in real-time.
Communicates via Unix domain socket at /tmp/tts_daemon.sock.

Commands (newline-terminated JSON):
  {"cmd": "speak", "text": "...", "voice": "alloy"}
  {"cmd": "pause"}
  {"cmd": "resume"}
  {"cmd": "stop"}
  {"cmd": "set_speed", "speed": 1.25}
  {"cmd": "status"}
  {"cmd": "quit"}

Responses: JSON with {"status": "...", ...}
"""

import json
import os
import socket
import sys
import threading
import time
import logging
from pathlib import Path

import sounddevice as sd

# ── Logging ──────────────────────────────────────────────────────────────────
LOG_PATH = Path.home() / "Library" / "Logs" / "TTSDaemon.log"
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("tts_daemon")

SOCKET_PATH = "/tmp/tts_daemon.sock"
CHUNK_BYTES = 4096  # bytes read per iteration from HTTP stream
SAMPLE_RATE = 24000  # OpenAI TTS PCM output sample rate
CHANNELS = 1


# ── Playback state ────────────────────────────────────────────────────────────
class PlaybackState:
    IDLE = "idle"
    PLAYING = "playing"
    PAUSED = "paused"


class TTSDaemon:
    def __init__(self):
        self.state = PlaybackState.IDLE
        self.state_lock = threading.Lock()
        self.pause_event = threading.Event()  # set = playing, clear = paused
        self.stop_event = threading.Event()  # set = stop requested
        self.play_thread = None
        self.current_text = ""
        self.speed = 1.0  # playback speed multiplier
        self.pause_event.set()  # start unpaused

    # ── OpenAI streaming ─────────────────────────────────────────────────────
    def _stream_tts(self, text: str, voice: str = "alloy"):
        """Generator: yields raw PCM chunks from OpenAI TTS streaming endpoint."""
        import urllib.request
        import urllib.error

        api_key = os.environ.get("OPENAI_API_KEY", "")
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY not set")

        payload = json.dumps(
            {
                "model": "tts-1",
                "input": text,
                "voice": voice,
                "response_format": "pcm",  # raw 16-bit PCM, 24kHz, mono
            }
        ).encode()

        req = urllib.request.Request(
            "https://api.openai.com/v1/audio/speech",
            data=payload,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )

        with urllib.request.urlopen(req, timeout=30) as resp:
            while True:
                chunk = resp.read(CHUNK_BYTES)
                if not chunk:
                    break
                yield chunk

    # ── Playback thread ───────────────────────────────────────────────────────
    def _play(self, text: str, voice: str):
        log.info(f"Starting TTS: voice={voice}, text[:60]={text[:60]!r}")
        self.stop_event.clear()
        self.pause_event.set()

        try:
            # Buffer all incoming PCM chunks so we can reopen the stream
            # when speed changes mid-playback. We use a queue fed by the
            # network thread; the playback loop drains it chunk by chunk,
            # reopening sd.RawOutputStream whenever self.speed changes.
            import queue

            pcm_queue = queue.Queue(maxsize=32)
            fetch_done = threading.Event()

            def _fetch():
                try:
                    for chunk in self._stream_tts(text, voice):
                        if self.stop_event.is_set():
                            break
                        pcm_queue.put(chunk)
                except Exception as e:
                    log.error(f"Fetch error: {e}")
                finally:
                    fetch_done.set()
                    pcm_queue.put(None)  # sentinel

            fetch_thread = threading.Thread(target=_fetch, daemon=True)
            fetch_thread.start()

            current_speed = self.speed
            stream = sd.RawOutputStream(
                samplerate=int(SAMPLE_RATE * current_speed),
                channels=CHANNELS,
                dtype="int16",
                blocksize=1024,
            )
            stream.start()

            try:
                while True:
                    if self.stop_event.is_set():
                        log.info("Playback stopped by request")
                        break

                    # Reopen stream if speed changed
                    new_speed = self.speed
                    if new_speed != current_speed:
                        stream.stop()
                        stream.close()
                        current_speed = new_speed
                        stream = sd.RawOutputStream(
                            samplerate=int(SAMPLE_RATE * current_speed),
                            channels=CHANNELS,
                            dtype="int16",
                            blocksize=1024,
                        )
                        stream.start()
                        log.info(f"Speed changed to {current_speed}×")

                    try:
                        pcm_chunk = pcm_queue.get(timeout=0.1)
                    except queue.Empty:
                        if fetch_done.is_set():
                            break
                        continue

                    if pcm_chunk is None:  # sentinel
                        break

                    # Write chunk honouring pause
                    offset = 0
                    while offset < len(pcm_chunk):
                        self.pause_event.wait()
                        if self.stop_event.is_set():
                            break
                        # Re-check speed between sub-chunks
                        if self.speed != current_speed:
                            break
                        end = min(offset + 2048, len(pcm_chunk))
                        stream.write(pcm_chunk[offset:end])
                        offset = end
            finally:
                stream.stop()
                stream.close()

        except Exception as e:
            log.error(f"Playback error: {e}")
        finally:
            with self.state_lock:
                self.state = PlaybackState.IDLE
            log.info("Playback finished")

    # ── Commands ──────────────────────────────────────────────────────────────
    def speak(self, text: str, voice: str = "alloy") -> dict:
        # Stop any ongoing playback first
        self.stop()
        time.sleep(0.1)

        self.current_text = text
        with self.state_lock:
            self.state = PlaybackState.PLAYING

        self.play_thread = threading.Thread(
            target=self._play, args=(text, voice), daemon=True
        )
        self.play_thread.start()
        return {"status": "ok", "state": "playing"}

    def pause(self) -> dict:
        with self.state_lock:
            if self.state == PlaybackState.PLAYING:
                self.pause_event.clear()
                self.state = PlaybackState.PAUSED
                return {"status": "ok", "state": "paused"}
        return {"status": "noop", "state": self.state}

    def resume(self) -> dict:
        with self.state_lock:
            if self.state == PlaybackState.PAUSED:
                self.pause_event.set()
                self.state = PlaybackState.PLAYING
                return {"status": "ok", "state": "playing"}
        return {"status": "noop", "state": self.state}

    def toggle_pause(self) -> dict:
        with self.state_lock:
            if self.state == PlaybackState.PLAYING:
                self.pause_event.clear()
                self.state = PlaybackState.PAUSED
                return {"status": "ok", "state": "paused"}
            elif self.state == PlaybackState.PAUSED:
                self.pause_event.set()
                self.state = PlaybackState.PLAYING
                return {"status": "ok", "state": "playing"}
        return {"status": "noop", "state": self.state}

    def stop(self) -> dict:
        self.stop_event.set()
        self.pause_event.set()  # unblock if paused
        if self.play_thread and self.play_thread.is_alive():
            self.play_thread.join(timeout=2)
        with self.state_lock:
            self.state = PlaybackState.IDLE
        return {"status": "ok", "state": "idle"}

    def set_speed(self, speed: float) -> dict:
        valid = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0}
        if speed not in valid:
            return {
                "status": "error",
                "message": f"Speed must be one of {sorted(valid)}",
            }
        self.speed = speed
        log.info(f"Speed set to {speed}×")
        return {"status": "ok", "speed": speed}

    def status(self) -> dict:
        with self.state_lock:
            return {
                "status": "ok",
                "state": self.state,
                "speed": self.speed,
                "text": self.current_text[:80],
            }

    # ── Socket server ─────────────────────────────────────────────────────────
    def _handle_client(self, conn: socket.socket):
        try:
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break

            msg = json.loads(data.strip())
            cmd = msg.get("cmd", "")
            log.info(f"Command: {cmd}")

            if cmd == "speak":
                resp = self.speak(msg.get("text", ""), msg.get("voice", "alloy"))
            elif cmd == "pause":
                resp = self.pause()
            elif cmd == "resume":
                resp = self.resume()
            elif cmd == "toggle_pause":
                resp = self.toggle_pause()
            elif cmd == "set_speed":
                resp = self.set_speed(float(msg.get("speed", 1.0)))
            elif cmd == "stop":
                resp = self.stop()
            elif cmd == "status":
                resp = self.status()
            elif cmd == "quit":
                resp = {"status": "ok", "state": "quitting"}
                conn.sendall((json.dumps(resp) + "\n").encode())
                conn.close()
                os._exit(0)
            else:
                resp = {"status": "error", "message": f"Unknown command: {cmd}"}

            conn.sendall((json.dumps(resp) + "\n").encode())
        except Exception as e:
            log.error(f"Client error: {e}")
            try:
                conn.sendall(
                    (json.dumps({"status": "error", "message": str(e)}) + "\n").encode()
                )
            except:
                pass
        finally:
            conn.close()

    def run(self):
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o600)
        server.listen(8)
        log.info(f"TTS Daemon listening on {SOCKET_PATH}")

        try:
            while True:
                conn, _ = server.accept()
                t = threading.Thread(
                    target=self._handle_client, args=(conn,), daemon=True
                )
                t.start()
        except KeyboardInterrupt:
            log.info("Daemon shutting down")
        finally:
            server.close()
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)


def main():
    daemon = TTSDaemon()
    daemon.run()

if __name__ == "__main__":
    main()
