# pi5_video_looper

A drop-in video looper for the Raspberry Pi 5 — the spiritual sequel to
[pi_video_looper](https://github.com/adafruit/pi_video_looper), updated for
the Pi 5 / Raspberry Pi OS Trixie / KMSDRM era.

Drop any video file into `/home/pi/video`, reboot, and the newest file plays
full-screen on loop with hardware-accelerated decoding. No desktop, no cursor,
no UI chrome.

Built on top of [benoitliard/video-player](https://github.com/benoitliard/video-player)
for the actual playback (FFmpeg + SDL2 + KMSDRM), plus
[comitup](https://davesteele.github.io/comitup/) so a fresh Pi can be onboarded
to WiFi without a keyboard.

## What you get

- 4K-capable video playback with hardware acceleration on Pi 5
- Plays the **newest** file in `/home/pi/video` on a continuous loop
- No mouse cursor, no boot text, no desktop
- Boots straight to fullscreen video in ~15 seconds
- WiFi fallback hotspot via comitup if no known network is found
- Restarts the player automatically if it crashes
- Press **p** on a connected keyboard to power off the Pi cleanly

## Supported formats

`.mp4`, `.mkv`, `.mov`, `.avi`, `.m4v`, `.webm`

H.264, H.265/HEVC video; AAC audio. Other codecs depend on what FFmpeg pulls in.

## Hardware

- Raspberry Pi 5 (4GB minimum, 8GB recommended for 4K)
- microSD card (16GB+)
- HDMI display

## Install — fresh SD card

Flash a fresh **Raspberry Pi OS Lite (64-bit, Trixie)** image with Raspberry Pi
Imager. In the imager's advanced options, set the **username to `pi`**, set a
password, and enable SSH. Boot the Pi and connect it to a network.

Then on the Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/nimast/pi5_video_looper/main/install.sh | bash
sudo reboot
```

That's it. The first reboot drops you into a black screen with no video.
Copy a video into `/home/pi/video` (via `scp`, USB stick, or comitup) and
reboot again — it plays.

## Install — flash the prebuilt image

If you'd rather skip the build step, download the prebuilt image from the
Internet Archive:

**[pi5_video_looper.img.xz](https://archive.org/download/pi5_video_looper/pi5_video_looper.img.xz)** (~2.3GB)

Item page: https://archive.org/details/pi5_video_looper

Flash it to a 32GB+ SD card with Raspberry Pi Imager (or balenaEtcher / `dd`).
Insert into a Pi 5, power it on, and drop a video into `/home/pi/video`
over SSH or by mounting the SD card on another machine.

Default credentials: `pi` / `modernlove` — **change the password immediately**
with `passwd` after first boot.

## Adding videos

```bash
scp myvideo.mp4 pi@<pi-ip>:/home/pi/video/
ssh pi@<pi-ip> sudo reboot
```

The looper picks the **most recently modified** file in `/home/pi/video`.
Old files are kept (they just don't play) — handy for rotating content.

## WiFi setup with comitup

When the Pi can't find a known WiFi network at boot, it broadcasts its own
hotspot named `comitup-XXXX`. Connect a phone to that hotspot, open
`http://10.41.0.1` in a browser, and pick a network. The Pi remembers it and
joins on every subsequent boot.

## How it works

- `multi-user.target` boot (no desktop)
- `tty1` autologins as `pi` via systemd `getty@tty1` override
- `~/.bash_profile` execs the looper script when (and only when) the login
  is on `tty1` (not over SSH)
- The looper script scans `/home/pi/video` and execs `video_player` on the
  newest file; when it exits, the loop restarts
- `video_player` itself loops a single file internally, so it never exits
  under normal operation; the outer loop is a safety net
- Kernel cmdline includes `vt.global_cursor_default=0 logo.nologo
  consoleblank=0 quiet` to suppress all boot chrome

## Uninstall

```bash
sudo raspi-config nonint do_boot_behaviour B4   # back to desktop autologin
rm ~/.bash_profile
sudo systemctl disable comitup
sudo reboot
```

## Credits

- Playback engine: [benoitliard/video-player](https://github.com/benoitliard/video-player)
- WiFi onboarding: [comitup](https://davesteele.github.io/comitup/)
- Inspired by: [adafruit/pi_video_looper](https://github.com/adafruit/pi_video_looper)
