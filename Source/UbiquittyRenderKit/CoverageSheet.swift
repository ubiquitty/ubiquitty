// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// CoverageSheet.swift — one R8 sheet, its slots, and the glyphs in them.
//
// The mono and wide atlases differ in one number: how many cells a slot spans.
// The texture, Core's slot cache, the index-to-rectangle arithmetic and the
// upload are the same work, so they are written once and instantiated per sheet
// rather than copied with a width changed.
//
// That matters beyond tidiness. Two sheets have to agree about what a slot index
// means, because a glyph placed by one arithmetic and sampled by another is off
// by a row and looks like a font bug rather than a renderer one. One
// implementation cannot disagree with itself.
//
// Core owns the slot policy: `GlyphSlotCache` holds the hash and the LRU, and
// the builder runs the whole hit path against the binding this hands over. The
// sheet is reached only to rasterise a glyph the cache had no slot for, which is
// once per glyph per style rather than once per cell.
//
// Core owns the UV arithmetic too. The binding structs carry their own
// `atlasRectForSlot`, so nothing here maps a slot index to a rectangle — a frontend
// that did would be a second mapping, and the builder samples through Core's.

import CoreText
import Metal
import UbiquittyCore

/// An R8 coverage sheet and Core's slot cache over it.
///
/// Not thread-safe: the cache and the rasteriser are reused frame to frame,
/// which is what keeps a steady-state frame free of allocation.
final class CoverageSheet {
    /// The sheet the glyph passes sample.
    let texture: MTLTexture
    /// The staged path to the sheet; see ``AtlasUploader``.
    private let uploader: AtlasUploader

    /// Slots per texture row, after Core clamped the grid to the device limit.
    let columns: Int

    /// Rows of slots in the sheet, after the same clamp.
    let rows: Int

    /// One slot's width in pixels.
    let slotWidthInPixels: Int

    /// One slot's height in pixels.
    let slotHeightInPixels: Int

    /// Core's hash-and-LRU over the slots.
    ///
    /// A reference, not a pointer: Core annotates the class as a shared
    /// reference type, so Swift retains and releases it and the address it hands
    /// the builder stays put for the frame without anything here managing a
    /// lifetime.
    let cache: Ubiquitty.Rendering.GlyphSlotCache

    private let rasterizer: GlyphRasterizer
    /// Where a glyph's origin sits inside a slot.
    let pen: CGPoint

    /// How many slots the sheet holds.
    ///
    /// The clamped product, not what the caller asked for: a grid Core shrank to
    /// fit the device holds fewer slots, and a capacity claiming otherwise would
    /// let the cache assign a slot outside the texture.
    var slotCapacity: Int { columns * rows }

    /// Builds a sheet sized to hold `slotCapacity` slots of one shape.
    ///
    /// - Parameters:
    ///   - device: The device the sheet allocates on.
    ///   - columns: Slots per texture row, before clamping.
    ///   - slotWidthInPixels: One slot's width.
    ///   - slotHeightInPixels: One slot's height.
    ///   - slotCapacity: How many slots to make room for, before clamping.
    ///   - pen: Where a glyph's origin sits inside a slot.
    ///   - centringWidthInPixels: The width a glyph's advance is centred in,
    ///     from the pen; zero draws every glyph at the pen.
    ///   - maxTextureDimension: The API's largest 2D texture edge. Passed in
    ///     rather than read here: Metal states it as a constant per GPU family
    ///     and Vulkan reports it as `maxImageDimension2D`, so the number is the
    ///     backend's while the clamp it feeds is Core's.
    /// The wide boost's multiplier, or zero for a sheet that draws natural.
    ///
    /// The wide sheet grows a glyph toward its two-cell slot; the double sheet
    /// must not, because its masters carry growth of their own.
    ///
    /// The cap applies at every scale this sheet draws, not only at one. A
    /// scaled master is the scale times what the sheet draws unscaled, so a
    /// master built without the growth its own unscaled cell applies renders
    /// the same character smaller when it is scaled — by exactly the cap.
    let boostCap: CGFloat

    /// The width, from the pen, that a glyph's advance is centred in.
    ///
    /// The wide sheet's is its two cells: a face whose advance is narrower than
    /// two cells, as a CJK face beside a narrower primary is, then stands in the
    /// middle of them rather than against the left one. Zero draws at the pen.
    let centringWidthInPixels: CGFloat

