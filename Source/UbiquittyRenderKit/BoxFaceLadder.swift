// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText

// BoxFaceLadder.swift — which face draws a box-drawing cell.

/// The box family's face ladder: the primary, else the symbol fallback.
///
/// Two faces and no further. Core routes the line and
/// terminal-graphics families font-first and falls to geometry only where the
/// atlas answers absent, so the question this answers is which face the atlas
/// asks. A per-code-point walk of the system cascade would answer it with
/// several faces at several weights, and a box scene's strokes have to meet —
/// a run of rules and the elbow continuing them would land on different rows.
package enum BoxFaceLadder {
    /// The face that carries a box code point, and its glyph in that face.
    ///
    /// - Parameters:
    ///   - codePoint: The box-drawing character to draw.
    ///   - primary: The configured family's face for this cell.
    ///   - symbolFallback: The adopted symbol face, or nil when none loaded.
    /// - Returns: The face and glyph, or nil when neither carries it — which is
    ///   what keeps the cell on the procedural path.
    package static func faceCarrying(
        _ codePoint: UInt32,
        primary: CTFont,
        symbolFallback: CTFont?
    ) -> (font: CTFont, glyph: CGGlyph)? {
        if let glyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: primary) {
            return (primary, glyph)
        }
        guard let symbolFallback,
            let glyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: symbolFallback)
        else {
            return nil
        }
        return (symbolFallback, glyph)
    }
}
