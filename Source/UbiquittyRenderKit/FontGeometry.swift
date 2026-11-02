// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FontGeometry.swift — one font configuration measured into atlas geometry.
//
// The measurement half of the font build: CoreText answers what the face is —
// advances, ascent, descent, leading, bounding boxes — and Core's shared
// policies (`FontMetrics::layoutCell`, `computeGlyphSlot`, `ruleGeometry`,
// `xHeightForStrike`) turn those answers into the cell, the slot and the rule
// metrics. Nothing here decides geometry; a decision made on this side of the
// seam would be a second policy for Linux's FreeType measurements to drift
// against.
//
// The faces are built at point size times atlas scale, so every metric read
// off them is already in atlas pixels — the unit the slot, the pen and the
// decoration inputs are specified in.

import CoreText
import UbiquittyCore

/// A font configuration measured into the geometry a renderer is built from.
///
/// Immutable: a family or size change measures a new value rather than
/// mutating one, for the reason ``FontFaces`` gives — a frame mid-encode must
/// not observe half a font change.
package struct FontGeometry {
    /// The faces the measurement was taken from, sized in atlas pixels.
    package let faces: FontFaces
    /// The slot layout the sheets are cut to and the builder lays out against.
    package let geometry: Ubiquitty.Rendering.GlyphSlotGeometry
    /// One cell's width in points, which is what turns a view into a grid.
    package let cellWidthInPoints: Double
    /// One cell's height in points.
    package let cellHeightInPoints: Double
    /// The pen's baseline height above the slot bottom, in atlas pixels.
    package let baselinePenInPixels: Double
    /// The face's own ascent, in atlas pixels, for the placement block.
    package let ascentInAtlasPixels: Double
    /// The face's own descent, in atlas pixels, for the placement block.
    package let descentInAtlasPixels: Double
    /// How far the face's `[` reaches above the baseline, in atlas pixels;
    /// the prompt mark centres on the bracket's box. Zero when the face has
    /// no bracket.
    package let bracketInkTopInAtlasPixels: Double
    /// How far the face's `[` reaches below the baseline, in atlas pixels.
    package let bracketInkBottomInAtlasPixels: Double
    /// The face's cap height in atlas pixels, which the search pills centre
    /// on; zero when the face reports none.
    package let capHeightInAtlasPixels: Double
    /// Atlas pixels per point — the scale the faces were sized at.
    package let atlasScale: Double
    /// The bitmap family's integer upscale, or zero for a CoreText raster.
    /// Non-zero means Core draws this family itself and every metric below
    /// came from its 8×16 cell rather than from the substituted face.
    package let unifontScale: Int
    /// The scalars the per-frame cell metrics derive from; the two cell-size
    /// fields carry the natural cell and are restated per frame by a caller
    /// whose resolved cell differs (DECCOLM, line-height snap).
    package let metricsInputs: CellMetricsInputs

    /// Measures a family at a size, or nil when the face cannot be built.
    ///
    /// - Parameters:
    ///   - familyName: The family to measure.
    ///   - pointSize: The em size in points.
    ///   - atlasScale: Atlas pixels per point; the faces are built at
    ///     `pointSize * atlasScale` so metrics read in atlas pixels.
    ///   - lineSpacingPoints: Extra leading folded into the splittable gap.
    ///   - baselineOffsetPoints: The user's baseline nudge, in points.
    ///   - snapsLineHeight: Whether the cell rounds to whole points and the
    ///     baseline to whole pixels, trading exact metrics for crisp rules.
    ///   - maxTextureDimension: The device's largest 2D texture edge, which
    ///     bounds the nominal slot grid. No default: the desktop number is
    ///     wrong on every GPU family below Apple 3, and a default is how a
    ///     call site takes it without saying so.
    ///   - symbolFallbackFace: The symbol fallback face the glyphs will be
    ///     drawn from, at the same size as the primary, or nil. Its bounding
    ///     box grows the slot: the bundled Nerd face is cut to a larger em
    ///     than the primary's, and a slot sized to the primary alone crops
    ///     its ink.
    package init?(
        familyName: String,
        pointSize: Double,
        atlasScale: Double,
        maxTextureDimension: Int,
        lineSpacingPoints: Double = 0,
        characterSpacingPoints: Double = 0,
        fontWeight: Int = 0,
        boldFontWeight: Int = 0,
        fontWidthPercent: Double = 0,
        featureSpec: String = "",
        variationSpec: String = "",
        baselineOffsetPoints: Double = 0,
        snapsLineHeight: Bool = false,
        symbolFallbackFace: CTFont? = nil
    ) {
        guard pointSize > 0, atlasScale > 0,
            let faces = FontFaces(
                family: familyName,
                size: pointSize * atlasScale,
                pixelsPerPoint: atlasScale,
                weight: fontWeight,
                boldWeight: boldFontWeight,
                featureSpec: featureSpec,
                widthPercent: fontWidthPercent,
                variationSpec: variationSpec
            )
        else {
            return nil
        }
        self.faces = faces
        self.atlasScale = atlasScale

        // A family Core rasterises itself takes its whole geometry from
        // Core's 8×16 cell — the same block UBRenderer keeps, field for
        // field, so the two macOS arms and the portable ones draw one grid.
        // The CoreText faces above stay built: colour, wide and box glyphs
        // still come from them, exactly as on the other arm.
        let embeddedScale = Int(Ubiquitty.Rendering.unifontScaleForConfiguredFamily(std.string(familyName), pointSize, atlasScale))
        self.unifontScale = embeddedScale
        if embeddedScale > 0 {
            let lineSpacingInPixels = Int32((lineSpacingPoints * atlasScale).rounded())
            // Whole pixels, as the line spacing beside it is: the bitmap face
            // draws on the pixel lattice, and a cell carrying a fraction of one
            // puts every second column's edge on a pixel centre.
            let characterSpacingInPixels = Int32((characterSpacingPoints * atlasScale).rounded())
            let cm = Ubiquitty.Rendering.unifontCellMetricsForScale(
                Int32(embeddedScale),
                lineSpacingInPixels,
                characterSpacingInPixels
            )
            let cellWidth = Double(cm.cellWidth)
            let cellHeight = Double(cm.cellHeight)
            let baselineFromTop = Double(cm.baselineFromTop)
            self.ascentInAtlasPixels = baselineFromTop
            self.descentInAtlasPixels = cellHeight - baselineFromTop
            self.bracketInkTopInAtlasPixels = 0
            self.bracketInkBottomInAtlasPixels = 0
            // The bitmap face reports no cap height, so its pills stay on the
            // cell's box on every arm.
            self.capHeightInAtlasPixels = 0
            // Pen from the slot bottom: the matching descent, plus the user's
            // nudge — the other arm's _baselineDyInPixels, spelled here.
            self.baselinePenInPixels = (cellHeight - baselineFromTop) + baselineOffsetPoints * atlasScale
            // Tracking lands in the CELL on this branch, not in a pitch laid
            // around it: `cellMetrics` already widened the cell by it, the slot
            // below is that cell, and Core's fill centres the 8-column bitmap in
            // the gap. So the pitch and the slot are one number, the blit is
            // 1:1, and the glyph keeps the shape the face drew rather than being
            // resampled across a cell wider than the box it was cut for.
            self.cellWidthInPoints = max(1, cellWidth / atlasScale)
            self.cellHeightInPoints = max(1, cellHeight / atlasScale)
            var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
            let slotWidth = Int32(cellWidth)
            let slotHeight = Int32(cellHeight)
            geometry.columns = min(128, max(1, Int32(maxTextureDimension) / max(1, slotWidth)))
            geometry.slotWidthInPixels = slotWidth
            geometry.slotHeightInPixels = slotHeight
            geometry.glyphWidthInPixels = slotWidth
            geometry.glyphMarginInPixels.width = 0
            geometry.glyphMarginInPixels.height = 0
            geometry.referenceAdvanceInPixels = Float(cellWidth)
            geometry.referenceLineHeightInPixels = Float(self.cellHeightInPoints * atlasScale)
            geometry.wideSlotWidthInPixels = 2 * slotWidth
            geometry.wideSlotHeightInPixels = slotHeight
            geometry.doubleSlotWidthInPixels = 2 * slotWidth
            geometry.doubleSlotHeightInPixels = 2 * slotHeight
            let ligaturePitchInPixels = max(
                geometry.glyphWidthInPixels,
                Int32((self.cellWidthInPoints * atlasScale).rounded(.up))
            )
            geometry.ligatureSlotWidthInPixels = max(
                1,
                Ubiquitty.Rendering.ligatureStripSlotWidthInPixels(ligaturePitchInPixels, 0)
            )
            // Taller than the cell by Core's strike overhang on both sides:
            // the bitmap tier's proportional face reaches past Unifont's
            // 16 rows, and the strip slot holds those rows rather than
            // cutting a descender at the cell.
            geometry.ligatureSlotHeightInPixels =
                slotHeight + 2 * Ubiquitty.Rendering.unifontProportionalStripOverhangInPixels(Int32(embeddedScale))
            self.geometry = geometry
            self.metricsInputs = CellMetricsInputs(
                cellWidthInPixels: self.cellWidthInPoints * atlasScale,
                cellHeightInPixels: cellHeight,
                cellHeightInPoints: self.cellHeightInPoints,
                deviceScale: atlasScale,
                atlasScale: atlasScale,
                fontSizeInPoints: pointSize,
                ascentInAtlasPixels: baselineFromTop,
                lineGapTopInAtlasPixels: 0,
                xHeightInAtlasPixels: Double(cm.xHeight),
                underlineThicknessInAtlasPixels: Double(cm.underlineThickness),
                underlineDropInAtlasPixels: Double(cm.underlineDrop),
                underlineThicknessBoldInAtlasPixels: Double(cm.underlineThickness),
                underlineDropBoldInAtlasPixels: Double(cm.underlineDrop),
                underlineCurlyThicknessInAtlasPixels: Double(cm.underlineCurlyThickness),
                strikeThicknessInAtlasPixels: Double(cm.strikeThickness),
                strikeThicknessBoldInAtlasPixels: Double(cm.strikeThickness)
            )
            return
        }
        let font = faces[bold: false, italic: false]

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        // The face rule policy: the face's own underline weight and the space
        // below its baseline, which is what AppKit places a rule by. The face
        // is built at point size times atlas scale, so every metric here is
        // already in device pixels.
        var faceRules = Ubiquitty.Rendering.RuleFaceMetrics()
        faceRules.underlineThickness = Float(CTFontGetUnderlineThickness(font))
        faceRules.descent = Float(descent)
        faceRules.leading = Float(leading)
        let rules = Ubiquitty.Rendering.ruleGeometry(
            Float(pointSize * atlasScale),
            Float(atlasScale),
            faceRules
        )
        let measuredXHeight = CTFontGetXHeight(font)
        let xHeight = Ubiquitty.Rendering.xHeightForStrike(
            Float(measuredXHeight >= 1.0 ? measuredXHeight : 0.0),
            Float(ascent)
        )

        // Cell width is the WIDEST printable-ASCII advance for a fixed face, not
        // one representative glyph's: a nominally-monospace face with one wider
        // glyph — usually punctuation or a digit — otherwise reports a cell
        // narrower than its own content, and that glyph paints into its
        // neighbour for as long as the font is selected. A proportional face is
        // cut to its digit, its rows being laid out as proportional runs.
        // CoreText answers what the advances are; which one the cell is, and
        // which entries are not answers at all, is Core's — this file measures
        // and does not decide.
        var advance = CGSize.zero
        // `char32_t` arrives as a Unicode.Scalar; CoreText takes UTF-16 units,
        // and every code point in the sample is one.
        let firstPrintable = UInt16(Ubiquitty.Rendering.FontMetrics.firstProbeCharacter.value)
        let lastPrintable = UInt16(Ubiquitty.Rendering.FontMetrics.lastProbeCharacter.value)
        let characters = [UInt16](firstPrintable...lastPrintable)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        if CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) {
            var advances = [CGSize](repeating: .zero, count: characters.count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, characters.count)
            let widths = advances.map { Double($0.width) }
            advance.width = widths.withUnsafeBufferPointer {
                let sample = Ubiquitty.Rendering.FontMetrics.AdvanceSpan($0)
                return Ubiquitty.Rendering.FontMetrics.cellAdvance(Ubiquitty.Rendering.FontMetrics.facePitch(sample), sample)
            }
        }
        if advance.width <= 0 {
            // The face lacks full printable-ASCII coverage (the batch probe
            // reports false if any character is missing); the single-glyph
            // probe still yields a usable cell.
            var probeCharacter: UInt16 = UInt16(UInt8(ascii: "M"))
            var probeGlyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(font, &probeCharacter, &probeGlyph, 1)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &probeGlyph, &advance, 1)
        }

        // The slot needs whole backing pixels, but the cell LAYOUT metric is
        // the true fractional advance and line height — a ceil'd cell would
        // over-space every column. Vertical layout is Core's: cell = ink box
        // + slack split evenly above and below, which keeps a face with a
        // built-in gap from riding low and locks the raster and draw
        // baselines to one gap split.
        let snapUnit = snapsLineHeight ? atlasScale : 0.0
        let vertical = Ubiquitty.Rendering.FontMetrics.layoutCell(
            ascent,
            descent,
            leading,
            lineSpacingPoints * atlasScale,
            snapUnit
        )
        var glyphWidthInPixels = Int32(ceil(advance.width))
        if glyphWidthInPixels < 1 {
            glyphWidthInPixels = 1
        }

        // Margin and slot from the font's bounding box via the shared policy,
        // so ink spilling past the cell box renders instead of clipping — the
        // same rule Linux feeds its FreeType bbox through. The symbol fallback's
        // box goes in beside the primary's: the bundled Nerd face is cut to a
        // larger em than the primary's, and the policy grows the margins by
        // half its excess per side, since the fallback pen centres each glyph
        // on the cell — so the ink renders into the margins instead of being
        // cropped at slot-fill time.
        var slotInputs = Ubiquitty.Rendering.GlyphOverhangInputs()
        slotInputs.advanceWidth = advance.width
        slotInputs.ascent = ascent
        slotInputs.descent = descent
        slotInputs.lineHeight = vertical.lineHeight
        let primaryBox = CTFontGetBoundingBox(font)
        slotInputs.primaryBboxX = primaryBox.origin.x
        slotInputs.primaryBboxY = primaryBox.origin.y
        slotInputs.primaryBboxWidth = primaryBox.size.width
        slotInputs.primaryBboxHeight = primaryBox.size.height
        if let symbolFallbackFace {
            let fallbackBox = CTFontGetBoundingBox(symbolFallbackFace)
            slotInputs.hasFallback = true
            slotInputs.fallbackBboxX = fallbackBox.origin.x
            slotInputs.fallbackBboxY = fallbackBox.origin.y
            slotInputs.fallbackBboxWidth = fallbackBox.size.width
            slotInputs.fallbackBboxHeight = fallbackBox.size.height
        }
        let slot = Ubiquitty.Rendering.computeGlyphSlot(slotInputs)

        // Pen baseline inside a slot = bottom margin + the layout baseline
        // above the cell bottom. The descent is fractional, so without
        // snapping the baseline lands between device rows and antialiases;
        // snapped mode rounds it. Same gap split the draw-path baseline
        // reads, so raster and underline baselines lock.
        var baselinePen =
            Double(slot.marginInPixels.height) + vertical.baselineFromBottom
            + baselineOffsetPoints * atlasScale
        if snapsLineHeight {
            baselinePen = baselinePen.rounded()
        }
        self.baselinePenInPixels = baselinePen
        self.ascentInAtlasPixels = Double(ascent)
        self.descentInAtlasPixels = Double(descent)
        let bracket = FontGeometry.bracketInk(of: font)
        self.bracketInkTopInAtlasPixels = bracket.top
        self.bracketInkBottomInAtlasPixels = bracket.bottom
        let measuredCapHeight = Double(CTFontGetCapHeight(font))
        self.capHeightInAtlasPixels = measuredCapHeight >= 1.0 ? measuredCapHeight : 0

        // Tracking lands on the pitch and nowhere else: the slot, the margins
        // and the reference advance stay the face's own, because they describe
        // the ink rather than the column it sits in.
        var cellWidthInPoints = Ubiquitty.Rendering.FontMetrics.trackedCellAdvance(
            advance.width / atlasScale,
            characterSpacingPoints
        )
        var cellHeightInPoints = vertical.lineHeight / atlasScale
        if cellWidthInPoints < 1 {
            cellWidthInPoints = 1
        }
        if cellHeightInPoints < 1 {
            cellHeightInPoints = 1
        }
        self.cellWidthInPoints = cellWidthInPoints
        self.cellHeightInPoints = cellHeightInPoints

        // The published layout: mono slot from the fit, wide and double slots
        // derived the way the sheets cut them — wide is two cell boxes at
        // normal height, double is the mono slot doubled on both axes — and
        // the ligature strip from Core's own derivation, so the sheet cut
        // from this geometry is the slot every arm agrees on.
        var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
        geometry.columns = min(128, max(1, Int32(maxTextureDimension) / max(1, slot.slotWidthInPixels)))
        geometry.slotWidthInPixels = slot.slotWidthInPixels
        geometry.slotHeightInPixels = slot.slotHeightInPixels
        geometry.glyphWidthInPixels = glyphWidthInPixels
        geometry.glyphMarginInPixels.width = slot.marginInPixels.width
        geometry.glyphMarginInPixels.height = slot.marginInPixels.height
        geometry.referenceAdvanceInPixels = Float(advance.width > 0 ? advance.width : Double(glyphWidthInPixels))
        geometry.referenceLineHeightInPixels = Float(cellHeightInPoints * atlasScale)
        geometry.wideSlotWidthInPixels = 2 * slot.slotWidthInPixels
        geometry.wideSlotHeightInPixels = slot.slotHeightInPixels
        geometry.doubleSlotWidthInPixels = 2 * slot.slotWidthInPixels
        geometry.doubleSlotHeightInPixels = 2 * slot.slotHeightInPixels
        // Cut for the grid pitch, not the face's advance: the sheet anchors
        // each cluster at its cell, so a tracked pitch widens every chunk's
        // strip and a slot cut for the advance clips its tail cells.
        let ligaturePitchInPixels = max(
            geometry.glyphWidthInPixels,
            Int32(ceil(cellWidthInPoints * atlasScale))
        )
        geometry.ligatureSlotWidthInPixels = max(
            1,
            Ubiquitty.Rendering.ligatureStripSlotWidthInPixels(
                ligaturePitchInPixels,
                geometry.glyphMarginInPixels.width
            )
        )
        geometry.ligatureSlotHeightInPixels = slot.slotHeightInPixels
        self.geometry = geometry

        // The natural cell in atlas pixels stands in for the resolved cell;
        // a caller whose frame compresses or snaps the cell restates the two
        // cell fields before resolving.
        let underlineThickness = Double(rules.underlineThickness)
        let underlineDrop = Double(rules.underlineDrop)
        let strikeThickness = Double(rules.strikeThickness)
        let curlyThickness = Double(rules.curlyThickness)
        self.metricsInputs = CellMetricsInputs(
            // The tracked pitch, because this is the LAYOUT metric: quads,
            // slices and the pointer's cell all derive from it, and a builder
            // fed the face's advance here places columns at a pitch the
            // window was not sized for.
            cellWidthInPixels: cellWidthInPoints * atlasScale,
            cellHeightInPixels: cellHeightInPoints * atlasScale,
            cellHeightInPoints: cellHeightInPoints,
            deviceScale: atlasScale,
            atlasScale: atlasScale,
            fontSizeInPoints: pointSize,
            ascentInAtlasPixels: Double(ascent),
            lineGapTopInAtlasPixels: Double(vertical.gapTop),
            xHeightInAtlasPixels: Double(xHeight),
            underlineThicknessInAtlasPixels: underlineThickness,
            underlineDropInAtlasPixels: underlineDrop,
            underlineThicknessBoldInAtlasPixels: underlineThickness,
            underlineDropBoldInAtlasPixels: underlineDrop,
            underlineCurlyThicknessInAtlasPixels: curlyThickness,
            strikeThicknessInAtlasPixels: strikeThickness,
            strikeThicknessBoldInAtlasPixels: strikeThickness
        )
    }
}

