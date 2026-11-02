#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-terminal-renderer.sh — one render call, cells to pixels.
#
# The four checks beside this one each cover a piece: the catalogue resolves
# faces, the rasteriser inks a plane, the atlas maps slots, and the encoder
# draws streams Core built. All four can pass while the assembly is wrong — a
# renderer that never opens the glyph frame, binds a sheet it did not fill, or
# encodes before building produces a texture either way, and every per-piece
# check still reports what it always reported.
#
# So the whole object is driven once and the target read back.
#
# It also demonstrates the seam: this links TerminalRenderer and its collaborators
# against Core, Metal and CoreText and nothing else — no app object, no bundle,
# no window. A renderer that could not be built that way would not be one this
# check could run.
#
# Needs Core's libraries and the app's compiled shaders, so both builds run first.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT"

SWIFT_DIRECTORY="$ROOT/Source/UbiquittyRenderKit"
CORE_BUILD="$UBQ_BUILD_ROOT/core"
METALLIB="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/default.metallib"
SCRATCH="$(mktemp -d -t ubq-terminal-renderer.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
OUT="$SCRATCH/driver"

# Keep the Kit's internal Core import in its own module, as in the app. The
# testable import lets the driver exercise the real selection model without
# widening the production API or mixing its imports with RenderKit's.
OVERLAY_ARGUMENTS=(
    -O -sanitize=address -wmo -swift-version 6 -enforce-exclusivity=checked -parse-as-library
    -module-name SurfaceOverlayModel -package-name ubiquitty -enable-testing
    -cxx-interoperability-mode=default -Xcc -std=c++23
    -I"$ROOT/Source" -I"$ROOT/Source/Platform/Apple"
    -emit-module -emit-module-path "$SCRATCH/SurfaceOverlayModel.swiftmodule"
    "$ROOT/Source/UbiquittyKit/Swift/SurfaceSelectionModel.swift"
)
if [[ -z "${UBIQUITTY_DRIVER_TYPECHECK_ONLY:-}" ]]; then
    OVERLAY_ARGUMENTS+=(-emit-object -o "$SCRATCH/SurfaceOverlayModel.o")
fi
xcrun swiftc "${OVERLAY_ARGUMENTS[@]}"

# One list, read by both passes below — a second spelling for the type-check
# pass would be a mirror of this one, which is the drift the glob already
# closed on the source half.
SWIFT_ARGUMENTS=(
    -O -sanitize=address -wmo -swift-version 6 -enforce-exclusivity=checked -parse-as-library
    -module-name TerminalRendererDriver
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    -Xcc -std=c++23
    -I"$SWIFT_DIRECTORY"
    -I"$ROOT/Source"
    -I"$ROOT/Source/Platform/Apple"
    -I"$ROOT/Source/Platform/macOS"
    -I"$SCRATCH"
    -framework Metal
    -framework CoreText
    -framework CoreGraphics
    -framework Foundation
    "$SWIFT_DIRECTORY"/*.swift
    "$ROOT/Scripts/drive-terminal-renderer.swift"
)

# Above the archive and shader checks, because type-checking links nothing and
# loads no metallib: refusing either here would make the cheap pass carry the
# expensive pass's prerequisites, which is the arrangement that kept this gate
# off every branch.
# shellcheck source=Scripts/swift-driver-typecheck.sh
source "$ROOT/Scripts/swift-driver-typecheck.sh"
swift_driver_typecheck_if_requested check-terminal-renderer "${SWIFT_ARGUMENTS[@]}"

if [[ ! -f "$CORE_BUILD/libubiquitty-core.a" ]]; then
    echo "check-terminal-renderer: $CORE_BUILD/libubiquitty-core.a is missing." >&2
    echo "  Build it first: Scripts/build-core-snapshot.sh" >&2
    exit 2
fi

# The archive can also be present and older than the headers this driver just
# parsed. That links, then crashes inside Core; refuse it the same way.
# shellcheck source=Scripts/build-provenance.sh
source "$ROOT/Scripts/build-provenance.sh"
build_provenance_require "$ROOT" "$CORE_BUILD" "check-terminal-renderer" "Scripts/build-core-snapshot.sh"
if [[ ! -f "$METALLIB" ]]; then
    echo "check-terminal-renderer: $METALLIB is missing." >&2
    echo "  Build it first: Scripts/build-macos.sh" >&2
    exit 2
fi

# The PAL system-services half, which the portable archives declare and no
# frontend supplies here: the driver reaches Core's frame pacing, and pacing
# reads a clock. The shared stub rather than a private one, so a contract that
# moves is answered in one place.
# shellcheck source=Scripts/portable-core-lib.sh
source "$ROOT/Scripts/portable-core-lib.sh"
PAL_STUB="$SCRATCH/pal.cpp"
PAL_STUB_OBJECT="$SCRATCH/pal.o"
ubiquitty_core_pal_stub_source "$PAL_STUB"
# Compiled here rather than handed to swiftc: swiftc links a non-Swift input
# rather than compiling it, so a .cpp reaches the linker as an unreadable file.
xcrun clang++ -std=c++23 -I"$ROOT/Source" -c "$PAL_STUB" -o "$PAL_STUB_OBJECT"

xcrun swiftc "${SWIFT_ARGUMENTS[@]}" \
    "$SCRATCH/SurfaceOverlayModel.o" \
    "$PAL_STUB_OBJECT" \
    "$CORE_BUILD/libubiquitty-core.a" \
    "$CORE_BUILD/libubiquitty-core-model.a" \
    "$CORE_BUILD/libubiquitty-behaviour.a" \
    -o "$OUT"

"$OUT" "$METALLIB"
