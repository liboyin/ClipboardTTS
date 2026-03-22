#!/bin/bash
# install.sh — sets up the TTS Service end-to-end
# Run once: bash install.sh
set -e

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}▶${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✗${NC}  $*"; exit 1; }

# ── 0. OpenAI API Key ─────────────────────────────────────────────────────────
if [ -z "$OPENAI_API_KEY" ]; then
    read -rsp "Enter your OpenAI API key: " OPENAI_API_KEY
    echo
fi
[ -z "$OPENAI_API_KEY" ] && error "OPENAI_API_KEY is required."

# ── 1. Install location ───────────────────────────────────────────────────────
INSTALL_DIR="$HOME/.tts-service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDA_ENV_NAME="tts-service"
info "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy source files
cp -r "$SCRIPT_DIR/daemon"   "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/menubar"  "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/service"  "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/scripts"  "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/service/tts_service.sh"
chmod +x "$INSTALL_DIR/daemon/tts_daemon.py"
chmod +x "$INSTALL_DIR/daemon/tts_client.py"
chmod +x "$INSTALL_DIR/menubar/tts_menubar.py"

# ── 2. Locate conda ───────────────────────────────────────────────────────────
info "Locating conda…"

# Try common install locations in order
CONDA_SH=""
for candidate in \
    "$HOME/miniconda3/etc/profile.d/conda.sh" \
    "$HOME/anaconda3/etc/profile.d/conda.sh" \
    "$HOME/miniforge3/etc/profile.d/conda.sh" \
    "$HOME/mambaforge/etc/profile.d/conda.sh" \
    "/opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh" \
    "/opt/miniconda3/etc/profile.d/conda.sh" \
    "/usr/local/miniconda3/etc/profile.d/conda.sh"
do
    if [ -f "$candidate" ]; then
        CONDA_SH="$candidate"
        break
    fi
done

if [ -z "$CONDA_SH" ]; then
    error "conda not found. Please install Miniconda or Anaconda first.\n  https://docs.conda.io/en/latest/miniconda.html"
fi

info "Found conda at: $CONDA_SH"
# shellcheck disable=SC1090
source "$CONDA_SH"

# Derive CONDA_BASE for use in plist (conda run needs it)
CONDA_BASE="$(conda info --base)"
CONDA_PY="$CONDA_BASE/envs/$CONDA_ENV_NAME/bin/python3"

# ── 3. Create conda environment + install deps ────────────────────────────────
if conda env list | grep -q "^$CONDA_ENV_NAME "; then
    warn "Conda env '$CONDA_ENV_NAME' already exists — updating packages."
    conda activate "$CONDA_ENV_NAME"
else
    info "Creating conda environment '$CONDA_ENV_NAME' (Python 3.13)…"
    conda create -y -n "$CONDA_ENV_NAME" python=3.13 -q
    conda activate "$CONDA_ENV_NAME"
fi

info "Installing Python dependencies into '$CONDA_ENV_NAME'…"
# Install most dependencies via conda, apart from PyObjC framework which is only available on pip
conda install -y -c conda-forge portaudio rumps python-sounddevice pysoundfile -q
pip install --upgrade pip -q
pip install pyobjc-framework-Cocoa pyobjc-framework-AppKit -q

info "Conda environment ready ✓  (python: $CONDA_PY)"

# ── 4. Update service script paths ───────────────────────────────────────────
info "Patching service script paths…"
sed -i '' \
    "s|PYTHON=\".*\"|PYTHON=\"$CONDA_PY\"|" \
    "$INSTALL_DIR/service/tts_service.sh"
sed -i '' \
    "s|CLIENT=\".*\"|CLIENT=\"$INSTALL_DIR/daemon/tts_client.py\"|" \
    "$INSTALL_DIR/service/tts_service.sh"
sed -i '' \
    "s|DAEMON=\".*\"|DAEMON=\"$INSTALL_DIR/daemon/tts_daemon.py\"|" \
    "$INSTALL_DIR/service/tts_service.sh"

# ── 5. launchd plist ─────────────────────────────────────────────────────────
info "Installing launchd service…"
PLIST_SRC="$INSTALL_DIR/scripts/com.tts-service.menubar.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.tts-service.menubar.plist"

sed -i '' "s|PYTHON_PLACEHOLDER|$CONDA_PY|g"                          "$PLIST_SRC"
sed -i '' "s|MENUBAR_PLACEHOLDER|$INSTALL_DIR/menubar/tts_menubar.py|g" "$PLIST_SRC"
sed -i '' "s|OPENAI_KEY_PLACEHOLDER|$OPENAI_API_KEY|g"                "$PLIST_SRC"
sed -i '' "s|HOMEDIR_PLACEHOLDER|$HOME|g"                             "$PLIST_SRC"

cp "$PLIST_SRC" "$PLIST_DST"

# Unload old instance if exists
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"
info "Menu bar app launched via launchd ✓"

# ── 6. Automator Service ──────────────────────────────────────────────────────
echo ""
warn "Manual step: create the macOS right-click Service in Automator"
echo ""
echo "  1. Open Automator (Spotlight → Automator)"
echo "  2. File → New → Quick Action (Service)"
echo "  3. Set: 'Workflow receives current' = text, in 'any application'"
echo "  4. Add action: Library → Utilities → Run Shell Script"
echo "  5. Shell: /bin/bash   |   Pass input: as stdin"
echo "  6. Paste this script body:"
echo ""
echo "     bash $INSTALL_DIR/service/tts_service.sh"
echo ""
echo "  7. File → Save → name it 'Speak with TTS'"
echo "  8. It will appear in right-click → Services → Speak with TTS"
echo ""

info "Installation complete! 🎉"
echo ""
echo "  🔊 Menu bar icon should be visible now."
echo "  Right-click any text → Services → Speak with TTS"
echo ""
echo "  Conda env : $CONDA_ENV_NAME  (python: $CONDA_PY)"
echo "  Logs      : ~/Library/Logs/TTSDaemon.log"
echo "              ~/Library/Logs/TTSMenuBar.log"
echo ""
echo "  To manually activate the env:"
echo "    conda activate $CONDA_ENV_NAME"
