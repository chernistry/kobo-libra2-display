#!/bin/sh
# Kobo screen launcher WITH remote diagnostics POSTed to the Mac.
BASE=/mnt/onboard/.adds/kobo-screen
RUN=/tmp/kobo-screen
# Server address comes from config.sh (MAC_HOST, MAC_PORT).
[ -f "$BASE/config.sh" ] && . "$BASE/config.sh"
if [ -z "${MAC_HOST:-}" ]; then echo "MAC_HOST is not set in $BASE/config.sh" >&2; exit 1; fi
MAC_PORT="${MAC_PORT:-8090}"
export LD_LIBRARY_PATH="$RUN:${LD_LIBRARY_PATH:-}"
mkdir -p "$RUN"

OLD="$(cat "$RUN/pid" 2>/dev/null)"; [ -n "$OLD" ] && kill "$OLD" 2>/dev/null; rm -f "$RUN/pid"

cp "$BASE/fbink" "$RUN/fbink" 2>/dev/null
cp "$BASE/libfbink.so.1" "$RUN/libfbink.so.1" 2>/dev/null
cp "$BASE/loop.sh" "$RUN/loop.sh" 2>/dev/null
chmod +x "$RUN/fbink" "$RUN/loop.sh" 2>/dev/null

# Attempt the proven test paint, capture stderr
"$RUN/fbink" -q -mp -y -3 "Kobo screen: starting..." >"$RUN/paint.out" 2>&1
PAINT_RC=$?

# Gather diagnostics
DIAG="$RUN/diag.txt"
{
  echo "## uname"; uname -a
  echo "## fbink paint rc=$PAINT_RC"; cat "$RUN/paint.out"
  echo "## fbink -e (einfo)"; "$RUN/fbink" -e 2>&1 | head -20
  echo "## ldd-ish: ls libs"; ls -la "$RUN/"
  echo "## fb devices"; ls -la /dev/fb* 2>&1
  echo "## fb0 virtual_size"; cat /sys/class/graphics/fb0/virtual_size 2>&1
  echo "## which nc wget curl"; for b in nc wget curl busybox; do command -v $b; done
  echo "## ld interpreter present"; ls -la /lib/ld-linux-armhf.so.3 2>&1
} > "$DIAG" 2>&1

# Send diagnostics back to Mac — try nc, then wget --post-file, then GET fallback
HOST="$MAC_HOST"
if command -v nc >/dev/null 2>&1; then
  LEN=$(wc -c < "$DIAG")
  { printf 'POST /report HTTP/1.0\r\nHost: %s\r\nContent-Length: %s\r\nContent-Type: text/plain\r\n\r\n' "$HOST" "$LEN"; cat "$DIAG"; } | nc "$MAC_HOST" "$MAC_PORT" 2>/dev/null
elif wget --help 2>&1 | grep -q post-file; then
  wget -q -O /dev/null --post-file="$DIAG" "http://$MAC_HOST:$MAC_PORT/report" 2>/dev/null
else
  wget -q -O /dev/null "http://$MAC_HOST:$MAC_PORT/report?nc_missing=1" 2>/dev/null
fi

echo "$(date) start.sh done paint_rc=$PAINT_RC" >> "$RUN/log"
nohup sh "$RUN/loop.sh" >>"$RUN/log" 2>&1 &
