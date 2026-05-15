#!/bin/bash
# pi5_video_looper installer
# Turns a fresh Raspberry Pi OS Lite (Trixie, 64-bit) install on a Pi 5
# into a kiosk video looper. Drop any video file into /home/pi/video,
# reboot, and the newest file plays full-screen on loop with no UI.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nimast/pi5_video_looper/main/install.sh | bash
#
# Or clone and run: ./install.sh

set -euo pipefail

REPO_URL="${PLAYER_REPO_URL:-https://github.com/benoitliard/video-player.git}"
TARGET_USER="${TARGET_USER:-pi}"
HOME_DIR="/home/${TARGET_USER}"
PLAYER_DIR="${HOME_DIR}/video-player"
VIDEO_DIR="${HOME_DIR}/video"
LOOPER_SCRIPT="${HOME_DIR}/pi5-video-looper.sh"

c_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
c_red() { printf "\033[1;31m%s\033[0m\n" "$*" >&2; }

require_root_via_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
        if ! sudo -n true 2>/dev/null; then
            c_yellow "This installer needs sudo. You may be prompted for a password."
        fi
    fi
}

step() { c_green "==> $*"; }

step "Updating apt and installing build dependencies"
require_root_via_sudo
$SUDO apt-get update
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential cmake git pkg-config \
    libsdl2-dev \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libswresample-dev libavfilter-dev \
    libasio-dev libboost-all-dev libv4l-dev libssl-dev zlib1g-dev libuv1-dev libjsoncpp-dev

step "Building websocketpp (from source)"
WORKDIR="$(mktemp -d)"
cd "$WORKDIR"
if [ ! -d websocketpp ]; then
    git clone --depth=1 https://github.com/zaphoyd/websocketpp.git
fi
cd websocketpp && mkdir -p build && cd build
cmake .. >/dev/null
$SUDO make install >/dev/null
cd "$WORKDIR"

step "Building uWebSockets (from source)"
if [ ! -d uWebSockets ]; then
    git clone --depth=1 --recursive https://github.com/uNetworking/uWebSockets.git
