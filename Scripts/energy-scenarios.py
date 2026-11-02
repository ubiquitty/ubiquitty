#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# energy-scenarios.py — what the shipping macOS app costs per wall second.
#
#   energy-scenarios.py --app <Ubiquitty.app> [--seconds 30] [--reps 3]
#                       [--only NAME[,NAME...]] [--window-size 640x400]
#                       [--window-origin X,Y]
#   energy-scenarios.py --self-test
#
# ubench (Docs/measuring-live-app.md) owns the throughput lane: how fast a flood
# drains, how many frames a scene presents. This owns the other axis — what the
# app costs when it is doing little or nothing, which is the question a battery
# answers. They do not share a harness because they do not share a workload: a
# throughput run wants the app saturated, and every number here is about the app
# while it is not.
#
# Each scenario launches its own instance under a private UBIQUITTY_HOME and
# XDG_CONFIG_HOME, so the developer's own config.toml cannot decide the result
# (the host suite has been caught reading it before), drives it with `-e` rather
# than the control socket — a child process is deterministic where typed input
# races the shell — activates it, samples, and kills it.
#
# Two rules the numbers depend on:
#
#   Arms interleave. Scenarios run round-robin across reps, never all reps of
#   one scenario then all of the next. Host drift over minutes is larger than
#   the differences being measured, and a sequential protocol folds that drift
#   into scenario identity, which can flip the sign of a renderer comparison.
#
#   Focus is verified, not assumed. An unfocused terminal freezes its caret and
#   draws almost nothing, so an instance that lost focus mid-window reports a
#   cheap number for a scenario that never ran. Every sample records the
#   frontmost pid at both ends and is marked invalid unless it was ours
#   throughout.
#
#   The window is small and out of the way, and raised once. A run shares the
#   screen with someone working, so each instance opens at --window-size
#   (640x400 points by default) in the bottom-right corner of the main
#   screen, is activated at most once per rep and never again while it is in
#   front; one that does not arrive is recorded unfocused, not raised again.
#   The cells drawn per frame scale with the window, so every sample records
#   its size and only samples of one size compare.

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

LINE = "0123456789abcdefghijklmnopqrstuvwxyz"

STEADY_WRITER = (
    "import sys, time\n"
    "while True:\n"
    f"    sys.stdout.write('{LINE}\\n')\n"
    "    sys.stdout.flush()\n"
    "    time.sleep(0.05)\n"
)

STATIC_WRITER = (
    "import sys, time\n"
    f"line = '\\x1b[H' + '{LINE}' + '\\r\\n'\n"
    "while True:\n"
    "    sys.stdout.write(line)\n"
    "    sys.stdout.flush()\n"
    "    time.sleep(0.002)\n"
)

BURSTY_WRITER = (
    "import sys, time\n"
    "while True:\n"
    f"    sys.stdout.write('{LINE}\\n' * 20)\n"
    "    sys.stdout.flush()\n"
    "    time.sleep(1.0)\n"
)

