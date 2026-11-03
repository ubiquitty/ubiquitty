#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# check-ubiquittykit.sh — an external app consumes UbiquittyKit.framework.
#
# Builds the framework target into its own tree, then compiles a short host
# against the BUILT framework — no Ubiquitty app, no app module — embeds the
# framework in the host's app bundle, signs the app ad hoc, and runs it from
# there, once per step, so each step is the process's first call into the
# framework: choose the preferred family, look a shipped family up by name,
# build a renderer, resolve the shipped faces past same-named decoys, draw the
# icons, report the family each of a set of configurations is drawn in, and
# draw a frame — create a surface, make a renderer through the public factory
# in a family the framework ships, feed bytes, draw. This is the one oracle
# over the framework's packaging: the
# versioned layout codesign seals, its Info.plist and the Kit version in it,
# the metallib, fonts and icons riding the framework bundle and read from it,
# the fonts registered for the host's process before anything resolves a
# family by name, the swiftmodule in Modules/, and the public surface being
# reachable from outside.
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
FRAMEWORK="$FRAMEWORK_DIR/UbiquittyKit.framework"
[ -d "$FRAMEWORK" ] || {
    echo "check-ubiquittykit: no framework at $FRAMEWORK_DIR" >&2
    exit 1
}

# The versioned layout, checked here as well as by the build's own layout step,
# so a build that stops running that step cannot pass: the root holds the
# Versions directory and one link per entry into the current version, and the
# version holds the binary, its resources and its module, and no build output.
layout_failure() {
    echo "check-ubiquittykit: $FRAMEWORK: $1" >&2
    exit 1
}
[ "$(readlink "$FRAMEWORK/Versions/Current")" = "A" ] || layout_failure "Versions/Current is not a link to A"
root_entries="$(cd "$FRAMEWORK" && ls -A | LC_ALL=C sort | tr '\n' ' ')"
[ "$root_entries" = "Modules Resources UbiquittyKit Versions " ] \
    || layout_failure "the root holds '$root_entries', not the links and Versions alone"
for entry in Modules Resources UbiquittyKit; do
    [ "$(readlink "$FRAMEWORK/$entry")" = "Versions/Current/$entry" ] \
        || layout_failure "$entry at the root is not a link into Versions/Current"
done
version_entries="$(cd "$FRAMEWORK/Versions/A" && ls -A | LC_ALL=C sort | tr '\n' ' ')"
[ "$version_entries" = "Modules Resources UbiquittyKit " ] \
    || layout_failure "Versions/A holds '$version_entries', not the binary, Resources and Modules alone"
hidden="$(find "$FRAMEWORK/Versions/A" -name '.*' | head -1)"
[ -z "$hidden" ] || layout_failure "${hidden#"$FRAMEWORK/"} is a build's leftover"

# The Info.plist codesign needs to seal the bundle, carrying the Kit version a
# host requires the framework's Swift interface by.
info="$FRAMEWORK/Versions/A/Resources/Info.plist"
[ -f "$info" ] || layout_failure "Versions/A/Resources holds no Info.plist"
kit_version="$(sed -n 's/.*kitVersionString = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$ROOT/Source/UbiquittyKit/Version.h")"
[ -n "$kit_version" ] || layout_failure "no kitVersionString in Source/UbiquittyKit/Version.h"
for key in CFBundleShortVersionString CFBundleVersion; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$info" 2>/dev/null || true)"
    [ "$value" = "$kit_version" ] || layout_failure "its Info.plist's $key is '$value', not the Kit version $kit_version"
done

# Every shipped font travels with its licence beside it, as the font manifest
# requires of anything that redistributes it, and the fonts, the Phosphor files
# and the process icons each travel as the tree has them: every file, byte for
# byte, and nothing the tree does not have.
python3 -I - "$ROOT/Resources" "$FRAMEWORK/Versions/A/Resources" <<'EOF'
import json
import sys
from pathlib import Path

tree, resources = Path(sys.argv[1]), Path(sys.argv[2])
findings = []
for font in json.loads((tree / "fonts/manifest.json").read_text(encoding="utf-8"))["fonts"]:
    names = [entry["path"] for entry in font["files"]] + [font["licence_file"]]
    # An entry naming files outside the directory is baked into the binary.
    if any("/" in name for name in names):
        continue
    findings += [f"does not carry fonts/{name}" for name in names if not (resources / "fonts" / name).is_file()]
