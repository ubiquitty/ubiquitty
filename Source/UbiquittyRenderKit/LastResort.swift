// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// LastResort.swift — whether CoreText resolved a face, or any run of a shaped
// line, to Apple's LastResort font.
//
// LastResort is the cascade's guaranteed-present floor: when no other font
// covers a code point CoreText substitutes it, and its glyph for every code
// point is a real drawn box — a category "?-in-a-box" — rather than a blank. A
// glyph probe against it therefore always succeeds, and the only place the
// substitution shows is the run's own font attribute.
//
// The raster paths that hand CoreText a bare base font and let its default
// cascade run — the glyph atlas's cluster and colour paths, the colour sheet
// and the ligature strips — ask this before baking a line. A box baked into a
// cached image sticks: a clean row is presented from the cache, so the tofu
// stays until a full rebuild. Leaving the slot blank is the lesser defect.
//
// CoreText alone, so Tests/Platform/test_macos_lastresort_guard.swift compiles
// it beside the test without the module.

import CoreText

/// Whether a face is Apple's LastResort font.
///
/// - Parameter font: The face to test.
/// - Returns: Whether its PostScript name is `LastResort`.
func ctFontIsLastResort(_ font: CTFont) -> Bool {
    (CTFontCopyPostScriptName(font) as String) == "LastResort"
}

/// Whether any run CoreText shaped for this line fell to LastResort.
///
/// - Parameter line: The shaped line to inspect.
/// - Returns: Whether any run's font is LastResort.
func ctLineHasLastResortRun(_ line: CTLine) -> Bool {
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    for run in runs {
        let attributes = CTRunGetAttributes(run) as! [CFString: Any]
        guard let runFont = attributes[kCTFontAttributeName] else {
            continue
        }
        if ctFontIsLastResort(runFont as! CTFont) {
            return true
        }
    }
    return false
}

/// The characters of a shaped string that a face other than LastResort draws.
///
/// A run carries the range of the string it was shaped from, so the characters
/// a LastResort run covers are left out and every other one is kept in order.
///
/// - Parameters:
///   - string: The string `line` was shaped from.
///   - line: The shaped line.
/// - Returns: `string` without the characters of its LastResort runs.
func stringOutsideLastResort(_ string: String, shapedAs line: CTLine) -> String {
    let length = string.utf16.count
    var isDropped = [Bool](repeating: false, count: length)
    var didDropAny = false
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as! [CFString: Any]
        guard let runFont = attributes[kCTFontAttributeName], ctFontIsLastResort(runFont as! CTFont) else {
            continue
        }
        let range = CTRunGetStringRange(run)
        let lower = max(range.location, 0)
        let upper = min(range.location + range.length, length)
        guard lower < upper else {
            continue
        }
        for index in lower..<upper {
            isDropped[index] = true
        }
        didDropAny = true
    }
    guard didDropAny else {
        return string
    }
    var kept = String.UnicodeScalarView()
    var offset = 0
    for scalar in string.unicodeScalars {
        if !isDropped[offset] {
            kept.append(scalar)
        }
        offset += scalar.utf16.count
    }
    return String(kept)
}
