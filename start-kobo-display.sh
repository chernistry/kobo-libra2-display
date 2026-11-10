#!/bin/bash
# Kobo Libra 2 as secondary Mac display
# Usage: MAC_HOST=<mac-address> ./start-kobo-display.sh <kobo-address>
#   (example addresses: 192.0.2.10 for the Mac, 192.0.2.20 for the Kobo)
#   KOBO_SSH_KEY=<path> selects the SSH key (default: ~/.ssh/kobo_key)
#
# Legacy fallback path (VNC client on the Kobo). The screenshot-push pipeline
# (screen-server.py + kobo-files/) does not use it.
#
# Prerequisites (one-time):
#   1. kobovncnogui (a separate project) installed on the Kobo (in /mnt/onboard/)
#   2. NickelMenu VNC entries in .adds/nm/vnc
#   3. DeskPad.app installed (brew install --cask deskpad)
#   4. macOS Screen Sharing enabled (System Settings → General → Sharing → Screen Sharing)
#
# Flow:
#   Mac: DeskPad creates virtual 1264x1680 display → Screen Sharing serves VNC on :5900
#   Kobo: kobovncnogui connects to Mac VNC → paints to e-ink framebuffer

set -euo pipefail

KOBO_IP="${1:-${KOBO_IP:-}}"
MAC_IP="${MAC_HOST:-}"
VNC_PORT="${VNC_PORT:-5900}"
SSH_KEY="${KOBO_SSH_KEY:-$HOME/.ssh/kobo_key}"
if [ -z "$KOBO_IP" ] || [ -z "$MAC_IP" ]; then
    echo "usage: MAC_HOST=<mac-address> $0 <kobo-address>" >&2
    exit 2
fi

echo "=== Kobo Display Setup ==="
echo "Mac IP:   $MAC_IP"
echo "Kobo IP:  $KOBO_IP"

# 1. Check Kobo is reachable
if ! ping -c1 -W2 "$KOBO_IP" &>/dev/null; then
    echo "ERROR: Kobo not reachable at $KOBO_IP"
    echo "  - Is it powered on and connected to WiFi?"
    echo "  - Check IP: on Kobo, NickelMenu → IP"
    exit 1
fi
echo "✓ Kobo reachable"

# 2. Start DeskPad (virtual display)
if ! pgrep -x DeskPad &>/dev/null; then
    echo "Starting DeskPad..."
    open -a DeskPad
    sleep 2
fi
echo "✓ DeskPad running"

# 3. Verify Screen Sharing (VNC) is enabled
if ! launchctl list com.apple.screensharing 2>/dev/null | grep -q .; then
    echo "WARNING: Screen Sharing may not be enabled."
    echo "  Enable: System Settings → General → Sharing → Screen Sharing"
    echo "  Then set a VNC password in Computer Settings..."
fi

# 4. Check if VNC port is listening
if nc -z localhost $VNC_PORT 2>/dev/null; then
    echo "✓ VNC server on port $VNC_PORT"
else
    echo "WARNING: VNC not listening on port $VNC_PORT"
    echo "  Enable Screen Sharing in System Settings"
fi

# 5. Try SSH to start VNC client on Kobo
echo ""
echo "=== Starting VNC client on Kobo ==="
echo "Trying SSH on port 2222 (KOReader dropbear)..."

if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 2222 root@"$KOBO_IP" "echo ok" &>/dev/null; then
    echo "✓ SSH connected"

    # Kill any existing VNC session
    ssh -i "$SSH_KEY" -p 2222 root@"$KOBO_IP" "killall kobovncnogui 2>/dev/null; sleep 1" 2>/dev/null

    # Start VNC client with A2 waveform for fast refresh
    ssh -i "$SSH_KEY" -p 2222 root@"$KOBO_IP" "nohup /mnt/onboard/kobovncnogui \
        --host $MAC_IP --port $VNC_PORT \
        --partial_update 2 --blue_noise \
        --scale fit --rotate 0 --fps 15 --refresh 100 \
        >/dev/null 2>&1 &"

    echo "✓ VNC client started on Kobo"
    echo ""
    echo "Kobo should now show your Mac desktop."
    echo "Move windows to the DeskPad virtual display to show them on Kobo."
    echo ""
    echo "To stop: ssh -i \"$SSH_KEY\" -p 2222 root@$KOBO_IP 'killall kobovncnogui'"
    echo "Or on Kobo: long-press screen for 6 seconds"
else
    echo "SSH not available. Start VNC manually on Kobo:"
    echo "  NickelMenu → SSH on (start SSH)"
    echo "  NickelMenu → VNC Display (connect to Mac)"
    echo ""
    echo "Or manually after SSH:"
    echo "  ssh -i \"$SSH_KEY\" -p 2222 root@$KOBO_IP"
    echo "  /mnt/onboard/kobovncnogui --host $MAC_IP --port $VNC_PORT --partial_update 2 --blue_noise --scale fit --fps 15 --refresh 100"
fi
