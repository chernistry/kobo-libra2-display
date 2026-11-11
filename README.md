# Kobo Libra 2 as an e-ink display for a Mac terminal

## What it does

A Mac captures one virtual display, converts each frame to a grayscale PNG sized for the Kobo Libra 2 panel (1264x1680), and serves it over HTTP. A shell loop on the Kobo, started from a NickelMenu entry, fetches the PNG over Wi-Fi and paints it on the e-ink screen with FBInk. The same HTTP connection carries a small command channel from the Mac to the Kobo and a diagnostics channel back.

## How it works

```
Mac                                            Kobo Libra 2
+---------------------------------+           +--------------------------+
| virtual display (e.g. DeskPad)  |           | NickelMenu -> start.sh   |
| screen-server.py                |           |  copies fbink + loop.sh  |
|   screencapture -D<n>           |   Wi-Fi   |  to /tmp                 |
|   -> grayscale PNG 1264x1680    |  HTTP     | loop.sh, each cycle:     |
|   GET  /screen.png              | <-------- |  GET /cmd.sh, run on     |
|   GET  /cmd.sh                  |           |   change (as root)       |
|   POST /report                  | --------> |  GET /screen.png         |
|   GET  /health                  |           |  fbink -g file=...       |
+---------------------------------+           +--------------------------+
 192.0.2.10:8090 (example)
```

- Only one display is captured, selected with `screencapture -D<n>`. Screen Sharing/VNC serves all displays as one large framebuffer, which does not suit the panel.
- Each frame is painted synchronously with FBInk. A frame is skipped when its checksum equals the previous one.
- With a waveform set (default `GL16`), every `DEGHOST`-th frame is painted as a full flashing refresh to clear ghosting.
- `kobo-power-config.py` sets `AutoSleepMinutes=255`, `AutoOffMinutes=255` and `ForceWifiOn=true` in `Kobo eReader.conf` (a backup is written next to it).

## Requirements

- Kobo Libra 2 with stock firmware (developed against 4.38) and NickelMenu installed.
- FBInk, installed by the user: the ARM `fbink` binary and `libfbink.so.1`, from the releases of the FBInk project, with image support (`-g file=`). They are not part of this repository.
- A virtual-display tool on the Mac. `provision.sh` looks for DeskPad (`brew install --cask deskpad`).
- Python 3 with Pillow on the Mac. macOS Screen Recording permission for the terminal that starts the server.

## Setup on the Mac

1. Edit `kobo-files/config.sh` and set `MAC_HOST` to the Mac's address as seen from the Kobo.
2. Run `./provision.sh --mac`. It creates `.venv` with Pillow, starts DeskPad, finds the `screencapture -D` index of the virtual display, and starts the server. It also enables macOS Screen Sharing with `sudo` if it is off; this is only used by the legacy VNC path in `start-kobo-display.sh`.
3. To start the server by hand instead:
   `.venv/bin/python3 screen-server.py --bind 192.0.2.10 --display 4 --port 8090 --fps 4 --rotate`
4. Optional: `com.kobo-screen.plist` is a launchd job for the server. Replace `/PATH/TO/kobo-display` with the checkout path and `192.0.2.10` with the bind address. A process started by launchd may lack Screen Recording permission and produce blank frames.

## Setup on the Kobo

1. Put your own `fbink` and `libfbink.so.1` into `kobo-files/` (or copy them to `.adds/kobo-screen/` on the device later). `start.sh` expects them at `/mnt/onboard/.adds/kobo-screen/`.
2. Connect the Kobo by USB, tap Connect, then run `./provision.sh --kobo --mac-ip 192.0.2.10 --eject`. This copies `kobo-files/` to `.adds/kobo-screen/`, installs the NickelMenu entries from `kobo-files/nm/kobo-screen` and patches the power settings.
3. Restart the Kobo so `ForceWifiOn` applies.
4. Choose "Screen push" in NickelMenu. "Screen stop" ends the loop. "SSH start" runs `ssh-start.sh`.

