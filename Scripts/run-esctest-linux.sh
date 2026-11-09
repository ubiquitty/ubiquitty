#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-esctest-linux.sh — run the esctest2 conformance suite against the GTK build.
#
# esctest2 drives the terminal over a PTY and reads the screen back with
# DECRQCRA, so it verifies rendered output rather than dispatch-table presence,
# and it must run INSIDE the terminal under test. The GTK binary needs a display
# to open a window at all, so the whole thing runs under Xvfb in the same
# container that builds it.
#
# Usage:
#   ./Scripts/run-esctest-linux.sh                  the whole suite
#   ./Scripts/run-esctest-linux.sh --include DECSET a regex over test NAMES
#   ./Scripts/run-esctest-linux.sh --allow-clipboard-read  use an isolated read-only grant
#   ./Scripts/run-esctest-linux.sh --native         run here, not in run-linux.sh's container
#   UBIQUITTY_ESCTEST=~/src/esctest2 ./Scripts/run-esctest-linux.sh
#
# The suite is mounted read-only at /esctest2 by run-linux.sh when a checkout is
# present. Results land in build/linux-container/esctest-linux.log, which the
# host reads directly — the container's /tmp does not survive the run.
#
# --native runs the same steps on this machine, against the GTK build
# Scripts/build-linux-gtk.sh leaves in $UBQ_BUILD_ROOT/linux, for a machine or a
# CI image that already carries GTK, Vulkan and Xvfb: the Linux CI battery runs
# inside such an image, where a second container would be a second image build.
# The results land in the same file.
#
# There is no window manager under Xvfb, so the XTWINOPS cases that ask one to
# iconify or move a window report the request as unperformed. Those are listed
# in Tests/Esctest/known-failing-linux-container.txt as what they are, rather
# than compared away.
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
esctestPath="${UBIQUITTY_ESCTEST:-$HOME/Projects/esctest2}"

if [ ! -f "$esctestPath/esctest/esctest.py" ]; then
    echo "run-esctest-linux: no esctest2 checkout at $esctestPath" >&2
    echo "  Clone it, or point UBIQUITTY_ESCTEST at one." >&2
    exit 2
fi

allowsClipboardRead=0
isNative=0
extraArgs=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --native) isNative=1; shift ;;
        --allow-clipboard-read) allowsClipboardRead=1; shift ;;
        --allow-clipboard-read=*) echo "--allow-clipboard-read takes no value" >&2; exit 2 ;;
        --) shift; extraArgs+=("$@"); break ;;
        *) extraArgs+=("$1"); shift ;;
    esac
done
unset UBIQUITTY_UNATTENDED

# The container's build directory is a separate mount (build/linux-container),
# because a CMake cache records the absolute path it was configured at and the
# bind mount would otherwise give one tree two of them. So the binary the
# container calls /src/build/linux/… is this, read from the host. A native run
# reads build-linux-gtk.sh's own tree.
if [[ "$isNative" = 1 ]]; then
    binary="$UBQ_BUILD_ROOT/linux/ubiquitty-linux"
    buildHint="./Scripts/build-linux-gtk.sh Release"
else
    binary="$UBQ_BUILD_ROOT/linux-container/linux/ubiquitty-linux"
    buildHint="./Scripts/run-linux.sh"
fi
if [ ! -x "$binary" ]; then
    echo "run-esctest-linux: no GTK build at $binary. Run $buildHint first." >&2
    exit 2
fi

mkdir -p "$UBQ_BUILD_ROOT/linux-container"
log="$UBQ_BUILD_ROOT/linux-container/esctest-linux.log"
rm -f "$log"
testConfiguration=''
if [[ "$allowsClipboardRead" = 1 ]]; then
    testConfigRoot="$(mktemp -d "$UBQ_BUILD_ROOT/linux-container/esctest-config.XXXXXX")"
    cp "$ROOT/Tests/Esctest/clipboard-read.toml" "$testConfigRoot/config.toml"
    if [[ "$isNative" = 1 ]]; then
        testConfiguration="$testConfigRoot/config.toml"
    else
        testConfiguration="/src/build/$(basename "$testConfigRoot")/config.toml"
    fi
