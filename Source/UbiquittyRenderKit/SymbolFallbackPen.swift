// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import UbiquittyCore

// SymbolFallbackPen.swift — where a symbol-fallback glyph is drawn in its slot.

/// The pen for a glyph from the adopted symbol face.
///
/// The face's em is not the primary's, so its ink overhangs the cell box the
/// cell quad samples even while it fits the wider slot, and the plain pen crops
/// one edge. Centring the ink on the cell box and clamping it to the slot
/// bitmap puts the whole symbol inside the sampled region at its native size —
/// no rescale, because the icon is drawn at the size it was designed for.
package enum SymbolFallbackPen {
    /// The pen that places `ink` inside the slot.
    ///
    /// Horizontal centres on the cell box, then clamps to the slot. Vertical
    /// keeps the text baseline and moves only for an icon that would hard-clip,
    /// so symbols sit on the same baseline as the text beside them.
    ///
    /// Ink LARGER than the slot cannot be contained by a translation, and the
    /// slot bitmap crops what it cannot hold. Such a glyph keeps its centring
    /// and is not clamped: clamping would spend the whole crop on one edge,
    /// which reads as a symbol sliced in half rather than one drawn slightly
    /// too large. The pen is a translation only — nothing here rescales, and a
    /// face whose symbols do not fit the cell needs a scale this cannot supply.
    ///
    /// A glyph that TILES is exempt from all of it. Its position in the cell is
    /// what it means -- a bracket section continues the section in the row above,
    /// a vertical box line stands on one edge -- so it draws on the plain text
    /// pen, where the face put it. Centring measures each piece's own ink, and
    /// a hook's ink is wider than the stem it continues, so the family arrives
    /// with its stem in a different column in every row.
    ///
    /// The code point is taken rather than left to the caller so that the
    /// exemption cannot be forgotten at a call site: every pen for a symbol
    /// glyph comes through here.
    ///
    /// - Parameters:
    ///   - codePoint: The cell's code point.
    ///   - ink: The glyph's bounding rect in the symbol face.
    ///   - subpixel: The phase the slot was keyed at, in pixels.
    ///   - glyphMarginX: The slot's left margin in pixels.
    ///   - glyphWidth: The cell box's width in pixels.
    ///   - slotWidth: The slot bitmap's width in pixels.
    ///   - slotHeight: The slot bitmap's height in pixels.
    ///   - baselinePen: The text baseline, in pixels from the slot's bottom.
    /// - Returns: The pen, in pixels from the slot's bottom-left.
    package static func pen(
        codePoint: UInt32,
        ink: CGRect,
        subpixel: CGFloat,
        glyphMarginX: CGFloat,
        glyphWidth: CGFloat,
        slotWidth: CGFloat,
        slotHeight: CGFloat,
        baselinePen: CGFloat
    ) -> CGPoint {
        var pen = CGPoint(x: glyphMarginX + subpixel, y: baselinePen)
        if Ubiquitty.Rendering.tilesOnTextPen(codePoint) {
            // Nothing horizontal at all. Not the centring, which measures each
            // piece's own ink -- a hook's is wider than the stem it continues,
            // so the two land in different columns -- and not the clamp either,
            // which moves each piece by a different amount for the same reason
            // and undoes a face's own relative placement, which is the one
            // thing about these that is usually right.
            //
            // A face that draws them wider than the cell overhangs it. That is
            // a real limitation and the answer is a column pin that moves the
            // whole family together, not a per-glyph shift that pulls it apart.
            return pen
        }
        guard ink.width > 0, ink.height > 0 else {
            return pen
        }
        let cellCentreX = glyphMarginX + glyphWidth * 0.5
        pen.x = cellCentreX - (ink.origin.x + ink.width * 0.5) + subpixel
        if ink.width <= slotWidth {
            let inkLeft = pen.x + ink.origin.x
            if inkLeft < 0 {
                pen.x -= inkLeft
            } else if inkLeft + ink.width > slotWidth {
                pen.x -= inkLeft + ink.width - slotWidth
            }
        }
        if ink.height <= slotHeight {
            let inkBottom = pen.y + ink.origin.y
            if inkBottom < 0 {
                pen.y -= inkBottom
            } else if inkBottom + ink.height > slotHeight {
                pen.y -= inkBottom + ink.height - slotHeight
            }
        } else {
            // Too tall to contain: centre the crop on the slot rather than
            // spending it all below the baseline.
            pen.y = (slotHeight - ink.height) * 0.5 - ink.origin.y
        }
        return pen
    }
}
