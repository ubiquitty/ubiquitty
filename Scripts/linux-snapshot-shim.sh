#!/bin/sh
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Scripts/linux-snapshot-shim.sh — the Linux renderer, callable from a Mac.
#
# The frontend already speaks the snapshot driver's interface: `--snapshot` with
# a grid, a config and a feed is a mode it has. What it cannot do on this host
# is run — it is an ELF, and the driver executes the program it is given. So the
# arguments pass through untouched and the binary runs inside the container that
# built it.
#
# Point the driver at it with --linux-binary, or UBIQUITTY_LINUX_BIN.
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
# One binary, two spellings. run-linux.sh mounts build/linux-container over
# /src/build, so a path is not the same file inside the container and out: the
# two below name one artefact. Spelled once, the shim checks a file the host can
# see and runs one the container built somewhere else, and the render succeeds
# against a binary no check ever looked at.
CONTAINER_BINARY=build/linux/ubiquitty-linux
# The host side lives in the external build root, outside the checkout, which
# is where run-linux.sh mounts the container's /src/build from.
BUILD_ROOT=$(python3 "$ROOT/Scripts/build_root.py" "$ROOT")
HOST_BINARY=$BUILD_ROOT/linux-container/linux/ubiquitty-linux

# The driver asks which binary this stands for, so its freshness and provenance
# guards measure the ELF rather than this script. Answered before the build
# check below: the answer is which path it would be, and a caller asking that
# has not asked to render anything.
if [ "${1:-}" = "--print-render-binary" ]; then
    printf '%s\n' "$HOST_BINARY"
    exit 0
fi

if [ ! -x "$HOST_BINARY" ]; then
    echo "linux-snapshot-shim: $HOST_BINARY is not built." >&2
    echo "  ./Scripts/run-linux.sh sh -c 'cmake -S . -B build/linux -G Ninja \\" >&2
    echo "    -DUBIQUITTY_FRONTEND=Linux -DCMAKE_BUILD_TYPE=Release && \\" >&2
    echo "    ninja -C build/linux ubiquitty-linux'" >&2
    exit 2
fi

# Host paths are what the driver knows; /src is where the repository is mounted.
# A path outside the repository is left alone, so it fails in the container
# rather than silently naming a different file.
rewrite() {
    case "$1" in
        "$ROOT"/*) printf '/src/%s' "${1#"$ROOT"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The staging path is the driver's output moved inside the mount. The driver
# writes to its own temporary file, which is outside the repository and so
# outside what the container can see: written there, the PNG lands in the
# container's filesystem and vanishes with it.
#
# Not under build/, which run-linux.sh gives the container as its own so a
# container object file never lands in a host tree. A file written to /src/build
# inside is invisible outside — the render reports success and the caller finds
# nothing.
# A fresh name per run, and removed before the render rather than only after it.
# A pid is not a fresh name, because pids recycle: a run whose render fails
# leaves its file behind, and a later run that draws nothing finds one already
# sitting there and moves it. The driver then compares a previous case's image
# and reports a difference nobody can attribute, on an arm that passes when it
# is asked again.
#
# mktemp because uniqueness should not depend on the process table. The Xs end
# the template: BSD mktemp substitutes only a trailing run of them, and given
# `-XXXXXX.png` it hands back the template unexpanded — a fixed name, which is
# the bug this is here to remove. The extension is appended after.
#
# The file mktemp creates is removed straight away: the check below reads "did
# the render write this", and an empty file left in place answers yes.
STAGED_BASE=$(mktemp "$ROOT/Tests/Snapshots/.shim-snapshot-XXXXXX")
rm -f "$STAGED_BASE"
STAGED_ABSOLUTE="$STAGED_BASE.png"
STAGED="Tests/Snapshots/${STAGED_ABSOLUTE##*/}"

# The fontconfig the container renders with, staged inside the mount for the
# same reason the output is: the container sees the repository and nothing of
# the host's temporary directories.
#
# Two things the container would otherwise get wrong, both silent:
#
# The runner points FONTCONFIG_FILE at a host temporary file that registers
# Tests/Snapshots/fixtures/fonts. Neither the variable nor that path reaches the
# container, so a case naming a fixture face renders in whatever fontconfig
# substitutes — a different face, and a frame that differs from the golden by a
# glyph shape nobody will attribute to the environment. The runner's file is
# carried in with its repository paths moved under /src and its host cache
# directory replaced by one the container can write.
#
# The goldens are drawn with grayscale antialiasing and no LCD filter. The
# image's Ubuntu fontconfig ships 10-sub-pixel-rgb.conf and
# 11-lcdfilter-default.conf, so Pango draws RGB fringes into every proportional
# run. Assigned after the system include, in both the pattern and font phases,
# because a later assignment wins in either and the Ubuntu rule lives in the
# system include.
STAGED_FONTCONFIG_BASE=$(mktemp "$ROOT/Tests/Snapshots/.shim-fontconfig-XXXXXX")
rm -f "$STAGED_FONTCONFIG_BASE"
STAGED_FONTCONFIG_ABSOLUTE="$STAGED_FONTCONFIG_BASE.conf"
STAGED_FONTCONFIG="Tests/Snapshots/${STAGED_FONTCONFIG_ABSOLUTE##*/}"
trap 'rm -f "$STAGED_BASE" "$STAGED_ABSOLUTE" "$STAGED_FONTCONFIG_BASE" "$STAGED_FONTCONFIG_ABSOLUTE"' EXIT
{
    if [ -n "${FONTCONFIG_FILE:-}" ] && [ -f "$FONTCONFIG_FILE" ]; then
        sed -e "s|$ROOT/|/src/|g" \
            -e 's|<cachedir>[^<]*</cachedir>|<cachedir>/tmp/ubiquitty-fontconfig-cache</cachedir>|' \
            -e '/<\/fontconfig>/d' "$FONTCONFIG_FILE"
    else
        printf '%s\n' \
            '<?xml version="1.0"?>' \
            '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">' \
            '<fontconfig>' \
            '  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>' \
            '  <cachedir>/tmp/ubiquitty-fontconfig-cache</cachedir>'
    fi
    for target in pattern font; do
        printf '%s\n' \
            "  <match target=\"$target\">" \
            '    <edit name="rgba" mode="assign"><const>none</const></edit>' \
            '    <edit name="lcdfilter" mode="assign"><const>lcdnone</const></edit>' \
            '  </match>'
    done
    printf '%s\n' '</fontconfig>'
} > "$STAGED_FONTCONFIG_ABSOLUTE"

