#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-ios-sync-conformance.sh — run the Sync conformance tests as iOS binaries,
# on a simulator, against the iOS Core archive.
#
#   ./Scripts/run-ios-sync-conformance.sh
#
# Exit 0 every test passed, 1 one failed, 2 the run could not be set up.
#
# Why this exists
#
# "The phone speaks the same protocol as the desktop" is easy to assert and hard
# to mean. Both arms compile the same Source/Core/Protocol/Sync sources, so the
# claim looks true by construction — but "same source" is not "same bytes". A
# frame's encoding depends on the target: type widths, struct layout, enum
# underlying types and endianness are all properties of the ABI the source is
# compiled for, not of the source. Reading the code cannot tell you the phone
# emits the same bytes; running its own build can.
#
# So this compiles the existing conformance tests for arm64-apple-ios-simulator,
# links them against libubiquitty-core-ios.a — the archive the app itself
# carries — and runs them on the simulator.
#
# No test is copied or reimplemented here. A second fixture would drift
# from the first, and then the two arms could disagree while both passed their
# own copy — which is the exact failure this is meant to exclude.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
KIT_ROOT="${UBIQUITTY_KIT_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-kit}"
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"

BUILD="$UBQ_BUILD_ROOT/ios-iphonesimulator"
STAGE="$BUILD/sync-conformance"
# The device this checkout owns, booted for this run and shut down when it
# ends; see Scripts/ios-simulator.sh.
# shellcheck source=Scripts/ios-simulator.sh
. "$KIT_ROOT/Scripts/ios-simulator.sh"
DEVICE_NAME="$(ubq_ios_device_name)"
ARCHIVE="$BUILD/libubiquitty-core-ios.a"

# The conformance set: the tests that judge the WIRE rather than the model. A
# test that only round-trips would pass on any self-consistent build.
#
# test_sync_wire_fingerprint is excluded. It pins a digest over a corpus that includes
# HelloAck's buildFlags, and localHostBuildFlags() resolves __OPTIMIZE__ and
# NDEBUG in whichever binary encodes — so the digest is a property of the BUILD
# TYPE, not of the wire. The repo's own test tree refuses to configure in
# anything but Debug for that reason; the iOS app is Release, and the two can
# never agree.
#
# Measured rather than assumed, because "iOS speaks a different protocol" is
# exactly the alarm this lane exists to raise and a false one would be worse than
# none. Dumping the encoded corpus from both builds shows 92 bytes identical
# except one:
#
#   host  ... 5634120000000000000202070000006c73 ...
#   iOS   ... 5634120000000000000102070000006c73 ...
#                              ^^ 0x02 AssertionsEnabled vs 0x01 Optimised
#
# One byte, and it is the field the struct's own comment calls decode-only —
# "the encoder fills it from the binary it is running in". Every other byte of
# every frame matches. The phone encodes the desktop's wire.
#
# Covering it means a fingerprint that excludes build-dependent fields,
# which is a change to the test rather than to this lane.
TESTS=(
    Tests/Core/Protocol/Sync/test_sync_frame_catalog.cpp
    Tests/Core/Protocol/Sync/test_sync_wire_refusal.cpp
    Tests/Core/Protocol/Sync/test_quicbootstrap.cpp
    Tests/Core/Protocol/Sync/test_quic_bootstrap_reader.cpp
    Tests/Core/Protocol/Sync/test_sync_envelope.cpp
    Tests/Core/Protocol/Sync/test_sync_history_wire.cpp
)

command -v xcrun >/dev/null 2>&1 || { echo "run-ios-sync-conformance: xcrun not on PATH" >&2; exit 2; }
[ -f "$ARCHIVE" ] || {
    echo "run-ios-sync-conformance: no $ARCHIVE — build it with ./Scripts/build-ios.sh --sdk iphonesimulator" >&2
    exit 2
}

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"
[ -n "$SDK" ] || { echo "run-ios-sync-conformance: no iphonesimulator SDK" >&2; exit 2; }
IOS_DEPLOYMENT_FLOOR="$(sed -n 's/^CMAKE_OSX_DEPLOYMENT_TARGET:[^=]*=//p' "$BUILD/CMakeCache.txt")"
[ -n "$IOS_DEPLOYMENT_FLOOR" ] || { echo "run-ios-sync-conformance: no configured iOS deployment target — rebuild the iOS app" >&2; exit 2; }

# The Sync codec hashes through AWS-LC, so a test that reaches it links the
# simulator's libcrypto from the prefix the iOS configure recorded. CMake
# appends the SDK's name to that prefix.
QUIC_PREFIX="$(sed -n 's/^UBIQUITTY_QUIC_PREFIX:[^=]*=//p' "$BUILD/CMakeCache.txt")"
CRYPTO="$QUIC_PREFIX/iphonesimulator/lib/libcrypto.a"
[ -n "$QUIC_PREFIX" ] && [ -f "$CRYPTO" ] || {
    echo "run-ios-sync-conformance: no simulator libcrypto at $CRYPTO — build the iOS app with QUIC on" >&2
    exit 2
}

ubq_ios_device_acquire run-ios-sync-conformance || exit 2
DEVICE="$UBQ_IOS_DEVICE"

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "run-ios-sync-conformance: ${#TESTS[@]} test(s) built for iOS, run on $DEVICE_NAME"
pass=0
fail=0
failed=()
for source in "${TESTS[@]}"; do
    name="$(basename "$source" .cpp)"
    binary="$STAGE/$name"
    if ! xcrun clang++ -std=c++23 -fno-exceptions -fno-rtti \
        -target "arm64-apple-ios${IOS_DEPLOYMENT_FLOOR}-simulator" -isysroot "$SDK" \
        -I "$ROOT/Source" -I "$KIT_ROOT/Source" -I "$CORE_ROOT/Source" -I "$CORE_ROOT/Tests" \
        -o "$binary" "$CORE_ROOT/$source" "$ARCHIVE" "$CRYPTO" > "$STAGE/$name.build.log" 2>&1; then
        printf '  FAIL  %s (did not compile for iOS)\n' "$name"
        sed 's/^/        /' "$STAGE/$name.build.log" | head -12
        fail=$((fail + 1))
        failed+=("$name")
        continue
    fi
    if out="$(xcrun simctl spawn "$DEVICE" "$binary" 2>&1)"; then
        printf '  ok    %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$name"
        sed 's/^/        /' <<<"$out" | head -20
        fail=$((fail + 1))
        failed+=("$name")
    fi
done

echo "run-ios-sync-conformance: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "run-ios-sync-conformance: FAILED — ${#failed[@]} test(s): ${failed[*]}" >&2
    exit 1
fi
