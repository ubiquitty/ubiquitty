#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Bound the compile fan-out. `cmake --build -j` with no number hands ninja its
# default of cores + 2, and several checkouts may build on one machine at
# once, so the unbounded form asks for far more processes than there are cores
# and the machine stops responding. UBQ_BUILD_JOBS overrides.
BUILD_JOBS="${UBQ_BUILD_JOBS:-$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )}"

#
# build-linux-gtk.sh — build the Linux GTK4 + Vulkan frontend (ubiquitty-linux).
#
# A native Linux build (gcc on a Linux machine); cannot build on macOS. Requires GTK4
# (-dev) + the Vulkan loader/headers; lavapipe (Mesa) covers headless rendering.
#
# QUIET by default — prints only warnings/errors + the result (per-file compile
# lines go to the log, not the terminal). Full log: $UBQ_BUILD_ROOT/linux/build.log.
#
#   ./Scripts/build-linux-gtk.sh            # Debug, quiet
#   ./Scripts/build-linux-gtk.sh Release
#   VERBOSE=1 ./Scripts/build-linux-gtk.sh  # stream full output
#
# Output: $UBQ_BUILD_ROOT/linux/ubiquitty-linux
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
KIT_ROOT="${UBIQUITTY_KIT_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-kit}"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
# shellcheck source=Scripts/gate-report-lib.sh
source "$CORE_ROOT/Scripts/gate-report-lib.sh"
BUILD="$UBQ_BUILD_ROOT/linux"
BUILD_TYPE="${1:-Debug}"
LOG="$BUILD/build.log"
VERBOSE="${VERBOSE:-0}"

# Names the development package a machine lacks, where cmake would name only
# the module it could not find.
"$KIT_ROOT/Scripts/check-linux-build-prerequisites.sh"

GEN="Unix Makefiles"
command -v ninja >/dev/null 2>&1 && GEN="Ninja"
mkdir -p "$BUILD"

# Run a step: stream it when VERBOSE, else capture to LOG (surfaced only on failure).
run() {
    if [ "$VERBOSE" = "1" ]; then "$@"; else "$@" >"$LOG" 2>&1; fi
}

# UBIQUITTY_LINUX_GPU_SHADERS=OFF builds a binary that renders on the CPU only,
# for a machine without glslc. Passed on every configure, ON when unset, for the
# reason given for UBIQUITTY_PGO below.
#
# UBIQUITTY_PGO=OFF builds without the training profile (Support/pgo/README.md).
# Passed on each optimised configure, ON when unset, so an OFF left in the CMake
# cache by one run cannot outlive the run that asked for it. A Debug configure
# never reads the variable and is not handed it, so CMake has no unused variable
# to report.
PGO_ARGUMENTS=()
case "$BUILD_TYPE" in
    Release | RelWithDebInfo | MinSizeRel) PGO_ARGUMENTS=(-DUBIQUITTY_PGO="${UBIQUITTY_PGO:-ON}") ;;
esac

if ! run cmake -B "$BUILD" -S "$ROOT" -G "$GEN" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DUBIQUITTY_FRONTEND=Linux \
    "-DUBIQUITTY_CORE_SOURCE_DIR=$CORE_ROOT" "-DUBIQUITTY_KIT_SOURCE_DIR=$KIT_ROOT" \
    -DUBIQUITTY_QUIC="${UBIQUITTY_QUIC:-OFF}" \
    -DUBIQUITTY_LINUX_GPU_SHADERS="${UBIQUITTY_LINUX_GPU_SHADERS:-ON}" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    ${PGO_ARGUMENTS[@]+"${PGO_ARGUMENTS[@]}"}; then
    # gate_failed_count returns 1, and under `set -e` that would exit before the
    # log below is printed, so its status is taken here and the exit is explicit.
    gate_failed_count "build-linux-gtk" 1 "step(s) failed: cmake configure" || true
    # A verdict with no evidence costs a second run to learn anything. When the
    # captured log is empty or absent the step still failed, so say which, rather
    # than printing nothing and leaving the two cases indistinguishable.
    if [ "$VERBOSE" != "1" ]; then
        if [ -s "$LOG" ]; then
            tail -40 "$LOG"
        else
            echo "  (no output captured in $LOG — rerun with VERBOSE=1 to stream the step)" >&2
        fi
    fi
    exit 1
fi

# clangd finds the configure's database through the checkout's
# compile_commands.json; Scripts/build-root.sh says when that name is claimed.
ubq_link_compile_database "$BUILD" "$ROOT"

# What the build did about the training profile, and every warning the
# configure raised, on the way past. The build step below writes its own output
# over this log, so a Release that cannot use the profile, or a configure that
# leaves out a backend, would say so into a file nobody opens, and an arm would
# ship unprofiled without anyone reading a line about it. A CMake warning
# is its heading line and the indented lines under it.
if [ "$VERBOSE" != "1" ]; then
    grep -E '^-- PGO:' "$LOG" || true
    awk '/^CMake (Deprecation )?Warning/ { shown = 1; print; next }
         shown && (/^[[:space:]]/ || /^$/) { print; next }
         { shown = 0 }' "$LOG" >&2
fi

if run cmake --build "$BUILD" -j"$BUILD_JOBS"; then
    # Surface warnings (the user wants those), nothing else, then the result.
    [ "$VERBOSE" = "1" ] || grep -iE 'warning|warn:' "$LOG" || true
    # Freshness stamp, for the same reason build-core-snapshot.sh carries one:
    # the snapshot arm's staleness guard compares this binary's mtime against
    # source mtimes, and a checkout or rebase re-dates sources while ccache
    # hands ninja identical objects and the link is skipped. A successful pass
    # proves the binary matches the sources whether or not it relinked, so the
    # stamp makes the mtime mean "verified current by this run".
    touch "$BUILD/ubiquitty-linux"
    echo "Built: $BUILD/ubiquitty-linux"
else
    gate_failed_count "build-linux-gtk" 1 "step(s) failed: ninja build" || true
    if [ "$VERBOSE" != "1" ]; then
        matches="$(grep -iE 'error|warning|fatal|undefined reference|FAILED|ld returned' "$LOG" | head -60 || true)"
        if [ -n "$matches" ]; then echo "$matches"; else tail -60 "$LOG"; fi
    fi
    exit 1
fi
