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
# icons, look programs' icons up by catalog key and draw them as the catalog
# paints them, hand them to a thread of their own and read and draw them there,
# report the family each of a set of configurations is drawn in, and
# draw a frame — create a surface, make a renderer through the public factory
# in a family the framework ships, feed bytes, draw — and read a theme's colors
# without a surface, apply the theme by name, and hear each OSC color write and
# reset, and a palette or theme the host applies, move the colors through the
# observer, once per batch or apply, never for one that moves nothing, and not
# inside a synchronized update, from fed bytes, on a surface nothing draws, and
# from programs writing to the surface's pseudo-terminal, one of them writing
# updates back to back. This is the one oracle
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
# compile. It compiles with warnings as errors, so a public value it hands to
# another thread has to be Sendable: the capture of one that is not is a
# warning in Swift 5 mode and an error in Swift 6.
#
# A second consumer, compiled the same way, shows a surface from the
# font-taking initializer in a window. The surface must submit a frame of its
# own. Then, while a shell floods it, a main-actor task and a thread of the
# host's own ask the surface's layer for drawables: each must be answered nil,
# never a raise, while the display link delivers them, and handed a drawable
# again once the link stands down. Last, a thread asks on its own schedule
# through a second flood, while the surface starts and stops its link under it.
#
# A further consumer launches a shell in a surface taken out of its window,
# runs a program the process catalog names, and reads the program's name,
# catalog key, icon and chains as the public observer hears the process sample move;
# hears nothing while the observer declines process facts, and the move once it
# asks again; reads the status a record posts and the colour a program sets as
# the status callback fires; and reads nothing named after the shell exits.
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
import os

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

/// Records each colour change a surface announces and when, and each batch of
/// output it delivers.
@MainActor
final class ColorWatch: TerminalSurfaceObserver {
    private(set) var reports: [TerminalColors] = []
    private(set) var reportTimes: [Date] = []
    private(set) var deliveredBatches = 0

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeColors colors: TerminalColors) {
        MainActor.assumeIsolated {
            reports.append(colors)
            reportTimes.append(Date())
        }
    }

    nonisolated func terminalSurfaceDidUpdateScreen(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            deliveredBatches += 1
        }
    }
}

/// Runs the main loop, which carries the surface's deliveries, until the
/// condition holds or the time is up.
@MainActor
func wait(seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return true
}

/// Feeds bytes as one batch and runs the main loop until the surface has
/// delivered it, so every report the batch raises has been raised.
///
/// The printed dot after the bytes makes the batch one the surface delivers
/// whatever the bytes did; a write that moves nothing still arrives.
@MainActor
func feedBatch(_ surface: TerminalSurface, _ watch: ColorWatch, _ bytes: String) -> Bool {
    let delivered = watch.deliveredBatches
    surface.feed(Data((bytes + ".").utf8))
    return wait(seconds: 10) { watch.deliveredBatches > delivered }
}

/// Reads a theme's colours without a surface, applies the theme by name, and
/// hears a program move the colours: once per batch that moves them, never
/// for one that moves nothing, and not inside a synchronized update.
@MainActor
func followsTheThemeColors() -> Bool {
    guard let surface = TerminalSurface(rows: 24, columns: 80) else {
        return refuse("no theme surface")
    }
    let watch = ColorWatch()
    surface.observer = watch
    let initial = surface.colors

    /// Feeds a batch and holds the reports it raised to the count expected.
    func expect(_ bytes: String, reports expected: Int, _ what: String) -> Bool {
        let before = watch.reports.count
        guard feedBatch(surface, watch, bytes) else {
            return refuse("\(what): the batch was never delivered")
        }
        let raised = watch.reports.count - before
        guard raised == expected else {
            return refuse("\(what) reported \(raised) changes, not \(expected)")
        }
        guard raised == 0 || watch.reports.last == surface.colors else {
            return refuse("\(what) reported colours the surface does not hold")
        }
        return true
    }

    // A theme whose background differs from the surface's, so the apply shows.
    guard let name = TerminalSurface.themeNames.first(where: { TerminalSurface.colors(ofTheme: $0)?.background != initial.background }),
        let themed = TerminalSurface.colors(ofTheme: name)
    else {
        return refuse("no theme's background differs from \(initial.background)")
    }
    guard themed.ansi.count == 16, themed.selectionBackground == nil, themed.selectionForeground == nil else {
        return refuse("\(name) carries \(themed.ansi.count) ANSI colours and selection \(String(describing: themed.selectionBackground))")
    }
    // A name Core does not know, and a known name with more after a NUL, which
    // a C string would cut back to the known name.
    for unknown in ["No Such Theme", "\(name)\u{0}No Such Theme"] {
        guard TerminalSurface.colors(ofTheme: unknown) == nil else {
            return refuse("the unknown theme name \(unknown.debugDescription) had colours")
        }
        guard !surface.applyTheme(named: unknown), surface.colors == initial, watch.reports.isEmpty else {
            return refuse("the unknown theme name \(unknown.debugDescription) was applied or moved the colours")
        }
    }
    // The first write is measured against the colours the surface was created
    // with, and one past the sixteen moves none of them.
    guard expect("\u{1b}]4;100;rgb:01/02/03\u{7}", reports: 0, "a first write, OSC 4 on index 100") else {
        return false
    }
    guard surface.applyTheme(named: name) else {
        return refuse("applying \(name) was refused")
    }
    guard surface.colors == themed else {
        return refuse("\(name) drew background \(surface.colors.background), not the \(themed.background) read for it")
    }
    guard watch.reports == [themed] else {
        return refuse("applying \(name) reported \(watch.reports.count) changes, not its colours once")
    }
    // The same theme again rewrites the palette and moves nothing.
    guard surface.applyTheme(named: name), watch.reports.count == 1 else {
        return refuse("re-applying \(name) reported \(watch.reports.count - 1) changes")
    }

    // Two colours in one batch are one change.
    guard expect("\u{1b}]10;rgb:ab/cd/ef\u{7}\u{1b}]11;rgb:12/34/56\u{7}", reports: 1, "OSC 10 and 11") else {
        return false
    }
    let ground = TerminalColor(red: 0x12, green: 0x34, blue: 0x56)
    var moved = themed
    moved.foreground = TerminalColor(red: 0xAB, green: 0xCD, blue: 0xEF)
    moved.background = ground
    guard watch.reports.last == moved else {
        return refuse("OSC 10 and 11 reported \(String(describing: watch.reports.last)), over \(themed)")
    }
    // The channels read in the space the host names.
    let sRGB = ground.platformColor(usesDisplayP3: false).usingColorSpace(.sRGB)
    guard let sRGB, abs(sRGB.redComponent - 0x12 / 255) < 0.001, abs(sRGB.blueComponent - 0x56 / 255) < 0.001 else {
        return refuse("the background read as \(String(describing: sRGB)) in sRGB")
    }
    let displayP3 = ground.platformColor(usesDisplayP3: true)
    guard displayP3.colorSpace == .displayP3, abs(displayP3.redComponent - 0x12 / 255) < 0.001,
        abs(displayP3.blueComponent - 0x56 / 255) < 0.001,
        let widened = displayP3.usingColorSpace(.sRGB), abs(widened.redComponent - sRGB.redComponent) > 0.001
    else {
        return refuse("the background read as \(displayP3) in Display P3")
    }

    // Writes that move nothing the host sees: a re-asserted colour, a colour
    // moved and put back in one batch, and a palette slot past the sixteen.
    guard expect("\u{1b}]11;rgb:12/34/56\u{7}", reports: 0, "a re-asserted OSC 11"),
        expect("\u{1b}]11;rgb:fe/fe/fe\u{7}\u{1b}]11;rgb:12/34/56\u{7}", reports: 0, "OSC 11 moved and put back"),
        expect("\u{1b}]4;100;rgb:01/02/03\u{7}", reports: 0, "OSC 4 on index 100")
    else {
        return false
    }

    // An ANSI colour and the cursor, then the selection colours, set and reset.
    guard expect("\u{1b}]4;1;rgb:0a/0b/0c\u{7}\u{1b}]12;rgb:65/43/21\u{7}", reports: 1, "OSC 4 on index 1 and OSC 12") else {
        return false
    }
    moved.ansi[1] = TerminalColor(red: 0x0A, green: 0x0B, blue: 0x0C)
    moved.cursor = TerminalColor(red: 0x65, green: 0x43, blue: 0x21)
    guard watch.reports.last == moved else {
        return refuse("OSC 4 and 12 reported \(String(describing: watch.reports.last))")
    }
    guard expect("\u{1b}]17;rgb:21/43/65\u{7}\u{1b}]19;rgb:fe/dc/ba\u{7}", reports: 1, "OSC 17 and 19") else {
        return false
    }
    guard watch.reports.last?.selectionBackground == TerminalColor(red: 0x21, green: 0x43, blue: 0x65),
        watch.reports.last?.selectionForeground == TerminalColor(red: 0xFE, green: 0xDC, blue: 0xBA)
    else {
        return refuse("OSC 17 and 19 reported \(String(describing: watch.reports.last))")
    }
    guard expect("\u{1b}]117\u{7}\u{1b}]119\u{7}", reports: 1, "OSC 117 and 119"), watch.reports.last == moved else {
        return refuse("OSC 117 and 119 reported \(String(describing: watch.reports.last))")
    }

    // A synchronized update holds the frame, and the report with it: the block
    // that closes reports, and so does one the terminal expires.
    guard expect("\u{1b}[?2026h\u{1b}]11;rgb:77/00/77\u{7}", reports: 0, "OSC 11 inside a synchronized update"),
        expect("\u{1b}[?2026l", reports: 1, "closing the synchronized update"),
        watch.reports.last?.background == TerminalColor(red: 0x77, green: 0x00, blue: 0x77)
    else {
        return refuse("the closed update reported \(String(describing: watch.reports.last?.background))")
    }
    let reportsBeforeExpiry = watch.reports.count
    guard expect("\u{1b}[?2026h\u{1b}]11;rgb:00/77/77\u{7}", reports: 0, "OSC 11 inside an update left open"),
        wait(seconds: 10, until: { watch.reports.count > reportsBeforeExpiry }),
        watch.reports.count == reportsBeforeExpiry + 1,
        watch.reports.last?.background == TerminalColor(red: 0x00, green: 0x77, blue: 0x77)
    else {
        return refuse("the expired update reported \(watch.reports.count - reportsBeforeExpiry) changes")
    }

    // The resets in one batch are one change, and land on the theme.
    guard expect("\u{1b}[?2026l\u{1b}]104;1\u{7}\u{1b}]110\u{7}\u{1b}]111\u{7}\u{1b}]112\u{7}", reports: 1, "OSC 104, 110, 111 and 112"),
        watch.reports.last == themed
    else {
        return refuse("the resets reported \(String(describing: watch.reports.last)), not \(name)'s colours")
    }

    // A palette the host resolved itself reports from inside the apply, and
    // once: the same palette again moves nothing.
    let paletteGround = TerminalColor(red: 0x2A, green: 0x2B, blue: 0x2C)
    var indexedRGB = [UInt8](repeating: 0, count: 768)
    for (index, color) in themed.ansi.enumerated() {
        indexedRGB.replaceSubrange(index * 3..<index * 3 + 3, with: [color.red, color.green, color.blue])
    }
    let defaultsRGB = [
        themed.foreground.red, themed.foreground.green, themed.foreground.blue,
        paletteGround.red, paletteGround.green, paletteGround.blue,
        themed.cursor.red, themed.cursor.green, themed.cursor.blue,
    ]
    let reportsBeforePalette = watch.reports.count
    guard surface.applyPalette(indexedRGB: indexedRGB, defaultsRGB: defaultsRGB),
        watch.reports.count == reportsBeforePalette + 1,
        watch.reports.last == surface.colors,
        watch.reports.last?.background == paletteGround
    else {
        return refuse(
            "applying a palette reported \(watch.reports.count - reportsBeforePalette) changes before it returned, "
                + "last \(String(describing: watch.reports.last?.background))"
        )
    }
    guard surface.applyPalette(indexedRGB: indexedRGB, defaultsRGB: defaultsRGB), watch.reports.count == reportsBeforePalette + 1 else {
        return refuse("re-applying the palette reported \(watch.reports.count - reportsBeforePalette - 1) changes")
    }

    // A theme applied while a program holds a synchronized update open waits
    // for the update to end, as the program's own write does.
    let held = surface.colors
    guard let next = TerminalSurface.themeNames.first(where: { TerminalSurface.colors(ofTheme: $0)?.background != held.background }),
        let nextColors = TerminalSurface.colors(ofTheme: next)
    else {
        return refuse("no theme's background differs from \(held.background)")
    }
    guard expect("\u{1b}[?2026h", reports: 0, "opening a synchronized update") else {
        return false
    }
    let reportsBeforeHeldApply = watch.reports.count
    guard surface.applyTheme(named: next), watch.reports.count == reportsBeforeHeldApply, surface.colors == held else {
        return refuse("applying \(next) inside a synchronized update reported \(watch.reports.count - reportsBeforeHeldApply) changes before it ended")
    }
    guard expect("\u{1b}[?2026l", reports: 1, "closing the update around the apply"), watch.reports.last == nextColors else {
        return refuse("the update around the apply reported \(String(describing: watch.reports.last?.background)), not \(next)'s colours")
    }
    print("consumer: \(name) applied by name and a palette applied; each OSC colour batch and apply reported once, and none that moved nothing or sat in an update")
    return true
}

