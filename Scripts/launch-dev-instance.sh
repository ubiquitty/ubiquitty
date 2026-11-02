#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# launch-dev-instance.sh — a window of this checkout's build for a person to
# look at: pinned to a grid, its own config and home, the debugging switches
# by flag.
#
#     launch-dev-instance.sh [--grid COLSxROWS]
#                            [--font FAMILY] [--font-size POINTS]
#                            [--no-adaptive] [--perflog] [--hud] [--phase-log]
#                            [--own-config] [--app BUNDLE] [--main-display]
#                            [--log FILE] [-- command ...]
#
# Without a command the shell from the shipped default runs. The adaptive frame
# drive is the shipped default, so --no-adaptive holds the link continuous.
# --perflog turns on per-frame logging, and --phase-log stamps each stderr line with a monotonic
# second so a frame sequence — a drag, a zoom — can be read back with its gaps.
# --own-config launches on the developer's ~/.config and home instead of a
# fresh pin, for testing by hand. --app names another bundle —
# a build of origin/main in its own build directory is the control a ratio is
# read against. --main-display places the window on the main display rather
# than the one holding the pointer. Prints the pid and the directory the config
# and log live in.
set -u
. "$(dirname "$0")/dev-instance.sh"
grid=140x36 family='' size='' adaptive='' perf='' hud='' phase='' own='' front='' log=''
while [ $# -gt 0 ]; do
    case $1 in
        --grid) grid=$2; shift 2 ;;
        --font) family=$2; shift 2 ;;
        --font-size) size=$2; shift 2 ;;
        --adaptive) adaptive=1; shift ;;
        --no-adaptive) adaptive=0; shift ;;
        --perflog) perf=1; shift ;;
        --hud) hud=1; shift ;;
        --phase-log) phase=1; shift ;;
        --own-config) own=1; shift ;;
        --app) export UBQ_DEV_APP=$2; shift 2 ;;
        --main-display) front=1; shift ;;
        --log) log=$2; shift 2 ;;
        --) shift; break ;;
        *) echo "launch-dev-instance.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
columns=${grid%x*}
rows=${grid#*x}
if [ -n "$own" ]; then
    # No pin: the log still needs a home of its own.
    dir=''
    [ -n "$log" ] || log=$(mktemp -d /tmp/ubq-dev-XXXXXX)/app.log
else
    dir=$(ubq_dev_config "$columns" "$rows" "$family" "$size")
    [ -n "$log" ] || log=$dir/app.log
fi
pairs=()
[ -n "$adaptive" ] && pairs+=(UBIQUITTY_ADAPTIVE_FPS="$adaptive")
[ -n "$perf" ] && pairs+=(UBIQUITTY_PERFLOG=1)
[ -n "$hud" ] && pairs+=(MTL_HUD_ENABLED=1)
[ -n "$phase" ] && pairs+=(UBIQUITTY_PHASE_LOG=1)
if [ -n "$phase" ]; then
    # Stamped through a pipe rather than by the app: the log is a debugging
    # instrument and the app's line is left as it is.
    app=$(ubq_dev_app)
    [ -n "$dir" ] && pairs+=(UBIQUITTY_HOME="$dir/home" XDG_CONFIG_HOME="$dir/config")
    before=$(pgrep -f "$app/Contents/MacOS/Ubiquitty" | sort)
    env ${pairs[@]+"${pairs[@]}"} nohup "$app/Contents/MacOS/Ubiquitty" ${1+-e "$@"} 2>&1 \
        | python3 -u -c 'import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.monotonic():.3f} {line}")' > "$log" &
    sleep 2
    after=$(pgrep -f "$app/Contents/MacOS/Ubiquitty" | sort)
    pid=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
else
    pid=$(ubq_dev_launch "$dir" "$log" ${pairs[@]+"${pairs[@]}"} -- "$@")
fi
[ -n "$pid" ] || { echo "launch-dev-instance.sh: the instance did not start" >&2; exit 1; }
[ -n "$front" ] && ubq_dev_front "$pid"
if [ -n "$own" ]; then
    pin="own-config"
else
    # Quoted: the face rides the same word as the grid, and unquoted the space
    # in front of it would split the line into a second assignment.
    pin="$grid${family:+ font=$family}"
fi
echo "pid=$pid adaptive=${adaptive:-default} pin=$pin app=$(ubq_dev_app) log=$log"
