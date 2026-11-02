#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# pty-size-probe.sh — what a program launched in a pinned window reads as its
# terminal size, straight from the PTY.
#
#     pty-size-probe.sh [--grid COLSxROWS]
#
# Prints `stty size` and `tput cols` as the child saw them and exits non-zero
# unless they name the pinned grid. A window that opens exactly at its grid
# takes no resize, and the winsize once rode the first resize: programs read
# 0x0 and laid out for 80 columns. This is the check that keeps that closed.
set -u
. "$(dirname "$0")/dev-instance.sh"
grid=140x36
while [ $# -gt 0 ]; do
    case $1 in
        --grid) grid=$2; shift 2 ;;
        *) echo "pty-size-probe.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
columns=${grid%x*}
rows=${grid#*x}
dir=$(ubq_dev_config "$columns" "$rows")
report=$dir/size.txt
pid=$(ubq_dev_launch "$dir" "$dir/app.log" -- /bin/sh -c "stty size > '$report'; tput cols >> '$report'; sleep 2")
sleep 3
ubq_dev_stop "$pid"
size=$(sed -n 1p "$report" 2>/dev/null)
cols=$(sed -n 2p "$report" 2>/dev/null)
echo "pinned=$grid  stty size: ${size:-<none>}  tput cols: ${cols:-<none>}  dir=$dir"
[ "$size" = "$rows $columns" ] && [ "$cols" = "$columns" ]
