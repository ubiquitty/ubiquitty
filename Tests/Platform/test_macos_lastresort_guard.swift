// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_macos_lastresort_guard.swift — pins
// ctLineHasLastResortRun (Source/UbiquittyRenderKit/LastResort.swift), the
// backstop that stops the glyph atlas's cluster and colour paths, the colour
// sheet and the ligature strips baking a CoreText LastResort ?-in-a-box tofu
// into a cached image, where the grid cache then freezes it. The guard walks a
// shaped line's runs and reports whether any resolved to the LastResort font,
// so the caller can leave the slot blank instead.
//
// Compiled by plain `xcrun swiftc` with LastResort.swift alone. A failure
// prints FAIL file:line, and any failure exits nonzero.
//

import CoreText
import Foundation

var failures = 0

func check(_ condition: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition {
        print("FAIL \(file):\(line): \(what)")
        failures += 1
    }
}

/// A single-run line over `text`, explicitly attributed with `font`.
func makeLine(_ text: String, _ font: CTFont) -> CTLine {
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    return CTLineCreateWithAttributedString(attributed)
}

/// A run whose font is the LastResort face is detected. The string is
/// attributed with LastResort directly — it covers every code point, so
/// CoreText will not substitute it away — a deterministic stand-in for the
/// cascade fall-through the guard exists to catch.
func detectsLastResortRun() {
    let lastResort = CTFontCreateWithName("LastResort" as CFString, 14.0, nil)
    // Confirm the platform gave us LastResort by that name and not a
    // substituted system face, or the assertion below would be meaningless.
    let resolvedLastResort = (CTFontCopyPostScriptName(lastResort) as String) == "LastResort"
    check(resolvedLastResort, "CoreText resolves the LastResort face by name")
    check(ctFontIsLastResort(lastResort) == resolvedLastResort, "the face test agrees with the PostScript name")
    if resolvedLastResort {
        check(ctLineHasLastResortRun(makeLine("A", lastResort)), "a run in LastResort is detected")
    }
}

/// A normally covered run (Menlo over ASCII) is not flagged — the guard must
/// not blank real glyphs.
func ignoresCoveredRun() {
    let menlo = CTFontCreateWithName("Menlo" as CFString, 14.0, nil)
    check(!ctFontIsLastResort(menlo), "Menlo is not LastResort")
    check(!ctLineHasLastResortRun(makeLine("Ab1", menlo)), "a covered run is not flagged")
}

/// A line with no runs is safe and reports no LastResort run.
func emptyLine() {
    let menlo = CTFontCreateWithName("Menlo" as CFString, 14.0, nil)
    check(!ctLineHasLastResortRun(makeLine("", menlo)), "an empty line has no LastResort run")
}

@main
struct LastResortGuardTest {
    static func main() {
        detectsLastResortRun()
        ignoresCoveredRun()
        emptyLine()

        if failures == 0 {
            print("test_macos_lastresort_guard: all checks passed")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
