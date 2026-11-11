#!/bin/bash
# provision.sh — Kobo Libra 2 as an e-ink display for a Mac terminal, 0 → 1 in one command.
#
#   ./provision.sh                   Mac side, then Kobo side if /Volumes/KOBOeReader is mounted
#   ./provision.sh --kobo            Kobo side only (device mounted over USB, "Connect" tapped)
#   ./provision.sh --mac             Mac side only
#   ./provision.sh --restart         restart screen-server.py (display index / port / fps changed)
#   ./provision.sh --mac-ip 192.0.2.10  write this Mac address into the Kobo copies of config.sh (remembered in .run/mac-ip)
#   ./provision.sh --via-terminal    launch the server in a Terminal.app window (TCC-granted context)
#   ./provision.sh --vnc             (re)set the legacy VNC password from $VNC_PASSWORD (fallback path, sudo)
#   ./provision.sh --display N       force screencapture -D index (default: auto-detect)
#   ./provision.sh --no-probe        trust display order, skip the screencapture probe
#   ./provision.sh --eject           unmount the Kobo after copying
#   ./provision.sh --dry-run         print actions only
#
# Env overrides: PORT=8090 FPS=4 BIND=<interface address> KOBO_DISPLAY=<idx> VDISPLAY_NAME="Kobo Libra 2"
#                VNC_PASSWORD=<your own password, only for --vnc>
#
# Idempotent: a healthy server is adopted, never restarted; unchanged Kobo files are skipped.
# Canonical Kobo-side files live in kobo-files/ — this script copies them, never edits them.
# FBInk is not included: put your own fbink + libfbink.so.1 into kobo-files/ (copied if present)
# or install them on the device yourself at .adds/kobo-screen/.
# Runbook: see README.md
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$HERE/.run"                      # pid, log, VNC note, remembered --mac-ip (gitignored)
VENV="$HERE/.venv"
SERVER_PY="$HERE/screen-server.py"
POWER_PY="$HERE/kobo-power-config.py"
KOBO_FILES="$HERE/kobo-files"
KOBO_SIDE_FILES="start.sh loop.sh config.sh ssh-start.sh"
KOBO_OPTIONAL_FILES="fbink libfbink.so.1"       # third-party FBInk, installed by the user
KOBO_VOL="${KOBO_VOL:-/Volumes/KOBOeReader}"
KOBO_CONF="$KOBO_VOL/.kobo/Kobo/Kobo eReader.conf"
PID_FILE="$RUN_DIR/screen-server.pid"
LOG_FILE="$RUN_DIR/screen-server.log"
VNC_NOTE="$RUN_DIR/VNC-FALLBACK.txt"
MAC_IP_FILE="$RUN_DIR/mac-ip"

PORT="${PORT:-8090}"
FPS="${FPS:-4}"
BIND="${BIND:-0.0.0.0}"                          # interface the server listens on; use a specific address
VDISPLAY_NAME="${VDISPLAY_NAME:-Kobo Libra 2}"   # name as listed by system_profiler
VDISPLAY_IDX="${KOBO_DISPLAY:-}"                 # screencapture -D index; empty = auto-detect
VDISPLAY_RES=""                                  # "WxH" from system_profiler, filled in step 2
VNC_PASSWORD="${VNC_PASSWORD:-}"                 # legacy VNC password, fallback path only; set your own
SHARING_PLIST=/System/Library/LaunchDaemons/com.apple.screensharing.plist
KICKSTART=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart

DO_MAC=true; DO_KOBO=true; KOBO_ONLY=false
RESTART=false; SET_VNC=false; PROBE=true; VIA_TERMINAL=false; EJECT=false; DRY=false
MAC_IP=""

usage() {
    sed -n '2,/^# Runbook/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kobo)         DO_MAC=false; KOBO_ONLY=true ;;
        --mac)          DO_KOBO=false ;;
        --restart)      RESTART=true ;;
        --vnc)          SET_VNC=true ;;
        --mac-ip)       MAC_IP="${2:-}"; shift ;;
        --display)      VDISPLAY_IDX="${2:-}"; shift ;;
        --no-probe)     PROBE=false ;;
        --via-terminal) VIA_TERMINAL=true ;;
        --eject)        EJECT=true ;;
        --dry-run)      DRY=true ;;
        -h|--help)      usage ;;
        *) echo "unknown option: $1"; usage 2 ;;
    esac
    shift
