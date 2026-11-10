#!/bin/sh
RUN=/tmp/kobo-screen
mkdir -p "$RUN"
LOG="$RUN/ssh.log"
echo "$(date) ssh-start" >> "$LOG"
if [ ! -d /dev/pts ]; then mkdir -p /dev/pts; mount -t devpts devpts /dev/pts 2>>"$LOG"; fi
cd /mnt/onboard/.adds/koreader || { echo "no koreader" >> "$LOG"; exit 1; }
export LD_LIBRARY_PATH="/mnt/onboard/.adds/koreader/libs:${LD_LIBRARY_PATH:-}"
[ -f /tmp/dropbear_koreader.pid ] && kill "$(cat /tmp/dropbear_koreader.pid)" 2>/dev/null
./dropbear -E -R -p 2222 -P /tmp/dropbear_koreader.pid -s >> "$LOG" 2>&1
echo "$(date) dropbear launched exit=$?" >> "$LOG"
