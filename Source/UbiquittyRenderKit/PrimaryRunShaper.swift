// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PrimaryRunShaper.swift — the CoreText arm's answer to Core's letter layout
// (Source/Core/Rendering/LetterLayout.h): how far each letter of a run
// advances in the primary face, kerned as the face kerns it.
//
// A proportional primary face lays its rows out as proportional runs. The
// builder asks this once per run of same-pen cells and places every letter
// from the answer; the glyphs themselves come off the mono sheet, one per
// letter, so the line is shaped with every ligature feature off and kerning
// left on — the positions are what travel, not the glyph identities.

import CoreText
import Foundation
import UbiquittyCore

/// Shapes a run in the grid's faces at their natural advances.
///
/// Thread-confined to the render thread like the atlas that owns it; the
/// line store is bounded by emptying, since a screen of prose mints new
/// runs without end.
package final class PrimaryRunShaper {
    private let faces: FontFaces
    private var lineStore: [LineKey: [Ubiquitty.ProportionalShapedGlyph]] = [:]

    /// How many shaped runs the store keeps before it empties.
    private static let lineCapacity = 4096

    private struct LineKey: Hashable {
        let codePoints: [UInt32]
        let face: UInt8
        let weight: UInt32
    }

    package init(faces: FontFaces) {
        self.faces = faces
    }

    /// Shapes `codePoints` in `face`.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The pen's face.
    ///   - weight: The SGR 1:n variable weight the pen carries. This arm draws
    ///     its mono glyphs at the configured weight whatever the pen asks, so
    ///     the run is shaped at the same, and the value only keys the store.
    /// - Returns: One glyph per glyph CoreText placed, in text order, each
    ///   naming the code point it begins at; empty when the run reached a
    ///   face other than the primary, which the caller then keeps on the grid.
    package func shape(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] {
        let count = Int(codePoints.size())
        guard count > 0, let data = codePoints.__dataUnsafe() else {
            return []
        }
        var text = [UInt32](repeating: 0, count: count)
        for index in 0..<count {
            text[index] = data[index]
        }
        let key = LineKey(codePoints: text, face: face.rawValue, weight: weight)
        if let cached = lineStore[key] {
            return cached
        }
        let shaped = shapeLine(text, face: face)
        if lineStore.count >= Self.lineCapacity {
            lineStore.removeAll(keepingCapacity: true)
        }
        lineStore[key] = shaped
        return shaped
    }

    private func shapeLine(_ text: [UInt32], face: Ubiquitty.Rendering.FontFace) -> [Ubiquitty.ProportionalShapedGlyph] {
        let font = faces[face]
        var scalars = String.UnicodeScalarView()
        for codePoint in text {
            scalars.append(Unicode.Scalar(codePoint) ?? "\u{FFFD}")
        }
        // Ligatures off: the builder draws each letter's own glyph at the pen
        // this answer puts it on, so a fused glyph would still draw as its
        // letters. Kerning stays, which is the advance the face designed for
        // the pair.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(scalars), attributes: attributes))
        let sourceIndices = LigatureSheet.proportionalUTF16SourceIndices(text)
        var out: [Ubiquitty.ProportionalShapedGlyph] = []
        var penBefore = 0.0
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0,
                let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                let runFontAny = runAttributes[NSAttributedString.Key(kCTFontAttributeName as String)]
            else {
                continue
            }
            let runFont = runFontAny as! CTFont
            // A run CoreText handed to another face is not this face's text: its
            // advances are another typeface's, and the mono sheet draws the
            // primary's glyph for the cell. The whole run then keeps the grid.
            // Compared by name and size rather than by object: the ligature
            // attribute has CoreText derive the run's font from the one asked
            // for, and the derived object is this face all the same.
            guard CTFontCopyPostScriptName(runFont) == CTFontCopyPostScriptName(font),
                CTFontGetSize(runFont) == CTFontGetSize(font)
            else {
                return []
            }
            let fontMatrix = CTFontGetMatrix(runFont)
            let range = CFRangeMake(0, glyphCount)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var indices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            CTRunGetAdvances(run, range, &advances)
            CTRunGetStringIndices(run, range, &indices)
            for index in 0..<glyphCount {
                // Advances carry the face's matrix and positions do not, so only
                // the positions are scaled; the offset is what the position
                // holds beyond the advances before it.
                let position = positions[index].applying(fontMatrix)
                var glyph = Ubiquitty.ProportionalShapedGlyph()
                glyph.glyph = UInt32(glyphs[index])
                glyph.advanceInPixels = Float(advances[index].width)
                glyph.offsetXInPixels = Float(position.x - penBefore)
                glyph.offsetYInPixels = Float(position.y)
                glyph.cluster = sourceIndices[min(max(Int(indices[index]), 0), sourceIndices.count - 1)]
                out.append(glyph)
                penBefore += advances[index].width
            }
        }
        return out
    }
}
