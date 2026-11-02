#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# pgo-train-swift.sh — (re)generate the Swift renderer's PGO profile
# (Support/pgo/swift-renderkit.profdata, consumed by build-macos.sh when
# present unless UBIQUITTY_PGO=OFF).
#
#   ./Scripts/pgo-train-swift.sh
#   UBQ_SWIFT_PGO_TRAIN_OUT=/tmp/arm-a.profdata ./Scripts/pgo-train-swift.sh
#
# A separate profile from a separate corpus: pgo-train.sh trains the C-family
# profile on bench_stack, which links no Swift — the Swift renderer's counters
# can only come from the app binary. The corpus is the profile-render scene
# battery (both grid-cache regimes) plus the two headless Swift benches, which
# together reach the sheet fills, the ligature strips, the frame encode and
# the ingest handshake.
#
# The profile is per-machine and untracked. Swift's front-end
# instrumentation keys functions as <primary-file path>:<mangled name>, and
# this build compiles Swift with absolute paths, so a shared artifact would
# embed one checkout's path and miss silently for any consumer compiling
# from a different directory. Each machine trains its own; .gitignore
# holds the line.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="build/swift-pgo-train"
PROFILE="${UBQ_SWIFT_PGO_TRAIN_OUT:-Support/pgo/swift-renderkit.profdata}"
RAW_DIRECTORY="$BUILD/profraw"
rm -rf "$RAW_DIRECTORY"
mkdir -p "$RAW_DIRECTORY" "$(dirname "$PROFILE")"

# UBIQUITTY_PGO=OFF keeps the two consume paths out of the training build:
# the C-family arm compiles at plain shipping flags, and the Swift consume
# block stays empty so the instrument flag below is the only PGO flag in play.
# UBIQUITTY_CMAKE_EXTRA lands after the script's own -D of the same variable,
# and the later definition wins.
echo "pgo-train-swift: building the instrumented app ..." >&2
UBIQUITTY_PGO=OFF \
    UBIQUITTY_BUILD_DIR="$BUILD" \
    UBIQUITTY_CMAKE_EXTRA="-DUBIQUITTY_SWIFT_PGO_FLAGS=-profile-generate" \
    ./Scripts/build-macos.sh

APP="$BUILD/Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty"
if [ ! -x "$APP" ]; then
    echo "pgo-train-swift: FAILED — no app binary at $APP" >&2
    exit 1
fi

# One raw shard per process; %m keeps concurrently-written shards apart.
echo "pgo-train-swift: running the corpus ..." >&2
LLVM_PROFILE_FILE="$RAW_DIRECTORY/%m-%p.profraw" "$APP" --bench-swift-frames > "$BUILD/train-frames.log" 2>&1
LLVM_PROFILE_FILE="$RAW_DIRECTORY/%m-%p.profraw" "$APP" --bench-swift-drain > "$BUILD/train-drain.log" 2>&1
LLVM_PROFILE_FILE="$RAW_DIRECTORY/%m-%p.profraw" "$APP" --profile-render --frames 40 --warmup 5 > "$BUILD/train-compare.log" 2>&1
LLVM_PROFILE_FILE="$RAW_DIRECTORY/%m-%p.profraw" "$APP" --profile-render --grid-cache --frames 40 --warmup 5 > "$BUILD/train-compare-grid.log" 2>&1

shopt -s nullglob
RAW_SHARDS=("$RAW_DIRECTORY"/*.profraw)
if [ ${#RAW_SHARDS[@]} -eq 0 ]; then
    echo "pgo-train-swift: FAILED — the corpus wrote no raw counters." >&2
    echo "pgo-train-swift: the instrument flag never reached the Swift compile," >&2
    echo "pgo-train-swift: or the runs above crashed before exit (see $BUILD/train-*.log)." >&2
    exit 1
fi

echo "pgo-train-swift: merging ${#RAW_SHARDS[@]} shard(s) ..." >&2
xcrun llvm-profdata merge -output "$PROFILE" "${RAW_SHARDS[@]}"

# The corpus claim, asserted: a hot symbol with no counters trains COLD, and
# -profile-use reads zero as cold rather than unknown. These are the symbols
# the Instruments captures named; a miss here is a corpus gap, not noise.
# Demangled before grepping: the mangler's substitution compression can spell
# a method without its own name — fillBackend(into:) mangles to 04fillE04into
# because Backend already appeared in the type — so a raw grep reports a
# trained symbol as missing.
REQUIRED_SYMBOLS="rasteriseStrip encodeWithoutCommit encodeGrid fillBackend"
MISSING=""
FUNCTION_DUMP="$BUILD/profile-functions.txt"
xcrun llvm-profdata show --all-functions "$PROFILE" | xcrun swift-demangle > "$FUNCTION_DUMP"
for symbol in $REQUIRED_SYMBOLS; do
    grep -q "$symbol" "$FUNCTION_DUMP" || MISSING="$MISSING $symbol"
done
if [ -n "$MISSING" ]; then
    echo "pgo-train-swift: FAILED — the corpus never reached:$MISSING" >&2
    echo "pgo-train-swift: extend the corpus, or drop the symbol here if it" >&2
    echo "pgo-train-swift: genuinely stopped shipping." >&2
    exit 1
fi

SIZE=$(du -h "$PROFILE" | cut -f1)
echo "pgo-train-swift: wrote $PROFILE ($SIZE)" >&2

# Absolute compile paths are expected here (see the header) — announced, not
# fatal, because the artifact is per-machine. A profile this check stays
# silent on is one whose keying went relative, which is what sharing needs.
if strings "$PROFILE" | grep -qE '/(Users|home)/[a-z]'; then
    echo "pgo-train-swift: profile carries absolute paths; it serves this checkout only." >&2
fi

trainedAt=$(git rev-parse HEAD 2>/dev/null || true)
if [ -n "$trainedAt" ]; then
    printf '%s\n' "$trainedAt" > "${PROFILE%.profdata}.trained-at"
    echo "pgo-train-swift: trained on $trainedAt (recorded beside the profile)" >&2
fi

echo "pgo-train-swift: done — the next ./Scripts/build-macos.sh consumes it." >&2