/// Hears the colours of a surface nothing draws: a host's chrome around a
/// hidden pane still shows them.
@MainActor
func followsAWithheldSurfacesColors() -> Bool {
    _ = NSApplication.shared
    guard let surface = TerminalSurface(rows: 24, columns: 80) else {
        return refuse("no surface to withhold")
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 384), styleMask: [.titled], backing: .buffered, defer: false)
    let content = NSView(frame: window.contentLayoutRect)
    window.contentView = content
    content.addSubview(surface)
    surface.frame = content.bounds
    surface.isHidden = true
    let watch = ColorWatch()
    surface.observer = watch
    let ground = TerminalColor(red: 0x21, green: 0x22, blue: 0x23)
    surface.feed(Data("\u{1b}]11;rgb:21/22/23\u{7}.".utf8))
    guard wait(seconds: 10, until: { !watch.reports.isEmpty }) else {
        return refuse("a withheld surface never reported its background")
    }
    guard watch.reports.count == 1, watch.reports.last?.background == ground, watch.reports.last == surface.colors else {
        return refuse("a withheld surface reported \(watch.reports.count) changes, last \(String(describing: watch.reports.last?.background))")
    }
    // The surface holds its screen updates for the reveal, so none raised
    // means the batch reached a withheld pane.
    guard watch.deliveredBatches == 0 else {
        return refuse("the hidden surface raised \(watch.deliveredBatches) screen updates, so it was drawing")
    }
    print("consumer: a surface nothing draws reported its colours")
    return true
}

/// Runs a program on the surface's pseudo-terminal that sets a canary
/// background only inside synchronized updates, putting the background back
/// before each one ends, and hears the colours it leaves outside them and never
/// the canary.
///
/// Fed bytes parse on the main actor, so the published screen never trails the
/// parser. A pseudo-terminal's output parses on the session's own thread, which
/// is often inside an update the surface has not published when a delivery
/// reads the colours.
///
/// - Parameter writer: The program, which the surface runs as its shell.
@MainActor
func followsAProgramsColorsOverItsTerminal(writer: String) -> Bool {
    guard let surface = TerminalSurface(rows: 24, columns: 80) else {
        return refuse("no terminal surface")
    }
    let watch = ColorWatch()
    surface.observer = watch
    // The login shell launchShell starts is the one SHELL names.
    setenv("SHELL", writer, 1)
    guard surface.launchShell() else {
        return refuse("the writer did not launch")
    }
    let canary = TerminalColor(red: 0xAB, green: 0x01, blue: 0xCD)
    let finished = TerminalColor(red: 0x0E, green: 0x0D, blue: 0x0C)
    guard wait(seconds: 30, until: { watch.reports.last?.background == finished }) else {
        return refuse("the writer's last background was never reported; \(watch.reports.count) reports")
    }
    let carried = watch.reports.filter { $0.background == canary }.count
    guard carried == 0 else {
        return refuse("\(carried) of \(watch.reports.count) reports carried a background set only inside a synchronized update")
    }
    guard watch.reports.last == surface.colors else {
        return refuse("the last report is not the colours the surface holds")
    }
    print("consumer: a program's colours over its terminal reported \(watch.reports.count) times, never from inside an update")
    return true
}

/// Runs a program on the surface's pseudo-terminal that moves the background
/// outside any synchronized update and then writes updates back to back for
/// seconds, moving nothing inside them, and hears the background long before
/// the updates stop: each one that ends is a frame the grid draws it in.
///
/// - Parameter writer: The program, which the surface runs as its shell.
@MainActor
func followsAColorPastBackToBackUpdates(writer: String) -> Bool {
    guard let surface = TerminalSurface(rows: 24, columns: 80) else {
        return refuse("no surface for back-to-back updates")
    }
    let watch = ColorWatch()
    surface.observer = watch
    setenv("SHELL", writer, 1)
    guard surface.launchShell() else {
        return refuse("the back-to-back writer did not launch")
    }
    let moved = TerminalColor(red: 0x44, green: 0x55, blue: 0x66)
    let finished = TerminalColor(red: 0x0E, green: 0x0D, blue: 0x0C)
    guard wait(seconds: 60, until: { watch.reports.last?.background == finished }) else {
        return refuse("the back-to-back writer's last background was never reported; \(watch.reports.count) reports")
    }
    guard let movedIndex = watch.reports.firstIndex(where: { $0.background == moved }), let finishedAt = watch.reportTimes.last else {
        return refuse("the background set before the updates was never reported on its own")
    }
    // The writer spends three seconds on its updates; a report that waited for
    // them to stop lands beside the last one.
    let lead = finishedAt.timeIntervalSince(watch.reportTimes[movedIndex])
    guard lead > 1.5 else {
        return refuse(String(format: "the background set before three seconds of updates was reported %.2f s before they stopped", lead))
    }
    print(String(format: "consumer: a colour set before back-to-back updates was reported %.2f s before they stopped", lead))
    return true
}

/// An image drawn into a square sRGB bitmap of `side` pixels, as
/// premultiplied red, green, blue and alpha bytes, on whatever thread calls.
func pixels(of image: NSImage, side: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        return []
    }
    bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
    }
    return bytes
}

/// The colour of each fully opaque pixel among `bytes`.
func opaqueColors(_ bytes: [UInt8]) -> [(red: UInt8, green: UInt8, blue: UInt8)] {
    stride(from: 0, to: bytes.count, by: 4).compactMap { index in
        bytes[index + 3] == 255 ? (bytes[index], bytes[index + 1], bytes[index + 2]) : nil
    }
}

/// Whether a colour is within a few units of another in every channel.
func isNear(_ color: (red: UInt8, green: UInt8, blue: UInt8), _ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
    abs(Int(color.red) - Int(red)) <= 3 && abs(Int(color.green) - Int(green)) <= 3 && abs(Int(color.blue) - Int(blue)) <= 3
}

