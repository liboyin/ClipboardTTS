#!/usr/bin/env bash
# Local Kokoro-82M v1.1-zh speech server for ClipboardTTS's Custom provider, run natively on macOS
# so the model can use the Apple GPU (PyTorch MPS), which Docker on macOS cannot reach. It speaks
# mixed Chinese-English text with a zf_/zm_ voice.
#
# One-time setup of the patched Kokoro-FastAPI v0.9.0 checkout: see README "Native on macOS".
# Start: kokoro/start-native.sh          (Apple GPU)
#        kokoro/start-native.sh --cpu    (CPU only, for comparison)
# Stop:  Ctrl-C
set -euo pipefail

# The checkout and its uv-built .venv; override with KOKORO_FASTAPI_DIR.
KOKORO_DIR="${KOKORO_FASTAPI_DIR:-$HOME/Code/Kokoro-FastAPI}"
# 8881 rather than the server's 8880, so this can run beside kokoro/compose.yaml; override with
# KOKORO_PORT.
PORT="${KOKORO_PORT:-8881}"

case "${1:-}" in
  "")
    export USE_GPU=true DEVICE_TYPE=mps
    ;;
  --cpu)
    export USE_GPU=false DEVICE_TYPE=cpu
    ;;
  *)
    echo "usage: $0 [--cpu]" >&2
    exit 2
    ;;
esac

PYTHON="$KOKORO_DIR/.venv/bin/python"
MODEL_FILES="$KOKORO_DIR/api/src/models/v1_1_zh"
if [[ ! -x "$PYTHON" || ! -f "$MODEL_FILES/kokoro-v1_1-zh.pth" || ! -d "$MODEL_FILES/voices" ]]; then
  echo "error: no set-up Kokoro-FastAPI checkout at $KOKORO_DIR (missing .venv, v1.1-zh weights" \
    "or voices); see README \"Native on macOS\"" >&2
  exit 1
fi
# Unpatched, the server loads v1.0's weights and drops English words inside Chinese text.
# Absolute, because git -C resolves a relative path inside the checkout.
PATCH="$(cd "$(dirname "$0")" && pwd)/kokoro-fastapi-v1_1-zh.patch"
if ! git -C "$KOKORO_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "error: $KOKORO_DIR does not carry $PATCH; see README \"Native on macOS\"" >&2
  exit 1
fi

# Operations MPS does not implement run on the CPU instead of failing the request.
export PYTORCH_ENABLE_MPS_FALLBACK=1
export PYTHONUNBUFFERED=1
export PYTHONPATH="$KOKORO_DIR:$KOKORO_DIR/api"
export MODEL_DIR="$KOKORO_DIR/api/src/models"
export VOICES_DIR="$MODEL_FILES/voices"
export WEB_PLAYER_PATH="$KOKORO_DIR/web"
# The repository ID selects misaki's v1.1 Chinese phonemizer. The startup warm-up speaks with the
# default voice, and upstream's af_heart does not exist in v1.1-zh.
export MODEL_REPO_ID=hexgrad/Kokoro-82M-v1.1-zh
export DEFAULT_VOICE=zf_001
# The weights were downloaded and checksum-verified at setup; skip the Hub's update check.
export HF_HUB_OFFLINE=1
# The same chunk sizing as kokoro/compose.yaml: for English text the maximum sets the first chunk's
# size, and so how soon the first audio arrives; Chinese text is chunked at clause punctuation and
# can exceed it (see README).
export TARGET_MIN_TOKENS=75
export TARGET_MAX_TOKENS=100
# INFO logs each text chunk's token count and first 50 characters, which is the user's copied
# text, to this terminal; WARNING keeps that text out.
export API_LOG_LEVEL=INFO

cd "$KOKORO_DIR"
# Loopback only, and not overridable: ClipboardTTS accepts plain HTTP only to a loopback literal,
# and the server has no authentication of its own.
exec "$PYTHON" -m uvicorn api.src.main:app --host 127.0.0.1 --port "$PORT"
