#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# winch-probe.py — what a program in a terminal window sees of a resize.
#
#   winch-probe.py --log /path/winch.log [--seconds N]
#   winch-probe.py --log /path/winch.log -- mc
#
# Runs as the window's program and records every SIGWINCH with a wall-clock
# stamp and the winsize the PTY reports at that moment. Alone, it paints the
# whole screen on each one the way a full-screen program does. Given a
# command, it runs that program in the same process group — the kernel sends
# SIGWINCH to the whole foreground group, so the probe counts what the program
# was told while the program paints. The log is what a resize tool reads back:
# how many size changes the program heard against how many the window went
# through.

import argparse
import fcntl
import os
import signal
import struct
import subprocess
import sys
import termios
import time


def winsize():
    packed = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
    rows, columns, _, _ = struct.unpack("HHHH", packed)
    return rows, columns


def paint(rows, columns):
    out = sys.stdout
    out.write("\x1b[H\x1b[2J")
    # Each row carries the grid it was painted for, so a frame that mixes
    # two paints reads as torn from its rows alone.
    for row in range(rows):
        line = f"{row + 1:3d} {rows}x{columns} " + ("#" * max(0, columns - 12))
        out.write(f"\x1b[{row + 1};1H{line[:columns]}")
    out.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--seconds", type=float, default=120.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    log = open(args.log, "w", buffering=1)
    count = 0

    def on_winch(signum, frame):
        nonlocal count
        count += 1
        rows, columns = winsize()
        log.write(f"{time.time():.4f} winch {count} {rows}x{columns}\n")
        if not command:
            paint(rows, columns)

    signal.signal(signal.SIGWINCH, on_winch)
    rows, columns = winsize()
    log.write(f"{time.time():.4f} start {rows}x{columns}\n")
    if command:
        # The same process group, so the tty's SIGWINCH reaches both; the
        # program owns the screen and the probe only counts.
        child = subprocess.Popen(command)
        while child.poll() is None:
            try:
                child.wait(timeout=0.05)
            except subprocess.TimeoutExpired:
                pass
        log.write(f"{time.time():.4f} end {count}\n")
        return child.returncode
    paint(rows, columns)
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        # A short sleep, so a signal that lands mid-wait is handled within it.
        time.sleep(0.02)
    log.write(f"{time.time():.4f} end {count}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