/// Looks programs' icons up by catalog key, as a host drawing its own tabs
/// does: a drawn icon in its own colours, with Core's plate decision; a
/// template icon in the ink it is given; and nothing for a key the catalog
/// does not hold. The host carries no icon of its own, so every pixel comes
/// from the framework's files.
@MainActor
func looksUpProgramIcons() -> Bool {
    let side = TerminalSurface.ProgramIcon.preferredSide
    let square = NSSize(width: side, height: side)
    guard let claude = TerminalSurface.ProgramIcon(key: "claude-code") else {
        return refuse("no icon for the catalog key claude-code")
    }
    guard claude.key == "claude-code", claude.title == "Claude Code", claude.renderingMode == .original, !claude.image.isTemplate,
        claude.image.size == square, claude.image.accessibilityDescription == "Claude Code"
    else {
        return refuse("claude-code's icon reads as \(claude.key), \(claude.title), \(claude.renderingMode), \(claude.image)")
    }
    // The catalog's own colour for Claude Code, which its file is drawn in.
    let own = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    let drawn = opaqueColors(pixels(of: claude.image, side: 32))
    guard drawn.count >= 32, drawn.contains(where: { isNear($0, 0xD9, 0x77, 0x57) }) else {
        return refuse("claude-code's icon drew \(drawn.count) opaque pixels, none of them its own colour")
    }
    // Core's plate: none on black, which the colour stands out on; one on a
    // ground of the colour itself.
    guard !claude.needsPlate(on: .black), claude.needsPlate(on: own) else {
        return refuse("claude-code needs a plate on black: \(claude.needsPlate(on: .black)); on its own colour: \(claude.needsPlate(on: own))")
    }
    guard let bare = claude.image(side: 32, ink: .black, ground: .black), let plated = claude.image(side: 32, ink: .black, ground: own),
        bare.size == NSSize(width: 32, height: 32)
    else {
        return refuse("claude-code drew no image at 32 points")
    }
    let bareCount = opaqueColors(pixels(of: bare, side: 32)).count
    let platedCount = opaqueColors(pixels(of: plated, side: 32)).count
    guard platedCount > bareCount else {
        return refuse("claude-code on its own colour drew \(platedCount) opaque pixels, no more than the \(bareCount) it drew on black")
    }
    guard claude.image(side: 0, ink: .black, ground: .black) == nil else {
        return refuse("claude-code drew an image with no side")
    }

    guard let template = TerminalSurface.ProgramIcon(key: "opencode") else {
        return refuse("no icon for the catalog key opencode")
    }
    guard template.renderingMode == .template, template.image.isTemplate, !template.needsPlate(on: .white),
        !template.needsPlate(on: .black)
    else {
        return refuse("opencode's icon reads as \(template.renderingMode), template \(template.image.isTemplate)")
    }
    let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    guard let inked = template.image(side: 32, ink: red, ground: .white) else {
        return refuse("opencode drew no image at 32 points")
    }
    let inkedColors = opaqueColors(pixels(of: inked, side: 32))
    guard !inkedColors.isEmpty, inkedColors.allSatisfy({ isNear($0, 255, 0, 0) }) else {
        return refuse("opencode in red drew \(inkedColors.count) opaque pixels, not all red")
    }

    // Each lookup's image is its own, so a host resizing one leaves the next.
    guard let again = TerminalSurface.ProgramIcon(key: "claude-code"), again.image !== claude.image else {
        return refuse("two lookups of claude-code share an image")
    }
    claude.image.size = NSSize(width: 64, height: 64)
    guard TerminalSurface.ProgramIcon(key: "claude-code")?.image.size == square else {
        return refuse("resizing one lookup's image resized the next")
    }

    // A name is not a key, and a key is matched as the catalog spells it.
    for key in ["", "claude", "no-such-program", "Claude-Code"] where TerminalSurface.ProgramIcon(key: key) != nil {
        return refuse("an icon for \"\(key)\", which is no catalog key")
    }
    print("consumer: claude-code's and opencode's icons drew from the framework's files, and no other key has one")
    return true
}

/// What a host reads of a program's icon: its values, Core's plate decision
/// on each of a few grounds, and its image's pixels.
struct ProgramIconReading: Equatable, Sendable {
    let key: String
    let title: String
    let renderingMode: TerminalSurface.ProgramIcon.RenderingMode
    let needsPlate: [Bool]
    let imagePixels: [UInt8]

    /// Reads an icon on whatever thread calls.
    init(of icon: TerminalSurface.ProgramIcon, on grounds: [NSColor]) {
        key = icon.key
        title = icon.title
        renderingMode = icon.renderingMode
        needsPlate = grounds.map { icon.needsPlate(on: $0) }
        imagePixels = pixels(of: icon.image, side: 32)
    }
}

/// Runs `body` on a thread of its own and waits for its answer.
///
/// - Returns: The answer, and whether the thread it ran on was the main one.
func onAnotherThread<Answer: Sendable>(_ body: @escaping @Sendable () -> Answer) -> (answer: Answer, wasMainThread: Bool)? {
    let outcome = OSAllocatedUnfairLock<(answer: Answer, wasMainThread: Bool)?>(initialState: nil)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        let answer = body()
        outcome.withLock { $0 = (answer, Thread.isMainThread) }
        done.signal()
    }
    done.wait()
    return outcome.withLock { $0 }
}

/// Hands programs' icons to a thread other than the main one, as a host
/// rasterising an icon for a thumbnail or a cache does, and reads them there:
/// each icon's values, Core's plate decision and its image, and the images
/// `image(side:ink:ground:)` makes, plated and in a template's ink. Each is
/// read or drawn there before anything does so on the main thread, which must
/// then answer the same and draw byte for byte the same.
@MainActor
func drawsProgramIconsOffTheMainThread() -> Bool {
    guard let claude = TerminalSurface.ProgramIcon(key: "claude-code"), let template = TerminalSurface.ProgramIcon(key: "opencode") else {
        return refuse("no icon for the catalog keys claude-code and opencode")
    }
    let own = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    guard let plated = claude.image(side: 32, ink: .black, ground: own), let inked = template.image(side: 32, ink: red, ground: .white) else {
        return refuse("claude-code or opencode drew no image at 32 points")
    }
    // The icon itself crosses to the other thread, as a host's background
    // task or cache takes it: Core's plate decision there is the main
    // thread's, none on black and one on the icon's own colour for a drawn
    // icon and none for a template.
    let grounds: [NSColor] = [.black, own]
    let icons: [(icon: TerminalSurface.ProgramIcon, needsPlate: [Bool])] = [(claude, [false, true]), (template, [false, false])]
    for (icon, needsPlate) in icons {
        guard let elsewhere = onAnotherThread({ ProgramIconReading(of: icon, on: grounds) }), !elsewhere.wasMainThread else {
            return refuse("\(icon.key)'s icon was not read on a thread of its own")
        }
        guard elsewhere.answer.key == icon.key, elsewhere.answer.needsPlate == needsPlate else {
            return refuse("\(icon.key)'s icon read off the main thread as \(elsewhere.answer.key), plates \(elsewhere.answer.needsPlate)")
        }
        let onMainThread = ProgramIconReading(of: icon, on: grounds)
        guard !opaqueColors(onMainThread.imagePixels).isEmpty, elsewhere.answer == onMainThread else {
            return refuse("\(icon.key)'s icon read differently off the main thread than on it")
        }
    }
    let images: [(name: String, image: NSImage)] = [
        ("claude-code on its plate", plated),
        ("opencode in red", inked),
    ]
    for (name, image) in images {
        guard let elsewhere = onAnotherThread({ pixels(of: image, side: 32) }), !elsewhere.wasMainThread else {
            return refuse("\(name) was not drawn on a thread of its own")
        }
        let onMainThread = pixels(of: image, side: 32)
        guard !opaqueColors(onMainThread).isEmpty, elsewhere.answer == onMainThread else {
            return refuse("\(name) drew differently off the main thread than on it")
        }
    }
    print("consumer: claude-code's and opencode's icons read and drew off the main thread as on it, and so did claude-code on its plate and opencode in red")
    return true
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
    case "program-icons":
        return looksUpProgramIcons()
    case "program-icons-off-main":
        return drawsProgramIconsOffTheMainThread()
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
    case "theme":
        return followsTheThemeColors() && followsAWithheldSurfacesColors()
    case "program-colors":
        guard let writer = arguments.first else {
            return refuse("no writer program")
        }
        return followsAProgramsColorsOverItsTerminal(writer: writer)
    case "back-to-back":
        guard let writer = arguments.first else {
            return refuse("no back-to-back writer program")
        }
        return followsAColorPastBackToBackUpdates(writer: writer)
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
    -warnings-as-errors \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/UbiquittyKit.framework"

# The consumers run in an empty home under an environment of nothing else,
# with /bin/sh as the shell the window consumer floods. A run reads none of the
# configuration or startup files of whoever ran it, which could change what it
# draws, answer the commands it types or replace the shell, and it writes
# nothing to their shell history.
TEMPORARY_ROOT="${TMPDIR:-/tmp}"
CONSUMER_HOME="$(mktemp -d "${TEMPORARY_ROOT%/}/ubiquittykit-consumer.XXXXXX")"
trap 'rm -rf "$CONSUMER_HOME"' EXIT
run_consumer() {
    env -i HOME="$CONSUMER_HOME" TMPDIR="$CONSUMER_HOME" SHELL=/bin/sh PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"
}

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

# The program the consumer runs on a surface's pseudo-terminal. Each round
# moves the background outside any synchronized update, then opens one, sets a
# canary background, floods text and puts the background back before closing
# it, so no frame the grid draws shows the canary. The pause between the two
# writes varies, so updates open at different points of a delivery.
cat > "$HOST_DIR/writer.swift" <<'EOF'
import Darwin

func put(_ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        guard written > 0 else { exit(1) }
        offset += written
    }
}

let flood = String(repeating: String(repeating: "y", count: 79) + "\r\n", count: 2500)
for round in 0..<40 {
    let outside = round.isMultiple(of: 2) ? "rgb:10/20/30" : "rgb:30/20/10"
    put("\u{1b}]11;\(outside)\u{7}")
    usleep(useconds_t(round % 8 * 40))
    put("\u{1b}[?2026h\u{1b}]11;rgb:ab/01/cd\u{7}" + flood + "\u{1b}]11;\(outside)\u{7}\u{1b}[?2026l")
}
put("\u{1b}]11;rgb:0e/0d/0c\u{7}")
sleep(30)
EOF

# The program that moves the background once outside any synchronized update
# and then writes 200 KB updates back to back for three seconds, moving no
# colour inside them, so a pass of the drain almost always ends inside one.
cat > "$HOST_DIR/back-to-back-writer.swift" <<'EOF'
import Darwin

func put(_ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        guard written > 0 else { exit(1) }
        offset += written
    }
}

let update = "\u{1b}[?2026h" + String(repeating: String(repeating: "z", count: 79) + "\r\n", count: 2500) + "\u{1b}[?2026l"
put("\u{1b}]11;rgb:44/55/66\u{7}")
let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start < 3_000_000_000 {
    put(update)
}
put("\u{1b}]11;rgb:0e/0d/0c\u{7}")
sleep(30)
EOF