fi
echo "test-configuration: ${testConfiguration:-(none; normal user configuration)}" \
    | tee "$UBQ_BUILD_ROOT/linux-container/esctest-linux-provenance.txt"

# The inner script is written out rather than spliced into a `sh -c` string: the
# suite's own arguments carry quotes, and nesting them inside the container
# command is what turns a bad --include into a shell error about an unbound
# variable rather than a message about the suite.
runner="$UBQ_BUILD_ROOT/linux-container/run-esctest-inner.sh"
mkdir -p "$(dirname "$runner")"
cat > "$runner" <<'INNER'
#!/bin/sh
set -eu
# The binary, the suite and where the result goes, as the container mounts
# them unless the caller names its own.
binary="${ESC_BINARY:-/src/build/linux/ubiquitty-linux}"
suite="${ESC_SUITE:-/esctest2}"
result="${ESC_RESULT:-/src/build/esctest-linux.log}"
work="$(mktemp -d "${TMPDIR:-/tmp}/esctest-linux.XXXXXX")"
suiteLog="$work/esctest-linux.log"
# Xvfb picks a free display and writes its number once it accepts clients, so
# a machine already running one is not taken over and nothing has to guess
# how long a start takes. A display that never comes up fails the launch with
# a message about the display rather than about the suite.
Xvfb -displayfd 3 -screen 0 1280x800x24 3>"$work/display" >/dev/null 2>&1 &
xvfbPid=$!
i=0
while [ ! -s "$work/display" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
[ -s "$work/display" ] || { kill "$xvfbPid" 2>/dev/null || true; echo "run-esctest-linux: Xvfb did not start" >&2; exit 1; }
export DISPLAY=":$(cat "$work/display")" GDK_BACKEND=x11
# The suite reads the screen back with DECRQCRA, from the terminal and not from
# pixels, so GTK's compositor has no part in the verdict. Under Xvfb its GL
# renderer runs on llvmpipe, which can crash the process mid-suite (Mesa
# 26.2's lp_rast_shade_quads_mask_sample); cairo draws the same window with no
# GL driver at all.
export GSK_RENDERER=cairo
unset UBIQUITTY_UNATTENDED
set --
if [ -n "$ESC_TEST_CONFIG" ]; then
    set -- --config "$ESC_TEST_CONFIG"
fi
# The child inherits none of this shell's directory — it starts in the home the
# runtime gives it — so the cd belongs inside the command the terminal runs, and
# esctest imports its own modules by relative name.
timeout 1800 "$binary" "$@" -e sh -c \
    "cd '$suite/esctest' && exec python3 ./esctest.py --expected-terminal=xterm --logfile='$suiteLog' --no-print-logs $ESC_EXTRA" \
    >/dev/null 2>&1 || true
kill "$xvfbPid" 2>/dev/null || true
# The suite's exit status is not the verdict: it exits 0 with tests failed, and
# it exits 0 when an --include matches no test at all and writes no log. The log
# is what discriminates, the same way the macOS runner uses it.
[ -s "$suiteLog" ] || { echo "run-esctest-linux: the suite wrote no log — it never started" >&2; exit 1; }
cp "$suiteLog" "$result"
rm -rf "$work"
INNER
chmod +x "$runner"

if [[ "$isNative" = 1 ]]; then
    env "ESC_EXTRA=${extraArgs[*]:-}" "ESC_TEST_CONFIG=$testConfiguration" \
        "ESC_BINARY=$binary" "ESC_SUITE=$esctestPath" "ESC_RESULT=$log" sh "$runner"
else
    ESC_EXTRA="${extraArgs[*]:-}" UBIQUITTY_LINUX_ROOT="$ROOT" "$CORE_ROOT/Scripts/run-linux.sh" \
        env "ESC_EXTRA=${extraArgs[*]:-}" "ESC_TEST_CONFIG=$testConfiguration" sh /src/build/run-esctest-inner.sh
fi

if [ ! -s "$log" ]; then
    echo "run-esctest-linux: no results at $log" >&2
    exit 1
fi

echo
grep -E '\*\*\*.*tests passed' "$log" || true
echo "log: $log"
