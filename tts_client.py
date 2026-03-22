#!/usr/bin/env python3
"""
tts_client.py — send commands to the TTS daemon.

Usage:
  tts_client.py speak "Hello world" [--voice alloy]
  tts_client.py pause
  tts_client.py resume
  tts_client.py toggle_pause
  tts_client.py stop
  tts_client.py set_speed 1.5
  tts_client.py status
  tts_client.py quit
"""

import json
import socket
import sys

SOCKET_PATH = "/tmp/tts_daemon.sock"

def send_command(cmd: dict) -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
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
        return json.loads(data.strip())
    except FileNotFoundError:
        return {"status": "error", "message": "Daemon not running (socket not found)"}
    except ConnectionRefusedError:
        return {"status": "error", "message": "Daemon not running (connection refused)"}
    finally:
        sock.close()


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    cmd_name = args[0]

    if cmd_name == "speak":
        if len(args) < 2:
            print("Usage: tts_client.py speak <text> [voice]")
            sys.exit(1)
        text  = args[1]
        voice = args[2] if len(args) > 2 else "alloy"
        cmd   = {"cmd": "speak", "text": text, "voice": voice}

    elif cmd_name in ("pause", "resume", "toggle_pause", "stop", "status", "quit"):
        cmd = {"cmd": cmd_name}

    elif cmd_name == "set_speed":
        if len(args) < 2:
            print("Usage: tts_client.py set_speed <0.5|0.75|1.0|1.25|1.5|2.0>")
            sys.exit(1)
        cmd = {"cmd": "set_speed", "speed": float(args[1])}

    else:
        print(f"Unknown command: {cmd_name}")
        sys.exit(1)

    resp = send_command(cmd)
    print(json.dumps(resp, indent=2))


if __name__ == "__main__":
    main()