xcrun swiftc -O "$HOST_DIR/writer.swift" -o "$HOST_DIR/writer"
xcrun swiftc -O "$HOST_DIR/back-to-back-writer.swift" -o "$HOST_DIR/back-to-back-writer"

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
run_consumer "$consumer" preferred ${preferred[@]+"${preferred[@]}"}
echo "check-ubiquittykit: ok (the preferred family is the first this system has or the framework ships, and choosing it registers every shipped font)"
run_consumer "$consumer" lookup
echo "check-ubiquittykit: ok (a family is looked up by name after the shipped fonts are registered)"
run_consumer "$consumer" renderer
echo "check-ubiquittykit: ok (a renderer built before any surface registers the shipped fonts)"
run_consumer "$consumer" faces
echo "check-ubiquittykit: ok (every shipped style and the symbol face are opened from the framework's files)"
run_consumer "$consumer" icons
echo "check-ubiquittykit: ok (the Phosphor and program icons are drawn from the framework's files)"
run_consumer "$consumer" program-icons
echo "check-ubiquittykit: ok (a program's icon is looked up by catalog key from the framework's files, drawn and template icons each as the catalog paints them, and an unknown key has none)"
run_consumer "$consumer" program-icons-off-main
echo "check-ubiquittykit: ok (a program's icon handed to another thread reads and draws there as on the main thread, and so do the images drawn for a title)"
run_consumer "$consumer" family
echo "check-ubiquittykit: ok (a surface reports a family that is drawn as configured, under any of its names, and one that is not by the family drawn in its place)"
run_consumer "$consumer" draw
echo "check-ubiquittykit: ok (the signed app drew a frame in a shipped family through its embedded framework)"
run_consumer "$consumer" theme
echo "check-ubiquittykit: ok (a theme's colors are read without a surface and applied by name, and a surface reports the colors a program moves, once per batch, never for one that moves nothing and not inside a synchronized update)"
run_consumer "$consumer" program-colors "$HOST_DIR/writer"
echo "check-ubiquittykit: ok (a program on the surface's pseudo-terminal moves the colors without one reported from inside a synchronized update)"
run_consumer "$consumer" back-to-back "$HOST_DIR/back-to-back-writer"
echo "check-ubiquittykit: ok (a color set before back-to-back synchronized updates is reported while they run)"

cat > "$HOST_DIR/window.swift" <<'EOF'
import AppKit
import Foundation
import QuartzCore
import UbiquittyKit

/// What a host's requests for the surface layer's drawables came to.
final class DrawableRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var askedCount = 0
    private var answeredNilUnderLinkCount = 0
    private var vendedAfterLinkCount = 0
    private var isStopRequested = false

    var asked: Int { lock.withLock { askedCount } }
    var answeredNilUnderLink: Int { lock.withLock { answeredNilUnderLinkCount } }
    var vendedAfterLink: Int { lock.withLock { vendedAfterLinkCount } }
    var shouldStop: Bool {
        get { lock.withLock { isStopRequested } }
        set { lock.withLock { isStopRequested = newValue } }
    }

    /// Asks `layer`, which holds a device, for a drawable and files the answer.
    ///
    /// Such a layer answers nil at once only while a display link delivers
    /// its drawables; with none attached it hands one out, or answers nil
    /// after waiting up to a second for one.
    ///
    /// - Returns: Whether the layer answered nil at once.
    @discardableResult
    func ask(_ layer: CAMetalLayer) -> Bool {
        let asked = Date()
        let drawable = layer.nextDrawable()
        let isAnsweredNilAtOnce = drawable == nil && Date().timeIntervalSince(asked) < 0.5
        lock.withLock {
            askedCount += 1
            if isAnsweredNilAtOnce {
                answeredNilUnderLinkCount += 1
            } else if drawable != nil, answeredNilUnderLinkCount > 0 {
                vendedAfterLinkCount += 1
            }
        }
        return isAnsweredNilAtOnce
    }
}

/// The surface's layer, handed to a thread of the host's own.
final class LayerReference: @unchecked Sendable {
    let layer: CAMetalLayer

    init(_ layer: CAMetalLayer) { self.layer = layer }
}

@MainActor
func refuse(_ message: String) -> Bool {
    FileHandle.standardError.write(Data("window-consumer: \(message)\n".utf8))
    return false
}