for directory in ("fonts", "phosphor", "process-icons"):
    sources = {entry.name: entry for entry in (tree / directory).iterdir()}
    copies = {entry.name: entry for entry in (resources / directory).iterdir()} if (resources / directory).is_dir() else {}
    for name in sorted(sources.keys() - copies.keys()):
        findings.append(f"does not carry {directory}/{name}")
    for name in sorted(copies.keys() - sources.keys()):
        findings.append(f"carries {directory}/{name}, which the tree does not have")
    for name in sorted(sources.keys() & copies.keys()):
        if not copies[name].is_file() or copies[name].read_bytes() != sources[name].read_bytes():
            findings.append(f"does not carry {directory}/{name} as the tree has it")
for finding in findings:
    print(f"check-ubiquittykit: the framework {finding}", file=sys.stderr)
sys.exit(1 if findings else 0)
EOF
echo "check-ubiquittykit: ok (the framework is in the versioned layout, carries the Kit version $kit_version, and carries its fonts with their licences and its icons as the tree has them)"

HOST_DIR="$BUILD/consumer"
rm -rf "$HOST_DIR"
mkdir -p "$HOST_DIR"
cat > "$HOST_DIR/main.swift" <<'EOF'
import AppKit
import CoreText
import Foundation
import Metal
import QuartzCore
import UbiquittyKit

func refuse(_ reason: String) -> Bool {
    FileHandle.standardError.write(Data("consumer: \(reason)\n".utf8))
    return false
}

/// The shipped font files among those this process can draw.
func registered(_ fonts: [URL]) -> [URL] {
    let available = Set(((CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? []).map { $0.resolvingSymlinksInPath().path })
    return fonts.filter { available.contains($0.resolvingSymlinksInPath().path) }
}

/// Whether every shipped font is registered for this process.
func allRegistered(_ fonts: [URL], after call: String) -> Bool {
    let missing = Set(fonts).subtracting(registered(fonts))
    return missing.isEmpty || refuse("\(call) left unregistered: \(missing.map(\.lastPathComponent).sorted())")
}

/// Whether CoreText resolves a family by its own name in this process, the
/// question the framework asks of each preferred family.
func resolvesByName(_ family: String) -> Bool {
    (CTFontCopyFamilyName(CTFontCreateWithName(family as CFString, 12, nil)) as String) == family
}

/// The families the shipped files carry, read from the files without
/// registering them.
func families(of fonts: [URL]) -> Set<String> {
    var names = Set<String>()
    for font in fonts {
        for descriptor in (CTFontManagerCreateFontDescriptorsFromURL(font as CFURL) as? [CTFontDescriptor]) ?? [] {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                names.insert(family)
            }
        }
    }
    return names
}