done
if $KOBO_ONLY && ! $DO_KOBO; then echo "--kobo and --mac exclude each other"; exit 2; fi
case "$VDISPLAY_IDX" in ""|[1-9]|[1-9][0-9]) ;; *) echo "--display must be a small integer"; exit 2 ;; esac
case "$MAC_IP" in ""|[0-9]*.[0-9]*.[0-9]*.[0-9]*) ;; *) echo "--mac-ip must be a dotted IPv4"; exit 2 ;; esac

# ---------- helpers ----------
FAILED=0
SUMMARY=()
say()  { printf '%s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }
bad()  { printf '❌ %s\n' "$*"; FAILED=1; }
pend() { printf '⏳ %s\n' "$*"; }
hdr()  { printf '\n── %s\n' "$*"; }
note() { SUMMARY+=("$(printf '%s %-13s %s' "$1" "$2" "$3")"); }
run()  { if $DRY; then printf '   [dry-run] %s\n' "$*"; return 0; fi; "$@"; }
wait_for() { local n="$1"; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n-1)); done; "$@"; }
port_open()    { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
port_closed()  { ! port_open "$1"; }
local_host()   { if [ "$BIND" = "0.0.0.0" ]; then echo 127.0.0.1; else echo "$BIND"; fi; }
health()       { curl -fs -m 2 -o /dev/null "http://$(local_host):$PORT/health" 2>/dev/null; }
frame_ok()     { curl -fs -m 3 -o /dev/null "http://$(local_host):$PORT/screen.png" 2>/dev/null; }
listener_pid() { lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n1; }
mac_lan_ip()   { local i; i="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"; [ -n "$i" ] && ipconfig getifaddr "$i" 2>/dev/null; }

# system_profiler is slow (~2 s): fetch once, parse many times.
SP_DISPLAYS=""
refresh_displays() { SP_DISPLAYS="$(system_profiler SPDisplaysDataType 2>/dev/null)"; }
display_names()    { printf '%s\n' "$SP_DISPLAYS" | awk '/^        [^ ].*:$/ {sub(/^ +/,""); sub(/:$/,""); print}'; }
display_ordinal()  { display_names | awk -v n="$1" '$0==n {print NR; exit}'; }
display_res()      { printf '%s\n' "$SP_DISPLAYS" | awk -v n="$1" '
    /^        [^ ].*:$/ { c=$0; sub(/^ +/,"",c); sub(/:$/,"",c); next }
    c==n && /Resolution:/ { print $2"x"$4; exit }'; }
# screencapture -D<i> → "WxH" of what that index really captures (empty on failure)
probe_dims() {
    local f d
    f="$(mktemp "${TMPDIR:-/tmp}/kobo-probe.XXXXXX")" || return 1
    if ! screencapture -x -t png "-D$1" "$f" 2>/dev/null; then rm -f "$f"; return 1; fi
    d="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{if (w && h) print w"x"h}')"
    rm -f "$f"
    [ -n "$d" ] && printf '%s\n' "$d"
}
# accept 1x / 2x (HiDPI) and rotated variants of the display resolution
dims_match() {
    local w="${2%x*}" h="${2#*x}"
    case "$1" in "${w}x${h}"|"${h}x${w}"|"$((w*2))x$((h*2))"|"$((h*2))x$((w*2))") return 0 ;; esac
    return 1
}

# ---------- 1/5 venv ----------
step_venv() {
    hdr "1/5 Python venv + Pillow"
    local py ver
    if [ ! -x "$VENV/bin/python3" ]; then
        py="$(command -v python3 || true)"
        [ -x /opt/homebrew/bin/python3 ] && py=/opt/homebrew/bin/python3
        if [ -z "$py" ]; then bad "python3 not found (brew install python)"; note ❌ venv "no python3"; return; fi
        run "$py" -m venv "$VENV" || { bad "venv creation failed"; note ❌ venv "venv failed"; return; }
        if $DRY; then pend "venv would be created at $VENV"; note ⏳ venv "dry-run"; return; fi
    fi
    if ! "$VENV/bin/python3" -c 'import PIL' 2>/dev/null; then
        run "$VENV/bin/python3" -m pip install -q --disable-pip-version-check pillow
    fi
    ver="$("$VENV/bin/python3" -c 'import PIL; print(PIL.__version__)' 2>/dev/null)"
    if [ -n "$ver" ]; then ok "venv ready, Pillow $ver"; note ✅ venv "Pillow $ver"
    elif $DRY; then pend "Pillow would be installed"; note ⏳ venv "dry-run"
    else bad "Pillow import fails in $VENV"; note ❌ venv "Pillow missing"; fi
}

# ---------- 2/5 DeskPad ----------
step_deskpad() {
    hdr "2/5 DeskPad virtual display"
    local n=15
    if [ ! -d /Applications/DeskPad.app ]; then
        if command -v brew >/dev/null 2>&1; then run brew install --cask deskpad
        else bad "DeskPad.app missing and no brew (brew install --cask deskpad)"; note ❌ DeskPad "not installed"; return; fi
    fi
    if ! pgrep -x DeskPad >/dev/null; then
        run open -ga DeskPad
        $DRY || wait_for 10 pgrep -x DeskPad >/dev/null
    fi
    if pgrep -x DeskPad >/dev/null; then ok "DeskPad running"
    elif $DRY; then pend "DeskPad would be started"
    else bad "DeskPad did not start"; fi
    # the virtual display can take a few seconds to register after launch
    while :; do
        refresh_displays
        [ -n "$(display_ordinal "$VDISPLAY_NAME")" ] && break
        if [ $n -le 0 ] || $DRY; then break; fi
        sleep 1; n=$((n-1))
    done
    if [ -z "$(display_ordinal "$VDISPLAY_NAME")" ] && [ -n "$(display_ordinal "DeskPad Display")" ]; then
        warn "no display named \"$VDISPLAY_NAME\"; using \"DeskPad Display\" (set VDISPLAY_NAME= to silence)"
        VDISPLAY_NAME="DeskPad Display"
    fi
    VDISPLAY_RES="$(display_res "$VDISPLAY_NAME")"
    if [ -n "$VDISPLAY_RES" ]; then
        ok "virtual display \"$VDISPLAY_NAME\" $VDISPLAY_RES (display #$(display_ordinal "$VDISPLAY_NAME") in system_profiler)"
        note ✅ DeskPad "\"$VDISPLAY_NAME\" $VDISPLAY_RES"
    else
        bad "no virtual display found — open DeskPad once and enable its display, then re-run"
        note ❌ DeskPad "no virtual display"
    fi
}

# ---------- 3/5 display index ----------
step_display_index() {
    hdr "3/5 Capture index (screencapture -D)"
    local ord dims i hit=""
    ord="$(display_ordinal "$VDISPLAY_NAME")"
    if [ -n "$VDISPLAY_IDX" ]; then say "using -D$VDISPLAY_IDX (given)"; else VDISPLAY_IDX="${ord:-4}"; fi
    if ! $PROBE || [ -z "$VDISPLAY_RES" ]; then
        say "probe skipped → -D$VDISPLAY_IDX"
        note ⚠️ display "-D$VDISPLAY_IDX (unverified)"
        return
    fi
    dims="$(probe_dims "$VDISPLAY_IDX" || true)"
    if [ -n "$dims" ] && dims_match "$dims" "$VDISPLAY_RES"; then
        ok "-D$VDISPLAY_IDX captures $dims = \"$VDISPLAY_NAME\""
        note ✅ display "-D$VDISPLAY_IDX captures $dims"
        return
    fi
    warn "-D$VDISPLAY_IDX captured '${dims:-nothing}', expected $VDISPLAY_RES — scanning -D1..8"
    for i in 1 2 3 4 5 6 7 8; do
        dims="$(probe_dims "$i" || true)"
        if [ -n "$dims" ] && dims_match "$dims" "$VDISPLAY_RES"; then hit=$i; break; fi
    done
    if [ -n "$hit" ]; then
        VDISPLAY_IDX=$hit; ok "found: -D$hit captures $dims"; note ✅ display "-D$hit captures $dims"
    else
        bad "no -D index captures $VDISPLAY_RES — is the virtual display enabled? (keeping -D$VDISPLAY_IDX)"
        note ❌ display "-D$VDISPLAY_IDX unverified"
    fi
}

# ---------- 4/5 Screen Sharing ----------
step_sharing() {
    hdr "4/5 macOS Screen Sharing (VNC fallback path, :5900)"
    if port_open 5900; then
        ok "Screen Sharing listening on :5900"; note ✅ "Screen Sharing" "on :5900 (fallback)"
    else
        warn "Screen Sharing is off — enabling (sudo will prompt)"
        run sudo launchctl enable system/com.apple.screensharing
        run sudo launchctl load -w "$SHARING_PLIST"
        if $DRY; then pend "would enable Screen Sharing"; note ⏳ "Screen Sharing" "dry-run"
        elif wait_for 5 port_open 5900; then ok "Screen Sharing now on :5900"; note ✅ "Screen Sharing" "enabled"
        else bad "still not listening — System Settings → General → Sharing → Screen Sharing"; note ❌ "Screen Sharing" "not listening"; fi
    fi
    if $SET_VNC; then
        if [ -z "$VNC_PASSWORD" ]; then bad "--vnc needs VNC_PASSWORD set to your own password"
        elif $DRY; then say "   [dry-run] sudo kickstart -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw ****"
        elif sudo "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "$VNC_PASSWORD" >/dev/null; then ok "legacy VNC password set"
        else bad "kickstart failed"; fi
    fi
    $DRY && return
    mkdir -p "$RUN_DIR"
    cat >"$VNC_NOTE" <<EOF
VNC fallback path (NOT used by the screenshot-push pipeline) — written by provision.sh $(date '+%Y-%m-%d %H:%M')
  Server : macOS Screen Sharing on :5900, legacy VNC auth enabled via ARDAgent kickstart
  Password: not stored here; set your own with VNC_PASSWORD=<password> ./provision.sh --vnc
  Client : /mnt/onboard/kobovncnogui on the Kobo (NickelMenu file .adds/nm/vnc)
  Off    : System Settings → General → Sharing → Screen Sharing
EOF
    say "   note: $VNC_NOTE"
}

# ---------- 5/5 screen-server ----------
tcc_context_hint() {
    # screencapture needs Screen Recording permission; the server inherits it from the app
    # that spawns it. launchd has none, which is why this is not a LaunchAgent.
    case "${TERM_PROGRAM:-}" in
        "") warn "TERM_PROGRAM unset (IDE/agent context?) — if frames come out blank, re-run from Terminal/iTerm or use --via-terminal" ;;
        *)  say "launch context: $TERM_PROGRAM — needs Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording)" ;;
    esac
}
start_server() {
    mkdir -p "$RUN_DIR"
    if [ -f "$LOG_FILE" ] && [ "$(stat -f %z "$LOG_FILE")" -gt 10000000 ]; then mv -f "$LOG_FILE" "$LOG_FILE.1"; fi
    if $VIA_TERMINAL; then
        osascript -e "tell application \"Terminal\" to do script \"cd '$HERE' && exec '$VENV/bin/python3' screen-server.py --bind $BIND --display $VDISPLAY_IDX --port $PORT --fps $FPS --rotate 2>&1 | tee -a '$LOG_FILE'\"" >/dev/null
    else
        nohup "$VENV/bin/python3" "$SERVER_PY" --bind "$BIND" --display "$VDISPLAY_IDX" --port "$PORT" --fps "$FPS" --rotate >>"$LOG_FILE" 2>&1 &
        disown 2>/dev/null || true
    fi
}
step_server() {
    hdr "5/5 screen-server.py (:$PORT)"
    local existing running_idx pid url
    if [ "$BIND" = "0.0.0.0" ]; then url="http://$(mac_lan_ip || echo 127.0.0.1):$PORT/screen.png"; else url="http://$BIND:$PORT/screen.png"; fi
    existing="$(listener_pid)"
    if [ -n "$existing" ] && ! $RESTART; then
        if health; then
            running_idx="$(ps -o command= -p "$existing" | sed -n 's/.*--display \([0-9][0-9]*\).*/\1/p')"
            $DRY || { mkdir -p "$RUN_DIR"; echo "$existing" >"$PID_FILE"; }
            ok "already running: pid $existing (-D${running_idx:-?}) — adopted, not restarted"
            if [ -n "$running_idx" ] && [ "$running_idx" != "$VDISPLAY_IDX" ]; then
                warn "it captures -D$running_idx but the Kobo display is -D$VDISPLAY_IDX → ./provision.sh --restart"
                note ⚠️ server "pid $existing on -D$running_idx ≠ -D$VDISPLAY_IDX → --restart"
            else
                note ✅ server "pid $existing → $url"
            fi
            return
        fi
        warn "port $PORT busy (pid $existing) but /health fails → restarting it"
        RESTART=true
    fi
    if [ -n "$existing" ]; then
        run kill "$existing"
        if ! $DRY; then wait_for 5 port_closed "$PORT" || { kill -9 "$existing" 2>/dev/null; sleep 1; }; fi
    fi
    tcc_context_hint
    if $DRY; then
        say "   [dry-run] nohup $VENV/bin/python3 screen-server.py --bind $BIND --display $VDISPLAY_IDX --port $PORT --fps $FPS --rotate >>$LOG_FILE &"
        note ⏳ server "dry-run"; return
    fi
    if [ ! -x "$VENV/bin/python3" ]; then bad "no venv — step 1 failed"; note ❌ server "no venv"; return; fi
    start_server
    if ! wait_for 10 health; then bad "no answer on /health after 10 s — tail $LOG_FILE"; note ❌ server "did not start"; return; fi
    pid="$(listener_pid)"; echo "$pid" >"$PID_FILE"
    if wait_for 10 frame_ok; then
        ok "pid $pid serving frames at $url (log: $LOG_FILE)"; note ✅ server "pid $pid → $url"
    else
        warn "pid $pid is up but /screen.png is still 503 — screencapture failing? tail $LOG_FILE"; note ⚠️ server "pid $pid, no frame yet"
    fi
}