/// Turns the main run loop until `isDone` answers true or the time runs out.
@MainActor
func spin(seconds: Double, until isDone: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !isDone(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    return isDone()
}

/// Turns the run loop until `isDone` answers true or the time runs out,
/// hiding and showing the surface each half second that passes without.
///
/// The surface's window is off every screen, so the window system reports it
/// covered, and a covered surface drives its display link only for a second
/// after an edge that shows it. The edge is made here, so the link attaches
/// when this host asks rather than whenever that report lands.
@MainActor
func spinRevealing(_ surface: TerminalSurface, seconds: Double, until isDone: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !spin(seconds: 0.5, until: isDone), Date() < deadline {
        surface.isHidden = true
        surface.isHidden = false
    }
    return isDone()
}

/// Has a thread of the host's own ask `reference`'s layer for a drawable,
/// and waits for the answer.
///
/// The surface attaches and detaches its display link on the main thread,
/// so the link stays as it was for as long as this waits.
@MainActor
func askFromThread(_ requests: DrawableRequests, _ reference: LayerReference) {
    let answered = DispatchSemaphore(value: 0)
    Thread {
        requests.ask(reference.layer)
        answered.signal()
    }.start()
    answered.wait()
}

let passed = MainActor.assumeIsolated { () -> Bool in
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.finishLaunching()
    guard let surface = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13),
        let renderer = surface.renderer
    else {
        return refuse("no surface with a renderer from the font-taking initializer")
    }
    let window = NSWindow(
        contentRect: CGRect(x: -4000, y: -4000, width: 640, height: 384),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = surface
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    // The host draws nothing itself, so a frame the renderer submitted for
    // the surface is one the surface drew into its own layer.
    surface.feed(Data("ubiquittykit-window\r\n".utf8))
    guard spin(seconds: 5, until: { renderer.presentedGeometry(for: surface) != nil }) else {
        let device = surface.metalLayer.device == nil ? "no device" : "a device"
        return refuse("a surface in a window submitted no frame in 5 s; its layer has \(device)")
    }
    guard surface.launchShell() else {
        return refuse("no shell")
    }

    // A flood, so the surface's display link takes over the layer's
    // drawables, and a host asking that layer for one from a main-actor task
    // meanwhile. A raise ends the process.
    let mainActorRequests = DrawableRequests()
    surface.send("yes\r")
    Task { @MainActor in
        while !mainActorRequests.shouldStop {
            try? await Task.sleep(for: .milliseconds(10))
            mainActorRequests.ask(surface.metalLayer)
        }
    }
    guard spinRevealing(surface, seconds: 10, until: { mainActorRequests.answeredNilUnderLink >= 3 }) else {
        mainActorRequests.shouldStop = true
        return refuse(
            "\(mainActorRequests.answeredNilUnderLink) of \(mainActorRequests.asked) drawable requests from a "
                + "main-actor task met the display link delivering the layer's drawables in 10 s, not 3"
        )
    }

    // A thread of the host's own, asked each time the main thread has just
    // been answered nil at once, so while the link certainly delivers.
    let threadRequests = DrawableRequests()
    let reference = LayerReference(surface.metalLayer)
    let mainThreadProbe = DrawableRequests()
    let threadMetLink = spinRevealing(surface, seconds: 10) {
        if mainThreadProbe.ask(surface.metalLayer) {
            askFromThread(threadRequests, reference)
        }
        return threadRequests.asked >= 3
    }
    guard threadMetLink, threadRequests.answeredNilUnderLink == threadRequests.asked else {
        mainActorRequests.shouldStop = true
        return refuse(
            "\(threadRequests.answeredNilUnderLink) of \(threadRequests.asked) drawable requests from a thread, "
                + "each made while the display link delivered the layer's drawables, were answered nil at once"
        )
    }

    // Interrupted, the flood stops, the link stands down, and the layer hands
    // drawables again, to the task and then to the thread.
    surface.send("\u{3}")
    let vendedAgain = spin(seconds: 5) { mainActorRequests.vendedAfterLink > 0 }
    mainActorRequests.shouldStop = true
    guard vendedAgain else {
        return refuse("the layer handed a main-actor task no drawable in 5 s once its display link stood down")
    }
    guard spin(seconds: 5, until: {
        askFromThread(threadRequests, reference)
        return threadRequests.vendedAfterLink > 0
    }) else {
        return refuse("the layer handed a thread no drawable in 5 s once its display link stood down")
    }
    print(
        "window-consumer: \(mainActorRequests.answeredNilUnderLink) of \(mainActorRequests.asked) drawable "
            + "requests from a main-actor task and \(threadRequests.answeredNilUnderLink) of "
            + "\(threadRequests.asked) from a thread answered nil under the display link, then each vended"
    )

    // A thread asking on its own schedule through a second flood, while the
    // surface hides and shows and starts and stops its link under it. A link
    // attaches only while no acquire waits, so a thread that keeps one
    // waiting keeps the surface on its view's display link instead.
    let freeRequests = DrawableRequests()
    let finished = DispatchSemaphore(value: 0)
    Thread {
        while !freeRequests.shouldStop {
            freeRequests.ask(reference.layer)
            Thread.sleep(forTimeInterval: 0.025)
        }
        finished.signal()
    }.start()
    surface.send("yes\r")
    _ = spinRevealing(surface, seconds: 2) { false }
    surface.send("\u{3}")
    freeRequests.shouldStop = true
    finished.wait()
    print(
        "window-consumer: a thread asking through a second flood was answered \(freeRequests.asked) times, "
            + "\(freeRequests.answeredNilUnderLink) of them nil under the display link"
    )
    return true
}
exit(passed ? 0 : 1)
EOF

xcrun swiftc "$HOST_DIR/window.swift" \
    -o "$HOST_DIR/window-consumer" \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"

run_consumer "$HOST_DIR/window-consumer"
echo "check-ubiquittykit: ok (a surface in a window drew its own frame, and its layer answered a host's task and thread nil under the display link, never a raise)"

# The clear commands, from a host that has only the public interface. Each pane
# runs a program of known output as its login shell: sixty numbered lines and a
# two-line prompt, marked as shell integration marks it, after which it writes
# every byte the terminal sends it to a file. What the screen and its history
# hold is read the way an assistive reader reads it; what the program was sent
# is that file, read up to a sentinel sent after the clear.
CLEAR_DIR="$BUILD/clear-consumer"
rm -rf "$CLEAR_DIR"
mkdir -p "$CLEAR_DIR/input"
cat > "$CLEAR_DIR/pane-program" <<'EOF'
#!/bin/sh
i=1
while [ "$i" -le 60 ]; do
    printf 'line-%02d\n' "$i"
    i=$((i + 1))
done
stty raw -echo
printf '\033]133;A\007user@host ~\r\nprompt$ '
exec cat >"$UBIQUITTY_KIT_CONSUMER_INPUT"
EOF
chmod +x "$CLEAR_DIR/pane-program"
cat > "$CLEAR_DIR/main.swift" <<'EOF'
import AppKit
import Foundation
import UbiquittyKit

final class SelectionWatch: TerminalSurfaceObserver {
    var changes = 0

    func terminalSurfaceSelectionDidChange(_: TerminalSurface) {
        changes += 1
    }
}

@MainActor
final class Pane {
    let surface: TerminalSurface
    let input: String
    var bytesRead = 0

    init(surface: TerminalSurface, input: String) {
        self.surface = surface
        self.input = input
    }
}

@MainActor
final class ClearConsumer {
    let program: String
    let inputDirectory: String
    var failures = 0
    let prompt = ["user@host ~", "prompt$"]
    let tail = (39...60).map { String(format: "line-%02d", $0) } + ["user@host ~", "prompt$"]

    init(program: String, inputDirectory: String) {
        self.program = program
        self.inputDirectory = inputDirectory
    }

    func expect(_ condition: Bool, _ what: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("clear-consumer: FAIL: \(what)\n".utf8))
        }
    }

    func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return true
    }

    func rows(_ surface: TerminalSurface) -> [String] {
        (surface.accessibilityValue() as? String ?? "").components(separatedBy: "\n")
    }

    func blank(_ count: Int) -> [String] { Array(repeating: "", count: count) }

    // A scroll reaches as far as the history the surface has published, which
    // can trail the text read through accessibilityValue() while output is
    // arriving, so a scroll is repeated until the view shows what it should.
    func scroll(_ surface: TerminalSurface, _ action: String, until condition: () -> Bool) -> Bool {
        waitUntil(seconds: 10) {
            surface.performKeyAction(named: action)
            return condition()
        }
    }

    // Forty lines of output, written to the terminal as a program writes
    // them: whether the view follows them, showing the last twenty-four.
    func viewFollowsOutput(_ surface: TerminalSurface, _ label: String) -> Bool {
        let lines = (1...40).map { label + String(format: "-%02d", $0) }
        surface.feed(Data(lines.map { "\r\n" + $0 }.joined().utf8))
        return waitUntil(seconds: 10) { rows(surface) == Array(lines[16...]) }
    }

    func openPane(_ name: String) -> Pane? {
        let input = inputDirectory + "/" + name
        FileManager.default.createFile(atPath: input, contents: nil)
        setenv("SHELL", program, 1)
        setenv("UBIQUITTY_KIT_CONSUMER_INPUT", input, 1)
        guard let surface = TerminalSurface(rows: 24, columns: 80), surface.launchShell() else {
            expect(false, "\(name): a surface launched its program")
            return nil
        }
        guard waitUntil(seconds: 20, { rows(surface) == tail }) else {
            expect(false, "\(name): the program's output filled the screen (shows \(rows(surface)))")
            return nil
        }
        expect(
            scroll(surface, "scroll_to_top", until: { rows(surface).first == "line-01" }),
            "\(name): the history holds the program's first line (shows \(rows(surface)))"
        )
        surface.performKeyAction(named: "scroll_to_bottom")
        return Pane(surface: surface, input: input)
    }

    // The bytes the program read since the last call, through a sentinel the
    // terminal sends after them.
    func received(_ pane: Pane) -> [UInt8]? {
        pane.surface.send("#")
        var bytes: [UInt8] = []
        let didArrive = waitUntil(seconds: 10) {
            bytes = Array(FileManager.default.contents(atPath: pane.input) ?? Data())
            return bytes.count > pane.bytesRead && bytes.last == UInt8(ascii: "#")
        }
        guard didArrive else { return nil }
        defer { pane.bytesRead = bytes.count }
        return Array(bytes[pane.bytesRead..<(bytes.count - 1)])
    }

    func run() -> Bool {
        let watch = SelectionWatch()

        if let pane = openPane("buffer") {
            let surface = pane.surface
            surface.observer = watch
            surface.selectAll(nil)
            expect(surface.hasSelection && rows(surface) == tail, "buffer: the screen is selected and unchanged")
            surface.performKeyAction(named: "scroll_page_up")
            expect(rows(surface) != tail, "buffer: the view is scrolled back")
            let changes = watch.changes
            surface.clear(.buffer)
            expect(rows(surface) == ["prompt$"] + blank(23), "buffer: the input line rises to a blank screen (shows \(rows(surface)))")
            expect(!surface.hasSelection, "buffer: the selection is dropped")
            expect(watch.changes > changes, "buffer: the observer hears the selection go")
            let sent = received(pane)
            expect(sent == [0x0C], "buffer: the program is sent Ctrl-L (got \(String(describing: sent)))")

            // The view the clear returned to the tail follows the output that
            // refills the history, which begins at the line the clear kept.
            expect(viewFollowsOutput(surface, "buffer"), "buffer: the view follows the output after the clear (shows \(rows(surface)))")
            let kept = ["prompt$"] + (1...23).map { String(format: "buffer-%02d", $0) }
            expect(
                scroll(surface, "scroll_to_top", until: { rows(surface) == kept }),
                "buffer: no history is left from before the clear (shows \(rows(surface)))"
            )
        }

        if let pane = openPane("scrollback") {
            let surface = pane.surface
            surface.performKeyAction(named: "scroll_page_up")
            expect(rows(surface) != tail, "scrollback: the view is scrolled back")
            surface.clear(.scrollback)
            expect(rows(surface) == tail, "scrollback: the view is at the tail and the screen stands (shows \(rows(surface)))")
            surface.performKeyAction(named: "scroll_to_top")
            expect(rows(surface) == tail, "scrollback: no history is left (shows \(rows(surface)))")
            var sent = received(pane)
            expect(sent == [], "scrollback: the program is sent nothing (got \(String(describing: sent)))")

            // With nothing selected and the view at the tail, no selection
            // change and no viewport move follow a clear, and the text read
            // just before it is what each must replace.
            expect(!surface.hasSelection && rows(surface) == tail, "scrollback: nothing is selected and the view is at the tail")
            surface.clear(.screen)
            expect(rows(surface) == prompt + blank(22), "scrollback: Clear Screen at the tail with nothing selected moves the prompt to the top row (shows \(rows(surface)))")
            surface.clear(.buffer)
            expect(rows(surface) == ["prompt$"] + blank(23), "scrollback: Clear Buffer at the tail with nothing selected leaves the input line (shows \(rows(surface)))")
            sent = received(pane)
            expect(sent == [0x0C], "scrollback: the program is sent Ctrl-L for Clear Buffer alone (got \(String(describing: sent)))")

            // A view scrolled back when Clear Scrollback empties the history
            // returns to the tail, and follows the output that refills it.
            expect(viewFollowsOutput(surface, "before"), "scrollback: output fills the history again (shows \(rows(surface)))")
            expect(
                scroll(surface, "scroll_page_up", until: { rows(surface).last != "before-40" }),
                "scrollback: the view is scrolled back over the new history (shows \(rows(surface)))"
            )
            surface.clear(.scrollback)
            expect(viewFollowsOutput(surface, "after"), "scrollback: the view follows the output that refills the history (shows \(rows(surface)))")
        }

        if let pane = openPane("screen") {
            let surface = pane.surface
            surface.observer = watch
            surface.selectAll(nil)
            expect(surface.hasSelection && rows(surface) == tail, "screen: the screen is selected and unchanged")
            surface.performKeyAction(named: "scroll_page_up")
            expect(rows(surface) != tail, "screen: the view is scrolled back")
            let changes = watch.changes
            surface.clear(.screen)
            expect(rows(surface) == prompt + blank(22), "screen: the view is at the tail and the prompt's first row is its top row (shows \(rows(surface)))")
            expect(!surface.hasSelection, "screen: the selection is dropped")
            expect(watch.changes > changes, "screen: the observer hears the selection go")
            for _ in 0..<22 {
                surface.performKeyAction(named: "scroll_line_up")
            }
            expect(rows(surface) == tail, "screen: the rows above the prompt are the history's last rows (shows \(rows(surface)))")
            surface.performKeyAction(named: "scroll_to_top")
            expect(rows(surface).first == "line-01", "screen: the history keeps its first line")
            surface.performKeyAction(named: "scroll_to_bottom")
            var sent = received(pane)
            expect(sent == [], "screen: the program is sent nothing (got \(String(describing: sent)))")

            // A program on the alternate screen owns its rows, so both
            // commands that would change them send it Ctrl-L instead.
            let alternate = ["alternate"] + blank(23)
            surface.feed(Data("\u{1B}[?1049h\u{1B}[Halternate".utf8))
            expect(waitUntil(seconds: 10, { rows(surface) == alternate }), "screen: the alternate screen shows (shows \(rows(surface)))")
            surface.selectAll(nil)
            surface.clear(.screen)
            surface.clear(.buffer)
            expect(rows(surface) == alternate, "screen: the alternate screen stands (shows \(rows(surface)))")
            expect(surface.hasSelection, "screen: the alternate screen's selection stays")
            sent = received(pane)
            expect(sent == [0x0C, 0x0C], "screen: the program is sent Ctrl-L for each (got \(String(describing: sent)))")

            // Clear Scrollback asks the program for nothing, so it runs on the
            // alternate screen too, and the selection goes with the history.
            let heard = watch.changes
            surface.clear(.scrollback)
            expect(rows(surface) == alternate, "screen: the alternate screen stands Clear Scrollback (shows \(rows(surface)))")
            expect(!surface.hasSelection, "screen: Clear Scrollback drops the alternate screen's selection")
            expect(watch.changes > heard, "screen: the observer hears it go")
            sent = received(pane)
            expect(sent == [], "screen: Clear Scrollback sends the program nothing (got \(String(describing: sent)))")
            surface.feed(Data("\u{1B}[?1049l".utf8))
            expect(waitUntil(seconds: 10, { rows(surface) == prompt + blank(22) }), "screen: the main screen returns (shows \(rows(surface)))")
            surface.performKeyAction(named: "scroll_to_top")
            expect(rows(surface) == prompt + blank(22), "screen: the main screen's history is gone (shows \(rows(surface)))")
        }

        // The surface's own context menu, which a host shows as it is: its
        // clear and reset items reach the surface it opened over through no
        // responder but the surface.
        if let surface = TerminalSurface(rows: 24, columns: 80) {
            let lines = (1...60).map { String(format: "line-%02d", $0) }
            let screen = Array(lines[37...]) + [""]
            surface.feed(Data(lines.map { $0 + "\r\n" }.joined().utf8))
            expect(waitUntil(seconds: 10, { rows(surface) == screen }), "menu: the lines fill the screen (shows \(rows(surface)))")
            expect(scroll(surface, "scroll_to_top", until: { rows(surface).first == "line-01" }), "menu: the history holds the first line")
            surface.performKeyAction(named: "scroll_to_bottom")

            let click = NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: 4, y: 4),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
            let menu = click.flatMap { surface.menu(for: $0) }
            func pick(_ title: String) {
                guard let item = menu?.items.first(where: { $0.title == title }), let action = item.action else {
                    expect(false, "menu: the menu offers \(title)")
                    return
                }
                let target = NSApplication.shared.target(forAction: action, to: item.target, from: item).map { $0 as AnyObject }
                expect(target === surface && surface.validateMenuItem(item), "menu: \(title) is enabled and answered by the surface")
                expect(NSApplication.shared.sendAction(action, to: item.target, from: item), "menu: picking \(title) reaches a responder")
            }

            pick("Clear Scrollback")
            surface.performKeyAction(named: "scroll_to_top")
            expect(rows(surface) == screen, "menu: Clear Scrollback leaves no history (shows \(rows(surface)))")
            surface.performKeyAction(named: "scroll_to_bottom")

            // Insert mode on, which a soft reset turns off: the next character
            // then overwrites rather than pushing the row along.
            surface.feed(Data("\u{1B}[H\u{1B}[2Jabc\r\u{1B}[4hY".utf8))
            expect(waitUntil(seconds: 10, { rows(surface).first == "Yabc" }), "menu: insert mode inserts (shows \(rows(surface)))")
            pick("Reset Terminal")
            surface.feed(Data("Z".utf8))
            expect(waitUntil(seconds: 10, { rows(surface).first != "Yabc" }), "menu: the next character lands")
            expect(rows(surface).first == "YZbc", "menu: Reset Terminal turns insert mode off (shows \(rows(surface)))")
        } else {
            expect(false, "menu: a surface is made")
        }
        return failures == 0
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: clear-consumer <pane-program> <input-directory>\n".utf8))
    exit(2)
}
let passed = MainActor.assumeIsolated {
    ClearConsumer(program: arguments[1], inputDirectory: arguments[2]).run()
}
exit(passed ? 0 : 1)
EOF

