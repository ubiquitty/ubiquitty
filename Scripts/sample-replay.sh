#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# sample-replay.sh — where a pinned instance spends its CPU on a recorded
# stream: `sample` over every thread, then the call-tree nodes that carry at
# least a threshold of samples, in tree order with depth kept.
#
#     sample-replay.sh [--stream NAME|PATH] [--seconds N]
#                      [--threshold N] [--grid COLSxROWS] [--streams DIR]
#
# No probes are on: a probe is cost, and this measures the build as shipped.
# `sample` runs at one sample per millisecond, so a node's count over N seconds
# reads as milliseconds per N seconds; a thread's idle wait (mach_msg, poll,
# kevent, workq) carries the total and is where the rest of the samples are.
set -u
. "$(dirname "$0")/dev-instance.sh"
stream=agent_tmux seconds=10 threshold=20 grid=140x36 streams=/tmp/ubqstreams
while [ $# -gt 0 ]; do
    case $1 in
        --stream) stream=$2; shift 2 ;;
        --seconds) seconds=$2; shift 2 ;;
        --threshold) threshold=$2; shift 2 ;;
        --grid) grid=$2; shift 2 ;;
        --streams) streams=$2; shift 2 ;;
        *) echo "sample-replay.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
columns=${grid%x*}
rows=${grid#*x}
path=$(ubq_dev_stream_path "$stream" "$grid" "$streams")
[ -f "$path" ] || { echo "sample-replay.sh: no stream at $path" >&2; exit 1; }
dir=$(ubq_dev_config "$columns" "$rows")
pid=$(ubq_dev_launch "$dir" "$dir/app.log" UBIQUITTY_ADAPTIVE_FPS=1 \
    -- /usr/bin/python3 "$CORE_ROOT/Scripts/replay-stream.py" --stream "$path" --counter "$dir/bytes")
[ -n "$pid" ] || { echo "sample-replay.sh: the instance did not start" >&2; exit 1; }
sleep 6
out=$dir/sample.txt
sample "$pid" "$seconds" -mayDie -file "$out" > /dev/null 2>&1
ubq_dev_stop "$pid"
echo "stream=$path seconds=$seconds threshold=$threshold"
echo "--- threads ---"
grep -E "^ +[0-9]+ Thread_" "$out" | sed -E 's/^ +//' | head -12
echo "--- nodes with >= $threshold samples (idle waits excluded) ---"
awk -v min="$threshold" '
    /Binary Images:/ { exit }
    {
        s = $0
        gsub(/[+!:|]/, " ", s)
        n = split(s, f, " ")
        if (n > 0 && f[1] + 0 >= min && $0 !~ /Thread_|mach_msg|__workq_kernreturn|kevent|[^a-z]poll |_pthread_wqthread|start_wqthread|__psynch/)
            print substr($0, 1, 170)
    }' "$out"
echo "sample: $out"
