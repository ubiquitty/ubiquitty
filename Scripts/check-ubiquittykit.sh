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
# compile.
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
# catalog key and chains as the public observer hears the process sample move;
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
        ProcessReport(
            name: surface.foregroundProgramName,
            key: surface.foregroundProgramKey,
            chain: surface.foregroundProcessChain,
            chainWithArguments: surface.foregroundProcessChainWithArguments
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
    guard wait(seconds: 20, until: { watch.reports.dropFirst(heardBeforeInterrupt).contains { $0.name == shell } }) else {
        return refuse("the shell \(shell) did not take the terminal back from \(name): heard \(watch.reports.map(\.name))")
    }

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
    guard ended.name.isEmpty, ended.key == nil, ended.chain.isEmpty, ended.chainWithArguments.isEmpty else {
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
echo "check-ubiquittykit: ok (external consumer read a shell's foreground program and its status out of a window, heard nothing while declining, and read nothing named after exit)"

# The generated header and archive this build just produced are the only place a
# Swift export naming a C++ interop type can silently vanish -- swiftc prints no
# diagnostic and the build stays green. Assert every such export survived both.
python3 "$ROOT/Scripts/check-swift-cxx-exports.py" "$ROOT" "$BUILD"
