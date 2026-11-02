#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-frame-instances.sh — Core builds a frame into the Swift renderer's memory.
#
# FrameInstances allocates the eleven instance streams, tells Core how much room
# each holds, calls buildCellInstances, and grows and rebuilds when one comes
# back over capacity. A compiler sees none of that: a span bound to the wrong
# buffer, a capacity reported in bytes rather than elements, and a retry that
# never fires are all well-typed. So a frame is built here and the counts read.
#
# Unlike the font catalogue's driver this links Core, because buildCellInstances
# is a translation unit rather than a header. Core must therefore be built first,
# and the libraries below are the ones the portable snapshot target produces.
#
# The retry is the reason this exists. It runs only when a stream overruns, which
# an ordinary frame never does, so the branch that repairs a flood is the branch
# that never executes until a flood arrives — and by then it is a dropped frame
# rather than a failing check.
#
# Its subject is stream production and the round trip through Core's glyph table.
# The stub source rasterises nothing, so nothing here covers the atlas, the ink,
# or the encode.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT"

SWIFT_DIRECTORY="$ROOT/Source/UbiquittyRenderKit"
CORE_BUILD="$UBQ_BUILD_ROOT/core"
OUT="${TMPDIR:-/tmp}/ubiquitty-frame-instances-driver"

# One list, read by both passes below — a second spelling for the type-check
# pass would be a mirror of this one.
SWIFT_ARGUMENTS=(
    -O -wmo -enforce-exclusivity=unchecked
    -module-name FrameInstancesDriver
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    -Xcc -std=c++23
    -I"$SWIFT_DIRECTORY"
    -I"$ROOT/Source"
    -I"$ROOT/Source/Platform/Apple"
    -I"$ROOT/Source/Platform/macOS"
    -framework Metal
    -framework CoreGraphics
    "$SWIFT_DIRECTORY/GrowableBuffer.swift"
    "$SWIFT_DIRECTORY/FrameInstances.swift"
    "$SWIFT_DIRECTORY/GlyphSource.swift"
    "$ROOT/Scripts/drive-frame-instances.swift"
)

# Above the archive checks, because type-checking links nothing: refusing a
# missing archive here would make the cheap pass carry the expensive pass's
# prerequisite, which is the arrangement that kept this gate off every branch.
# shellcheck source=Scripts/swift-driver-typecheck.sh
source "$ROOT/Scripts/swift-driver-typecheck.sh"
swift_driver_typecheck_if_requested check-frame-instances "${SWIFT_ARGUMENTS[@]}"

if [[ ! -f "$CORE_BUILD/libubiquitty-core.a" ]]; then
    echo "check-frame-instances: $CORE_BUILD/libubiquitty-core.a is missing." >&2
    echo "  Build it first: Scripts/build-core-snapshot.sh" >&2
    exit 2
fi

# The archive can also be present and older than the headers this driver just
# parsed. That links, then crashes inside Core; refuse it the same way.
# shellcheck source=Scripts/build-provenance.sh
source "$ROOT/Scripts/build-provenance.sh"
build_provenance_require "$ROOT" "$CORE_BUILD" "check-frame-instances" "Scripts/build-core-snapshot.sh"

# The same interop flags the app's Swift compile uses. A driver built under
# different flags proves the renderer works in a configuration nothing ships.
xcrun swiftc "${SWIFT_ARGUMENTS[@]}" \
    "$CORE_BUILD/libubiquitty-core.a" \
    "$CORE_BUILD/libubiquitty-core-model.a" \
    "$CORE_BUILD/libubiquitty-behaviour.a" \
    -o "$OUT"

"$OUT"
