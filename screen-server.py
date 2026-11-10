#!/usr/bin/env python3
"""Kobo screen server — serves a live capture of the Kobo virtual display as a
1-bit-friendly grayscale PNG sized for the Libra 2 panel (1264x1680 portrait).

The Kobo's loop.sh fetches GET /screen.png ~4x/sec and paints it with FBInk A2.
Single-display capture (screencapture -D 4) avoids macOS Screen Sharing's
whole-desktop framebuffer problem.

Run:  python3 screen-server.py [--bind ADDRESS] [--display 4] [--port 8090] [--rotate]

The server has no authentication. See the Security section of README.md.
"""
import argparse
import io
import os
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageFilter

_CAP_PATH = os.path.join(tempfile.gettempdir(), "kobo-capture.png")

# Kobo Libra 2 panel: 1264 wide x 1680 tall (portrait)
PANEL_W, PANEL_H = 1264, 1680

_lock = threading.Lock()
_frame = {"png": None, "ts": 0.0}
ARGS = None


def capture_display(index: int) -> Image.Image:
    """Capture one macOS display to a PIL image.

    screencapture's stdout mode ('-') returns empty with -D on recent macOS,
    so capture to a temp file and read it back.
    """
    p = subprocess.run(
        # -C includes the (hardware-overlay) mouse cursor, which is omitted by default
        ["screencapture", "-x", "-C", "-t", "png", f"-D{index}", _CAP_PATH],
        capture_output=True,
    )
    if p.returncode != 0 or not os.path.exists(_CAP_PATH):
        raise RuntimeError(f"screencapture failed: {p.stderr.decode(errors='replace')[:200]}")
    img = Image.open(_CAP_PATH)
    img.load()
    return img


def _levels_lut(black: int, white: int, gamma: float = 1.0):
    """LUT mapping input [black..white] → [0..255]. gamma > 1 darkens midtones so
    medium-grey text (window titles, menu bar) goes dark instead of staying faint."""
    span = max(white - black, 1)
    lut = []
    for i in range(256):
        if i <= black:
            lut.append(0)
        elif i >= white:
            lut.append(255)
        else:
            lut.append(round(((i - black) / span) ** gamma * 255))
    return lut


def to_panel_png(img: Image.Image, rotate: bool, black: int, white: int, gamma: float) -> bytes:
    """Grayscale, rotate to fill the portrait panel, enhance for e-ink, return PNG.

    A landscape capture letterboxed into the portrait panel leaves the content a
    thin, tiny band; rotating 90° CCW makes a 1680×1264 capture 1264×1680 so it
    fills the panel. macOS UI is low-contrast light grey that e-ink renders almost
    invisibly, so a fixed levels map pulls text below `black` to 0 and the light
    desktop above `white` to 255, then unsharp crisps the edges. The map is fixed,
    not autocontrast — autocontrast stretches a near-empty desktop's uniform grey
    into a solid black band.
    """
    img = img.convert("L")  # 8-bit grayscale; FBInk dithers to the panel's levels
    if rotate:
        img = img.rotate(90, expand=True)  # 90° counter-clockwise
    img.thumbnail((PANEL_W, PANEL_H), Image.LANCZOS)  # fit, preserve aspect
    img = img.point(_levels_lut(black, white, gamma))
    img = img.filter(ImageFilter.UnsharpMask(radius=2, percent=160, threshold=2))
    canvas = Image.new("L", (PANEL_W, PANEL_H), 255)
    canvas.paste(img, ((PANEL_W - img.width) // 2, (PANEL_H - img.height) // 2))
    buf = io.BytesIO()
    canvas.save(buf, "PNG", optimize=False)
    return buf.getvalue()


def capture_loop():
    """Continuously refresh the shared frame so requests return instantly."""
    period = 1.0 / max(ARGS.fps, 0.5)
    while True:
        t0 = time.time()
        try:
            png = to_panel_png(capture_display(ARGS.display), ARGS.rotate, ARGS.black, ARGS.white, ARGS.gamma)
            with _lock:
                _frame["png"], _frame["ts"] = png, time.time()
        except Exception as e:  # keep serving the last good frame
            print(f"[capture] {e}")
        dt = time.time() - t0
        time.sleep(max(0, period - dt))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {self.client_address[0]} {fmt % args}", flush=True)

    def _save_report(self, body: bytes):
        path = os.path.join(tempfile.gettempdir(), "kobo-report.txt")
        with open(path, "ab") as f:
            f.write(f"\n===== {time.strftime('%H:%M:%S')} from {self.client_address[0]} =====\n".encode())
            f.write(body)
            f.write(b"\n")
        print(f"[REPORT] {len(body)}B from {self.client_address[0]} -> {path}", flush=True)

    def do_POST(self):
        if self.path.startswith("/report"):
            n = int(self.headers.get("Content-Length", 0))
            self._save_report(self.rfile.read(n) if n else b"(empty)")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/health"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if self.path.startswith("/report?"):
            self._save_report(self.path.split("?", 1)[1].encode())
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        if self.path.startswith("/cmd.sh"):
            cmd_path = os.path.join(tempfile.gettempdir(), "kobo-cmd.sh")
            try:
                with open(cmd_path, "rb") as f:
                    body = f.read()
            except OSError:
                body = b""  # no command queued
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/screen.png"):
            with _lock:
                png = _frame["png"]
            if png is None:
                self.send_response(503)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(png)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(png)
            return
        self.send_response(404)
        self.end_headers()


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--display", type=int, default=4, help="screencapture -D index (4 = Kobo virtual display)")
    ap.add_argument("--bind", default=os.environ.get("KOBO_BIND", "0.0.0.0"),
                    help="interface address to listen on (env KOBO_BIND); default is all interfaces, use a specific address")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--fps", type=float, default=4.0, help="server-side capture rate")
    ap.add_argument("--rotate", action="store_true", help="rotate 90° CCW so a landscape capture fills the portrait panel")
    ap.add_argument("--black", type=int, default=90, help="e-ink levels black point: input ≤ this → 0")
    ap.add_argument("--white", type=int, default=205, help="e-ink levels white point: input ≥ this → 255")
    ap.add_argument("--gamma", type=float, default=2.2, help="midtone curve: >1 darkens grey text (titles/menu bar)")
    ARGS = ap.parse_args()

    threading.Thread(target=capture_loop, daemon=True).start()
    srv = ThreadingHTTPServer((ARGS.bind, ARGS.port), Handler)
    print(f"Kobo screen server: display -D{ARGS.display} -> {ARGS.bind}:{ARGS.port}/screen.png "
          f"({PANEL_W}x{PANEL_H}, {ARGS.fps} fps capture)")
    srv.serve_forever()


if __name__ == "__main__":
    main()
