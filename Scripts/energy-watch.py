#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# energy-watch.py — sample every running Ubiquitty while a person drives it.
#
#   energy-watch.py --out results.ndjson [--interval 4] [--scenario agent]
#
# The scenario harnesses launch a terminal, feed it and sample it in one process,
# which is right when the workload is a script. It is wrong when the workload is
# a person: the arm under test is whichever window holds focus at that moment,
# and nothing in a harness that never sees the keyboard knows when that changed.
#
# So this samples every Ubiquitty it can find, on a loop, and keeps only the
# samples that are both focused and busy. Focus matters because an unfocused
# terminal freezes its caret and stops presenting, and so reports a near-zero
# that reads as the arm winning. Busy matters because the two windows waiting
# their turn would otherwise pour idle samples into their own medians and make
# whichever arm was driven last look the most expensive.
#
# Runs are labelled from an environment variable read back off the running
# process, so a window the launcher failed to open is absent rather than
# silently credited to another run's numbers.
#
# Window size is read back per arm for the same reason: a build that ignores
# `[window] initial_columns` renders a different number of cells than the arm it
# is being compared against, which is a difference in the workload rather than
# in the terminal, and it has to be visible instead of assumed away.

import argparse
import json
import re
import subprocess
import sys
import time

# top prints minutes, seconds and hundredths, gaining an hours field past an hour.
CPUTIME = re.compile(r"^(?:(\d+):)?(\d+):(\d+)\.(\d+)$")

ARM_ENV = re.compile(r"\bUBQ_ARM=([A-Za-z0-9_.-]+)")


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
            "cputime": cputime_seconds(cputime),
            # A trailing + marks a delta reading rather than a lifetime total.
            "idlew": int(idlew.rstrip("+")),
            "power": float(power),
        }
    return rows


def sample(duration, pids):
    """Two top samples `duration` apart, so cpu time can be differenced.

    top's first sample averages over the whole life of the process, so a single
    reading of a long-lived app describes its morning rather than the scenario.
    """
    args = ["top", "-l", "2", "-s", str(duration), "-stats", "pid,command,cpu,time,idlew,power"]
    for pid in pids:
        args += ["-pid", str(pid)]
    try:
        completed = subprocess.run(args, capture_output=True, text=True, timeout=duration * 3 + 30)
    except subprocess.TimeoutExpired:
        return None
    blocks = completed.stdout.split("PID ")
    if len(blocks) < 3:
        return None
    return parse(blocks[1]), parse(blocks[2])


def arms():
    """Every running Ubiquitty, keyed by pid, valued by the arm it says it is."""
    found = subprocess.run(["pgrep", "-x", "Ubiquitty"], capture_output=True, text=True).stdout.split()
    labelled = {}
    for text in found:
        pid = int(text)
        environ = subprocess.run(["ps", "-Ewwp", text], capture_output=True, text=True).stdout
        matched = ARM_ENV.search(environ)
        labelled[pid] = matched.group(1) if matched else f"unlabelled-{pid}"
    return labelled


def front_pid():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    if not asn:
        return None
    info = subprocess.run(["lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True).stdout
    digits = "".join(c for c in info if c.isdigit())
    return int(digits) if digits else None


def window_points(pid):
    script = (f'tell application "System Events" to get size of front window of '
              f'(first process whose unix id is {pid})')
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()
    parts = [p.strip() for p in out.split(",")]
    if len(parts) != 2 or not all(p.lstrip("-").isdigit() for p in parts):
        return None
    return [int(parts[0]), int(parts[1])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--interval", type=int, default=4)
    parser.add_argument("--scenario", default="agent")
    # A window with nothing running in it still costs a little; below this it is
    # waiting its turn rather than under test. One percent of a core is far under
    # anything the paced scenario draws and far over a settled idle screen.
    parser.add_argument("--busy-floor", type=float, default=0.01)
    parser.add_argument("--font", default="JetBrains Mono 12")
    parser.add_argument("--grid", default="140x36")
    args = parser.parse_args()

    out = open(args.out, "a", buffering=1)
    geometry = {}

    while True:
        labels = arms()
        if not labels:
            print("waiting for an Ubiquitty window", file=sys.stderr, flush=True)
            time.sleep(args.interval)
            continue

        front = front_pid()
        taken = sample(args.interval, sorted(labels))
        if taken is None:
            continue
        first, second = taken

        for pid, arm in sorted(labels.items(), key=lambda row: row[1]):
            if pid not in first or pid not in second:
                continue
            before, after = first[pid], second[pid]
            cpu = (after["cputime"] - before["cputime"]) / args.interval
            focused = pid == front
            busy = cpu >= args.busy_floor
            if arm not in geometry:
                geometry[arm] = window_points(pid)

            state = "sampled" if (focused and busy) else ("idle" if focused else "background")
            print(f"{arm:<8} cpu {cpu:6.3f}  power {after['power']:6.1f}  {state}",
                  file=sys.stderr, flush=True)
            if not (focused and busy):
                continue

            out.write(json.dumps({
                "scenario": args.scenario,
                "terminal": arm,
                "pid": pid,
                "window_s": args.interval,
                "cpu_s_per_s": round(cpu, 5),
                "wakeups_per_s": round((after["idlew"] - before["idlew"]) / args.interval, 2),
                "power_impact": after["power"],
                "window_points": geometry.get(arm),
                "focused": True,
                "font": args.font,
                "grid": args.grid,
                "blink": False,
            }) + "\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
