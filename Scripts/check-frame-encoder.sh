#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-frame-encoder.sh — the Swift renderer's passes reach the GPU.
#
# FrameEncoder binds a pipeline, a uniform, an instance buffer and a sheet per
# pass, then draws instanced quads. Every mistake available there is silent: a
# pass bound to the wrong buffer draws the wrong stream, a uniform carrying a
# stale viewport puts every quad off-screen, and a count read from the wrong
# stream draws nothing. All of it compiles, and all of it yields a command buffer
# that completes without error.
#
# So the target is read back. The pass clears to magenta, which no cell resolves
# to, and a surviving magenta pixel is one the cell pass never covered.
#
# Headless, into an ordinary texture rather than a drawable — the renderer needs
# no window to draw a frame.
#
# Needs the app's compiled shaders and Core's libraries, so both builds run
# first. The shader library is the app's own rather than one built here: a driver
# with its own shaders would prove the passes work against something that does
# not ship.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT"

SWIFT_DIRECTORY="$ROOT/Source/UbiquittyRenderKit"
CORE_BUILD="$UBQ_BUILD_ROOT/core"
METALLIB="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/default.metallib"
OUT="${TMPDIR:-/tmp}/ubiquitty-frame-encoder-driver"

# The whole render kit, from the list its targets compile; see
# Scripts/renderkit-sources.sh.
# shellcheck source=Scripts/renderkit-sources.sh
source "$ROOT/Scripts/renderkit-sources.sh"
renderkit_sources_load "$ROOT" check-frame-encoder

# One list, read by both passes below — a second spelling for the type-check
# pass would be a mirror of this one.
SWIFT_ARGUMENTS=(
    -O -wmo -swift-version 6 -enforce-exclusivity=checked
    -module-name FrameEncoderDriver
    -target "$RENDERKIT_TARGET"
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    -Xcc -std=c++23
    -I"$SWIFT_DIRECTORY"
    -I"$ROOT/Source"
    -I"$ROOT/Source/Platform/Apple"
    -I"$ROOT/Source/Platform/macOS"
    -import-bridging-header "$ROOT/Scripts/FrameEncoderFixture.h"
    -framework Metal
    -framework CoreText
    -framework CoreGraphics
    -framework Foundation
    "${RENDERKIT_SOURCES[@]}"
    "$ROOT/Scripts/drive-rich-text.swift"
    "$ROOT/Scripts/drive-frame-encoder.swift"
)

# Above the archive and shader checks, because type-checking links nothing and
# loads no metallib: refusing either here would make the cheap pass carry the
# expensive pass's prerequisites, which is the arrangement that kept this gate
# off every branch.
# shellcheck source=Scripts/swift-driver-typecheck.sh
source "$ROOT/Scripts/swift-driver-typecheck.sh"
swift_driver_typecheck_if_requested check-frame-encoder "${SWIFT_ARGUMENTS[@]}"

# A borrowed atlas cannot become a result whose unique owner has gone away.
LIFETIME_LOG="$(mktemp "${TMPDIR:-/tmp}/ubiquitty-frame-encoder-lifetime.XXXXXX")"
trap 'rm -f "$LIFETIME_LOG"' EXIT
if xcrun swiftc -typecheck -D FRAME_ENCODER_LIFETIME_NEGATIVE "${SWIFT_ARGUMENTS[@]}" >"$LIFETIME_LOG" 2>&1; then
    echo "check-frame-encoder: escaping atlas lifetime control unexpectedly compiled." >&2
    exit 1
fi
if ! grep -q 'a function cannot return a ~Escapable result' "$LIFETIME_LOG"; then
    cat "$LIFETIME_LOG" >&2
    echo "check-frame-encoder: lifetime control failed for an unexpected reason." >&2
    exit 1
fi

if [[ ! -f "$CORE_BUILD/libubiquitty-core.a" ]]; then
    echo "check-frame-encoder: $CORE_BUILD/libubiquitty-core.a is missing." >&2
    echo "  Build it first: Scripts/build-core-snapshot.sh" >&2
    exit 2
fi

# The archive can also be present and older than the headers this driver just
# parsed. That links, then crashes inside Core; refuse it the same way.
# shellcheck source=Scripts/build-provenance.sh
source "$ROOT/Scripts/build-provenance.sh"
build_provenance_require "$ROOT" "$CORE_BUILD" "check-frame-encoder" "Scripts/build-core-snapshot.sh"
if [[ ! -f "$METALLIB" ]]; then
    echo "check-frame-encoder: $METALLIB is missing." >&2
    echo "  Build it first: Scripts/build-macos.sh" >&2
    exit 2
fi

# The whole kit reaches the runtime, which calls the PAL for clocks, the PTY
# and the clipboard; the snapshot archives carry no backend, so the same stub
# check-terminal-renderer links stands in for one.
# shellcheck source=Scripts/portable-core-lib.sh
source "$ROOT/Scripts/portable-core-lib.sh"
ubiquitty_core_pal_stub_source "$OUT-pal.cpp"
xcrun clang++ -std=c++23 -target "$RENDERKIT_TARGET" -I"$ROOT/Source" -c "$OUT-pal.cpp" -o "$OUT-pal.o"

xcrun swiftc "${SWIFT_ARGUMENTS[@]}" \
    "$OUT-pal.o" \
    "$CORE_BUILD/libubiquitty-core.a" \
    "$CORE_BUILD/libubiquitty-core-model.a" \
    "$CORE_BUILD/libubiquitty-behaviour.a" \
    -o "$OUT"

"$OUT" "$METALLIB"