fi
cd uWebSockets/uSockets
make >/dev/null
$SUDO cp uSockets.a /usr/local/lib/libusockets.a
$SUDO cp -r src/* /usr/local/include/
cd ..
$SUDO mkdir -p /usr/local/include/uWS
$SUDO cp -r src/* /usr/local/include/uWS/
cd "$WORKDIR"

step "Cloning and building video-player"
if [ -d "$PLAYER_DIR" ]; then
    cd "$PLAYER_DIR" && git pull --ff-only || true
else
    git clone "$REPO_URL" "$PLAYER_DIR"
fi
cd "$PLAYER_DIR"

# Patch source to hide SDL cursor (idempotent)
if ! grep -q "SDL_ShowCursor(SDL_DISABLE)" src/VideoPlayer.cpp; then
    step "Patching VideoPlayer.cpp to hide SDL cursor"
    sed -i '/SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)/,/^    }$/{
        /^    }$/a\
\
    SDL_ShowCursor(SDL_DISABLE);
    }' src/VideoPlayer.cpp
fi

# Patch source to handle 'p' key as poweroff (idempotent)
if ! grep -q "SDLK_p" src/VideoPlayer.cpp; then
    step "Patching VideoPlayer.cpp to bind 'p' to poweroff"
    python3 - <<'PYEOF'
with open("src/VideoPlayer.cpp") as f: s = f.read()
if "#include <cstdlib>" not in s:
    s = s.replace('#include "VideoPlayer.h"', '#include "VideoPlayer.h"\n#include <cstdlib>', 1)
s = s.replace(
    "if (event.key.keysym.sym == SDLK_ESCAPE) {",
    "if (event.key.keysym.sym == SDLK_p) {\n"
    "                        Logger::logInfo(\"P pressed, powering off...\");\n"
    "                        system(\"sudo /sbin/poweroff\");\n"
    "                        return;\n"
    "                    } else if (event.key.keysym.sym == SDLK_ESCAPE) {",
    1,
)
with open("src/VideoPlayer.cpp", "w") as f: f.write(s)
PYEOF
fi

mkdir -p build
cd build
cmake .. >/dev/null
make -j"$(nproc)"

step "Creating video directory at $VIDEO_DIR"
mkdir -p "$VIDEO_DIR"

step "Installing power-key listener (presses 'p' to poweroff when no video is playing)"
cat > "${HOME_DIR}/pi5-power-key.py" <<'EOF'
#!/usr/bin/env python3
"""Listen for the 'p' key on any input device and poweroff.
Used as a fallback when the video player isn't running (e.g. no videos in folder).
The player itself handles 'p' while playing, since SDL grabs input devices."""
import glob
import os
import struct
from select import select

EV_KEY = 0x01
KEY_P = 25
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)

fds = []
for path in glob.glob("/dev/input/event*"):
    try:
        fds.append(open(path, "rb"))
    except OSError:
        pass

if not fds:
    raise SystemExit("No input devices accessible")

while True:
    ready, _, _ = select(fds, [], [])
    for f in ready:
        data = f.read(EVENT_SIZE)
        if not data or len(data) != EVENT_SIZE:
            continue
        sec, usec, etype, code, value = struct.unpack(EVENT_FMT, data)
        if etype == EV_KEY and code == KEY_P and value == 1:
            os.system("sudo /sbin/poweroff")
EOF
chmod +x "${HOME_DIR}/pi5-power-key.py"

step "Installing looper script at $LOOPER_SCRIPT"
cat > "$LOOPER_SCRIPT" <<EOF
#!/bin/bash
# pi5_video_looper — plays the newest video file in VIDEO_DIR on loop
set -u

VIDEO_DIR="\${VIDEO_DIR:-${VIDEO_DIR}}"
PLAYER="\${PLAYER:-${PLAYER_DIR}/build/video_player}"
POWER_KEY="\${POWER_KEY:-${HOME_DIR}/pi5-power-key.py}"

# Fallback power-key listener: press 'p' to poweroff while idle (no video).
# The player handles 'p' itself while running, since SDL grabs input.
if [ -x "\$POWER_KEY" ]; then
    python3 "\$POWER_KEY" &
fi

shopt -s nullglob nocaseglob

while true; do
    newest=""
    newest_mtime=0
    for f in "\$VIDEO_DIR"/*.{mp4,mkv,mov,avi,m4v,webm}; do
        [ -f "\$f" ] || continue
        mtime=\$(stat -c %Y "\$f")
        if [ "\$mtime" -gt "\$newest_mtime" ]; then
            newest_mtime=\$mtime
            newest="\$f"
        fi
    done

    if [ -z "\$newest" ]; then
        echo "No video files in \$VIDEO_DIR; retrying in 5s..."
        sleep 5
        continue
    fi

    echo "Playing: \$newest"
    "\$PLAYER" "\$newest"
    sleep 1
done
EOF
chmod +x "$LOOPER_SCRIPT"

step "Configuring autologin and tty1 autostart"
$SUDO raspi-config nonint do_boot_behaviour B2

# .bash_profile: autostart looper on tty1 console login only
cat > "${HOME_DIR}/.bash_profile" <<EOF
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

if [ "\$(tty)" = "/dev/tty1" ] && [ -z "\${SSH_CONNECTION:-}" ]; then
    setterm -cursor off -blank 0 -powersave off 2>/dev/null
    clear
    exec ${LOOPER_SCRIPT}
fi
EOF

step "Hiding kernel/boot output (cmdline tweaks)"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
if [ -f "$CMDLINE" ]; then
    for opt in vt.global_cursor_default=0 logo.nologo consoleblank=0; do
        if ! grep -q "$opt" "$CMDLINE"; then
            $SUDO sed -i "s/rootwait/rootwait $opt/" "$CMDLINE"
        fi
    done
fi

step "Installing comitup (fallback WiFi hotspot for setup)"
if ! dpkg -s comitup >/dev/null 2>&1; then
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y comitup
fi

c_green ""
c_green "Done."
c_green "Drop video files into: $VIDEO_DIR"
c_green "Reboot to start: sudo reboot"
c_green ""
c_green "If no known WiFi is found, the Pi will broadcast a 'comitup-XXXX' hotspot."
c_green "Connect from a phone, open http://10.41.0.1 in a browser, and pick a network."
