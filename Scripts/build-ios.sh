#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Bound the compile fan-out. `cmake --build -j` with no number hands ninja its
# default of cores + 2, and several checkouts may build on one machine at
# once, so the unbounded form asks for far more processes than there are cores
# and the machine stops responding. UBQ_BUILD_JOBS overrides.
BUILD_JOBS="${UBQ_BUILD_JOBS:-$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )}"

#
# build-ios.sh — build the SwiftUI app and portable Core for simulator and device.
#
#   ./Scripts/build-ios.sh                       both SDKs (DEFAULT)
#   ./Scripts/build-ios.sh --sdk iphonesimulator just the simulator
#   ./Scripts/build-ios.sh --sdk iphoneos        just the device slice
#   ./Scripts/build-ios.sh --ui-tests            also the XCUITest bundle
#   ./Scripts/build-ios.sh --debug               -O0, asserts
#   ./Scripts/build-ios.sh --clean               wipe the iOS build dirs first
#
# Both SDKs by default, because each one answers a question the other cannot.
# The simulator SDK is the one a development machine can run, and its sysroot also carries the
# host's frameworks — so a reach into something the device has no answer for
# compiles there and is caught only on the device slice, which is the arm that
# has to hold for a shipped build.
#
# Builds the SwiftUI application and the Core archive. The -all_load link probe
# catches unresolved Core symbols even when the application does not use them.
# Runtime behavior is covered separately by run-ios-smokes.sh and the UI suite.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"

BUILD_TYPE=Release
SDKS=(iphonesimulator iphoneos)
CLEAN=0
# The XCUITest bundle is off by default: it is a simulator-only artefact that
# nothing in the app links, and building it costs a swiftc invocation on every
# normal build. Scripts/run-ios-ui-tests.sh is what asks for it.
UI_TESTS=OFF

while [ $# -gt 0 ]; do
    case "$1" in
        --debug) BUILD_TYPE=Debug ;;
        --clean) CLEAN=1 ;;
        --ui-tests) UI_TESTS=ON ;;
        --sdk)
            shift
            case "${1:-}" in
                iphoneos|iphonesimulator) SDKS=("$1") ;;
                *) echo "build-ios: --sdk takes iphoneos or iphonesimulator, got '${1:-}'" >&2; exit 2 ;;
            esac
            ;;
        *) echo "build-ios: unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# An iOS SDK is not part of the Command Line Tools, so a machine with a working
# macOS build can still lack this one. Say which SDK is missing rather than
# letting CMake report a compiler that cannot find a header.
for sdk in "${SDKS[@]}"; do
    if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
        echo "build-ios: no $sdk SDK — this arm needs a full Xcode install (xcode-select -p points at $(xcode-select -p 2>/dev/null || echo 'nothing'))" >&2
        exit 1
    fi
done

GEN="Unix Makefiles"
command -v ninja >/dev/null 2>&1 && GEN="Ninja"

# shellcheck source=Scripts/build-provenance.sh
source "$ROOT/Scripts/build-provenance.sh"

for sdk in "${SDKS[@]}"; do
    BUILD="$UBQ_BUILD_ROOT/ios-$sdk"
    [ "$CLEAN" = 1 ] && rm -rf "$BUILD"
    build_provenance_warning "$ROOT" "$BUILD" "Scripts/build-ios.sh --clean"

    # CMAKE_SYSTEM_NAME is what makes this a cross build: without it CMake
    # compiles for the host and the arm answers a question about macOS while
    # being named for iOS. The sysroot is passed by NAME rather than as a
    # resolved path so the build directory survives an Xcode update.
    #
    # arm64 alone: the simulator runs arm64 on every Mac this tree is built on,
    # and x86_64 would be a slice nobody here can execute.
    #
    # UBIQUITTY_QUIC rides an override the way build-macos.sh's does. The iOS
    # branch links the QUIC client, and ubiquitty_ensure_quic_deps() cross-
    # builds ngtcp2 + AWS-LC for the SDK being targeted, into a prefix of that
    # SDK's own — a shared one would hand this link the host's macOS archives,
    # which the existence check cannot tell apart.
    #
    # OFF is a real answer here rather than a lie about the arm: it skips a
    # dependency fetch that costs minutes and a network, which is what a build
    # that only needs the simulator to draw wants.
    # The dependencies' prefix rides the same override as build-macos.sh's;
    # CMake's default is the checkout's build root. CMake appends the SDK's name
    # to whatever prefix it is given.
    cmake -B "$BUILD" -S "$ROOT" -G "$GEN" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DUBIQUITTY_FRONTEND=iOS \
        -DUBIQUITTY_QUIC="${UBIQUITTY_QUIC:-ON}" \
        ${UBIQUITTY_QUIC_PREFIX:+"-DUBIQUITTY_QUIC_PREFIX=$UBIQUITTY_QUIC_PREFIX"} \
        -DUBIQUITTY_IOS_UI_TESTS="$UI_TESTS" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    cmake --build "$BUILD" -j"$BUILD_JOBS"
    build_provenance_stamp "$ROOT" "$BUILD"

    LIB="$BUILD/libubiquitty-core-ios.a"
    [ -f "$LIB" ] || { echo "build-ios: $LIB was not produced" >&2; exit 1; }
    echo "build-ios: $sdk -> $LIB ($(lipo -info "$LIB" 2>/dev/null | sed 's/.*: //'))"
done