## Configuration

| Setting | Where | Meaning |
|---|---|---|
| `MAC_HOST`, `MAC_PORT` | `kobo-files/config.sh` | Address and port the Kobo connects to. `--mac-ip` on `provision.sh` rewrites them in the copy sent to the device. |
| `REFRESH_SECS`, `DEGHOST`, `WAVEFORM` | `kobo-files/config.sh` | Poll interval, full refresh every N frames, FBInk waveform (empty means full refresh every frame). Re-read each cycle. |
| `--bind` / `KOBO_BIND` | `screen-server.py` | Interface address to listen on. Default `0.0.0.0` (all interfaces). |
| `--display`, `--port`, `--fps`, `--rotate` | `screen-server.py` | Capture index, port, capture rate, rotate 90 degrees counter-clockwise to fill the portrait panel. |
| `--black`, `--white`, `--gamma` | `screen-server.py` | Levels and gamma applied before sending the frame. |
| `BIND`, `PORT`, `FPS`, `KOBO_DISPLAY`, `VDISPLAY_NAME`, `KOBO_VOL` | environment of `provision.sh` | Same settings for the provisioning script. `--restart`, `--via-terminal`, `--display`, `--dry-run` are also available (`--help`). |

Troubleshooting:
- Blank or black frames: the server lacks Screen Recording permission. Run `./provision.sh --restart --via-terminal`.
- `screencapture failed` in the log: the display index changed. Run `./provision.sh --restart` to rescan indexes 1 to 8.
- The Kobo stops fetching: it slept or lost Wi-Fi, or the Mac address changed. Re-run `./provision.sh --kobo --mac-ip <address>` or edit `config.sh` on the device.
- Old loop still running after using KOReader: choose "Screen stop", then "Screen push".

## Security

- `screen-server.py` has no authentication, no encryption and no access control. Any host that can reach its port can read the captured screen (`/screen.png`), fetch the command file, and append data of any size to `kobo-report.txt` in the server user's temporary directory.
- The Kobo polls `GET /cmd.sh` every cycle. When the content differs from the last run, `loop.sh` executes it with `sh` as root on the device and posts the output to `/report`. The first fetch after the loop starts also runs any existing file. The command file is `kobo-cmd.sh` in the server user's temporary directory.
- Whoever can write that file, or can intercept or spoof the plain-HTTP traffic between the Kobo and the Mac, can run commands as root on the Kobo.
- Run the server only on a trusted private network. Bind it to one interface with `--bind`; the default listens on all interfaces. Stop it when not in use, and delete `kobo-cmd.sh` afterwards.
- `start.sh` posts diagnostics (kernel string, directory listings, FBInk output) to `/report` at start.
- `ssh-start.sh` starts the KOReader copy of dropbear on port 2222 with password login disabled (`-s`); key authorisation is configured in KOReader.
- `start-kobo-display.sh` (legacy VNC path) connects with `StrictHostKeyChecking=no`. If you use the VNC fallback, set your own VNC password; none is included.

## Limits and known problems

- Sleep handling is incomplete. The firmware maximum for auto-sleep is 255 minutes, so the Kobo sleeps after about four hours of idle time. Sleep stops the loop and drops Wi-Fi, and a tap wakes the device. Keeping it awake by injecting input events is not implemented.
- Inbound SSH to the Kobo is unreliable. Use the command channel instead.
- "Screen push" must be started by hand after each boot; autostart is not implemented.
- Transport is Wi-Fi only. USB networking is not implemented.
- Waveform and orientation settings are not tuned.
- Only firmware 4.38 on a Libra 2 was used.
- There is no teardown script. Stop the loop with "Screen stop", stop the server with `kill`, and restore power settings from the backup next to `Kobo eReader.conf`.

## Licence

Apache License 2.0; see `LICENSE` and `NOTICE`. FBInk, NickelMenu and KOReader are separate projects under their own licences.
