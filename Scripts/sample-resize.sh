#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# sample-resize.sh — where an arm spends its time while a window zooms.
#
#     sample-resize.sh [--program CMD] [--grid COLSxROWS]
#                      [--rounds N] [--threshold N]
#
# A pinned dev instance runs the program (mc by default), `sample` takes the
# whole process at one sample per millisecond while Window → Zoom runs
# --rounds maximise-and-restore pairs through Accessibility, and the main
# thread's call-tree nodes above the threshold are listed in tree order with
# depth kept — the frame the animation is waiting on is whichever of them
# holds the main thread. No probes are on: a probe is cost.
set -u
. "$(dirname "$0")/dev-instance.sh"
program=mc grid=140x36 rounds=2 threshold=15
while [ $# -gt 0 ]; do
    case $1 in
        --program) program=$2; shift 2 ;;
        --grid) grid=$2; shift 2 ;;
        --rounds) rounds=$2; shift 2 ;;
        --threshold) threshold=$2; shift 2 ;;
        *) echo "sample-resize.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
columns=${grid%x*}
rows=${grid#*x}
dir=$(ubq_dev_config "$columns" "$rows")
pid=$(ubq_dev_launch "$dir" "$dir/app.log" UBIQUITTY_ADAPTIVE_FPS=1 -- "$program")
[ -n "$pid" ] || { echo "sample-resize.sh: the instance did not start" >&2; exit 1; }
sleep 2
script=$dir/zoom.applescript
{
    echo "tell application \"System Events\""
    echo "  tell (first process whose unix id is $pid)"
    echo "    set frontmost to true"
    echo "    delay 0.3"
    for ((r = 0; r < rounds; r++)); do
        echo "    click menu item \"Zoom\" of menu \"Window\" of menu bar 1"
        echo "    delay 1.0"
        echo "    click menu item \"Zoom\" of menu \"Window\" of menu bar 1"
        echo "    delay 1.0"
    done
    echo "  end tell"
    echo "end tell"
} > "$script"
seconds=$((rounds * 2 + 1))
out=$dir/sample.txt
sample "$pid" "$seconds" -mayDie -file "$out" > /dev/null 2>&1 &
sampler=$!
sleep 0.4
osascript "$script" > /dev/null 2>&1
wait "$sampler"
ubq_dev_stop "$pid"
echo "program=$program rounds=$rounds sampled ${seconds}s at 1 ms"
echo "--- threads ---"
grep -E "^ +[0-9]+ Thread_" "$out" | sed -E 's/^ +//' | head -8
echo "--- main thread: nodes with >= $threshold samples, idle waits excluded ---"
awk -v min="$threshold" '
    /^ +[0-9]+ Thread_/ { thread++ }
    /Binary Images:/ { exit }
    thread == 1 {
        s = $0
        gsub(/[+!:|]/, " ", s)
        n = split(s, f, " ")
        if (n > 0 && f[1] + 0 >= min && $0 !~ /Thread_|mach_msg|__workq_kernreturn|kevent|[^a-z]poll |_pthread_wqthread|start_wqthread|__psynch|__CFRunLoopServiceMachPort|__CFRunLoopRun  |_CFRunLoopRunSpecific|RunCurrentEventLoopInMode|ReceiveNextEventCommon|_BlockUntilNextEvent|_DPSBlockUntil|_DPSNextEvent|nextEventMatchingMask|_nextEventMatchingEventMask|NSApplication run|^ +[0-9]+ main |^ +[0-9]+ start /)
            print substr($0, 1, 190)
    }' "$out"
echo "sample: $out"
