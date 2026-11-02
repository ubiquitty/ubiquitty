#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# resize-census.sh — drive a window through a resize and read back what the
# terminal and its program went through.
#
#     resize-census.sh [--grid COLSxROWS]
#                      [--mode zoom|steps] [--program CMD] [--rounds N]
#                      [--steps N] [--step-points P] [--step-ms M]
#
# A pinned dev instance runs winch-probe.py as its program, which records
# every SIGWINCH with the winsize it reads; alone it repaints the whole screen
# on each one as a full-screen program does, or it runs --program (mc, htop)
# and only counts while that program paints. The window is then driven
# through Accessibility, in one System Events script so the steps land at
# their own pace rather than a process launch apart:
#
#   zoom   Window → Zoom, then Zoom again — the double-click maximise and
#          the restore, both animated by AppKit; --rounds pairs.
#   steps  grows the window by --step-points every --step-ms for --steps
#          steps and shrinks it back the same way, the shape of a drag.
#
# The time-stamped phase log and the probe's log are read back: sizes the
# program was told (SIGWINCH count, distinct grids, the peak per second),
# frames encoded during the drive with their gaps, rows owed, grid reuse,
# frames that drew almost no cells — a program's erase presented mid-redraw,
# the blink — and the CPU the process spent per frame.
#
# Accessibility: System Events needs the terminal running this script allowed
# in Privacy & Security → Accessibility; a refusal reads as no size change.
set -u
. "$(dirname "$0")/dev-instance.sh"
grid=140x36 mode=zoom program='' rounds=2 steps=40 step_points=12 step_ms=16
while [ $# -gt 0 ]; do
    case $1 in
        --grid) grid=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --program) program=$2; shift 2 ;;
        --rounds) rounds=$2; shift 2 ;;
        --steps) steps=$2; shift 2 ;;
        --step-points) step_points=$2; shift 2 ;;
        --step-ms) step_ms=$2; shift 2 ;;
        *) echo "resize-census.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