    init?(
        device: MTLDevice,
        uploader: AtlasUploader,
        columns: Int,
        slotWidthInPixels: Int,
        slotHeightInPixels: Int,
        slotCapacity: Int,
        pen: CGPoint,
        boostCap: CGFloat = 0,
        centringWidthInPixels: CGFloat = 0,
        maxTextureDimension: Int
    ) {
        self.boostCap = boostCap
        self.centringWidthInPixels = centringWidthInPixels
        self.uploader = uploader
        guard columns > 0, slotCapacity > 0, slotWidthInPixels > 0, slotHeightInPixels > 0,
            let rasterizer = GlyphRasterizer(
                width: slotWidthInPixels,
                height: slotHeightInPixels
            )
        else {
            return nil
        }
        // Core clamps the grid to the device limit. A bounded slot count is not
        // enough on its own: the per-slot pixels alone can push a large font past
        // the maximum texture dimension, and creation then fails descriptor
        // validation rather than returning a smaller sheet.
        let wantedRows = (slotCapacity + columns - 1) / columns
        let fit = Ubiquitty.Rendering.clampAtlasGridToTextureLimit(
            Ubiquitty.GridSize(columns: Int32(columns), rows: Int32(wantedRows)),
            Ubiquitty.IntSize(width: Int32(slotWidthInPixels), height: Int32(slotHeightInPixels)),
            Int32(maxTextureDimension)
        )
        guard fit.valid else {
            return nil
        }
        let fitColumns = Int(fit.columns)
        let fitRows = Int(fit.rows)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: fitColumns * slotWidthInPixels,
            height: fitRows * slotHeightInPixels,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        guard let texture = device.makeTexture(descriptor: descriptor),
            // Core's factory, because the class is a shared reference type and
            // Swift cannot place one itself. The bucket count is Core's too: the
            // load factor and the power-of-two mask are one decision every
            // backend's cache has to make the same way.
            let cache = Ubiquitty.Rendering.makeGlyphSlotCache(
                Int32(fitColumns * fitRows),
                Ubiquitty.Rendering.recommendedHashBuckets(Int32(fitColumns * fitRows)),
                Int32(fitColumns)
            )
        else {
            return nil
        }
        self.texture = texture
        self.columns = fitColumns
        self.rows = fitRows
        self.slotWidthInPixels = slotWidthInPixels
        self.slotHeightInPixels = slotHeightInPixels
        self.rasterizer = rasterizer
        self.pen = pen
        self.cache = cache
    }

    /// Opens a frame, after which touched slots survive eviction within it.
    /// How many glyphs this sheet has queued for a batched raster, ever.
    var enqueuedRasterCount: Int { rasterizer.enqueuedCount }

    func flushRasterBatch() {
        rasterizer.flushBatch()
    }

    func beginFrame() {
        flushRasterBatch()
        cache.beginFrame()
    }

