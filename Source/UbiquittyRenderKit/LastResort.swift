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
