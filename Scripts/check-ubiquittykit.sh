#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# check-ubiquittykit.sh — an external app consumes UbiquittyKit.framework.
#
# Builds the framework target into its own tree, then compiles a twenty-line
# host against the BUILT framework — no Ubiquitty app, no app module — and
# runs it: create a surface, make a renderer through the public factory, feed
# bytes, draw a frame. This is the one oracle over the framework's packaging:
# the metallib riding the framework bundle, the swiftmodule in Modules/, and
# the public surface being reachable from outside.
#
# The consumer compiles with -F and nothing else: no C++ interoperability,
# no module maps, no include paths. That compile is the assertion — the UbiquittyKit
# module imports the machinery and every Core interop module internally, so
# one interop-typed public declaration anywhere in its interface fails this
# compile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
BUILD="$UBQ_BUILD_ROOT/ubiquittykit"

# The build's own output goes to a log and is replayed only on failure:
# swallowed entirely, a failing configure exits this script with nothing
# said, which reads as a broken gate rather than a diagnosed one.
LOG="$BUILD-build.log"
mkdir -p "$BUILD"
# The bundle is deleted before every build: the metallib and interface ride
# POST_BUILD copies that rerun only on relink, so an incremental run against
# a bundle from another configuration serves stale resources — and the
# consumer then declines a frame for a reason no log names.
rm -rf "$BUILD/Source/Platform/macOS/UbiquittyKit.framework"
if ! cmake -B "$BUILD" -S "$ROOT" -G Ninja \
        -DUBIQUITTY_FRONTEND=macOS \
        -DUBIQUITTY_KIT=ON \
        -DCMAKE_BUILD_TYPE=Release >"$LOG" 2>&1; then
    tail -40 "$LOG" >&2
    exit 1
fi

# Dynamic exclusivity is a Swift code-generation setting, so the generated
# command is the source of truth: inspecting the CMake text alone can pass
# while a shared option list or generator expression puts the flag back. The
# renderer is the one measured exception; the app and both Kit products keep
# the runtime check over their mutable session and surface state.
swift_codegen_command() {
    local target="$1"
    local selector="$2"
    local commands
    local matches
    commands="$(ninja -C "$BUILD" -t commands "$target")"
    matches="$(printf '%s\n' "$commands" | grep -F 'swiftc ' | grep -F -- "$selector" || true)"
    if [ "$(printf '%s\n' "$matches" | grep -c . || true)" -ne 1 ]; then
        echo "check-ubiquittykit: expected one Swift codegen command for $target" >&2
        exit 1
    fi
    printf '%s' "$matches"
}

check_exclusivity_mode() {
    local target="$1"
    local selector="$2"
    local expected="$3"
    local actual
    local command
    command="$(swift_codegen_command "$target" "$selector")"
    case "$command" in
        *' -enforce-exclusivity=unchecked '*) actual=unchecked ;;
        *) actual=checked ;;
    esac
    if [ "$actual" != "$expected" ]; then
        echo "check-ubiquittykit: $target compiles with exclusivity $actual, expected $expected" >&2
        exit 1
    fi
}

check_exclusivity_mode UbiquittyRenderKit '-module-link-name UbiquittyRenderKit ' unchecked
check_exclusivity_mode UbiquittyKitModule '-module-link-name UbiquittyKitModule ' checked
check_exclusivity_mode UbiquittyKit '-module-link-name UbiquittyKit ' checked
check_exclusivity_mode Ubiquitty '-emit-executable ' checked
echo "check-ubiquittykit: ok (unchecked exclusivity is confined to UbiquittyRenderKit)"

# The generated header the export check at the end reads is a target of its
# own, which only the app depends on. Built here beside the framework, so a fresh
# directory has one, and the one read is this build's rather than a header an
# earlier run left behind.
if ! cmake --build "$BUILD" --target UbiquittyKit UbiquittyRenderKitHeader >>"$LOG" 2>&1; then
    tail -40 "$LOG" >&2
    exit 1
fi

FRAMEWORK_DIR="$BUILD/Source/Platform/macOS"
[ -d "$FRAMEWORK_DIR/UbiquittyKit.framework" ] || {
    echo "check-ubiquittykit: no framework at $FRAMEWORK_DIR" >&2
    exit 1
}

HOST_DIR="$BUILD/consumer"
mkdir -p "$HOST_DIR"
cat > "$HOST_DIR/main.swift" <<'EOF'
import AppKit
import Foundation
import Metal
import QuartzCore
import UbiquittyKit

let drawn = MainActor.assumeIsolated { () -> Bool in
    guard let surface = TerminalSurface(rows: 24, columns: 80) else {
        FileHandle.standardError.write(Data("consumer: no surface\n".utf8))
        return false
    }
    guard let renderer = TerminalSurface.makeRenderer() else {
        FileHandle.standardError.write(Data("consumer: no renderer\n".utf8))
        return false
    }
    surface.renderer = renderer
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    layer.pixelFormat = .bgra8Unorm
    layer.frame = CGRect(x: 0, y: 0, width: 640, height: 384)
    layer.drawableSize = CGSize(width: 1280, height: 768)
    surface.feed(Data("ubiquittykit-consumer\r\n".utf8))
    guard renderer.encodeFrame(for: surface, into: layer) else {
        FileHandle.standardError.write(Data("consumer: frame declined\n".utf8))
        return false
    }
    return true
}
exit(drawn ? 0 : 1)
EOF

xcrun swiftc "$HOST_DIR/main.swift" \
    -o "$HOST_DIR/consumer" \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"

"$HOST_DIR/consumer"
echo "check-ubiquittykit: ok (external consumer drew a frame through the framework)"

# The generated header and archive this build just produced are the only place a
# Swift export naming a C++ interop type can silently vanish -- swiftc prints no
# diagnostic and the build stays green. Assert every such export survived both.
python3 "$ROOT/Scripts/check-swift-cxx-exports.py" "$ROOT" "$BUILD"