# Every scenario is (config, child command). The child is what the terminal
# runs; the config is what the terminal believes about blinking.
#
# idle_cat is the floor: `cat` reading a pty nobody types into emits nothing at
# all, so what remains is the terminal's own cost of existing with a window on
# screen. idle_cat_noblink is its control — the one knob that should change the
# floor, and if it does not move the number then the instrument never saw the
# caret. idle_shell is the realistic form of the same question, with a login
# shell's prompt on screen. The stream scenarios establish that the instrument
# can see cost, and price a byte of output.
SCENARIOS = {
    "idle_cat": {
        "blink": True,
        "command": ["/bin/cat"],
        "note": "empty grid, caret blinking, nothing running",
    },
    "idle_cat_noblink": {
        "blink": False,
        "command": ["/bin/cat"],
        "note": "control: the same floor with the caret held solid",
    },
    "idle_shell": {
        "blink": True,
        "command": None,
        "note": "a login shell sitting at its prompt",
    },
    "stream_slow": {
        "blink": True,
        "command": ["/bin/sh", "-c", "while :; do date; sleep 0.1; done"],
        "note": "~10 lines/s, a tailed log",
    },
    "stream_flood": {
        "blink": True,
        "command": ["/bin/sh", "-c", "while :; do yes 0123456789abcdefghijklmnopqrstuvwxyz | head -200000; done"],
        "note": "saturated output",
    },
    # The pair below carry the same ten lines a second and differ only in how
    # those lines are spaced. FrameDriver drops back to on-demand drive after
    # 100 ms of output silence, so a writer pausing 100 ms never lets it: the
    # steady arm holds the display link open continuously while the bursty arm
    # lets it pause between bursts. Equal bytes, so any gap between them is the
    # pacing rule and not the volume.
    # 0.05 s spacing is half the timeout, so the steady arm cannot reach it even
    # with scheduling jitter added to each gap; a 0.1 s sleep would land either
    # side of the threshold depending on scheduling and decide nothing.
    #
    # Both writers sleep in-process. The obvious shell form —
    # `while :; do echo …; sleep 0.05; done` — forks 20 times a second, and
    # Core/Title/WalkPacing.h documents a process-table walk driven by
    # process-tree edges, which a forking writer pays and a non-forking one does not.
    # Pairing it against a bursty arm that forks once a second would have varied
    # fork rate and frame pacing together and credited the whole difference to
    # pacing. steady_20hz_forking below restores the forks as their own arm.
    "steady_20hz": {
        "blink": True,
        "command": ["/usr/bin/python3", "-c", STEADY_WRITER],
        "note": "20 lines/s, fork-free — never reaches the idle timeout",
    },
    "bursty_20hz": {
        "blink": True,
        "command": ["/usr/bin/python3", "-c", BURSTY_WRITER],
        "note": "20 lines/s in one burst per second, fork-free — idles between bursts",
    },
    "steady_20hz_forking": {
        "blink": True,
        "command": ["/bin/sh", "-c", "while :; do echo 0123456789abcdefghijklmnopqrstuvwxyz; sleep 0.05; done"],
        "note": "the same 20 lines/s, but each line costs a fork",
    },
    # The same steady writer with [render] max_fps pinned. If the steady arm's
    # cost is presents rather than bytes, capping the rate has to cut it in
    # proportion — and if it does not, the pacing account is wrong and the cost
    # is somewhere else.
    # What damage reuse is worth, isolated in one binary. UBIQUITTY_GRID_CACHE=0
    # rebuilds every row of every frame; =1 rebuilds only the rows the drain
    # reported. Same writer, same pixels, so the gap is the reuse and nothing else.
    "steady_cache_on": {
        "blink": True,
        "env": {"UBIQUITTY_GRID_CACHE": "1"},
        "command": ["/usr/bin/python3", "-c", STEADY_WRITER],
        "note": "20 lines/s with damage reuse",
    },
    "steady_cache_off": {
        "blink": True,
        "env": {"UBIQUITTY_GRID_CACHE": "0"},
        "command": ["/usr/bin/python3", "-c", STEADY_WRITER],
        "note": "20 lines/s rebuilding every row",
    },
    "flood_cache_on": {
        "blink": True,
        "env": {"UBIQUITTY_GRID_CACHE": "1"},
        "command": ["/bin/sh", "-c", "while :; do yes 0123456789abcdefghijklmnopqrstuvwxyz | head -200000; done"],
        "note": "saturated output with damage reuse",
    },
    "flood_cache_off": {
        "blink": True,
        "env": {"UBIQUITTY_GRID_CACHE": "0"},
        "command": ["/bin/sh", "-c", "while :; do yes 0123456789abcdefghijklmnopqrstuvwxyz | head -200000; done"],
        "note": "saturated output rebuilding every row",
    },
    # A screen that is rewritten identically 500 times a second: bytes arrive
    # constantly, nothing a viewer can see ever changes. The case the frame skip
    # exists for, and the one where a terminal that presents per vsync burns a
    # panel's worth of frames for no visible reason.
    "static_skip_on": {
        "blink": False,
        "command": ["/usr/bin/python3", "-c", STATIC_WRITER],
        "note": "unchanging screen, unchanged frames skipped",
    },
    "static_skip_off": {
        "blink": False,
        "env": {"UBIQUITTY_SKIP_UNCHANGED_FRAMES": "0"},
        "command": ["/usr/bin/python3", "-c", STATIC_WRITER],
        "note": "unchanging screen, presenting every link callback",
    },
    "steady_skip_on": {
        "blink": False,
        "command": ["/usr/bin/python3", "-c", STEADY_WRITER],
        "note": "20 lines/s of NEW text, unchanged frames skipped",
    },
    "steady_skip_off": {
        "blink": False,
        "env": {"UBIQUITTY_SKIP_UNCHANGED_FRAMES": "0"},
        "command": ["/usr/bin/python3", "-c", STEADY_WRITER],
        "note": "20 lines/s of NEW text, presenting every link callback",
    },
    # Under flood every frame carries new rows, so the skip must never fire and the
    # check must cost nothing measurable. This is the arm that says whether the
    # product's fastest path paid for the saving above.
    "flood_skip_on": {
        "blink": False,
        "command": ["/bin/sh", "-c", "while :; do yes 0123456789abcdefghijklmnopqrstuvwxyz | head -200000; done"],
        "note": "saturated output, skip enabled",
    },
    "flood_skip_off": {
        "blink": False,
        "env": {"UBIQUITTY_SKIP_UNCHANGED_FRAMES": "0"},
        "command": ["/bin/sh", "-c", "while :; do yes 0123456789abcdefghijklmnopqrstuvwxyz | head -200000; done"],
        "note": "saturated output, skip disabled",
    },
    "steady_20hz_capped30": {
        "blink": True,
        "max_fps": 30,
        "command": ["/bin/sh", "-c", "while :; do echo 0123456789abcdefghijklmnopqrstuvwxyz; sleep 0.05; done"],
        "note": "the steady writer with the frame rate capped at 30",
    },
}


