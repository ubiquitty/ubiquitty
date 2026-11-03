// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_macos_ideographic_face.swift — pins
// ideographicCharacterFaceCentre (Source/UbiquittyRenderKit/IdeographicFace.swift),
// which reads where a CJK face sets its ideographs from the face's BASE table:
// the centre of the box its icfb and icft baselines bound. The system CJK faces
// carry the table, a Latin face does not, and a malformed table reads as absent.
//
// Compiled by plain `xcrun swiftc` with IdeographicFace.swift alone. A failure
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

/// The ink centre of a character in a face, above the baseline.
func inkCentre(of character: Character, in font: CTFont) -> CGFloat? {
    var units = Array(String(character).utf16)
    var glyph = CGGlyph(0)
    guard units.count == 1, CTFontGetGlyphsForCharacters(font, &units, &glyph, 1), glyph != 0 else {
        return nil
    }
    return CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1).midY
}

/// A system CJK face names its ideographic character face, its ideographs sit on
/// that box's centre, and the centre stands between a third and two fifths of
/// the em above the baseline.
func readsSystemCJKFaces() {
    for name in ["PingFangSC-Regular", "HiraginoSans-W3"] {
        let font = CTFontCreateWithName(name as CFString, 24, nil)
        guard (CTFontCopyPostScriptName(font) as String) == name else {
            check(false, "\(name) is installed")
            continue
        }
        guard let centre = ideographicCharacterFaceCentre(font) else {
            check(false, "\(name) names an ideographic character face")
            continue
        }
        check(centre > 24 / 3 && centre < 24 * 2 / 5, "\(name)'s centre \(centre) stands a third to two fifths of the em up")
        if let ink = inkCentre(of: "漢", in: font) {
            check(abs(ink - centre) < 24 * 0.05, "\(name)'s 漢 centres on the box (\(ink) against \(centre))")
        }
        let doubled = CTFontCreateCopyWithAttributes(font, 48, nil, nil)
        if let scaled = ideographicCharacterFaceCentre(doubled) {
            check(abs(scaled - 2 * centre) < 0.001, "\(name)'s centre scales with its size")
        }
    }
}

/// A Latin face has no ideographic character face.
func latinFaceHasNone() {
    check(
        ideographicCharacterFaceCentre(CTFontCreateWithName("Menlo-Regular" as CFString, 24, nil)) == nil,
        "Menlo names no ideographic character face"
    )
}

/// Every truncation of a real table, and bytes that are no table, read as absent
/// rather than past the end.
func malformedTablesReadAsAbsent() {
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 24, nil)
    guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableBASE), []) as Data? else {
        check(false, "PingFang SC carries a BASE table")
        return
    }
    let units = Int(CTFontGetUnitsPerEm(font))
    check(ideographicCharacterFaceCentre(baseTable: table, unitsPerEm: units, pointSize: 24) != nil, "the whole table reads")
    for length in 0..<min(table.count, 512) {
        let centre = ideographicCharacterFaceCentre(baseTable: table.prefix(length), unitsPerEm: units, pointSize: 24)
        if length < 8 {
            check(centre == nil, "a \(length)-byte table reads as absent")
        }
    }
    check(
        ideographicCharacterFaceCentre(baseTable: Data(repeating: 0xFF, count: 64), unitsPerEm: units, pointSize: 24) == nil,
        "bytes that are no table read as absent"
    )
    check(ideographicCharacterFaceCentre(baseTable: table, unitsPerEm: 0, pointSize: 24) == nil, "a face with no em reads as absent")
}

@main
struct IdeographicFaceTest {
    static func main() {
        readsSystemCJKFaces()
        latinFaceHasNone()
        malformedTablesReadAsAbsent()

        if failures == 0 {
            print("test_macos_ideographic_face: all checks passed")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