    /// The pixel rectangle a slot occupies.
    ///
    /// - Parameter slot: The slot index the cache assigned.
    /// - Returns: The region to upload into.
    func region(for slot: Int) -> MTLRegion {
        // Core's arithmetic, not a second copy. The Vulkan backend uploads to the
        // same slots from the same grid, and two derivations of where slot N sits
        // would place a glyph in one rectangle and sample it from another.
        let box = Ubiquitty.Rendering.atlasSlotRegion(
            Int32(slot),
            Int32(columns),
            Int32(slotWidthInPixels),
            Int32(slotHeightInPixels)
        )
        return MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height))
    }

    /// Draws a code point into a slot the cache has already assigned.
    ///
    /// Uploaded whether or not the draw put down ink: a slot the cache reassigned
    /// still holds its predecessor, so a blank has to overwrite the sheet rather
    /// than leave it — the rasteriser clears for the same reason.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - font: The face to draw it in.
    ///   - style: The raster style, whose tier is the foreground's weight.
    ///   - subpixel: How far into its pixel the pen falls, 0..<1.
    ///   - raise: The whole pixels the glyph's face is raised.
    ///   - slot: The slot the cache assigned.
    func rasterise(
        _ codePoint: UInt32,
        in font: CTFont,
        style: GlyphRasterizer.Style,
        subpixel: CGFloat,
        raisedBy raise: CGFloat,
        slot: Int
    ) {
        guard let glyph = GlyphAtlas.glyphIdentifier(for: codePoint, in: font) else {
            rasterizer.rasteriseBlank()
            upload(slot)
            return
        }
        let centred = centredPen(of: glyph, in: font, raisedBy: raise)
        rasterizer.enqueue(
            glyph: glyph,
            in: font,
            at: CGPoint(x: centred.x + subpixel, y: centred.y),
            boostCappedTo: boostCap,
            style: style
        ) { [weak self] plane in
            guard let self else { return }
            plane.withUnsafeBytes { pixels in
                self.uploader.stage(
                    pixels.baseAddress!,
                    bytesPerRow: self.slotWidthInPixels,
                    region: self.region(for: slot),
                    into: self.texture
                )
            }
        }
    }

    /// The pen a glyph stands at in a slot so its advance is centred.
    ///
    /// The sheet's pen moved across by the whole pixels its advance leaves of
    /// the centring width, halved, and up by its face's raise. A sized master
    /// magnifies this pen, so a sized glyph stands where the unsized one does,
    /// at its scale.
    ///
    /// - Parameters:
    ///   - glyph: The glyph, or a cluster's base.
    ///   - font: The face that carries it.
    ///   - raise: The whole pixels the face is raised.
    /// - Returns: The pen, bottom-left origin; the sheet's own when it neither
    ///   centres nor raises.
    func centredPen(of glyph: CGGlyph, in font: CTFont, raisedBy raise: CGFloat) -> CGPoint {
        CGPoint(x: pen.x + centringOffset(of: glyph, in: font), y: pen.y + raise)
    }

    /// Where a glyph's ink centre lands above the baseline as this sheet draws it.
    ///
    /// Drawn at the sheet's pen with its growth into the rasteriser's plane and
    /// read back, so what it reports is the raster's own placement rather than a
    /// prediction of it. Nothing is uploaded.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - glyph: The glyph `font` maps it to, which sizes the growth.
    ///   - font: The face to draw it in.
    /// - Returns: The height of the ink's centre above the pen's baseline, in
    ///   pixels, or `nil` when the glyph leaves no ink.
    func drawnInkCentre(of codePoint: UInt32, glyph: CGGlyph, in font: CTFont) -> CGFloat? {
        guard let scalar = Unicode.Scalar(codePoint) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: String(Character(scalar)),
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]
            )
        )
        rasterizer.rasterise(line: line, at: pen, boostCappedTo: boostCap, sizedBy: glyph, in: font)
        // Half coverage marks an edge, so the top and bottom are read alike.
        var topRow: Int?
        var bottomRow: Int?
        rasterizer.coverage.withUnsafeBufferPointer { plane in
            for row in 0..<slotHeightInPixels {
                let start = row * slotWidthInPixels
                if plane[start..<start + slotWidthInPixels].contains(where: { $0 >= 128 }) {
                    topRow = topRow ?? row
                    bottomRow = row
                }
            }
        }
        guard let topRow, let bottomRow else {
            return nil
        }
        // The plane's first row is its top; the pen is measured from its bottom.
        let inkTop = CGFloat(slotHeightInPixels - topRow)
        let inkBottom = CGFloat(slotHeightInPixels - 1 - bottomRow)
        return (inkTop + inkBottom) / 2 - pen.y
    }

    /// How far past the pen a glyph is drawn so its advance is centred.
    ///
    /// Whole pixels, so the pen keeps the subpixel phase Core keyed the slot at.
    ///
    /// - Parameters:
    ///   - glyph: The glyph, or a cluster's base.
    ///   - font: The face that carries it.
    /// - Returns: The offset in pixels; zero when the sheet does not centre.
    private func centringOffset(of glyph: CGGlyph, in font: CTFont) -> CGFloat {
        guard centringWidthInPixels > 0 else {
            return 0
        }
        var glyph = glyph
        let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        guard advance > 0 else {
            return 0
        }
        return ((centringWidthInPixels - advance) / 2).rounded(.towardZero)
    }

    /// Clears a slot, for a cluster CoreText could only resolve to LastResort.
    ///
    /// An upload rather than a skip: the slot the cache assigned may hold a
    /// previous tenant, and the cache has already handed the key over.
    ///
    /// - Parameter slot: The slot the cache assigned.
    /// Draws one glyph by identity at a subpixel phase.
    ///
    /// For a proportional run's glyph (Docs/proportional-text.md): the face is
    /// the proportional one, the pen is the sheet's baseline pen with the
    /// phase added, so a glyph whose shaped origin falls a fraction into a
    /// pixel is drawn at that fraction and its quad lands on whole pixels.
    ///
    /// - Parameters:
    ///   - glyph: The glyph, in `font`'s numbering.
    ///   - font: The face that shaped it.
    ///   - phase: The subpixel phase, 0..<`phaseCount`.
    ///   - phaseCount: How many phases a pixel is divided into.
    ///   - style: The raster style, whose tier is the run's colour weight:
    ///     the fill CoreText's own text draw would land at on that colour,
    ///     so the glyph weighs what a text view's would.
    ///   - slot: The slot the cache assigned.
    func rasterise(glyph: CGGlyph, in font: CTFont, phase: Int, phaseCount: Int, style: GlyphRasterizer.Style, slot: Int) {
        let subpixel = phaseCount > 0 ? CGFloat(phase) / CGFloat(phaseCount) : 0
        rasterizer.rasterise(glyph: glyph, in: font, at: CGPoint(x: pen.x + subpixel, y: pen.y), style: style)
        rasterizer.coverage.withUnsafeBufferPointer { plane in
            Ubiquitty.Rendering.recordProportionalGlyphInk(
                cache,
                Int32(slot),
                Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                Int32(slotWidthInPixels),
                Int32(slotHeightInPixels)
            )
        }
        upload(slot)
    }

    /// Draws one slot-wide window of a proportional glyph drawn larger than
    /// its slot: for a DECDWL row, a DECDHL pair or an OSC 66 scale.
    ///
    /// The raster is the glyph at `scale` times its size both ways and
    /// `horizontalScale` times again across, on a canvas `scale` slots tall
    /// whose baseline is the slot's taken `scale` times, as a sized block's
    /// master is drawn. The sized quad starts `scale * widthScale` margins
    /// before its pen, so the pen stands that many margins in, at the sized
    /// origin's phase, and the window is the slot-wide cut `window` slots along
    /// from the slot height `band` slots down. A DECDWL row is one row tall:
    /// its raster is scale 1, scaled across about the pen and not down.
    ///
    /// - Parameters:
    ///   - glyph: The glyph to draw.
    ///   - font: The face to draw it in, widened where a DECDWL row's family
    ///     can widen.
    ///   - scale: How many times its size the glyph is drawn, and how many
    ///     slots tall the canvas is.
    ///   - widthScale: The doubling across past `scale`: 2 on a DECDWL row.
    ///   - horizontalScale: The outline's factor across past `scale`: what of
    ///     `widthScale` the widened face did not give.
    ///   - phase: The sized origin's subpixel phase, 0..<`phaseCount`.
    ///   - phaseCount: How many phases a pixel is divided into.
    ///   - window: Which slot-wide cut of the sized glyph.
    ///   - band: Which slot height of the canvas, from the top.
    ///   - style: The raster style.
    ///   - slot: The slot the cache assigned.
    func rasteriseSizedWindow(
        glyph: CGGlyph,
        in font: CTFont,
        scale: Int,
        widthScale: Int,
        horizontalScale: CGFloat,
        phase: Int,
        phaseCount: Int,
        window: Int,
        band: Int,
        style: GlyphRasterizer.Style,
        slot: Int
    ) {
        let subpixel = phaseCount > 0 ? CGFloat(phase) / CGFloat(phaseCount) : 0
        // In device pixels from the window's bottom-left; the CTM scales the
        // pen with the glyph, so it is passed at its share.
        let penX = CGFloat(scale * widthScale) * pen.x + subpixel - CGFloat(window * slotWidthInPixels)
        let penY = CGFloat(scale) * pen.y - CGFloat((scale - 1 - band) * slotHeightInPixels)
        let factor = CGFloat(scale)
        rasterizer.rasterise(
            glyph: glyph,
            in: font,
            at: CGPoint(x: penX / factor, y: penY / factor),
            scaleX: factor * horizontalScale,
            scaleY: factor,
            style: style
        )
        upload(slot)
    }

    /// Draws one proportional glyph of the bitmap tier's strike into a slot.
    ///
    /// The native tier's ``rasterise(glyph:in:phase:phaseCount:style:slot:)``
    /// with Core's strike in CoreText's place: the raster is the reference
    /// sheet's, the ink record beside it is what the builder reads to place
    /// and clip the quad, and the upload is this sheet's own.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph, as Core's shaper named it.
    ///   - face: Regular or bold.
    ///   - variant: The subpixel phase and coverage tier.
    ///   - scale: The bitmap family's upscale.
    ///   - plan: The slot this sheet was cut to.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether the glyph was drawn; a refusal leaves the slot as it was.
    func rasteriseUnifontProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        scale: Int,
        plan: Ubiquitty.Rendering.ProportionalGlyphSlotPlan,
        slot: Int
    ) -> Bool {
        guard rasterizer.rasteriseUnifontProportionalGlyph(glyphID, face: face, variant: variant, scale: scale, plan: plan) else {
            return false
        }
        rasterizer.coverage.withUnsafeBufferPointer { plane in
            Ubiquitty.Rendering.recordProportionalGlyphInk(
                cache,
                Int32(slot),
                Ubiquitty.Rendering.CoveragePlaneSpan(plane),
                Int32(slotWidthInPixels),
                Int32(slotHeightInPixels)
            )
        }
        upload(slot)
        return true
    }

    /// Draws one window of a bitmap-tier proportional glyph drawn larger
    /// than its slot into a slot: the reference sheet's window, uploaded here.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph, as Core's shaper named it.
    ///   - face: Regular or bold.
    ///   - variant: The sized origin's subpixel phase and coverage tier.
    ///   - tile: The scale, the band, the window and the doubling across.
    ///   - scale: The bitmap family's upscale.
    ///   - plan: The slot this sheet was cut to.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether the window was drawn; a refusal leaves the slot as it was.
    func rasteriseUnifontSizedProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        tile: Ubiquitty.Rendering.SizedTile,
        scale: Int,
        plan: Ubiquitty.Rendering.ProportionalGlyphSlotPlan,
        slot: Int
    ) -> Bool {
        guard
            rasterizer.rasteriseUnifontSizedProportionalGlyph(
                glyphID,
                face: face,
                variant: variant,
                tile: tile,
                scale: scale,
                plan: plan
            )
        else {
            return false
        }
        upload(slot)
        return true
    }

    func rasteriseBlankSlot(_ slot: Int) {
        rasterizer.rasteriseBlank()
        upload(slot)
    }

    /// The full-slot UV rect a slot occupies, from Core's derivation.
    ///
    /// A span of one: this sheet's slot is already as wide as it needs to be, so
    /// asking for two would sample the slot beside it.
    ///
    /// - Parameter slot: The slot index the cache assigned.
    /// - Returns: The slot's rect in this sheet's texture.
    func atlasRectForSlot(_ slot: Int) -> Ubiquitty.Rendering.GlyphUV {
        var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
        geometry.columns = Int32(columns)
        geometry.slotWidthInPixels = Int32(slotWidthInPixels)
        geometry.slotHeightInPixels = Int32(slotHeightInPixels)
        geometry.glyphWidthInPixels = Int32(slotWidthInPixels)
        return geometry.atlasRectForSlotFull(Int32(slot), Int32(slotCapacity), 1)
    }

    /// Shapes a prepared cluster line into a slot, with the base's growth.
    ///
    /// The line comes in already shaped, so the cluster's string building and the
    /// LastResort refusal stay with the caller that owns them rather than being
    /// written a second time per sheet. What belongs here is the destination: this
    /// sheet's pen, its plane, its growth cap and its slot.
    ///
    /// - Parameters:
    ///   - line: The shaped cluster.
    ///   - baseGlyph: The cluster's base, which sizes the growth.
    ///   - font: The face carrying the base.
    ///   - style: The raster style, whose tier is the foreground's weight.
    ///   - subpixel: How far into its pixel the pen falls, 0..<1.
    ///   - raise: The whole pixels the base's face is raised.
    ///   - slot: The slot the cache assigned.
    func rasterise(
        cluster line: CTLine,
        baseGlyph: CGGlyph,
        in font: CTFont,
        style: GlyphRasterizer.Style,
        subpixel: CGFloat,
        raisedBy raise: CGFloat,
        slot: Int
    ) {
        let centred = centredPen(of: baseGlyph, in: font, raisedBy: raise)
        rasterizer.rasterise(
            line: line,
            at: CGPoint(x: centred.x + subpixel, y: centred.y),
            boostCappedTo: boostCap,
            sizedBy: baseGlyph,
            in: font,
            style: style
        )
        upload(slot)
    }

    /// Fills a slot from Core's embedded bitmap face, at this sheet's extent.
    ///
    /// No pen, no phase and no fallback routing: a bitmap family's slot is its
    /// cell, and a code point the face lacks leaves the slot blank rather than
    /// substituted. Uploaded either way, because the slot may hold a predecessor.
    ///
    /// The native width comes from the caller because it belongs to the page
    /// rather than to this sheet — the slot is measured in device pixels and the
    /// source cell in Unifont's own, so neither derives the other.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - scale: The integer upscale the cell was cut for.
    ///   - nativeWidthInPixels: The source cell width; 16 for a two-cell page.
    ///   - slot: The slot the cache assigned.
    func rasteriseUnifont(_ codePoint: UInt32, scale: Int, nativeWidthInPixels: Int, slot: Int) {
        rasterizer.rasteriseUnifont(codePoint, scale: scale, nativeWidthInPixels: nativeWidthInPixels)
        upload(slot)
    }

    /// Uploads a bitmap cluster to its assigned slot.
    func rasteriseUnifontCluster(_ codePoints: Ubiquitty.Rendering.ClusterSpan, scale: Int, slot: Int) {
        rasterizer.rasteriseUnifontCluster(codePoints, scale: scale)
        upload(slot)
    }

    /// Draws a code point at twice its size into a slot, as a double master.
    ///
    /// The pen stays at the same unscaled coordinates the 1x raster uses and
    /// the transform doubles everything, so the master's baseline is exactly
    /// twice the single-height baseline and a DECDHL top/bottom pair lines up
    /// with the single rows around it. A box glyph's strokes are stretched to
    /// the doubled cell box, the same treatment the 1x atlas gives normal
    /// rows — a DECDWL line of boxes has to meet like one.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - font: The face to draw it in.
    ///   - style: The raster style, whose tier is the foreground's weight.
    ///   - slot: The slot the cache assigned.
    ///   - cellBox: The doubled cell box within the slot, for the stretch.
    func rasteriseDoubleMaster(
        _ codePoint: UInt32,
        in font: CTFont,
        style: GlyphRasterizer.Style,
        slot: Int,
        cellBox: (x0: Int, x1: Int, y0: Int, y1: Int)
    ) {
        drawGlyph(codePoint, in: font, scale: 2, style: style)
        rasterizer.stretchBoxEdges(codePoint, x0: cellBox.x0, x1: cellBox.x1, y0: cellBox.y0, y1: cellBox.y1)
        upload(slot)
    }

    /// Draws the DECDWL master from a face widened on its `wdth` axis.
    ///
    /// The row is twice as wide as it is tall. The widened face supplies as
    /// much of that as its axis reaches, measured on the glyph's own advance,
    /// and the horizontal scale supplies only the rest: at a widening of `r`
    /// the ink is drawn `2 / r` wide and twice as tall, which fills the same
    /// doubled cell box as ``rasteriseDoubleMaster``. A glyph the widened face
    /// lacks, or does not widen, takes the uniform master.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - font: The face the row is set in.
    ///   - widened: The same face at its widened `wdth`.
    ///   - style: The raster style, whose tier is the foreground's weight.
    ///   - slot: The slot the cache assigned.
    ///   - cellBox: The doubled cell box within the slot, for the stretch.
    func rasteriseDoubleWidthMaster(
        _ codePoint: UInt32,
        in font: CTFont,
        widened: CTFont,
        style: GlyphRasterizer.Style,
        slot: Int,
        cellBox: (x0: Int, x1: Int, y0: Int, y1: Int)
    ) {
        guard let glyph = Self.glyph(for: codePoint, in: font), let widenedGlyph = Self.glyph(for: codePoint, in: widened) else {
            rasteriseDoubleMaster(codePoint, in: font, style: style, slot: slot, cellBox: cellBox)
            return
        }
        var glyphs = [glyph, widenedGlyph]
        let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs[0], nil, 1)
        let widenedAdvance = CTFontGetAdvancesForGlyphs(widened, .horizontal, &glyphs[1], nil, 1)
        guard advance > 0, widenedAdvance > advance else {
            rasteriseDoubleMaster(codePoint, in: font, style: style, slot: slot, cellBox: cellBox)
            return
        }
        rasterizer.rasterise(
            glyph: widenedGlyph,
            in: widened,
            at: pen,
            scaleX: 2 * advance / widenedAdvance,
            scaleY: 2,
            style: style
        )
        rasterizer.stretchBoxEdges(codePoint, x0: cellBox.x0, x1: cellBox.x1, y0: cellBox.y0, y1: cellBox.y1)
        upload(slot)
    }

    /// The glyph a face maps a code point to.
    ///
    /// - Parameters:
    ///   - codePoint: The character, encoded as UTF-16 for the lookup.
    ///   - font: The face to look in.
    /// - Returns: The glyph, or `nil` when the face does not carry it.
    private static func glyph(for codePoint: UInt32, in font: CTFont) -> CGGlyph? {
        let characters: [UInt16] =
            codePoint <= 0xFFFF
            ? [UInt16(codePoint)]
            : [UInt16(0xD800 + ((codePoint - 0x10000) >> 10)), UInt16(0xDC00 + ((codePoint - 0x10000) & 0x3FF))]
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
            return nil
        }
        return glyphs[0]
    }

    /// The pen grid a glyph is drawn on once this sheet has grown it.
    ///
    /// - Parameters:
    ///   - glyph: The glyph to draw.
    ///   - font: The face that carries it.
    /// - Returns: How many pen positions one device pixel holds for it.
    func penGridPhaseCount(sizedBy glyph: CGGlyph, in font: CTFont) -> Int {
        rasterizer.penGridPhaseCount(sizedBy: glyph, in: font, cappedTo: boostCap)
    }

    /// Uploads a window another raster drew into its slot.
    ///
    /// Uploaded whether or not the window holds ink: a slot the cache
    /// reassigned still holds its predecessor, so a blank has to overwrite it.
    ///
    /// - Parameters:
    ///   - window: `slotWidthInPixels * slotHeightInPixels` coverage bytes, top row first.
    ///   - slot: The slot the cache assigned.
    func upload(_ window: [UInt8], slot: Int) {
        window.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: slotWidthInPixels,
                region: region(for: slot),
                into: texture
            )
        }
    }

    private func drawGlyph(
        _ codePoint: UInt32,
        in font: CTFont,
        scale: CGFloat,
        style: GlyphRasterizer.Style,
        subpixel: CGFloat = 0,
        boostCap: CGFloat = 0
    ) {
        let pen = CGPoint(x: self.pen.x + subpixel, y: self.pen.y)
        var characters: [UInt16] = []
        if codePoint <= 0xFFFF {
            characters = [UInt16(codePoint)]
        } else {
            let value = codePoint - 0x10000
            characters = [UInt16(0xD800 + (value >> 10)), UInt16(0xDC00 + (value & 0x3FF))]
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
            // The plane still holds the previous glyph; clear it through the
            // rasteriser so the upload that follows evicts rather than keeps.
            rasterizer.rasteriseBlank()
            return
        }
        if boostCap > 1, scale == 1 {
            rasterizer.rasterise(glyph: glyphs[0], in: font, at: pen, boostCappedTo: boostCap, style: style)
        } else {
            rasterizer.rasterise(glyph: glyphs[0], in: font, at: pen, scale: scale, style: style)
        }
    }

    private func upload(_ slot: Int) {
        rasterizer.coverage.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: slotWidthInPixels,
                region: region(for: slot),
                into: texture
            )
        }
    }
}
