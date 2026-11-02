// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation
import UbiquittyCore

/// Proves that a resolved static font's ASCII run needs no contextual shaping.
final class ShapingCandidateFilter {
    private var filter = Ubiquitty.Rendering.OpenTypeShapingFilter()
    private var glyphs = [CGGlyph](repeating: 0, count: 128)
    private var eligible = [Bool](repeating: false, count: 128)

    init?(font: CTFont) {
        guard CTFontGetMatrix(font).isIdentity else { return nil }
        // These tables require shaping or positioning semantics outside the
        // static OpenType coverage proof.
        for tag in ["morx", "mort", "kerx", "kern", "trak", "fvar"] where CTFontCopyTable(font, Self.tagValue(tag), []) != nil {
            return nil
        }
        let characters = (0..<128).map { UTF16.CodeUnit($0) }
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        let definition = CTFontCopyTable(font, Self.tagValue("GDEF"), [])
        let definitionBytes = definition.map { [UInt8]($0 as Data) } ?? []
        let validClasses = definitionBytes.withUnsafeBufferPointer { bytes in
            glyphs.withUnsafeBufferPointer { nominal in
                filter.setGlyphClasses(Ubiquitty.Rendering.FontTableBytes(bytes), Ubiquitty.Rendering.NominalFontGlyphs(nominal))
            }
        }
        guard validClasses else { return nil }
        var bounds = [CGRect](repeating: .zero, count: 128)
        CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, &bounds, glyphs.count)
        for index in 32..<127 {
            eligible[index] = glyphs[index] != 0 && (index == 32 || (!bounds[index].isNull && bounds[index].width > 0.01))
        }
        let originalSettings = (CTFontCopyFeatureSettings(font) as NSArray?) ?? []
        let requested = (CTFontCopyAttribute(font, kCTFontFeatureSettingsAttribute) as? [[CFString: Any]]) ?? []
        for (tag, positioning) in [("GSUB", false), ("GPOS", true)] {
            guard let data = CTFontCopyTable(font, Self.tagValue(tag), []) else { continue }
            let bytes = [UInt8](data as Data)
            let tags = bytes.withUnsafeBufferPointer {
                Ubiquitty.Rendering.OpenTypeShapingFilter.featureTags(Ubiquitty.Rendering.FontTableBytes($0))
            }
            var disabled: [UInt32] = []
            for feature in tags {
                let name = String(
                    bytes: [
                        UInt8(truncatingIfNeeded: feature >> 24), UInt8(truncatingIfNeeded: feature >> 16),
                        UInt8(truncatingIfNeeded: feature >> 8), UInt8(truncatingIfNeeded: feature),
                    ],
                    encoding: .ascii
                )
                guard let name else { return nil }
                func normalized(_ value: Int) -> NSArray {
                    let settings = requested + [[kCTFontOpenTypeFeatureTag: name, kCTFontOpenTypeFeatureValue: value]]
                    let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
                    let configured = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
                    return (CTFontCopyFeatureSettings(configured) as NSArray?) ?? []
                }
                // An ignored or unmapped setting cannot establish that a
                // feature is off: both explicit values normalize identically.
                if originalSettings.isEqual(normalized(0)), !originalSettings.isEqual(normalized(1)) {
                    disabled.append(feature)
                }
            }
            let valid = bytes.withUnsafeBufferPointer { table in
                disabled.withUnsafeBufferPointer { tags in
                    glyphs.withUnsafeBufferPointer { nominal in
                        filter.addTable(
                            Ubiquitty.Rendering.FontTableBytes(table),
                            Ubiquitty.Rendering.FontFeatureTags(tags),
                            Ubiquitty.Rendering.NominalFontGlyphs(nominal),
                            positioning ? .Positioning : .Substitution
                        )
                    }
                }
            }
            guard valid else { return nil }
        }
    }

    func identities(
        codePoints: [UInt32],
        characterCount: Int,
        leftContext: Int,
        drawnCells: Int
    ) -> [Ubiquitty.Rendering.ShapedCell]? {
        guard characterCount > 0, characterCount <= codePoints.count,
            leftContext >= 0, drawnCells > 0, leftContext + drawnCells <= characterCount
        else { return nil }
        for index in 0..<characterCount {
            let character = codePoints[index]
            guard character < 128, eligible[Int(character)] else { return nil }
        }
        let mayChange = codePoints.withUnsafeBufferPointer { words in
            filter.mayChange(Ubiquitty.Rendering.ShapingCodePoints(words.extracting(..<characterCount)))
        }
        guard !mayChange else { return nil }
        return (leftContext..<(leftContext + drawnCells))
            .map { index in
                var answer = Ubiquitty.Rendering.ShapedCell()
                answer.glyphID = UInt32(glyphs[Int(codePoints[index])])
                answer.coveredCells = 1
                return answer
            }
    }

    private static func tagValue(_ tag: String) -> UInt32 {
        tag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