# Rebuilt as positional parameters, never as a string. A feed is one argument
# that contains newlines, and a command line assembled by quoting into a string
# for `sh -c` breaks at every one of them: the frontend gets the first line, the
# rest become commands. Positionally there is nothing to quote and nothing to
# split.
#
# --snapshot goes first. The frontend reads its mode from the first argument, so
# a --snapshot appended after the grid leaves --snapshot-backend in the mode
# position: nothing matches, no render runs, and the failure names the missing
# file rather than the misplaced flag.
OUTPUT=""
set -- "$@" --end-of-driver-arguments
while [ "$1" != "--end-of-driver-arguments" ]; do
    case "$1" in
        --snapshot) OUTPUT=$2; shift 2 ;;
        --config|--feed-file)
            option=$1
            value=$(rewrite "$2")
            shift 2
            set -- "$@" "$option" "$value" ;;
        *)
            # Any other argument under the repository is a path the container
            # sees under /src: a frames case's --also-snapshot targets, the
            # runner's temporaries, a feed file named by a case. Only those go
            # through the rewrite: a command substitution drops the trailing
            # newlines of what it returns, and a feed passed as one argument
            # ends in one — rewritten, it lost its last line feed and the
            # cursor sat a row above where every other arm left it.
            case "$1" in
                "$ROOT"/*) option=$(rewrite "$1") ;;
                *) option=$1 ;;
            esac
            shift
            set -- "$@" "$option" ;;
    esac
done
shift # the marker

if [ -z "$OUTPUT" ]; then
    echo "linux-snapshot-shim: no --snapshot output path" >&2
    exit 3
fi

# xvfb because the frontend opens a display even to render headlessly and the
# container has no session. The filter drops Mesa's driver-probe noise, which
# every container here emits for having no GPU; left in, each run reads as a
# failure.
#
# No `exec`. Replacing the shell makes xvfb-run the container's PID 1, where it
# waits on an Xvfb it cannot reap and the render never returns — a hang, not an
# error, so the caller's only symptom is a timeout.
# shellcheck disable=SC2016 # $0/$@ are the inner shell's, expanded in the container.
# The render's own words are kept: the filter drops the display server's
# noise, and what remains is appended to UBIQUITTY_SHIM_LOG when that names a
# file, and printed with the refusal below when no frame came back. A failure
# whose only record is "no file" is a failure nobody can read.
RENDER_OUTPUT=$("$ROOT/Scripts/run-linux.sh" sh -c \
    'fontconfig=$0; binary=$1; shift
     FONTCONFIG_FILE=$fontconfig xvfb-run -a "$binary" "$@" 2>&1 | grep -viE "Gdk-WARNING|powervr|drm devices|Loader Message" || true' \
    "/src/$STAGED_FONTCONFIG" "./$CONTAINER_BINARY" --snapshot "/src/$STAGED" "$@" 2>&1) || true
if [ -n "${UBIQUITTY_SHIM_LOG:-}" ]; then
    printf '%s\n--\n' "$RENDER_OUTPUT" >> "$UBIQUITTY_SHIM_LOG"
fi
# The runner reads the render-path marker off this shim's stdout, so the
# captured words go back out whole.
printf '%s\n' "$RENDER_OUTPUT"

# The container's write reaches the host through the bind mount a moment after
# the container returns; under a run of hundreds of renders the file is often
# not there yet on the first look, and a frame the render wrote then reads as
# one it did not. Up to two seconds, in tenths.
waited=0
while [ ! -f "$ROOT/$STAGED" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ ! -f "$ROOT/$STAGED" ]; then
    echo "linux-snapshot-shim: the render produced no file at $STAGED" >&2
    printf '%s\n' "$RENDER_OUTPUT" >&2
    exit 4
fi
mv "$ROOT/$STAGED" "$OUTPUT"
