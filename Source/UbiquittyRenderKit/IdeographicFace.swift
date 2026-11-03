// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// IdeographicFace.swift — where a CJK face sets its ideographs, from its BASE
// table.
//
// A CJK face draws each ideograph inside its ideographic character face, the box
// the BASE table bounds with the icfb and icft baselines: a little inside the
// ideographic em-box, and where the ink of every ideograph is designed to fall.
// Text that sets those ideographs beside a Latin face reads level when that
// box's centre meets the Latin face's cap-height midline.
//
// The table comes from whatever font is installed, so every read is bounded by
// the table's length and a malformed table reads as absent.
//
// CoreText alone, so Tests/Platform/test_macos_ideographic_face.swift compiles
// it beside the test without the module.

import CoreText
import Foundation

/// The centre of a face's ideographic character face, above its baseline.
///
/// Read from the face's BASE table on the horizontal axis: the icfb and icft
/// baselines of the first of the Han, kana, Hangul and default scripts that
/// names both.
///
/// - Parameter font: The face to read.
/// - Returns: The centre in points at the face's size, or `nil` when the face has
///   no BASE table or names no ideographic character face.
func ideographicCharacterFaceCentre(_ font: CTFont) -> CGFloat? {
    guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableBASE), []) as Data? else {
        return nil
    }
    return ideographicCharacterFaceCentre(
        baseTable: table,
        unitsPerEm: Int(CTFontGetUnitsPerEm(font)),
        pointSize: CTFontGetSize(font)
    )
}

/// The centre of the ideographic character face a BASE table names.
///
/// - Parameters:
///   - table: The BASE table's bytes.
///   - unitsPerEm: The face's design units per em.
///   - pointSize: The size to scale the centre to.
/// - Returns: The centre in points above the baseline, or `nil` when the table is
///   malformed or names no ideographic character face.
func ideographicCharacterFaceCentre(baseTable table: Data, unitsPerEm: Int, pointSize: CGFloat) -> CGFloat? {
    let bytes = [UInt8](table)
    func unsigned16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else {
            return nil
        }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
    func signed16(_ offset: Int) -> Int? {
        unsigned16(offset).map { $0 >= 0x8000 ? $0 - 0x10000 : $0 }
    }
    func tag(_ offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }
        return String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
    }
    guard unitsPerEm > 0, let horizontalOffset = unsigned16(4), horizontalOffset != 0,
        let tagListOffset = unsigned16(horizontalOffset), tagListOffset != 0,
        let scriptListOffset = unsigned16(horizontalOffset + 2), scriptListOffset != 0
    else {
        return nil
    }
    let tagList = horizontalOffset + tagListOffset
    guard let tagCount = unsigned16(tagList) else {
        return nil
    }
    let tags = (0..<tagCount).map { tag(tagList + 2 + 4 * $0) }
    guard let bottomIndex = tags.firstIndex(of: "icfb"), let topIndex = tags.firstIndex(of: "icft") else {
        return nil
    }

    // Each script's coordinates, in its BaseValues table's tag order.
    let scriptList = horizontalOffset + scriptListOffset
    guard let scriptCount = unsigned16(scriptList) else {
        return nil
    }
    var centres: [String: Int] = [:]
    for index in 0..<scriptCount {
        let record = scriptList + 2 + 6 * index
        guard let script = tag(record), let scriptOffset = unsigned16(record + 4),
            let valuesOffset = unsigned16(scriptList + scriptOffset), valuesOffset != 0
        else {
            continue
        }
        let values = scriptList + scriptOffset + valuesOffset
        guard let coordinateCount = unsigned16(values + 2), bottomIndex < coordinateCount, topIndex < coordinateCount,
            let bottomOffset = unsigned16(values + 4 + 2 * bottomIndex),
            let topOffset = unsigned16(values + 4 + 2 * topIndex),
            let bottom = signed16(values + bottomOffset + 2), let top = signed16(values + topOffset + 2)
        else {
            continue
        }
        centres[script] = bottom + top
    }
    guard let twiceCentre = ["hani", "kana", "hang", "DFLT"].lazy.compactMap({ centres[$0] }).first else {
        return nil
    }
    return CGFloat(twiceCentre) / 2 * pointSize / CGFloat(unitsPerEm)
}