columns=${grid%x*}
rows=${grid#*x}
dir=$(ubq_dev_config "$columns" "$rows")
winch=$dir/winch.log
phase=$dir/phase.log
app=$(ubq_dev_app)
before=$(pgrep -f "$app/Contents/MacOS/Ubiquitty" | sort)
probe=("/usr/bin/python3" "$ROOT/Scripts/winch-probe.py" --log "$winch")
[ -n "$program" ] && probe+=(-- "$program")
env UBIQUITTY_HOME="$dir/home" XDG_CONFIG_HOME="$dir/config" UBIQUITTY_ADAPTIVE_FPS=1 UBIQUITTY_PHASE_LOG=1 UBIQUITTY_PERFLOG=1 TERM=xterm-256color \
    nohup "$app/Contents/MacOS/Ubiquitty" -e "${probe[@]}" 2>&1 \
    | python3 -u -c 'import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f} {line}")' > "$phase" &
sleep 3
after=$(pgrep -f "$app/Contents/MacOS/Ubiquitty" | sort)
pid=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
[ -n "$pid" ] || { echo "resize-census.sh: the instance did not start" >&2; exit 1; }

ax_size() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get size of front window" 2>/dev/null | tr -d ' '; }
read_times() { ps -p "$1" -o utime=,stime= | awk '{print $1, $2}'; }
to_seconds() { echo "$1" | awk -F'[:.]' '{ if (NF == 3) print $1 * 60 + $2 + $3 / 100; else print $1 * 3600 + $2 * 60 + $3 + $4 / 100 }'; }
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

start=$(ax_size)
w0=${start%,*}
h0=${start#*,}
[ -n "$w0" ] && [ -n "$h0" ] || { echo "resize-census.sh: could not read the window size through Accessibility" >&2; ubq_dev_stop "$pid"; exit 1; }
script=$dir/drive.applescript
{
    echo "tell application \"System Events\""
    echo "  tell (first process whose unix id is $pid)"
    if [ "$mode" = zoom ]; then
        echo "    set frontmost to true"
        echo "    delay 0.3"
        for ((r = 0; r < rounds; r++)); do
            echo "    click menu item \"Zoom\" of menu \"Window\" of menu bar 1"
            echo "    delay 1.2"
            echo "    click menu item \"Zoom\" of menu \"Window\" of menu bar 1"
            echo "    delay 1.2"
        done
    else
        delay=$(awk -v ms="$step_ms" 'BEGIN { printf "%.3f", ms / 1000 }')
        for ((i = 1; i <= steps; i++)); do
            echo "    set size of front window to {$((w0 + i * step_points)), $((h0 + i * step_points / 2))}"
            echo "    delay $delay"
        done
        for ((i = steps - 1; i >= 0; i--)); do
            echo "    set size of front window to {$((w0 + i * step_points)), $((h0 + i * step_points / 2))}"
            echo "    delay $delay"
        done
    fi
    echo "  end tell"
    echo "end tell"
} > "$script"
driven=$(grep -c "set size\|click menu item" "$script")
t0=$(read_times "$pid")
drive_start=$(now)
osascript "$script" > /dev/null 2>&1
sleep 0.6
drive_end=$(now)
t1=$(read_times "$pid")
end=$(ax_size)
ubq_dev_stop "$pid"

u0=$(to_seconds "${t0%% *}"); s0=$(to_seconds "${t0##* }")
u1=$(to_seconds "${t1%% *}"); s1=$(to_seconds "${t1##* }")
echo "mode=$mode program=${program:-probe} grid=$grid window ${w0}x${h0} -> $end, $driven window moves driven"
python3 - "$winch" "$phase" "$drive_start" "$drive_end" "$driven" "$u0" "$s0" "$u1" "$s1" <<'EOF'
import sys
winch, phase, t_start, t_end, driven, u0, s0, u1, s1 = sys.argv[1:]
t_start, t_end, driven = float(t_start), float(t_end), int(driven)
sizes = []
for line in open(winch):
    parts = line.split()
    if len(parts) >= 4 and parts[1] == "winch":
        sizes.append((float(parts[0]), parts[3]))
in_drive = [s for s in sizes if t_start - 0.2 <= s[0] <= t_end + 0.5]
distinct = []
for _, grid in in_drive:
    if not distinct or distinct[-1] != grid:
        distinct.append(grid)
print(f"program: {len(in_drive)} SIGWINCH, {len(distinct)} distinct grids ({' '.join(distinct[:6])}{' ...' if len(distinct) > 6 else ''})")
if in_drive:
    stamps = [t for t, _ in in_drive]
    burst = max(sum(1 for t in stamps if a <= t < a + 1.0) for a in stamps)
    print(f"         peak {burst} SIGWINCH in one second")
frames = []
for line in open(phase):
    parts = line.split()
    if len(parts) > 1 and parts[1] == "[phase]":
        stamp = float(parts[0])
        if t_start - 0.2 <= stamp <= t_end:
            fields = {p.split("=")[0]: p.split("=")[1] for p in parts[2:] if "=" in p}
            frames.append((stamp, fields))
# The legacy arm writes no phase line; its [perf] line carries the frames of
# each second, so those inside the drive window stand in for a frame count.
legacy_frames = 0
if not frames:
    import re
    for line in open(phase):
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith("[perf] ") and "fr " in parts[1]:
            stamp = float(parts[0])
            if t_start - 1.0 <= stamp <= t_end + 1.0:
                found = re.search(r"(\d+)fr", parts[1])
                if found:
                    legacy_frames += int(found.group(1))
gaps = sorted(round((frames[i][0] - frames[i - 1][0]) * 1000) for i in range(1, len(frames)))
def pct(values, q):
    return values[min(len(values) - 1, int(len(values) * q))] if values else 0
reused = sum(1 for _, f in frames if f.get("reused") == "1")
skipped = sum(1 for _, f in frames if f.get("rebuilt") == "skipped")
whole = sum(1 for _, f in frames if f.get("reused") == "0" and f.get("dirty", "0/1").split("/")[0] == f.get("dirty", "0/1").split("/")[1])
# Only a frame that rebuilt every row can read as cleared: a Delta builds the
# rows it owes and nothing else, so its count says nothing about the screen.
cells = [int(f["cells"]) for _, f in frames if "cells" in f and f.get("reused") == "0"]
peak = max(cells) if cells else 0
blank = sum(1 for c in cells if peak > 0 and c < peak * 0.25)
if frames:
    print(f"frames:  {len(frames)} encoded; gap ms p50={pct(gaps, 0.5)} p90={pct(gaps, 0.9)} max={gaps[-1] if gaps else 0}")
else:
    print(f"frames:  {legacy_frames} presented (the legacy arm's per-second [perf] lines around the drive)")
print(f"         {whole} rebuilt every row, {reused} loaded the retained grid, {skipped} declined as identical")
if cells:
    print(f"         {blank} of the {len(cells)} full rebuilds drew under a quarter of the peak {peak} cells (a cleared frame presented)")
# Torn: a frame whose rows carry two size markers or two divider columns.
import re
torn = 0
shifted = 0
signed = 0
for _, f in frames:
    sig = f.get("rows")
    if not sig:
        continue
    signed += 1
    runs = [(run.rsplit("*", 1)[0], int(run.rsplit("*", 1)[1])) for run in sig.split(",") if "*" in run]
    markers = {t for t, n in runs if re.match(r"^\d+x\d+$", t)}
    # Header and status rows carry dividers of their own; a tear is two
    # bodies of at least three rows that disagree.
    bodies = {t for t, n in runs if t.startswith("|") and n >= 3}
    if len(markers) > 1 or len(bodies) > 1:
        torn += 1
    # A body whose first divider is not column 0 is the wrap cascade: the
    # program drew rows for a width the grid no longer had.
    if any(t.startswith("|") and n >= 3 and not t.startswith("|0/") and t != "|0" for t, n in runs):
        shifted += 1
if signed:
    print(f"         {torn} of {signed} signed frames torn (rows from two layouts), {shifted} shifted (a wrap cascade)")
cpu = ((float(u1) - float(u0)) + (float(s1) - float(s0))) * 1000
count = len(frames) or legacy_frames
print(f"cpu:     {cpu:.0f} ms over the drive; {cpu / count if count else 0:.1f} ms per frame (user {(float(u1) - float(u0)) * 1000:.0f}, system {(float(s1) - float(s0)) * 1000:.0f})")
EOF
echo "logs: $winch $phase"