extension FontGeometry {
    /// The pitch of a face, from the printable-ASCII sample its cell is measured from.
    ///
    /// CoreText answers the advances; whether they are one pitch is Core's.
    ///
    /// - Parameter font: The face, at its device size.
    /// - Returns: `Proportional` when the sampled advances differ.
    package static func facePitch(of font: CTFont) -> Ubiquitty.Rendering.FontMetrics.FacePitch {
        let first = UInt16(Ubiquitty.Rendering.FontMetrics.firstProbeCharacter.value)
        let last = UInt16(Ubiquitty.Rendering.FontMetrics.lastProbeCharacter.value)
        let characters = [UInt16](first...last)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        // A partial map still names the glyphs it found; a missing one is
        // glyph 0, whose advance Core skips only when it is zero, so it is
        // cleared here rather than measured as .notdef.
        _ = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, characters.count)
        let widths = zip(glyphs, advances).map { $0.0 == 0 ? 0 : Double($0.1.width) }
        return widths.withUnsafeBufferPointer {
            Ubiquitty.Rendering.FontMetrics.facePitch(Ubiquitty.Rendering.FontMetrics.AdvanceSpan($0))
        }
    }
}

extension FontGeometry {
    /// The ink box of a face's `[`, as how far it reaches above and below the
    /// baseline in the face's own pixels; both zero when the face has no
    /// bracket glyph.
    ///
    /// - Parameter font: The face, at its device size.
    /// - Returns: The reach above and below the baseline, each non-negative.
    static func bracketInk(of font: CTFont) -> (top: Double, bottom: Double) {
        var characters: [UInt16] = [0x5B]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1), glyphs[0] != 0 else {
            return (0, 0)
        }
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, &box, 1)
        return (max(0, Double(box.maxY)), max(0, Double(-box.minY)))
    }
}