/// The first call into the framework, then everything the step asserts.
///
/// - Parameters:
///   - step: The step's name.
///   - arguments: The step's own arguments: the preferred families, best
///     first, for the preferred family's step.
///   - shipped: The font files the framework carries.
@MainActor
func run(_ step: String, arguments: [String], shipped: [URL]) -> Bool {
    switch step {
    case "preferred":
        // The answer is worked out before the first call: the first preferred
        // family the framework ships or this system has. Choosing it registers
        // every shipped font. Whether the lookup comes after the registration
        // is the `lookup` step's to tell: here a lookup made first answers the
        // same on any system with a family ahead of the shipped one, or with
        // its own copy of it. A shipped family is never asked for by name
        // here, so the framework's lookup is CoreText's first for that name.
        guard var expected = arguments.last else {
            return refuse("no preferred families to choose from")
        }
        let shippedFamilies = families(of: shipped)
        var isShipped = false
        for candidate in arguments {
            if shippedFamilies.contains(candidate) {
                expected = candidate
                isShipped = true
                break
            }
            if resolvesByName(candidate) {
                expected = candidate
                break
            }
        }
        let family = TerminalSurface.preferredFontFamily()
        guard allRegistered(shipped, after: "choosing the preferred family") else {
            return false
        }
        guard family == expected else {
            return refuse("the preferred family is \(family), where the first the framework ships or this system has is \(expected)")
        }
        print("consumer: the preferred family is \(family), \(isShipped ? "which the framework ships" : "which this system has")")
        return true
    case "lookup":
        // The shipped families this system has no copy of are found by name
        // only once registered, so a lookup made before the registration
        // misses them whatever else the system has installed.
        return ShippedFamilyLookupSmokeEntry.run() || refuse("a shipped family was looked up by name before it was registered")
    case "family":
        // The configured family, spelled as configured, when it is drawn by
        // any route, and the family drawn in its place when it is not, so
        // comparing the two tells a substitute from the family asked for.
        // CoreText answers a name no font carries with its own default face,
        // which "Helv" and "H" begin the names of.
        guard let fixedPitch = CTFontCreateUIFontForLanguage(.userFixedPitch, 13, nil) else {
            return refuse("no fixed-pitch system face")
        }
        let substitute = CTFontCopyFamilyName(fixedPitch) as String
        let bitmap = SurfaceTypography(unifontScale: 2)
        let cases: [(configured: String, typography: SurfaceTypography, drawn: String)] = [
            ("Monaspace Neon", SurfaceTypography(), "Monaspace Neon"),
            ("monaspace neon", SurfaceTypography(), "monaspace neon"),
            ("Menlo-Regular", SurfaceTypography(), "Menlo-Regular"),
            ("Helvetica", SurfaceTypography(), "Helvetica"),
            ("GNU Unifont", SurfaceTypography(), "GNU Unifont"),
            ("GNU Unifont", bitmap, "GNU Unifont"),
            ("Menlo", bitmap, "GNU Unifont"),
            ("No Such Family Qz", SurfaceTypography(), substitute),
            ("Helv", SurfaceTypography(), substitute),
            ("H", SurfaceTypography(), substitute),
        ]
        for (configured, typography, drawn) in cases {
            guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: configured, typography: typography) else {
                return refuse("no surface in \(configured)")
            }
            guard surface.resolvedFontFamily == drawn else {
                let tier = typography.unifontScale > 0 ? " on the bitmap tier" : ""
                return refuse("\(configured)\(tier) reports \(surface.resolvedFontFamily ?? "no family"), not \(drawn)")
            }
        }
        return true
    case "icons":
        return ShippedIconsSmokeEntry.run() || refuse("an icon was not drawn from the framework's own files")
    case "renderer":
        guard TerminalSurface.makeRenderer(fontFamily: "Monaspace Neon") != nil else {
            return refuse("no renderer")
        }
        return allRegistered(shipped, after: "a renderer built before any surface")
    case "faces":
        // With nothing registered, a family looked up by name finds only the
        // smoke's decoys and the machine's own copies; only a face opened from
        // the framework's file by path passes.
        return ShippedFacesSmokeEntry.run() || refuse("a shipped face resolved off the framework's own files")
    case "draw":
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return refuse("no surface")
        }
        // A family the framework ships, which a framework that cannot find
        // its own files draws in a substitute.
        guard let renderer = TerminalSurface.makeRenderer(fontFamily: "Monaspace Neon") else {
            return refuse("no renderer")
        }
        surface.renderer = renderer
        guard surface.resolvedFontFamily == "Monaspace Neon" else {
            return refuse("Monaspace Neon resolved to \(surface.resolvedFontFamily ?? "no family")")
        }
        guard allRegistered(shipped, after: "a surface and its renderer") else {
            return false
        }
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 384)
        layer.drawableSize = CGSize(width: 1280, height: 768)
        surface.feed(Data("ubiquittykit-consumer\r\n".utf8))
        return renderer.encodeFrame(for: surface, into: layer) || refuse("frame declined")
    default:
        return refuse("no step named \(step)")
    }
}