xcrun swiftc "$CLEAR_DIR/main.swift" \
    -swift-version 6 \
    -o "$CLEAR_DIR/clear-consumer" \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"

run_consumer "$CLEAR_DIR/clear-consumer" "$CLEAR_DIR/pane-program" "$CLEAR_DIR/input"
echo "check-ubiquittykit: ok (external consumer ran Clear Buffer, Clear Scrollback and Clear Screen)"

# The foreground program and its status, from a host that has only the public
# interface. A shell runs in a surface taken out of its window; the program it
# runs is a stock binary copied under a name the process catalog
# (Source/Core/Title/ProcessIconCatalog.h) holds, since nothing the catalog
# names ships with macOS: `sleep` as `claude`, which the catalog keys
# `claude-code`, a key that is not the name, so the consumer cannot pass by
# reading the name back. macOS kills a copied platform binary at exec; an ad hoc
# signature makes the copy an ordinary program under its own name. The shell is
# $SHELL, started as a login shell, and run_consumer's empty HOME leaves it
# nothing but the stock /etc/profile.
PROGRAM_DIR="$BUILD/program-consumer"
rm -rf "$PROGRAM_DIR"
mkdir -p "$PROGRAM_DIR"
/bin/cp /bin/sleep "$PROGRAM_DIR/claude"
if ! /usr/bin/codesign --force --sign - "$PROGRAM_DIR/claude" >>"$LOG" 2>&1; then
    tail -5 "$LOG" >&2
    exit 1
fi
cat > "$PROGRAM_DIR/main.swift" <<'EOF'
import AppKit
import Foundation
import UbiquittyKit

/// What one process-state callback read, taken inside the callback so the
/// values are the ones current when it fires.
struct ProcessReport {
    let name: String
    let key: String?
    let chain: String
    let chainWithArguments: String
    /// The key and title of the icon the surface gives for its program.
    let iconKey: String?
    let iconTitle: String?
}

/// What one status callback read, taken inside the callback for the same reason.
struct StatusReport {
    let status: TerminalSurface.ProgramStatus
    let key: String?
}

/// Records each process-state and status change a surface announces, and
/// what the surface names when its session ends; answers whether it needs
/// process facts as `needsProcessState` says.
@MainActor
final class ProcessWatch: TerminalSurfaceObserver {
    private(set) var reports: [ProcessReport] = []
    private(set) var statuses: [StatusReport] = []
    private(set) var exitReport: ProcessReport?
    var needsProcessState = true

    private static func report(_ surface: TerminalSurface) -> ProcessReport {
        let icon = surface.foregroundProgramIcon
        return ProcessReport(
            name: surface.foregroundProgramName,
            key: surface.foregroundProgramKey,
            chain: surface.foregroundProcessChain,
            chainWithArguments: surface.foregroundProcessChainWithArguments,
            iconKey: icon?.key,
            iconTitle: icon?.title
        )
    }

    nonisolated func terminalSurfaceNeedsProcessState(_ surface: TerminalSurface) -> Bool {
        MainActor.assumeIsolated { needsProcessState }
    }

    nonisolated func terminalSurfaceDidChangeProcessState(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            reports.append(Self.report(surface))
        }
    }

    nonisolated func terminalSurfaceDidChangeTabStatus(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            statuses.append(StatusReport(status: surface.programStatus, key: surface.foregroundProgramKey))
        }
    }

    nonisolated func terminalSurfaceDidExit(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            exitReport = Self.report(surface)
        }
    }
}

func refuse(_ message: String) -> Bool {
    FileHandle.standardError.write(Data("consumer: \(message)\n".utf8))
    return false
}

/// Runs the main loop, which carries the surface's deliveries, until the
/// condition holds or the time is up.
@MainActor
func wait(seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return true
}

