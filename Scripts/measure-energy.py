#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# measure-energy.py — per-process energy accounting for a live app, no root.
#
#   measure-energy.py SECONDS PID [PID ...]
#
# Emits one JSON object per pid. The perf lane measures throughput — how fast a
# flood drains; this measures the other axis, what a process costs per wall
# second, which is what a battery answers for.
#
# Instrument is top(1)'s per-process accounting, chosen because powermetrics is
# root-only and a measurement nobody can run without a password does not get run:
#
#   TIME   cumulative CPU time at centisecond resolution -> CPU seconds per wall
#          second. The primary: monotonic, so a sampling boundary cannot inflate
#          it, and directly proportional to energy at a fixed frequency.
#   IDLEW  idle wakeups, differenced between the two samples. Reported because
#          on Apple silicon a process that wakes often keeps the package out of
#          its deep idle states and costs battery at CPU time that rounds to
#          nothing. The column is CUMULATIVE since process start even in
#          interval mode — dividing one reading by the window gives a rate that
#          looks alarming and describes nothing, even for a process that is
#          making no wakeups at all.
#   POWER  macOS "Energy Impact", the composite Activity Monitor shows. Last,
#          because its weights are Apple's and unpublished — it corroborates a
#          direction, it does not establish a magnitude.
#
# Two samples, and the CPU figure is the delta between them rather than either
# sample's %CPU: top's first sample reports an average since process start, so a
# single-sample read of a long-lived app describes its whole life instead of the
# scenario under test.

import json
import re
import subprocess
import sys

# top prints minutes, seconds and hundredths, gaining an hours field past an hour.
CPUTIME = re.compile(r"^(?:(\d+):)?(\d+):(\d+)\.(\d+)$")


def cputime_seconds(text):
    matched = CPUTIME.match(text)
    if not matched:
        return float("nan")
    hours, minutes, seconds, centis = matched.groups()
    return int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds) + int(centis) / 100.0


def parse(block):
    rows = {}
    for line in block.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 6 or not fields[0].isdigit():
            continue
        pid, command, cpu, cputime, idlew, power = fields[:6]
        rows[int(pid)] = {
            "command": command,
            "cpu": float(cpu),
            "cputime": cputime_seconds(cputime),
            # A trailing + marks a delta reading rather than a lifetime total.
            "idlew": int(idlew.rstrip("+")),
            "power": float(power),
        }
    return rows


def sample(duration, pids):
    args = ["top", "-l", "2", "-s", str(duration), "-stats", "pid,command,cpu,time,idlew,power"]
    for pid in pids:
        args += ["-pid", str(pid)]
    completed = subprocess.run(args, capture_output=True, text=True, timeout=duration * 3 + 30)
    blocks = completed.stdout.split("PID ")
    if len(blocks) < 3:
        raise SystemExit("top returned fewer than two samples — a pid under test probably exited")
    return parse(blocks[1]), parse(blocks[2])


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__ or "usage: measure-energy.py SECONDS PID [PID ...]")
    duration = int(sys.argv[1])
    pids = [int(pid) for pid in sys.argv[2:]]
    first, second = sample(duration, pids)
    for pid in pids:
        if pid not in first or pid not in second:
            print(json.dumps({"pid": pid, "error": "top did not report this pid — exited mid-run"}))
            continue
        before, after = first[pid], second[pid]
        print(json.dumps({
            "pid": pid,
            "command": after["command"],
            "window_s": duration,
            "cpu_s_per_s": round((after["cputime"] - before["cputime"]) / duration, 5),
            "wakeups_per_s": round((after["idlew"] - before["idlew"]) / duration, 2),
            "wakeups_lifetime": after["idlew"],
            "power_impact": after["power"],
        }))


if __name__ == "__main__":
    main()
