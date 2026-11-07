#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# install-macos.sh — build the release app and install it into /Applications.
#
#   ./Scripts/install-macos.sh                  build --release, verify, install
#   ./Scripts/install-macos.sh --app PATH       install an already-built release bundle
#   ./Scripts/install-macos.sh --wait-for-quit  when Ubiquitty is running, install
#                                               the moment it quits (the waiter is
#                                               detached, so it outlives the terminal
#                                               it was started from)
#   ./Scripts/install-macos.sh --open           open the installed app afterwards
#
# A bundle is never swapped out from under a running app. The running process
# would carry on from wherever its bundle was moved to, while the identifier
# names the new bundle at /Applications, which is not running — so the next
# notification click or `open` starts a second instance with none of the
# first one's windows. When Ubiquitty is running the install stops and says so
# (exit 3), or with --wait-for-quit waits for the quit.
#
# One previous version is kept, outside /Applications, and every copy but the
# installed one is unregistered from LaunchServices, so the identifier resolves
# to exactly one bundle.
#
# Environment: UBIQUITTY_INSTALL_DIR (default /Applications) and
# UBIQUITTY_INSTALL_STATE (default ~/Library/Caches/Ubiquitty/install) place the
# install and its staged and previous copies; UBIQUITTY_LSREGISTER names the
# LaunchServices registration tool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
# shellcheck source=Scripts/release-bundle.sh
. "$ROOT/Scripts/release-bundle.sh"

INSTALL_DIR="${UBIQUITTY_INSTALL_DIR:-/Applications}"
STATE_DIR="${UBIQUITTY_INSTALL_STATE:-$HOME/Library/Caches/Ubiquitty/install}"
LSREGISTER="${UBIQUITTY_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
TARGET="$INSTALL_DIR/Ubiquitty.app"
STAGED="$STATE_DIR/staged/Ubiquitty.app"
PREVIOUS="$STATE_DIR/previous/Ubiquitty.app"

SOURCE_APP=""
IS_WAITING_FOR_QUIT=0
SHOULD_OPEN=0
IS_FROM_STAGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            shift
            [ $# -gt 0 ] || { echo "--app requires a path" >&2; exit 2; }
            SOURCE_APP="$1"
            ;;
        --wait-for-quit) IS_WAITING_FOR_QUIT=1 ;;
        --open) SHOULD_OPEN=1 ;;
        # The detached waiter's own entry: install what is already staged.
        --from-stage) IS_FROM_STAGE=1 ;;
        -h|--help) sed -n '5,28p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# The process ids running the installed app's executable, one per line.
#
# Matched on the command's first word. The path reaches awk through its
# environment rather than its arguments, so the matcher's own command line does
# not match itself.
running_processes() {
    ps -axo pid=,args= | INSTALLED_EXECUTABLE="$TARGET/Contents/MacOS/Ubiquitty" awk '
        {
            pid = $1
            $1 = ""
            sub(/^ +/, "")
            executable = ENVIRON["INSTALLED_EXECUTABLE"]
            if ($0 == executable || index($0, executable " ") == 1)
                print pid
        }'
}

