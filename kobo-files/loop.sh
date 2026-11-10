#!/bin/sh
# Kobo screen mirror + remote command channel (run from /tmp by start.sh).
RUN=/tmp/kobo-screen
BASE=/mnt/onboard/.adds/kobo-screen
export LD_LIBRARY_PATH="$RUN:${LD_LIBRARY_PATH:-}"
FB="$RUN/fbink"
LOG="$RUN/log"
# Server address comes from config.sh (MAC_HOST, MAC_PORT).
[ -f "$BASE/config.sh" ] && . "$BASE/config.sh"
if [ -z "${MAC_HOST:-}" ]; then echo "$(date) MAC_HOST is not set in $BASE/config.sh" >> "$LOG"; exit 1; fi
MAC_PORT="${MAC_PORT:-8090}"

echo "$(date) loop start pid=$$" >> "$LOG"
echo $$ > "$RUN/pid"
for IF in wlan0 eth0; do iwconfig $IF power off 2>/dev/null; done

# POST a file body to /report via nc (robust) or wget
report() {
  F="$1"
  if command -v nc >/dev/null 2>&1; then
    L=$(wc -c < "$F")
    { printf 'POST /report HTTP/1.0\r\nHost: %s\r\nContent-Length: %s\r\n\r\n' "$MAC_HOST" "$L"; cat "$F"; } | nc "$MAC_HOST" "$MAC_PORT" 2>/dev/null
  else
    wget -q -O /dev/null --post-file="$F" "http://$MAC_HOST:$MAC_PORT/report" 2>/dev/null
  fi
}

LAST_SUM=""
CMD_SUM=""
REFRESH_SECS="0.3"
DEGHOST=30
FRAME=0
while : ; do
  [ -f "$BASE/config.sh" ] && . "$BASE/config.sh"

  # --- remote command channel ---
  if wget -q -T 4 -O "$RUN/cmd.sh" "http://$MAC_HOST:$MAC_PORT/cmd.sh" 2>/dev/null && [ -s "$RUN/cmd.sh" ]; then
    CS="$(md5sum "$RUN/cmd.sh" 2>/dev/null | cut -d' ' -f1)"
    if [ "$CS" != "$CMD_SUM" ]; then
      CMD_SUM="$CS"
      echo "## $(date) running /cmd.sh" > "$RUN/cmd.out"
      sh "$RUN/cmd.sh" >> "$RUN/cmd.out" 2>&1
      echo "## exit=$?" >> "$RUN/cmd.out"
      report "$RUN/cmd.out"
    fi
  fi

  # --- screen frame ---
  if wget -q -T 5 -O "$RUN/screen.png.tmp" "http://$MAC_HOST:$MAC_PORT/screen.png" 2>>"$LOG" && [ -s "$RUN/screen.png.tmp" ]; then
    SUM="$(md5sum "$RUN/screen.png.tmp" 2>/dev/null | cut -d' ' -f1)"
    if [ "$SUM" != "$LAST_SUM" ]; then
      mv "$RUN/screen.png.tmp" "$RUN/screen.png"
      FRAME=$((FRAME+1))
      WF=""
      [ "$WAVEFORM" ] && WF="-W $WAVEFORM"
      if [ -n "$WF" ] && [ $((FRAME % DEGHOST)) -ne 0 ]; then
        "$FB" -q $WF -g file="$RUN/screen.png",halign=CENTER,valign=CENTER 2>>"$LOG"
      else
        "$FB" -q -c -f -g file="$RUN/screen.png",halign=CENTER,valign=CENTER 2>>"$LOG"
      fi
      LAST_SUM="$SUM"
    fi
  fi
  sleep "$REFRESH_SECS"
done
