// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(HarfBuzzProbe)
import CoreText
import HarfBuzzProbe
import UbiquittyCore

/// Shapes ASCII identity runs whose source mapping and positioning need no adapter.
final class UniformFaceShaper {
    private let font: CTFont
    private let shaper: OpaquePointer
    private let buffer: OpaquePointer
    private var features: [hb_feature_t] = []

    init?(font: CTFont, featureSpecification: String) {
        let scale = CTFontGetSize(font) * 65536
        guard CTFontGetMatrix(font).isIdentity, scale > 0, scale < Double(Int32.max) else { return nil }
        var features: [hb_feature_t] = []
        let parsed = Ubiquitty.Rendering.parseFontFeatureSpecification(std.string(featureSpecification))
        for setting in parsed {
            var feature = hb_feature_t()
            let specification = "\(String(setting.tag))=\(setting.value)"
            guard specification.withCString({ hb_feature_from_string($0, -1, &feature) }) != 0 else { return nil }
            features.append(feature)
        }
        guard let shaper = hb_coretext_font_create(font) else { return nil }
        guard let buffer = hb_buffer_create() else {
            hb_font_destroy(shaper)
            return nil
        }
        self.font = font
        self.shaper = shaper
        self.buffer = buffer
        self.features = features
        hb_ot_font_set_funcs(shaper)
        hb_font_set_scale(shaper, Int32(scale.rounded()), Int32(scale.rounded()))
    }

    deinit {
        hb_buffer_destroy(buffer)
        hb_font_destroy(shaper)
    }

    func identities(
        codePoints: [UInt32],
        characterCount: Int,
        leftContext: Int,
        drawnCells: Int
    ) -> [Ubiquitty.Rendering.ShapedCell]? {
        guard characterCount > 0, characterCount <= codePoints.count,
            leftContext >= 0, drawnCells > 0, leftContext + drawnCells <= characterCount,
            codePoints.prefix(characterCount).allSatisfy({ $0 >= 0x20 && $0 <= 0x7E })
        else { return nil }
        hb_buffer_reset(buffer)
        codePoints.withUnsafeBufferPointer {
            hb_buffer_add_utf32(buffer, $0.baseAddress, Int32(characterCount), 0, Int32(characterCount))
        }
        hb_buffer_guess_segment_properties(buffer)
        hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS)
        hb_buffer_set_flags(buffer, HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT)
        features.withUnsafeBufferPointer { hb_shape(shaper, buffer, $0.baseAddress, UInt32($0.count)) }
        var count: UInt32 = 0
        guard let glyphs = hb_buffer_get_glyph_infos(buffer, &count), Int(count) == characterCount,
            let positions = hb_buffer_get_glyph_positions(buffer, nil)
        else { return nil }
        var identifiers = [CGGlyph](repeating: 0, count: characterCount)
        for index in 0..<characterCount {
            let glyphID = glyphs[index][keyPath: \hb_glyph_info_t.codepoint]
            guard glyphs[index].cluster == UInt32(index), glyphID > 0,
                glyphID <= UInt32(UInt16.max),
                positions[index].x_offset == 0, positions[index].y_offset == 0,
                positions[index].y_advance == 0
            else { return nil }
            identifiers[index] = CGGlyph(glyphID)
        }
        var bounds = [CGRect](repeating: .zero, count: characterCount)
        var advances = [CGSize](repeating: .zero, count: characterCount)
        CTFontGetBoundingRectsForGlyphs(font, .default, &identifiers, &bounds, characterCount)
        CTFontGetAdvancesForGlyphs(font, .default, &identifiers, &advances, characterCount)
        for index in 0..<characterCount {
            guard codePoints[index] == 0x20 || (!bounds[index].isNull && bounds[index].width > 0.01),
                abs(Double(positions[index].x_advance) / 65536 - advances[index].width) < 0.001
            else { return nil }
        }
        return (leftContext..<(leftContext + drawnCells))
            .map { index in
                var answer = Ubiquitty.Rendering.ShapedCell()
                answer.glyphID = UInt32(identifiers[index])
                answer.coveredCells = 1
                return answer
            }
    }
}
#endif