# Unregisters a bundle from LaunchServices; a bundle it never saw is not an error.
unregister() {
    [ -e "$1" ] || return 0
    "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# Checks a bundle is one this script may install: release identifier, intact
# signature, the helpers it ships, and a surface that draws.
verify() {
    local app="$1"
    [ -d "$app" ] || { echo "ERROR: no app at $app" >&2; exit 1; }
    require_release_bundle "$app"
    codesign --verify --deep --strict "$app" || { echo "ERROR: $app has a missing or broken signature" >&2; exit 1; }
    [ -x "$app/Contents/Helpers/ubiquitty-host" ] || { echo "ERROR: $app bundles no ubiquitty-host" >&2; exit 1; }
    "$app/Contents/MacOS/Ubiquitty" --smoke-surface >/dev/null 2>&1 \
        || { echo "ERROR: $app failed --smoke-surface" >&2; exit 1; }
}

# Moves the staged bundle into place, keeping the replaced one as the single
# previous version.
swap_in_staged() {
    verify "$STAGED"
    mkdir -p "$INSTALL_DIR" "$(dirname "$PREVIOUS")"
    if [ -e "$TARGET" ]; then
        unregister "$PREVIOUS"
        rm -rf "$PREVIOUS"
        mv "$TARGET" "$PREVIOUS"
        unregister "$PREVIOUS"
    fi
    if ! mv "$STAGED" "$TARGET"; then
        echo "ERROR: could not move the new bundle into $TARGET; restoring the previous one" >&2
        [ -e "$PREVIOUS" ] && mv "$PREVIOUS" "$TARGET"
        exit 1
    fi
    "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
    codesign --verify --deep --strict "$TARGET"
    echo "installed $TARGET ($(bundle_identifier "$TARGET"))"
    [ -e "$PREVIOUS" ] && echo "previous version kept at $PREVIOUS (unregistered)"
    if [ "$SHOULD_OPEN" = "1" ]; then
        open "$TARGET"
    fi
}

if [ "$IS_FROM_STAGE" = "1" ]; then
    swap_in_staged
    exit 0
fi

if [ -z "$SOURCE_APP" ]; then
    # shellcheck source=Scripts/build-root.sh
    . "$CORE_ROOT/Scripts/build-root.sh"
    "$ROOT/Scripts/build-macos.sh" --release
    SOURCE_APP="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app"
fi
verify "$SOURCE_APP"

# The build directory is rebuilt by the next development build, so the verified
# bundle is copied aside, and kept out of LaunchServices while it waits.
#
# The bundle folder is made fresh and only its contents are copied: ditto
# carries a directory's own dates with it, and the build tree's bundle folder
# dates from the first build in that tree, so a copied folder reads in Finder
# as created and modified weeks before the binary inside it.
rm -rf "$(dirname "$STAGED")"
mkdir -p "$STAGED"
ditto "$SOURCE_APP/Contents" "$STAGED/Contents"
unregister "$STAGED"

running="$(running_processes)"
if [ -z "$running" ]; then
    swap_in_staged
    exit 0
fi

pids="$(echo "$running" | tr '\n' ' ' | sed 's/ $//')"
if [ "$IS_WAITING_FOR_QUIT" = "0" ]; then
    echo "Ubiquitty is running (pid $pids); nothing was installed." >&2
    echo "  The verified build is staged at $STAGED." >&2
    echo "  Quit Ubiquitty and run this again, or re-run with --wait-for-quit to install when it quits." >&2
    exit 3
fi

# A new session, so quitting the app — and with it the terminal this was
# started from — does not take the waiter down with it.
LOG="$STATE_DIR/install.log"
arguments=(--from-stage)
[ "$SHOULD_OPEN" = "1" ] && arguments+=(--open)
python3 - "$ROOT/Scripts/install-macos.sh" "$LOG" "$pids" "${arguments[@]}" <<'PYTHON'
import os
import sys

script, log, pids, *arguments = sys.argv[1:]
if os.fork():
    sys.exit(0)
os.setsid()
if os.fork():
    os._exit(0)
with open(log, "ab", buffering=0) as output:
    os.dup2(output.fileno(), 1)
    os.dup2(output.fileno(), 2)
with open(os.devnull, "rb") as nothing:
    os.dup2(nothing.fileno(), 0)
alive = " || ".join(f"kill -0 {int(pid)} 2>/dev/null" for pid in pids.split())
os.execv("/bin/bash", ["/bin/bash", "-c", f'while {alive}; do sleep 1; done; exec "$0" "$@"', script, *arguments])
PYTHON
echo "Ubiquitty is running (pid $pids); the install happens when it quits."
echo "  Log: $LOG"