/// Launches a shell in a surface taken out of its window, runs the program
/// from it, and reads the program back through the values the process-state
/// callback announces; hears nothing while the observer declines process
/// facts, and the move once it asks again; reads the status a record posts
/// and the colour a program sets through the status callback; and reads
/// nothing named once the shell has exited.
@MainActor
func readsTheForegroundProgram(at path: String, expectedKey: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard let surface = TerminalSurface(rows: 24, columns: 80) else {
        return refuse("no shell surface")
    }
    // A window never ordered front shows no title, so the surface leaves it
    // unpresented: what it hears from here on, it hears because its observer
    // asks for process facts, which is how a host keeps hearing a background
    // tab it keeps out of the window.
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(surface)
    surface.removeFromSuperview()
    // Assigned after the surface has been through a window, so the only
    // question asked of it is the one the assignment asks.
    let watch = ProcessWatch()
    surface.observer = watch
    guard surface.launchShell() else {
        return refuse("the shell did not launch")
    }
    guard wait(seconds: 20, until: { !watch.reports.isEmpty }) else {
        return refuse("no process-state change after the shell launched")
    }
    let shell = surface.foregroundProgramName
    surface.send("'\(path)' 30\n")
    guard wait(seconds: 20, until: { watch.reports.contains { $0.name == name } }),
        let report = watch.reports.first(where: { $0.name == name })
    else {
        return refuse(
            "no process-state change named \(name): heard \(watch.reports.map(\.name)), chain now \(surface.foregroundProcessChain)"
        )
    }
    guard report.key == expectedKey else {
        return refuse("\(name) resolved to key \(report.key ?? "nil"), expected \(expectedKey)")
    }
    // The surface's icon is the catalog's for that key, read in the same
    // callback from the same sample.
    guard report.iconKey == expectedKey, let iconTitle = report.iconTitle, !iconTitle.isEmpty else {
        return refuse("\(name)'s icon is \(report.iconKey ?? "nil") titled \(report.iconTitle ?? "nil"), expected \(expectedKey)'s")
    }
    // The chain names the program without its argument, and is the argument
    // chain with the argument taken out.
    guard report.chain.contains(name), !report.chain.contains("\(name) 30"), report.chainWithArguments.contains("\(name) 30"),
        report.chainWithArguments.replacingOccurrences(of: "\(name) 30", with: name) == report.chain
    else {
        return refuse("\(name)'s chains read \(report.chain) / \(report.chainWithArguments)")
    }
    print("consumer: \(name) runs as key \(expectedKey), chain \(report.chain), with arguments \(report.chainWithArguments)")

    let heardBeforeInterrupt = watch.reports.count
    surface.send("\u{3}")
    guard wait(seconds: 20, until: { watch.reports.dropFirst(heardBeforeInterrupt).contains { $0.name == shell } }),
        let back = watch.reports.dropFirst(heardBeforeInterrupt).first(where: { $0.name == shell })
    else {
        return refuse("the shell \(shell) did not take the terminal back from \(name): heard \(watch.reports.map(\.name))")
    }
    guard back.key == nil, back.iconKey == nil else {
        return refuse("the shell \(shell) at its prompt has the key \(back.key ?? "nil") and the icon \(back.iconKey ?? "nil")")
    }
    print("consumer: \(name)'s icon is \(iconTitle)'s, and the shell at its prompt has none")

    // Declined, the surface samples nothing and says nothing: the program
    // starts unheard, and the name read fresh is still the shell's. Asked
    // again, it samples and names the program.
    watch.needsProcessState = false
    surface.observer = watch
    let heardWhileDeclined = watch.reports.count
    surface.send("'\(path)' 30\n")
    _ = wait(seconds: 2, until: { watch.reports.count != heardWhileDeclined || surface.foregroundProgramName != shell })
    guard watch.reports.count == heardWhileDeclined else {
        return refuse("a surface whose observer declines process facts announced \(watch.reports.dropFirst(heardWhileDeclined).map(\.name))")
    }
    guard surface.foregroundProgramName == shell else {
        return refuse("a surface whose observer declines process facts sampled \(surface.foregroundProgramName)")
    }
    watch.needsProcessState = true
    surface.observer = watch
    guard wait(seconds: 20, until: { watch.reports.dropFirst(heardWhileDeclined).contains { $0.name == name } }) else {
        return refuse("asked again, the surface did not name \(name): heard \(watch.reports.dropFirst(heardWhileDeclined).map(\.name))")
    }
    let heardBeforeSecondInterrupt = watch.reports.count
    surface.send("\u{3}")
    guard wait(seconds: 20, until: { watch.reports.dropFirst(heardBeforeSecondInterrupt).contains { $0.name == shell } }) else {
        return refuse("the shell \(shell) did not take the terminal back a second time: heard \(watch.reports.map(\.name))")
    }
    print("consumer: declined, the surface was silent; asked again, it named \(name)")

    // A record names codex while the shell holds the terminal: the status is
    // the record's, and the key stays the shell's, which the catalog lacks.
    surface.send("printf '\\033]7501;state=working:progress=40:app=codex\\033\\\\'\n")
    guard wait(seconds: 20, until: { watch.statuses.contains { $0.status.kind == .working } }),
        let working = watch.statuses.first(where: { $0.status.kind == .working })?.status
    else {
        return refuse("no status change to working: heard \(watch.statuses.map { String(describing: $0.status.kind) })")
    }
    guard working.progress == 40, working.blockKind == nil, working.colorSlot == .working, working.color != nil,
        working.label.contains("Working")
    else {
        return refuse("the working record reads as \(working)")
    }
    surface.send("printf '\\033]7501;state=blocked:kind=question:app=codex\\033\\\\'\n")
    guard wait(seconds: 20, until: { watch.statuses.contains { $0.status.kind == .blocked } }),
        let blocked = watch.statuses.first(where: { $0.status.kind == .blocked })
    else {
        return refuse("no status change to blocked: heard \(watch.statuses.map { String(describing: $0.status.kind) })")
    }
    guard blocked.status.blockKind == .question, blocked.status.progress == nil, blocked.status.colorSlot == .blocked,
        blocked.status.color != nil, blocked.status.color != working.color, blocked.status.label.contains("Waiting for input")
    else {
        return refuse("the blocked record reads as \(blocked.status) beside working's \(working)")
    }
    guard blocked.key == nil else {
        return refuse("the shell holds the terminal, yet the record keys it \(blocked.key ?? "nil")")
    }
    print("consumer: a blocked record reads as \(blocked.status.label)")

    // With the record cleared, the colour is the one the program chose, each
    // channel its own, and stands for no theme status.
    surface.send("printf '\\033]7501;state=clear\\033\\\\\\033]21337;indicator=#123456;status=deploying\\007'\n")
    guard wait(seconds: 20, until: { watch.statuses.contains { $0.status.kind == nil && $0.status.color != nil } }),
        let indicated = watch.statuses.last(where: { $0.status.kind == nil && $0.status.color != nil })?.status
    else {
        return refuse("no status change to the program's own colour: heard \(watch.statuses.map(\.status))")
    }
    guard let color = indicated.color, color.red == 0x12, color.green == 0x34, color.blue == 0x56,
        indicated.colorSlot == nil, indicated.label == "deploying", indicated.progress == nil
    else {
        return refuse("the program's own colour reads as \(indicated)")
    }
    print("consumer: the program's own colour reads as \(indicated.label)")

    // The session ends: nothing runs there, so nothing is named.
    surface.send("exit\n")
    guard wait(seconds: 20, until: { watch.exitReport != nil }), let ended = watch.exitReport else {
        return refuse("the shell did not exit")
    }
    guard ended.name.isEmpty, ended.key == nil, ended.iconKey == nil, ended.chain.isEmpty, ended.chainWithArguments.isEmpty else {
        return refuse("an ended session still names \(ended)")
    }
    guard let last = watch.reports.last, last.name.isEmpty, last.chain.isEmpty else {
        return refuse("the process-state change at the end names \(String(describing: watch.reports.last))")
    }
    print("consumer: the ended session names nothing")
    return true
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    _ = refuse("usage: program-consumer <program> <catalog key>")
    exit(2)
}
let passed = MainActor.assumeIsolated {
    readsTheForegroundProgram(at: arguments[1], expectedKey: arguments[2])
}
exit(passed ? 0 : 1)
EOF

xcrun swiftc "$PROGRAM_DIR/main.swift" \
    -o "$PROGRAM_DIR/program-consumer" \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"

run_consumer "$PROGRAM_DIR/program-consumer" "$PROGRAM_DIR/claude" claude-code
echo "check-ubiquittykit: ok (external consumer read a shell's foreground program, its icon and its status out of a window, heard nothing while declining, and read nothing named after exit)"

# Another consumer moves panes in code, as a host laying out its own panes
# does: an animation of a pane's frame, a sequence of frames set a display
# refresh apart, lone changes, and a drag of the host's own divider bracketed
# by beginLiveResize() and endLiveResize() and held still on the way. Its
# window is off every screen, so the window system reports it covered and the
# runs draw nothing until an edge reveals the pane. No run in the covered
# window may turn the transactional present on, and every grid the observer
# hears must differ from the one before it. The pane must land on the grid a
# pane laid out once at the final frame takes, draw that grid when a
# key-window edge reveals it, and hold a picture of its text row for row as a
# fresh pane given the same text draws it, cursor hidden in both, with text on
# every row the moves exposed. A run in a window with no extent must leave the
# pane out of a resize, so an image the program deletes goes. It runs in an
# empty home, so it reads none of the configuration of whoever runs it.
cat > "$HOST_DIR/resize.swift" <<'EOF'
import AppKit
import Foundation
import Metal
import QuartzCore
import UbiquittyKit

/// Every grid a surface reported, in order.
final class GridReport: TerminalSurfaceObserver {
    private(set) var grids: [(rows: Int, columns: Int)] = []
    var rows: Int { grids.last?.rows ?? 0 }
    var columns: Int { grids.last?.columns ?? 0 }

    /// The reports that named the grid the report before them named.
    var repeats: Int {
        zip(grids, grids.dropFirst()).filter { $0.0 == $0.1 }.count
    }

    func terminalSurface(_: TerminalSurface, didResizeGridTo rows: Int, columns: Int) {
        grids.append((rows, columns))
    }
}

/// A layer that keeps the texture of the last drawable it handed out, so a
/// frame encoded into it can be read back.
final class ProbeLayer: CAMetalLayer {
    var lastTexture: (any MTLTexture)?

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let drawable = super.nextDrawable()
        lastTexture = drawable?.texture
        return drawable
    }
}

@MainActor
func refuse(_ message: String) -> Bool {
    FileHandle.standardError.write(Data("resize-consumer: \(message)\n".utf8))
    return false
}

/// Turns the main run loop until `isDone` answers true or the time runs out,
/// calling `observe` on every turn.
@MainActor
func spin(seconds: Double, observe: () -> Void = {}, until isDone: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !isDone(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        observe()
    }
    return isDone()
}

/// Encodes the frame `surface` would draw now into a probe the size of its
/// own drawable, and counts the probe's pixels row by row.
///
/// The probe matches the surface's drawable and presents with its
/// transaction, so a frame of a pane nothing has changed since its last
/// frame Loads the retained grid the pane's own frames Load and is not
/// skipped as the glass it already shows. A frame the output's own hold
/// declines is asked for again.
///
/// - Returns: For each pixel row, the pixels unlike the corner; the
///   pure-red pixels in all; or nil when no frame was encoded within two
///   seconds.
@MainActor
func inkOfFrame(_ surface: TerminalSurface, _ renderer: any TerminalSurfaceRenderer) -> (rows: [Int], red: Int)? {
    let probe = ProbeLayer()
    probe.device = MTLCreateSystemDefaultDevice()
    probe.pixelFormat = surface.metalLayer.pixelFormat
    probe.framebufferOnly = false
    probe.presentsWithTransaction = true
    probe.contentsScale = surface.metalLayer.contentsScale
    probe.frame = surface.metalLayer.bounds
    probe.drawableSize = surface.metalLayer.drawableSize
    var drawn: (any MTLTexture)?
    _ = spin(
        seconds: 2,
        until: {
            probe.lastTexture = nil
            if renderer.encodeFrame(for: surface, into: probe) {
                drawn = probe.lastTexture
            }
            return drawn != nil
        }
    )
    guard let texture = drawn else { return nil }
    // The present waits for the frame's scheduling, not its completion.
    _ = spin(seconds: 0.1, until: { false })
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    var rows = [Int](repeating: 0, count: texture.height)
    var red = 0
    for row in 0..<texture.height {
        for column in 0..<texture.width {
            let index = (row * texture.width + column) * 4
            if bytes[index] != bytes[0] || bytes[index + 1] != bytes[1] || bytes[index + 2] != bytes[2] {
                rows[row] += 1
            }
            if bytes[index + 2] > 200, bytes[index + 1] < 60, bytes[index] < 60 {
                red += 1
            }
        }
    }
    return (rows, red)
}