def screen_is_locked():
    # loginwindow owns the front when the screen locks or the screensaver runs.
    # Every scenario here then measures a window nobody can see: the caret
    # freezes, the display link stops, and each arm reports a confident 0.0 that
    # is a fact about the lock screen rather than about the app. Refusing is the
    # whole point — a zero from a locked screen is indistinguishable from a zero
    # earned, and the first run of this harness reported five of them.
    front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    if not front:
        return True
    name = subprocess.run(["lsappinfo", "info", "-only", "name", front], capture_output=True, text=True).stdout
    return "loginwindow" in name or "ScreenSaver" in name


def frontmost_pid():
    front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    if not front:
        return None
    info = subprocess.run(["lsappinfo", "info", "-only", "pid", front], capture_output=True, text=True).stdout
    digits = "".join(character for character in info if character.isdigit())
    return int(digits) if digits else None


def activate(pid):
    subprocess.run(
        ["osascript", "-e", f"tell application \"System Events\" to set frontmost of (first process whose unix id is {pid}) to true"],
        capture_output=True,
    )


def launch(app, scenario, workdir):
    home = os.path.join(workdir, "home")
    config_home = os.path.join(workdir, "config")
    os.makedirs(os.path.join(config_home, "ubiquitty"), exist_ok=True)
    os.makedirs(home, exist_ok=True)
    with open(os.path.join(config_home, "ubiquitty", "config.toml"), "w") as handle:
        handle.write("[cursor]\nblink = {}\n".format("true" if scenario["blink"] else "false"))
        # Opened near its measured size rather than at the default, which fills
        # the screen: place_window then sets the exact size in points.
        handle.write("\n[window]\ninitial_columns = 80\ninitial_rows = 22\n")
        if scenario.get("max_fps"):
            handle.write("\n[render]\nmax_fps = {}\n".format(scenario["max_fps"]))

    environment = dict(os.environ, UBIQUITTY_HOME=home, XDG_CONFIG_HOME=config_home)
    # The app is launched with an environment this harness builds, so a knob
    # under test has to be placed here — one exported in the invoking shell does
    # not arrive. Passing the arm as an env var keeps both sides of an A/B in
    # ONE binary: two builds differ by their whole optimisation regime, and that
    # gap has been read as an arm difference in this codebase before.
    environment.update(scenario.get("env", {}))
    argv = [os.path.join(app, "Contents", "MacOS", "Ubiquitty")]
    if scenario["command"]:
        argv += ["-e"] + scenario["command"]
    process = subprocess.Popen(argv, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return process


def measure(pid, seconds):
    output = subprocess.run(
        [sys.executable, os.path.join(HERE, "measure-energy.py"), str(seconds), str(pid)],
        capture_output=True, text=True,
    ).stdout.strip()
    return json.loads(output) if output else {"error": "no sample"}


def parse_pair(text, separator):
    """Parses "AxB" or "A,B" into two integers; raises ValueError otherwise."""
    first, second = text.split(separator)
    return int(first), int(second)


def main_visible_frame():
    """The main screen's visible frame as (x, y, width, height), y from the bottom, in points."""
    script = ('ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.visibleFrame; '
              'var s = $.NSScreen.mainScreen.frame; '
              '[f.origin.x, f.origin.y, f.size.width, f.size.height, s.size.height].join(",")')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout
    return tuple(float(v) for v in out.strip().split(","))


def default_origin(frame, size):
    """The top-left, in System Events' coordinates, that puts a window of `size`
    in the bottom-right corner of the visible frame.

    `frame` is (x, y, width, height, screenHeight) with y measured from the
    bottom, as AppKit gives it; System Events measures y from the top.
    """
    x, y, width, height, screen_height = frame
    return int(x + width - size[0]), int(screen_height - y - size[1])


def place_window(pid, size, origin):
    """Sizes and moves the instance's window without bringing it forward."""
    subprocess.run(
        ["osascript", "-e",
         f"tell application \"System Events\" to tell (first process whose unix id is {pid})\n"
         f"set size of first window to {{{size[0]}, {size[1]}}}\n"
         f"set position of first window to {{{origin[0]}, {origin[1]}}}\n"
         "end tell"],
        capture_output=True,
    )


def focus_once(pid, frontmost, activate_window, wait_seconds=8):
    """Activates the instance at most once and waits for it to be frontmost.

    Never re-activates: a window that is already in front is left alone, and
    one that has not arrived after one activation is reported unfocused rather
    than raised again over the reader's work.
    - Returns: whether the instance was frontmost by the end of the wait.
    """
    if frontmost() == pid:
        return True
    activate_window(pid)
    for _ in range(wait_seconds):
        time.sleep(1)
        if frontmost() == pid:
            return True
    return False


def self_test():
    failures = []
    if parse_pair("640x400", "x") != (640, 400) or parse_pair("12,34", ",") != (12, 34):
        failures.append("size and origin parsing")
    if default_origin((0.0, 25.0, 1512.0, 920.0, 982.0), (640, 400)) != (872, 557):
        failures.append("bottom-right origin")
    calls = []
    if not focus_once(7, lambda: 7, lambda pid: calls.append(pid)) or calls:
        failures.append("an instance already in front was activated")
    answers = iter([1, 7])
    if not focus_once(7, lambda: next(answers), lambda pid: calls.append(pid), wait_seconds=1) or calls != [7]:
        failures.append("an instance behind was not activated exactly once")
    calls.clear()
    if focus_once(7, lambda: 1, lambda pid: calls.append(pid), wait_seconds=1) or calls != [7]:
        failures.append("an instance that never arrived was activated again or reported focused")
    if failures:
        print(f"energy-scenarios: self-test FAILED — {len(failures)} case(s) wrong: {'; '.join(failures)}",
              file=sys.stderr)
        return 1
    print("energy-scenarios: self-test ok (parsing, bottom-right placement, one activation at most)")
    return 0


def run_once(app, name, seconds, size, origin):
    scenario = SCENARIOS[name]
    workdir = tempfile.mkdtemp(prefix="ubq-energy-")
    process = None
    try:
        process = launch(app, scenario, workdir)
        # The window has to exist before activating it, and the first frames
        # after launch are startup work that belongs to no scenario.
        time.sleep(6)
        # Polled rather than slept on: a single activate-then-wait loses samples
        # to an activation that had not landed yet, and each loss is a
        # whole arm-rep. A direct binary launch does not raise its own window,
        # and an unfocused terminal freezes its caret and stops drawing.
        place_window(process.pid, size, origin)
        focused = focus_once(process.pid, frontmost_pid, activate)
        sample = measure(process.pid, seconds)
        after = frontmost_pid()
        sample["scenario"] = name
        sample["note"] = scenario["note"]
        sample["focused"] = focused and after == process.pid
        # The cells drawn per frame scale with the window, so a sample is only
        # comparable with one taken at the same size.
        sample["window_pt"] = list(size)
        return sample
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
        shutil.rmtree(workdir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--only", default="")
    # A locked screen is a legitimate arm, not only a hazard: the same scenario
    # measured locked and unlocked differs by exactly the render and present
    # work, because nothing else about the app changes. It has to be asked for,
    # and every sample it produces says which side it came from.
    parser.add_argument("--allow-locked", action="store_true")
    parser.add_argument("--window-size", default="640x400",
                        help="the measured window, WxH in points; samples record it")
    parser.add_argument("--window-origin", default=None,
                        help="top-left X,Y in points; default: the main screen's bottom-right corner")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        raise SystemExit(self_test())
    if not args.app:
        raise SystemExit("--app is required")
    size = parse_pair(args.window_size, "x")
    origin = parse_pair(args.window_origin, ",") if args.window_origin else default_origin(main_visible_frame(), size)

    names = [n for n in args.only.split(",") if n] or list(SCENARIOS)
    for unknown in [n for n in names if n not in SCENARIOS]:
        raise SystemExit(f"no such scenario: {unknown}")

    locked = screen_is_locked()
    if locked and not args.allow_locked:
        raise SystemExit(
            "refusing to measure: the screen is locked or asleep, so every scenario would "
            "report the cost of a window nobody is drawing. Unlock the display and re-run, "
            "or pass --allow-locked to measure the display-off side deliberately."
        )

    for rep in range(args.reps):
        for name in names:
            sample = run_once(args.app, name, args.seconds, size, origin)
            sample["rep"] = rep
            sample["display"] = "locked" if locked else "on"
            print(json.dumps(sample), flush=True)


if __name__ == "__main__":
    main()
