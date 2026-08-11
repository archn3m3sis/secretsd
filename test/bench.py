#!/usr/bin/env python3
"""Measure what the program actually costs. usage: test/bench.py [runs]

Every guess anyone made about where this program spent its first second was
wrong, including several of mine in a row: it was "obviously" the sops decrypt,
then "obviously" the posture scan, then "obviously" the row building. It was
none of those — it was `ykman --version`, a permission audit forking stat
fifteen times, and painting the screen with a subshell every fourth column.

So: measure. This drives the real binary through a real pty, at a real terminal
size, and reports medians. Numbers only.
"""

import fcntl
import os
import pty
import select
import statistics
import struct
import subprocess
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin", "secretsd")
COLS, ROWS = 120, 40


def drive(args, until, keys=b"", timeout=30.0, env=None):
    """Run BIN with args in a pty; return seconds until `until` appears."""
    e = dict(os.environ)
    e["COLORTERM"] = "truecolor"
    e["TERM"] = "xterm-256color"
    if env:
        e.update(env)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.clear()
        os.environ.update(e)
        os.execvp(BIN, [BIN] + args)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    t0 = time.time()
    seen = b""
    hit = None
    sent = False
    while time.time() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                c = os.read(fd, 65536)
            except OSError:
                break
            if not c:
                break
            seen += c
            if hit is None and until in seen:
                hit = time.time() - t0
                if not keys:
                    break
                if not sent:
                    try:
                        os.write(fd, keys)
                    except OSError:
                        break
                    sent = True
                    t0 = time.time()
                    seen = b""
                    hit = None
                    until_first = False
    try:
        os.write(fd, b"q")
    except OSError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except Exception:
        pass
    try:
        os.close(fd)
    except Exception:
        pass
    return hit


def cli(args, runs):
    ts = []
    for _ in range(runs):
        t0 = time.time()
        subprocess.run([BIN] + args, capture_output=True)
        ts.append(time.time() - t0)
    return statistics.median(ts)


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5

    print("\n  secretsd benchmark — %d runs, median, %dx%d\n" % (runs, COLS, ROWS))

    # warm every cache first: a benchmark that measures a cold cache once and a
    # warm one thereafter reports the difference between its own runs
    drive([], b"DOCTOR")
    subprocess.run([BIN, "names"], capture_output=True)

    rows = []

    ts = [drive([], b"DOCTOR") for _ in range(runs)]
    ts = [t for t in ts if t]
    rows.append(("dashboard: first paint", statistics.median(ts) if ts else None))

    ts = [drive([], b"DOCTOR", keys=b"j") for _ in range(runs)]
    ts = [t for t in ts if t]
    rows.append(("dashboard: move selection", statistics.median(ts) if ts else None))

    for label, args in [
        ("names", ["names"]),
        ("names --json", ["names", "--json"]),
        ("doctor --json", ["doctor", "--json"]),
        ("expiring --json", ["expiring", "--json"]),
        ("posture --json", ["posture", "--json"]),
        ("alerts scan", ["alerts", "scan"]),
    ]:
        rows.append((label, cli(args, runs)))

    for label, t in rows:
        if t is None:
            print("  %-28s      —" % label)
        else:
            print("  %-28s %7.0f ms" % (label, t * 1000))
    print()


if __name__ == "__main__":
    main()