let passed = MainActor.assumeIsolated { () -> Bool in
    // The framework this process runs is the copy inside its own bundle, and
    // that bundle carries no fonts of its own.
    let kit = Bundle(for: TerminalSurface.self)
    let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks").resolvingSymlinksInPath().path
    guard kit.bundleURL.resolvingSymlinksInPath().path.hasPrefix(frameworks + "/") else {
        return refuse("loaded \(kit.bundlePath), not the copy in \(frameworks)")
    }
    for directory in ["fonts", "phosphor", "process-icons"] where Bundle.main.url(forResource: directory, withExtension: nil) != nil {
        return refuse("the host carries \(directory) of its own")
    }
    guard let resources = kit.resourceURL,
        let files = try? FileManager.default.contentsOfDirectory(
            at: resources.appendingPathComponent("fonts"),
            includingPropertiesForKeys: nil
        )
    else {
        return refuse("the framework has no fonts directory")
    }
    let shipped = files.filter { ["ttf", "otf"].contains($0.pathExtension) }
    guard !shipped.isEmpty else {
        return refuse("the framework ships no fonts")
    }
    let early = registered(shipped)
    guard early.isEmpty else {
        return refuse("registered before the first call: \(early.map(\.lastPathComponent).sorted())")
    }
    return run(CommandLine.arguments.dropFirst().first ?? "", arguments: Array(CommandLine.arguments.dropFirst(2)), shipped: shipped)
}
exit(passed ? 0 : 1)
EOF

# The host as an app ships it: the framework in Contents/Frameworks, found
# through the executable's run path and nowhere else.
APP="$HOST_DIR/Consumer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>consumer</string>
    <key>CFBundleIdentifier</key>
    <string>dev.ubiquitty.UbiquittyKitConsumer</string>
    <key>CFBundleName</key>
    <string>Consumer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
</dict>
</plist>
EOF
xcrun swiftc "$HOST_DIR/main.swift" \
    -o "$APP/Contents/MacOS/consumer" \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/UbiquittyKit.framework"

# Signing seals the embedded framework too, and codesign refuses an app around
# a framework with anything unsealed in it; the strict verification then reads
# every seal back.
sign_log="$HOST_DIR/codesign.log"
if ! codesign --force --deep --sign - "$APP" >"$sign_log" 2>&1 \
        || ! codesign --verify --strict --deep --verbose=2 "$APP" >>"$sign_log" 2>&1; then
    cat "$sign_log" >&2
    echo "check-ubiquittykit: an app embedding the framework does not sign" >&2
    exit 1
fi
echo "check-ubiquittykit: ok (an app embedding the framework signs and verifies strictly)"

# Core's preference list, best first, which the preferred family's step works
# its answer out from.
preferred=()
while IFS= read -r family; do
    preferred+=("$family")
done <<EOF
$(sed -n 's/.*houseFontFamilies\[\] = {\(.*\)};.*/\1/p' "$ROOT/Source/Core/Preferences/PreferencesDefaults.h" | grep -o '"[^"]*"' | tr -d '"')
EOF
[ -n "${preferred[0]:-}" ] || {
    echo "check-ubiquittykit: no preferred families in Source/Core/Preferences/PreferencesDefaults.h" >&2
    exit 1
}

consumer="$APP/Contents/MacOS/consumer"
"$consumer" preferred ${preferred[@]+"${preferred[@]}"}
echo "check-ubiquittykit: ok (the preferred family is the first this system has or the framework ships, and choosing it registers every shipped font)"
"$consumer" lookup
echo "check-ubiquittykit: ok (a family is looked up by name after the shipped fonts are registered)"
"$consumer" renderer
echo "check-ubiquittykit: ok (a renderer built before any surface registers the shipped fonts)"
"$consumer" faces
echo "check-ubiquittykit: ok (every shipped style and the symbol face are opened from the framework's files)"
"$consumer" icons
echo "check-ubiquittykit: ok (the Phosphor and program icons are drawn from the framework's files)"
"$consumer" family
echo "check-ubiquittykit: ok (a surface reports a family that is drawn as configured, under any of its names, and one that is not by the family drawn in its place)"
"$consumer" draw
echo "check-ubiquittykit: ok (the signed app drew a frame in a shipped family through its embedded framework)"

# The generated header and archive this build just produced are the only place a
# Swift export naming a C++ interop type can silently vanish -- swiftc prints no
# diagnostic and the build stays green. Assert every such export survived both.
python3 "$ROOT/Scripts/check-swift-cxx-exports.py" "$ROOT" "$BUILD"
