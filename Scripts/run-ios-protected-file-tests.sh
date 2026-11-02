#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-ios-protected-file-tests.sh — the real iOS protected-file backend, built
# for the simulator and run there, without building or installing the app.
#
#   ./Scripts/run-ios-protected-file-tests.sh                 the checkout's simulator
#   ./Scripts/run-ios-protected-file-tests.sh BOOTED_UDID     a simulator the caller owns
#
# With no argument the run acquires this checkout's simulator through
# Scripts/ios-simulator.sh and shuts it down again if it booted it. A named
# device is used as it is and left running.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: Scripts/run-ios-protected-file-tests.sh [BOOTED_SIMULATOR_UDID]" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -eq 1 ]]; then
    DEVICE="$1"
else
    # shellcheck source=Scripts/build-root.sh
    . "$ROOT/Scripts/build-root.sh"
    # shellcheck source=Scripts/ios-simulator.sh
    . "$ROOT/Scripts/ios-simulator.sh"
    ubq_ios_device_acquire run-ios-protected-file-tests || exit 2
    DEVICE="$UBQ_IOS_DEVICE"
fi
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/ubq-ios-protected-file.XXXXXX")"
ARCH="$(uname -m)"
echo "iOS protected-file evidence: $OUTPUT"
# The creator is Swift (Source/UbiquittyKit/Swift/ProtectedFile.swift) behind
# a C symbol, and so is the suite's protection-class probe, so the C++ units
# are compiled first and swiftc links them with the Swift runtime.
for unit in Tests/Platform/test_ios_protected_file.cpp Source/Platform/POSIX/SystemPAL.cpp; do
    xcrun --sdk iphonesimulator clang++ -c \
        -std=c++23 -fno-exceptions -fno-rtti -Wall -Wextra -Werror \
        -DUBIQUITTY_TEST_WITHOUT_CORE=1 -target "$ARCH-apple-ios17.0-simulator" \
        -I"$ROOT/Source" -I"$ROOT/Tests" \
        "$ROOT/$unit" -o "$OUTPUT/$(basename "$unit").o"
done
xcrun --sdk iphonesimulator swiftc -parse-as-library -O -warnings-as-errors \
    -target "$ARCH-apple-ios17.0-simulator" \
    "$ROOT/Source/UbiquittyKit/Swift/ProtectedFile.swift" \
    "$ROOT/Tests/Platform/test_ios_protected_file_probe.swift" \
    "$OUTPUT/test_ios_protected_file.cpp.o" "$OUTPUT/SystemPAL.cpp.o" \
    -lc++ -framework Foundation -Xlinker -dead_strip -o "$OUTPUT/test_ios_protected_file"
xcrun simctl spawn "$DEVICE" "$OUTPUT/test_ios_protected_file" 2>&1 | tee "$OUTPUT/tests.log"