# ---------- Kobo side (USB) ----------
CHANGED=0
install_file() {   # src dst label
    if [ -f "$2" ] && cmp -s "$1" "$2"; then say "   = $3 (unchanged)"; return 0; fi
    if $DRY; then say "   [dry-run] cp $1 → $2"; return 0; fi
    if cp "$1" "$2" && cmp -s "$1" "$2"; then say "   + $3"; CHANGED=$((CHANGED+1)); return 0; fi
    bad "copy failed: $3"; return 1
}
step_kobo() {
    hdr "Kobo side ($KOBO_VOL)"
    local f missing="" stage configured detected
    if [ ! -d "$KOBO_VOL/.kobo" ]; then
        pend "Kobo not mounted → plug in Kobo and re-run with --kobo"
        note ⏳ Kobo "plug in Kobo and re-run with --kobo"
        $KOBO_ONLY && FAILED=1
        return
    fi
    for f in $KOBO_SIDE_FILES nm/kobo-screen; do [ -f "$KOBO_FILES/$f" ] || missing="$missing $f"; done
    if [ -n "$missing" ]; then bad "canonical files missing in $KOBO_FILES:$missing"; note ❌ Kobo "kobo-files incomplete"; return; fi
    [ -d "$KOBO_VOL/.adds/nm" ] || warn "no .adds/nm on the device — NickelMenu not installed? entries appear only once it is"

    # remembered --mac-ip: keeps re-runs idempotent without repeating the flag
    if [ -n "$MAC_IP" ]; then $DRY || { mkdir -p "$RUN_DIR"; echo "$MAC_IP" >"$MAC_IP_FILE"; }
    elif [ -f "$MAC_IP_FILE" ]; then MAC_IP="$(cat "$MAC_IP_FILE")"; say "using remembered --mac-ip $MAC_IP ($MAC_IP_FILE)"; fi

    # stage = canonical copies, optionally with the Mac IP rewritten; the Kobo gets the stage
    stage="$(mktemp -d "${TMPDIR:-/tmp}/kobo-stage.XXXXXX")" || { bad "mktemp failed"; return; }
    for f in $KOBO_SIDE_FILES; do cp "$KOBO_FILES/$f" "$stage/$f"; done
    for f in $KOBO_OPTIONAL_FILES; do [ -f "$KOBO_FILES/$f" ] && cp "$KOBO_FILES/$f" "$stage/$f"; done
    if [ -n "$MAC_IP" ]; then
        sed -i '' -e "s|^MAC_HOST=.*|MAC_HOST=\"$MAC_IP\"|" -e "s|^MAC_PORT=.*|MAC_PORT=\"$PORT\"|" "$stage/config.sh"
    fi
    run mkdir -p "$KOBO_VOL/.adds/kobo-screen" "$KOBO_VOL/.adds/nm"
    for f in $KOBO_SIDE_FILES; do install_file "$stage/$f" "$KOBO_VOL/.adds/kobo-screen/$f" ".adds/kobo-screen/$f"; done
    for f in $KOBO_OPTIONAL_FILES; do
        if [ -f "$stage/$f" ]; then install_file "$stage/$f" "$KOBO_VOL/.adds/kobo-screen/$f" ".adds/kobo-screen/$f"
        elif [ ! -f "$KOBO_VOL/.adds/kobo-screen/$f" ]; then warn "$f is not on the device and not in kobo-files/ — install FBInk yourself (see README.md)"; note ⚠️ FBInk "$f missing"; fi
    done
    install_file "$KOBO_FILES/nm/kobo-screen" "$KOBO_VOL/.adds/nm/kobo-screen" ".adds/nm/kobo-screen"
    rm -rf "$stage"

    # keep the device awake while mirroring — a sleep freezes the loop and drops Wi-Fi.
    # patches AutoSleepMinutes/AutoOffMinutes=255 + ForceWifiOn=true (idempotent, backs up).
    local py
    py="$VENV/bin/python3"; [ -x "$py" ] || py="$(command -v python3 || true)"
    if [ ! -f "$KOBO_CONF" ]; then
        warn "no \"$KOBO_CONF\" — cannot disable auto-sleep (loop will pause when it sleeps)"
        note ⚠️ sleep "conf not found"
    elif [ -z "$py" ]; then
        warn "no python3 to patch auto-sleep — set Auto-sleep: never by hand"
        note ⚠️ sleep "no python3"
    elif $DRY; then
        "$py" "$POWER_PY" "$KOBO_CONF" --dry-run || true
        note ⏳ sleep "dry-run"
    elif "$py" "$POWER_PY" "$KOBO_CONF"; then
        note ✅ sleep "AutoSleep/Off=255, ForceWifiOn=true"
    else
        bad "auto-sleep patch failed — check \"$KOBO_CONF\""; note ❌ sleep "patch failed"
    fi

    configured="${MAC_IP:-$(sed -n 's/^MAC_HOST="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$KOBO_FILES/config.sh" | head -n1)}"
    detected="$(mac_lan_ip || true)"
    if [ -n "$detected" ] && [ "$configured" != "$detected" ]; then
        warn "Kobo copies dial $configured but this Mac is $detected → ./provision.sh --kobo --mac-ip $detected"
        note ⚠️ Kobo "files on device, but MAC_HOST=$configured ≠ this Mac $detected"
    else
        note ✅ Kobo "$CHANGED file(s) written, server IP $configured"
    fi
    run sync
    if $EJECT; then run diskutil unmount "$KOBO_VOL"; else say "   eject when done: diskutil unmount $KOBO_VOL"; fi
}

# ---------- main ----------
print_summary() {
    local s
    printf '\n════ provision summary ════\n'
    if [ ${#SUMMARY[@]} -gt 0 ]; then for s in "${SUMMARY[@]}"; do printf '%s\n' "$s"; done; fi
    printf '\nNext on the Kobo: reboot once (so ForceWifiOn applies), then NickelMenu → "Screen push" (stop: "Screen stop").\n'
    printf 'Auto-sleep is pushed to its 255-min max + Wi-Fi forced on; a true never-sleep (input injection) is tuned later over the remote channel.\n'
    printf 'Teardown: NickelMenu → "Screen stop"; stop the Mac server with kill $(cat %s); restore sleep from the on-device conf backup.\n' "$PID_FILE"
}

if $DO_MAC; then step_venv; step_deskpad; step_display_index; step_sharing; step_server; fi
if $DO_KOBO; then step_kobo; fi
print_summary
exit $FAILED