/// Makes the frame changes `move` makes, then lets the run settle.
///
/// - Returns: Whether the layer presented with its transaction at any turn.
@MainActor
func isTransactionalThroughRun(_ surface: TerminalSurface, _ move: (_ observe: () -> Void) -> Void) -> Bool {
    var didTurnTransactional = false
    let observe = { didTurnTransactional = didTurnTransactional || surface.metalLayer.presentsWithTransaction }
    move(observe)
    _ = spin(seconds: 0.6, observe: observe, until: { false })
    return didTurnTransactional
}

let passed = MainActor.assumeIsolated { () -> Bool in
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.finishLaunching()
    guard let renderer = TerminalSurface.makeRenderer(),
        let moved = TerminalSurface(rows: 24, columns: 80),
        let control = TerminalSurface(rows: 24, columns: 80)
    else {
        return refuse("no surfaces or no renderer")
    }
    moved.renderer = renderer
    control.renderer = renderer
    let movedGrid = GridReport()
    let controlGrid = GridReport()
    moved.observer = movedGrid
    control.observer = controlGrid
    let window = NSWindow(
        contentRect: CGRect(x: -4000, y: -4000, width: 1000, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    window.contentView = container
    moved.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    container.addSubview(moved)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // More lines than the tallest grid holds, so every row the moves expose
    // has text to draw. The cursor is hidden, so the picture is the text's.
    let markers = (0..<60).map { "resize-marker-\($0)" }
    moved.feed(Data(("\u{1b}[?25l" + markers.joined(separator: "\r\n")).utf8))
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    guard spin(seconds: 10, until: { renderer.presentedGeometry(for: moved) != nil }) else {
        return refuse("the pane drew no frame in 10 s")
    }

    var isAnimating = true
    let isAnimationTransactional = isTransactionalThroughRun(moved) { observe in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            moved.animator().frame = CGRect(x: 0, y: 0, width: 520, height: 360)
        }, completionHandler: { isAnimating = false })
        _ = spin(seconds: 5, observe: observe, until: { !isAnimating })
    }
    guard !isAnimating else {
        return refuse("an animation of the pane's frame did not finish in 5 s")
    }
    guard !isAnimationTransactional else {
        return refuse("an animated run in a covered window presented with its transaction")
    }

    let finalFrame = CGRect(x: 0, y: 0, width: 760, height: 560)
    let start = moved.frame.size
    let isSteppedTransactional = isTransactionalThroughRun(moved) { observe in
        for step in 1...20 {
            let progress = CGFloat(step) / 20
            moved.frame = CGRect(
                x: 0,
                y: 0,
                width: start.width + (finalFrame.width - start.width) * progress,
                height: start.height + (finalFrame.height - start.height) * progress
            )
            _ = spin(seconds: 1.0 / 60.0, observe: observe, until: { false })
        }
    }
    guard !isSteppedTransactional else {
        return refuse("a stepped run in a covered window presented with its transaction")
    }

    _ = isTransactionalThroughRun(moved) { observe in
        moved.frame = CGRect(x: 0, y: 0, width: 700, height: 520)
        _ = spin(seconds: 0.3, observe: observe, until: { false })
        moved.frame = finalFrame
    }

    // The host's own divider drag, bracketed, held still mid-drag for longer
    // than a run's quiet interval.
    _ = isTransactionalThroughRun(moved) { observe in
        moved.beginLiveResize()
        for step in 1...10 {
            moved.frame = CGRect(x: 0, y: 0, width: finalFrame.width - CGFloat(step) * 6, height: finalFrame.height)
            _ = spin(seconds: 1.0 / 60.0, observe: observe, until: { false })
        }
        _ = spin(seconds: 0.3, observe: observe, until: { false })
        for step in 1...10 {
            moved.frame = CGRect(x: 0, y: 0, width: finalFrame.width - 60 + CGFloat(step) * 6, height: finalFrame.height)
            _ = spin(seconds: 1.0 / 60.0, observe: observe, until: { false })
        }
        moved.endLiveResize()
    }
    guard movedGrid.repeats == 0 else {
        return refuse(
            "the observer heard \(movedGrid.repeats) grid reports naming the grid before them: "
                + movedGrid.grids.map { "\($0.rows)x\($0.columns)" }.joined(separator: " ")
        )
    }

    // The grid the runs settled on is the one a pane laid out once at the
    // final frame takes.
    control.frame = finalFrame
    container.addSubview(control, positioned: .below, relativeTo: moved)
    guard spin(seconds: 2, until: { controlGrid.rows > 0 }) else {
        return refuse("a pane laid out at the final frame reported no grid")
    }
    guard movedGrid.rows == controlGrid.rows, movedGrid.columns == controlGrid.columns else {
        return refuse(
            "the moved pane settled on \(movedGrid.rows)x\(movedGrid.columns), "
                + "a pane laid out at its final frame on \(controlGrid.rows)x\(controlGrid.columns)"
        )
    }

    // The window becoming key reveals the pane, which draws the settled
    // grid over whatever its frames retained.
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    let isSettledGridDrawn = {
        guard let geometry = renderer.presentedGeometry(for: moved) else { return false }
        return Int(geometry.rows) == movedGrid.rows && Int(geometry.columns) == movedGrid.columns
    }
    guard spin(seconds: 5, until: isSettledGridDrawn) else {
        let drawn = renderer.presentedGeometry(for: moved).map { "\($0.rows)x\($0.columns)" } ?? "none"
        return refuse("the revealed pane drew no frame of its settled \(movedGrid.rows)x\(movedGrid.columns) grid; last \(drawn)")
    }
    let visibleText = moved.accessibilityValue() as? String ?? ""
    let visibleLines = visibleText.components(separatedBy: "\n")
    guard visibleText.contains(markers[markers.count - 1]),
        visibleLines.filter({ $0.hasPrefix("resize-marker-") }).count >= movedGrid.rows - 1
    else {
        return refuse("the moved pane's \(movedGrid.rows) rows hold \(visibleLines.count) lines, not its last \(movedGrid.rows) markers")
    }

    // A fresh pane given the text the moved one shows draws the picture the
    // moved one's frames Load, pixel row for pixel row.
    control.feed(Data(("\u{1b}[?25l" + visibleLines.joined(separator: "\r\n")).utf8))
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    guard spin(seconds: 2, until: { (control.accessibilityValue() as? String ?? "") == visibleText }) else {
        return refuse("a fresh pane given the moved pane's text shows other text")
    }
    _ = spin(seconds: 0.3, until: { false })
    guard let movedInk = inkOfFrame(moved, renderer), let controlInk = inkOfFrame(control, renderer),
        movedInk.rows.count == controlInk.rows.count
    else {
        return refuse("the moved pane or a fresh pane drew no frame of its final drawable")
    }
    let differingRows = zip(movedInk.rows, controlInk.rows).enumerated().filter { $0.element.0 != $0.element.1 }
    let textRows = controlInk.rows.filter { $0 > 0 }.count
    guard textRows > 0, differingRows.isEmpty else {
        let first = differingRows.first.map { "pixel row \($0.offset): \($0.element.0) against \($0.element.1)" } ?? "no ink"
        return refuse("the moved pane's picture differs from a fresh pane's in \(differingRows.count) pixel rows (\(first))")
    }

    // A window with no extent: a run there opens no gesture, so nothing is
    // left holding the pane in a resize once it settles.
    let emptyWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    emptyWindow.isReleasedWhenClosed = false
    let emptyContainer = NSView(frame: .zero)
    emptyWindow.contentView = emptyContainer
    guard let imaged = TerminalSurface(rows: 24, columns: 80) else {
        return refuse("no surface for the window with no extent")
    }
    imaged.renderer = renderer
    imaged.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    emptyContainer.addSubview(imaged)
    emptyWindow.orderFrontRegardless()
    defer { emptyWindow.orderOut(nil) }
    var image = [UInt8]()
    for _ in 0..<(16 * 16) { image += [255, 0, 0] }
    imaged.feed(Data("image probe\r\n\u{1b}_Gf=24,s=16,v=16,a=T;\(Data(image).base64EncodedString())\u{1b}\\".utf8))
    guard spin(seconds: 3, until: { (inkOfFrame(imaged, renderer)?.red ?? 0) > 50 }) else {
        return refuse("the image drew no red pixels")
    }
    imaged.frame = CGRect(x: 0, y: 0, width: 600, height: 460)
    _ = spin(seconds: 1.0 / 60.0, until: { false })
    imaged.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    _ = spin(seconds: 0.6, until: { false })
    imaged.feed(Data("\u{1b}_Ga=d\u{1b}\\\r\nafter delete\r\n".utf8))
    _ = spin(seconds: 0.3, until: { false })
    _ = inkOfFrame(imaged, renderer)
    imaged.feed(Data("x".utf8))
    _ = spin(seconds: 0.2, until: { false })
    guard let afterDelete = inkOfFrame(imaged, renderer), afterDelete.red == 0,
        !imaged.metalLayer.presentsWithTransaction
    else {
        return refuse("a run in a window with no extent left the pane in a resize: the deleted image is still drawn")
    }
    print(
        "resize-consumer: \(movedGrid.grids.count) grid reports, none repeated, settled on \(movedGrid.rows)x\(movedGrid.columns); "
            + "\(textRows) pixel rows of text match a fresh pane's"
    )
    return true
}
exit(passed ? 0 : 1)
EOF

xcrun swiftc "$HOST_DIR/resize.swift" \
    -o "$HOST_DIR/resize-consumer" \
    -F "$FRAMEWORK_DIR" \
    -framework UbiquittyKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"

RESIZE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ubiquittykit-resize.XXXXXX")"
resize_status=0
env -i HOME="$RESIZE_HOME" TMPDIR="$RESIZE_HOME" PATH=/usr/bin:/bin "$HOST_DIR/resize-consumer" || resize_status=$?
rm -rf "$RESIZE_HOME"
[ "$resize_status" -eq 0 ] || exit "$resize_status"
echo "check-ubiquittykit: ok (panes moved in code reported each grid once, settled on the grid of their final frame, and kept a picture of their text)"

# The generated header and archive this build just produced are the only place a
# Swift export naming a C++ interop type can silently vanish -- swiftc prints no
# diagnostic and the build stays green. Assert every such export survived both.
python3 "$ROOT/Scripts/check-swift-cxx-exports.py" "$ROOT" "$BUILD"
