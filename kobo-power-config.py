#!/usr/bin/env python3
"""Patch "Kobo eReader.conf" so the device stays awake while used as a Mac display.

Keeps the device from sleeping (which freezes the mirror loop and drops Wi-Fi):
  [PowerOptions]    AutoSleepMinutes=255   "Automatically go to sleep after" (max; 1-255)
  [PowerOptions]    AutoOffMinutes=255     "Automatically power off after"   (max; 1-255)
  [DeveloperSettings] ForceWifiOn=true     keep Wi-Fi associated regardless of inactivity

Keys and ranges are from the MobileRead "Kobo Configuration Options" wiki
(all WORKING on firmware 4.25+; this device is 4.38). 255 min is the documented
max — not literally "never"; a true never-sleep needs periodic input injection,
layered on top of this later over the remote channel.

Line-based on purpose: Python's configparser lowercases keys and rewrites
"key=value" as "key = value", both of which Nickel can mishandle. This edits
only the three target lines and leaves every other byte of the file alone.

Idempotent: a conf already holding the target values is reported "ok" and not
rewritten. The first real change backs the original up to <conf>.bak-<ts>.

Usage:
  kobo-power-config.py "<...>/Kobo eReader.conf"            apply
  kobo-power-config.py "<...>/Kobo eReader.conf" --dry-run  show what would change
  kobo-power-config.py "<...>/Kobo eReader.conf" --show     print power/dev sections, no change
"""
import argparse
import sys
import time

# (section, key, value) — order within a section is preserved; missing sections
# are appended at EOF, missing keys just under their section header.
TARGETS = [
    ("PowerOptions", "AutoSleepMinutes", "255"),
    ("PowerOptions", "AutoOffMinutes", "255"),
    ("DeveloperSettings", "ForceWifiOn", "true"),
]
SHOW_SECTIONS = {"PowerOptions", "DeveloperSettings"}


def section_of(line: str):
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        return s[1:-1]
    return None


def key_of(line: str):
    s = line.strip()
    if not s or s.startswith("#") or s.startswith(";") or section_of(line) is not None:
        return None
    if "=" not in s:
        return None
    return s.split("=", 1)[0].strip()


def show(lines):
    cur = None
    for ln in lines:
        sec = section_of(ln)
        if sec is not None:
            cur = sec
            if sec in SHOW_SECTIONS:
                print(ln.rstrip("\n"))
            continue
        if cur in SHOW_SECTIONS and ln.strip():
            print(ln.rstrip("\n"))


def patch(lines):
    """Return (new_lines, changes[list of str]). Operates on a list of raw lines."""
    changes = []
    lines = list(lines)

    # index the section header line numbers
    def section_bounds(name):
        start = None
        for i, ln in enumerate(lines):
            if section_of(ln) == name:
                start = i
                break
        if start is None:
            return None, None
        end = len(lines)
        for j in range(start + 1, len(lines)):
            if section_of(lines[j]) is not None:
                end = j
                break
        return start, end

    for sec, key, val in TARGETS:
        start, end = section_bounds(sec)
        if start is None:
            # append a new section at EOF
            if lines and lines[-1].strip() != "":
                lines.append("")
            lines.append(f"[{sec}]")
            lines.append(f"{key}={val}")
            changes.append(f"+ [{sec}] {key}={val}  (section created)")
            continue
        # find the key within [start+1, end)
        found = None
        for i in range(start + 1, end):
            if key_of(lines[i]) == key:
                found = i
                break
        if found is None:
            lines.insert(start + 1, f"{key}={val}")
            changes.append(f"+ [{sec}] {key}={val}  (key added)")
        else:
            cur = lines[found].split("=", 1)[1].strip()
            if cur == val:
                pass  # already correct
            else:
                lines[found] = f"{key}={val}"
                changes.append(f"~ [{sec}] {key}: {cur} -> {val}")
    return lines, changes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("conf", help="path to 'Kobo eReader.conf' on the mounted device")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--show", action="store_true", help="print power/dev sections and exit")
    args = ap.parse_args()

    try:
        with open(args.conf, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print(f"❌ cannot read {args.conf}: {e}", file=sys.stderr)
        return 2

    had_trailing_nl = text.endswith("\n")
    lines = text.split("\n")
    if had_trailing_nl:
        lines = lines[:-1]  # drop the empty element after the final newline

    if args.show:
        show(lines)
        return 0

    new_lines, changes = patch(lines)
    if not changes:
        print("✅ auto-sleep/Wi-Fi keys already set (AutoSleepMinutes=255, AutoOffMinutes=255, ForceWifiOn=true)")
        return 0

    print("Changes:")
    for c in changes:
        print("  " + c)

    if args.dry_run:
        print("[dry-run] not written")
        return 0

    bak = f"{args.conf}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    try:
        with open(bak, "w", encoding="utf-8") as f:
            f.write(text)
        out = "\n".join(new_lines) + ("\n" if had_trailing_nl or new_lines else "")
        with open(args.conf, "w", encoding="utf-8") as f:
            f.write(out)
    except OSError as e:
        print(f"❌ write failed: {e}", file=sys.stderr)
        return 2
    print(f"✅ patched {len(changes)} key(s); backup: {bak}")
    print("   reboot the Kobo once after ejecting so ForceWifiOn takes effect")
    return 0


if __name__ == "__main__":
    sys.exit(main())
