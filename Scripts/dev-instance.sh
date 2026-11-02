#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# dev-instance.sh — launch this checkout's build pinned to a grid, with its own
# config and home, for shell callers. Sourced, not run:
#
#     . "$(dirname "$0")/dev-instance.sh"
#     dir=$(ubq_dev_config 140 36)
#     pid=$(ubq_dev_launch "$dir" "$dir/app.log" UBIQUITTY_PHASE_LOG=1 -- /bin/zsh -l)
#     ...
#     ubq_dev_stop "$pid"
#
# The config is written fresh under a temporary directory and the home is empty,
# so an instance answers for the build and the pin, never for what the
# developer's own ~/.config says today. The pin goes in as [window]
# initial_columns / initial_rows; everything else is the shipped default.
# The launched pid is the one process that appeared
# while launching, read back rather than guessed.
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/Scripts/build-root.sh"

ubq_dev_app() { # -> the app bundle this checkout builds, or the one UBQ_DEV_APP names
    # The override is for a control: a pair of instances from two builds — this
    # checkout's and, say, origin/main's in its own build directory — is how an
    # arm ratio is read against a renderer that is known to draw.
    printf '%s' "${UBQ_DEV_APP:-$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app}"
}

ubq_dev_config() { # <columns> <rows> [font-family [size-points]] -> a fresh directory holding config/ and home/
    local columns=$1 rows=$2 family=${3:-} size=${4:-} dir
    dir=$(mktemp -d /tmp/ubq-dev-XXXXXX)
    mkdir -p "$dir/config/ubiquitty" "$dir/home"
    printf '[window]\ninitial_columns = %s\ninitial_rows = %s\n' \
        "$columns" "$rows" > "$dir/config/ubiquitty/config.toml"
    # The face is part of the pin when asked for: a texture-healing family
    # shapes every row where a plain one shapes none, and an instance opened
    # to look at that cost must name the face rather than inherit one.
    if [ -n "$family" ]; then
        printf '\n[font]\nfamily = "%s"\n' "$family" >> "$dir/config/ubiquitty/config.toml"
        [ -n "$size" ] && printf 'size = %s\n' "$size" >> "$dir/config/ubiquitty/config.toml"
    fi
    printf '%s' "$dir"
}

ubq_dev_launch() { # <devdir|""> <logfile> [VAR=value ...] -- [command ...] -> the new pid
    # An empty devdir launches on the developer's own config and home — the
    # shape a person testing by hand wants, where the pinned one answers for
    # the build alone.
    local dir=$1 log=$2
    shift 2
    local -a pairs=()
    [ -n "$dir" ] && pairs+=("UBIQUITTY_HOME=$dir/home" "XDG_CONFIG_HOME=$dir/config")
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        pairs+=("$1")
        shift
    done
    [ "${1:-}" = "--" ] && shift
    local app before after
    app=$(ubq_dev_app)
    before=$(pgrep -f "$app/Contents/MacOS/Ubiquitty" | sort)
    if [ $# -gt 0 ]; then
        env ${pairs[@]+"${pairs[@]}"} nohup "$app/Contents/MacOS/Ubiquitty" -e "$@" > "$log" 2>&1 &
    else
        env ${pairs[@]+"${pairs[@]}"} nohup "$app/Contents/MacOS/Ubiquitty" > "$log" 2>&1 &
    fi
    sleep 2
    after=$(pgrep -f "$app/Contents/MacOS/Ubiquitty" | sort)
    comm -13 <(echo "$before") <(echo "$after") | head -1
}

ubq_dev_front() { # <pid> — bring the instance's window to the front, on the main display
    # A new window opens on the display holding the pointer. With two
    # monitors a bench or a recording lands wherever the mouse was; {0, 0} is
    # the main display's origin in System Events' coordinates.
    osascript > /dev/null 2>&1 <<EOF
tell application "System Events"
    set proc to first process whose unix id is $1
    set frontmost of proc to true
    set position of first window of proc to {0, 0}
end tell
EOF
}

ubq_dev_stop() { # <pid>
    [ -n "${1:-}" ] && kill "$1" 2>/dev/null
    sleep 1
}

ubq_dev_stream_path() { # <name-or-path> <grid> <streams-dir> -> the stream file
    case $1 in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s_%s.stream' "$3" "$1" "$2" ;;
    esac
}
