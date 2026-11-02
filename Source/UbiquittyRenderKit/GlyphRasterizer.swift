// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GlyphRasterizer.swift — one glyph into an 8-bit coverage plane.
//
// The bottom of the glyph path. Core decides which glyph and which face, the
// catalogue resolves the font, and this draws it: a grayscale bitmap where each
// byte is how much of that pixel the ink covers. The atlas uploads the plane as
// an R8 texture and the shader tints it with the cell's foreground, which is why
// the plane carries coverage and no colour of its own.
//
// An alpha-only context, drawn with a gray fill the plane never stores. The
// fill matters even though only alpha comes back: CoreText's font smoothing
// dilates a glyph by an amount that steps with the fill's Rec.709 linear
// luminance, and the alpha it writes is that tier's coverage with the colour
// already divided out. Filling at the tier's representative gray therefore
// yields the mask AppKit composites for a foreground in that tier, where a
// gray plane filled white holds only the heaviest tier. See GlyphKey.h
// rasterTierForLinearLuma for the tiers.
//
// The context is built once per slot geometry and reused. CGBitmapContext
// creation is not cheap, and this runs on every glyph miss — a font change or a
// resize is what rebuilds it, not a cache miss.

import CoreGraphics
import CoreText
import Foundation
import UbiquittyCore

/// Draws glyphs into a reusable 8-bit coverage plane.
///
/// Not thread-safe: one context and one scratch plane are reused across calls,
/// which is what makes a miss cheap. The frame build is the only caller.
final class GlyphRasterizer {
    /// The plane's width in pixels.
    let width: Int
    /// The plane's height in pixels.
    let height: Int

    /// One rasterisation's smoothing tier, which sets the fill gray CoreText
    /// weights the glyph by.
    struct Style: Equatable {
        var tier: UInt32 = Ubiquitty.Rendering.rasterTierCount - 1

        static let heaviest = Style()
    }

    /// The gray a tier is filled at: any value inside the tier's luminance band
    /// draws the same mask, and these sit at the band centres (tier 0 at a
    /// small gray rather than black, which CoreText treats the same and which
    /// leaves the fill distinguishable from the clear).
    static func fillGray(forTier tier: UInt32) -> CGFloat {
        switch tier {
        case 0: return 0.05
        case 1: return 0.537
        case 2: return 0.735
        case 3: return 0.881
        default: return 1.0
        }
    }

    /// The coverage bytes, `width * height` of them, row-major and tightly packed.
    ///
    /// Valid until the next ``rasterise(glyph:in:at:)``, which clears and redraws
    /// it. The atlas copies out before asking for another.
    private(set) var coverage: [UInt8]

    private let context: CGContext

    private struct PendingGlyph {
        let glyph: CGGlyph
        let font: CTFont
        let origin: CGPoint
        let style: Style
        let transform: CGAffineTransform
        let consume: ([UInt8]) -> Void
    }

    /// One draw group: the same font object, tier and scale.
    ///
    /// Compared and hashed by the font's identity rather than by
    /// `CFEqual`/`CFHash`, which do not keep Hashable's contract for a varied
    /// face: drawing font_variations (JetBrains Mono at wght 700), the
    /// dictionary found two keys equal while it grew and Swift trapped with
    /// "Duplicate keys of type 'BatchKey' were found in a Dictionary",
    /// failing the frame on both Apple arms. Identity cannot change under a
    /// key; two instances of one face only cost a second draw.
    private struct BatchKey: Hashable {
        let font: CTFont
        let tier: UInt32
        let scale: CGFloat

        static func == (left: Self, right: Self) -> Bool {
            left.font === right.font && left.tier == right.tier && left.scale == right.scale
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
            hasher.combine(tier)
            hasher.combine(scale)
        }
    }

    private var pendingGlyphs: [PendingGlyph] = []

    /// How many glyphs have been queued for a batched raster, ever. A caller
    /// compares two readings to learn whether a build faulted a glyph whose
    /// ink is measured only when its batch lands.
    private(set) var enqueuedCount = 0
    private var batchContext: CGContext?
    private static let batchCapacity = 128
    private static let maxBatchDimension = 4096
    private static let maxBatchBytes = 8 << 20
    private static let isBatchLogging = ProcessInfo.processInfo.environment["UBQ_RASTER_BATCHLOG"] != nil
    private(set) var batchedGlyphCount = 0
    private(set) var batchDrawCount = 0

    /// Defers only the pixels: the caller reserves and pins the atlas slot now.
    /// The consumer must run before the frame samples that slot.
    func enqueue(
        glyph: CGGlyph,
        in font: CTFont,
        at origin: CGPoint,
        boostCappedTo boostCap: CGFloat = 0,
        style: Style,
        consume: @escaping ([UInt8]) -> Void
    ) {
        enqueuedCount += 1
        pendingGlyphs.append(
            PendingGlyph(
                glyph: glyph,
                font: font,
                origin: origin,
                style: style,
                transform: boostTransform(sizedBy: glyph, in: font, at: origin, cappedTo: boostCap, landing: .onPenGrid),
                consume: consume
            )
        )
        if pendingGlyphs.count == Self.batchCapacity { flushBatch() }
    }

    /// Draws each font/tier/scale group at explicit positions in disjoint tiles.
    /// Padding includes every glyph's overhang; cropping copies only its slot.
    func flushBatch() {
        guard !pendingGlyphs.isEmpty else { return }
        let requests = pendingGlyphs
        pendingGlyphs.removeAll(keepingCapacity: true)
        var groups: [BatchKey: [PendingGlyph]] = [:]
        for request in requests {
            let key = BatchKey(font: request.font, tier: request.style.tier, scale: request.transform.a)
            groups[key, default: []].append(request)
        }
        let beforeDraws = batchDrawCount
        for (key, group) in groups {
            drawBatch(group, key: key)
        }
        if Self.isBatchLogging {
            FileHandle.standardError.write(
                Data("[perf] raster-batch glyphs=\(requests.count) draws=\(batchDrawCount - beforeDraws)\n".utf8)
            )
        }
    }

    private func drawBatch(_ requests: [PendingGlyph], key: BatchKey) {
        var glyphs = requests.map(\.glyph)
        var bounds = [CGRect](repeating: .zero, count: requests.count)
        CTFontGetBoundingRectsForGlyphs(key.font, .horizontal, &glyphs, &bounds, glyphs.count)
        var left = 2
        var right = 2
        var bottom = 2
        var top = 2
        for (request, ink) in zip(requests, bounds) {
            let positioned = ink.offsetBy(dx: request.origin.x, dy: request.origin.y).applying(request.transform)
            guard positioned.minX.isFinite, positioned.maxX.isFinite, positioned.minY.isFinite, positioned.maxY.isFinite,
                positioned.minX >= -CGFloat(Self.maxBatchDimension), positioned.minY >= -CGFloat(Self.maxBatchDimension),
                positioned.maxX <= CGFloat(Self.maxBatchDimension), positioned.maxY <= CGFloat(Self.maxBatchDimension)
            else {
                drawIndividually(requests)
                return
            }
            left = max(left, Int(ceil(-positioned.minX)) + 2)
            right = max(right, Int(ceil(positioned.maxX - CGFloat(width))) + 2)
            bottom = max(bottom, Int(ceil(-positioned.minY)) + 2)
            top = max(top, Int(ceil(positioned.maxY - CGFloat(height))) + 2)
        }
        let tileWidth = width + left + right
        let tileHeight = height + bottom + top
        let columns = min(requests.count, min(16, Self.maxBatchDimension / tileWidth))
        let rows = columns > 0 ? (requests.count + columns - 1) / columns : 0
        let pageWidth = columns * tileWidth
        let pageHeight = rows * tileHeight
        guard columns > 0, pageHeight <= Self.maxBatchDimension,
            pageWidth * pageHeight <= Self.maxBatchBytes
        else {
            drawIndividually(requests)
            return
        }
        if batchContext?.width != pageWidth || batchContext?.height != pageHeight {
            batchContext = CGContext(
                data: nil,
                width: pageWidth,
                height: pageHeight,
                bitsPerComponent: 8,
                bytesPerRow: pageWidth,
                space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
            batchContext?.setShouldAntialias(true)
        }
        guard let page = batchContext, let data = page.data else {
            drawIndividually(requests)
            return
        }
        page.saveGState()
        page.textMatrix = .identity
        page.setBlendMode(.copy)
        page.setFillColor(gray: 0, alpha: 0)
        page.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        page.setBlendMode(.normal)
        page.setFillColor(gray: Self.fillGray(forTier: key.tier), alpha: 1)
        page.scaleBy(x: key.scale, y: key.scale)
        var positions = requests.enumerated()
            .map { index, request in
                CGPoint(
                    x: request.origin.x + (CGFloat(index % columns * tileWidth + left) + request.transform.tx) / key.scale,
                    y: request.origin.y + (CGFloat(index / columns * tileHeight + bottom) + request.transform.ty) / key.scale
                )
            }
        CTFontDrawGlyphs(key.font, &glyphs, &positions, glyphs.count, page)
        page.restoreGState()
        batchedGlyphCount += glyphs.count
        batchDrawCount += 1
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for (index, request) in requests.enumerated() {
            // CGBitmapContext's first row is the top row, while pen positions
            // are measured from the bottom of the page.
            let x = index % columns * tileWidth + left
            let y = pageHeight - (index / columns * tileHeight + bottom + height)
            coverage.withUnsafeMutableBufferPointer { target in
                for row in 0..<height {
                    target.baseAddress!.advanced(by: row * width).update(from: bytes.advanced(by: (y + row) * pageWidth + x), count: width)
                }
            }
            request.consume(coverage)
        }
    }

    private func drawIndividually(_ requests: [PendingGlyph]) {
        for request in requests {
            clearPlane()
            context.saveGState()
            context.concatenate(request.transform)
            draw(request.glyph, in: request.font, at: request.origin, style: request.style)
            context.restoreGState()
            _ = captureCoverage()
            request.consume(coverage)
        }
    }

    /// Applies the box family's transforms to the rasterised coverage.
    ///
    /// The single family-wide centring shift moves the connection stroke from
    /// its baseline-relative row to the cell centre, and the 9-slice stretch
    /// then extends the strokes to the cell edges — in that order, because a
    /// per-glyph recentre would move an asymmetric corner or tee off the
    /// family's shared row and reintroduce the seam between cells.
    ///
    /// Core says which glyphs the shift may move. The terminal-graphics scan
    /// lines and vertical box lines name the row or the edge they stand on, so
    /// they take the stretch and not the shift.
    ///
    /// - Parameters:
    ///   - codePoint: The box glyph, which names its own reach.
    ///   - centerShiftY: The family's uniform vertical shift, in pixels.
    ///   - glyphBoxLeft: The glyph box's left edge inside the slot.
    ///   - glyphBoxRight: The glyph box's right edge.
    ///   - glyphBoxTop: The glyph box's top edge.
    ///   - glyphBoxBottom: The glyph box's bottom edge.
    func applyBoxFamilyTransforms(
        codePoint: UInt32,
        centerShiftY: Int32,
        glyphBoxLeft: Int32,
        glyphBoxRight: Int32,
        glyphBoxTop: Int32,
        glyphBoxBottom: Int32
    ) {
        let planeWidth = Int32(width)
        let planeHeight = Int32(height)
        coverage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            if centerShiftY != 0, Ubiquitty.Rendering.BoxDrawing.takesFamilyCentring(codePoint) {
                Ubiquitty.Rendering.translateScratchVertical(base, planeWidth, planeHeight, centerShiftY)
            }
            var reachesLeft = false
            var reachesRight = false
            var reachesTop = false
            var reachesBottom = false
            if Ubiquitty.Rendering.boxReachEdges(codePoint, &reachesLeft, &reachesRight, &reachesTop, &reachesBottom) {
                Ubiquitty.Rendering.edgeStretchBoxScratch(
                    base,
                    planeWidth,
                    planeHeight,
                    glyphBoxLeft,
                    glyphBoxRight,
                    glyphBoxTop,
                    glyphBoxBottom,
                    reachesLeft,
                    reachesRight,
                    reachesTop,
                    reachesBottom
                )
            }
        }
    }

    /// Builds a rasteriser for one slot geometry.
    ///
    /// - Parameters:
    ///   - width: Slot width in pixels.
    ///   - height: Slot height in pixels.
    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else {
            return nil
        }
        self.width = width
        self.height = height
        self.coverage = [UInt8](repeating: 0, count: width * height)
        // bytesPerRow equals the width: the plane is handed to Metal as a tight
        // R8 upload, and a padded row would shift every line after the first.
        // Alpha-only, so one byte a pixel like the gray plane it replaces; the
        // colour space is a formality the initialiser insists on.
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        else {
            return nil
        }
        self.context = context
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.setShouldAntialias(true)
        // Left at the context default on purpose: a gray or alpha bitmap
        // context smooths unless the user's AppleFontSmoothing preference says
        // otherwise, and that preference must reach this raster exactly as it
        // reaches every AppKit text view. Forcing it on here is ignored under
        // the preference; forcing it off would thin every user's text.
    }

    /// Draws one glyph and returns whether it put down any ink.
    ///
    /// The plane is cleared first: a slot the cache reassigned still holds the
    /// previous glyph, and a draw that misses would otherwise leave the old one
    /// visible under a new code point — which looks like a mapping bug rather
    /// than a rasterisation one.
    ///
    /// - Parameters:
    ///   - glyph: The glyph identifier, from the font that carries it.
    ///   - font: The face to draw it in.
    ///   - origin: The pen position within the slot, in pixels from bottom-left.
    /// - Returns: Whether any pixel came back non-zero.
    /// Draws one glyph grown toward the slot, the wide sheet's treatment.
    ///
    /// The boost multiplies around the glyph's natural ink centre so it grows
    /// in place rather than re-centring on the geometric slot centre, capped
    /// to the physical slot on both axes and never applied to a glyph whose
    /// natural ink already fills the cell.
    ///
    /// - Parameters:
    ///   - glyph: The glyph identifier, from the font that carries it.
    ///   - font: The face to draw it in.
    ///   - origin: The pen position, baseline-relative like the plain draw.
    ///   - boostCap: The multiplier before the slot caps, at most.
    /// - Returns: Whether any pixel came back non-zero.
    @discardableResult
    func rasterise(glyph: CGGlyph, in font: CTFont, at origin: CGPoint, boostCappedTo boostCap: CGFloat, style: Style = .heaviest) -> Bool {
        clearPlane()
        context.saveGState()
        applyBoost(sizedBy: glyph, in: font, at: origin, cappedTo: boostCap, landing: .onPenGrid)
        draw(glyph, in: font, at: origin, style: style)
        context.restoreGState()
        // The context draws into its own plane; the coverage the caller
        // uploads is captured from it, exactly as the plain draw does.
        return captureCoverage()
    }

    @discardableResult
    func rasterise(glyph: CGGlyph, in font: CTFont, at origin: CGPoint, scale: CGFloat = 1, style: Style = .heaviest) -> Bool {
        clearPlane()
        if scale != 1 {
            // The CTM scales and the pen does not: the pen stays at the same
            // unscaled slot coordinates the 1x raster uses, so a 2x master's
            // baseline is exactly twice the single-height baseline and a
            // DECDHL top/bottom pair lines up with the single rows around it.
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            draw(glyph, in: font, at: origin, style: style)
            context.restoreGState()
        } else {
            draw(glyph, in: font, at: origin, style: style)
        }
        return captureCoverage()
    }

    /// Draws a glyph scaled by a different factor on each axis.
    ///
    /// The pen lands where a uniform `scaleY` draw puts it, so a master drawn
    /// this way shares its baseline and left inset with the uniform master of
    /// the same slot, and only the ink's width differs.
    ///
    /// - Parameters:
    ///   - glyph: The glyph to draw.
    ///   - font: The face to draw it in.
    ///   - origin: The unscaled pen.
    ///   - scaleX: The horizontal scale.
    ///   - scaleY: The vertical scale, which also places the pen.
    ///   - style: The raster style.
    /// - Returns: Whether any pixel came back non-zero.
    @discardableResult
    func rasterise(glyph: CGGlyph, in font: CTFont, at origin: CGPoint, scaleX: CGFloat, scaleY: CGFloat, style: Style = .heaviest) -> Bool
    {
        clearPlane()
        context.saveGState()
        context.translateBy(x: (scaleY - scaleX) * origin.x, y: 0)
        context.scaleBy(x: scaleX, y: scaleY)
        draw(glyph, in: font, at: origin, style: style)
        context.restoreGState()
        return captureCoverage()
    }

    /// The smoothed fill at the tier's gray, under whatever CTM the caller set.
    private func draw(_ glyph: CGGlyph, in font: CTFont, at origin: CGPoint, style: Style) {
        var glyphs = [glyph]
        var positions = [origin]
        context.setFillColor(gray: Self.fillGray(forTier: style.tier), alpha: 1.0)
        CTFontDrawGlyphs(font, &glyphs, &positions, 1, context)
    }

    /// Draws a glyph with its HEIGHT scaled and its width left alone.
    ///
    /// For the tiling pieces, where one piece has to meet the next exactly. A
    /// face draws these at whatever size its own design calls for -- a math
    /// face's brace middle is half again the text line -- and a piece that does
    /// not span exactly one cell either overflows into the row beside it or
    /// falls short of it. Fitting the height makes every face's pieces meet at
    /// the cell boundary.
    ///
    /// Vertical only, because a uniform scale would thin the stem in proportion:
    /// what has to change is how far the stroke runs, not how wide it is.
    ///
    /// - Parameters:
    ///   - glyph: The glyph to draw.
    ///   - font: The face to draw it in.
    ///   - origin: The pen, in the scaled space the draw takes it in.
    ///   - verticalScale: How much to stretch the height by.
    ///   - style: The smoothing tier.
    /// - Returns: Whether any pixel came back non-zero.
    @discardableResult
    func rasterise(
        glyph: CGGlyph,
        in font: CTFont,
        at origin: CGPoint,
        verticalScale: CGFloat,
        style: Style = .heaviest
    ) -> Bool {
        clearPlane()
        context.saveGState()
        context.scaleBy(x: 1, y: verticalScale)
        draw(glyph, in: font, at: origin, style: style)
        context.restoreGState()
        return captureCoverage()
    }

    /// Draws a sized master: one glyph at an exact pen, scaled by a factor on each axis.
    ///
    /// The plane is the master Core sized, and the pen is where Core placed the
    /// glyph in it, in the plane's own pixels from its bottom-left. Nothing here
    /// chooses a window or a margin; the caller lifts the window out with Core's
    /// cut. The glyph is drawn at the origin under the transform, so the pen is
    /// the only thing that places it, and it places it exactly: CoreText's own
    /// grid, whole pixels down and as coarse as whole pixels across at a
    /// master's size, is turned off for the draw. Each band of a block is a
    /// separate master whose pen carries the fraction of a pixel that band's
    /// place leaves, and a pen snapped to the grid moves each band by its own
    /// rounding, which a diagonal stroke shows as a step at every join.
    ///
    /// - Parameters:
    ///   - glyph: The glyph to draw.
    ///   - font: The face to draw it in.
    ///   - pen: The glyph's origin in the plane, in device pixels.
    ///   - scaleX: The horizontal scale: the master's magnification times what
    ///     the width axis left of a doubling.
    ///   - scaleY: The vertical scale, the master's em factor.
    ///   - boostCappedTo: The wide sheet's growth multiplier, zero where the sheet
    ///     draws natural. Applied inside the scale, so the master is the scale
    ///     times the glyph the sheet draws unscaled.
    ///   - slot: The unscaled slot the growth must fit, which the cap bounds
    ///     the grown ink to.
    ///   - style: The raster style.
    /// - Returns: Whether any pixel came back non-zero.
    @discardableResult
    func rasterise(
        master glyph: CGGlyph,
        in font: CTFont,
        at pen: CGPoint,
        scaleX: CGFloat,
        scaleY: CGFloat,
        boostCappedTo boostCap: CGFloat = 0,
        within slot: CGSize,
        style: Style = .heaviest
    ) -> Bool {
        clearPlane()
        // Not part of the graphics state, so restored by hand: every other draw
        // on this plane keeps the grid the 1x phases are measured against.
        context.setShouldSubpixelQuantizeFonts(false)
        defer { context.setShouldSubpixelQuantizeFonts(true) }
        context.saveGState()
        context.translateBy(x: pen.x, y: pen.y)
        context.scaleBy(x: scaleX, y: scaleY)
        applyBoost(sizedBy: glyph, in: font, at: .zero, cappedTo: boostCap, within: slot, landing: .whereGrown)
        draw(glyph, in: font, at: .zero, style: style)
        context.restoreGState()
        return captureCoverage()
    }

    /// Applies Core's donor reconstruction and seam coverage before upload.
    func finishTilingGlyph(
        codePoint: UInt32,
        drawnCodePoint: UInt32,
        glyphBoxLeft: Int32,
        glyphBoxRight: Int32,
        glyphBoxTop: Int32,
        glyphBoxBottom: Int32
    ) {
        coverage.withUnsafeMutableBufferPointer { plane in
            let tiling = Ubiquitty.Rendering.TilingCoverage(
                Ubiquitty.Rendering.TilingCoverageSpan(plane),
                Int32(width),
                Int32(height),
                glyphBoxLeft,
                glyphBoxRight,
                glyphBoxTop,
                glyphBoxBottom
            )
            tiling.finish(codePoint, drawnCodePoint)
        }
    }

    /// Stretches a box-drawing glyph's connecting strokes to the given box.
    ///
    /// Runs on the plane between the draw and the upload. A box glyph carries
    /// the font's side bearings, so a run of them shows a gap at every cell
    /// boundary; the 9-slice replicates each connecting stroke outward from a
    /// clean near-edge sample without moving it off the row the font chose.
    /// Core decides which edges a code point reaches — a dash reaches none,
    /// so stretching cannot close the gaps that make it a dash.
    ///
    /// - Parameters:
    ///   - codePoint: The cell's code point; a non-box one is a no-op.
    ///   - x0: The cell box's left edge within the plane.
    ///   - x1: The cell box's right edge.
    ///   - y0: The cell box's top edge.
    ///   - y1: The cell box's bottom edge.
    func stretchBoxEdges(_ codePoint: UInt32, x0: Int, x1: Int, y0: Int, y1: Int) {
        var reachesLeft = false
        var reachesRight = false
        var reachesTop = false
        var reachesBottom = false
        guard
            Ubiquitty.Rendering.boxReachEdges(
                codePoint,
                &reachesLeft,
                &reachesRight,
                &reachesTop,
                &reachesBottom
            )
        else {
            return
        }
        coverage.withUnsafeMutableBufferPointer { plane in
            Ubiquitty.Rendering.edgeStretchBoxScratch(
                plane.baseAddress,
                Int32(width),
                Int32(height),
                Int32(x0),
                Int32(x1),
                Int32(y0),
                Int32(y1),
                reachesLeft,
                reachesRight,
                reachesTop,
                reachesBottom
            )
        }
    }

    /// Where a grown glyph's origin lands.
    private enum BoostLanding {
        /// Wherever growing about the ink centre leaves it.
        case whereGrown
        /// On the pen grid CoreText quantises a glyph of the grown size onto.
        case onPenGrid
    }

    /// Draws one shaped line and returns whether it put down any ink.
    ///
    /// The line path exists for what a single glyph cannot express: a combining
    /// cluster whose marks CoreText positions against the base's advance, with
    /// its own cascade for a mark the base face lacks. The line is drawn with
    /// foreground-from-context, so the ink lands as the plane's white and the
    /// byte stays coverage — a line drawn in CoreText's default black is zero
    /// coverage, and the slot comes back blank with every call succeeding.
    ///
    /// - Parameters:
    ///   - line: The shaped line to draw.
    ///   - origin: The pen position within the slot, in pixels from bottom-left,
    ///     naming the baseline.
    /// - Returns: Whether any pixel came back non-zero.
    /// Grows the plane's transform around a glyph's own ink centre.
    ///
    /// Capped to the plane and never shrinking ink that already fills it. Sized
    /// by one glyph rather than by whatever a caller is about to draw: a cluster
    /// scaled to its composed extent sits a mark's height above the plain
    /// character beside it, so the base is what has to size the transform and
    /// the marks ride it.
    ///
    /// The pen is not moved — only the CTM — so a caller's origin holds whether
    /// or not this applied.
    ///
    /// Growing about the ink centre moves the glyph's device origin by a part
    /// of a pixel that depends on the glyph, and CoreText snaps the origin it
    /// is handed onto its own pen grid. Left there, a pen Core keyed in one
    /// bucket is drawn in the next for every glyph whose ink centre says so.
    /// A growth landing on the pen grid is followed by the shift, at most half
    /// a bucket, that puts the origin back on the grid of the grown size, so
    /// the bucket Core keys is the one CoreText draws: the raster is the one
    /// `CTLineDraw` makes at that pen under this transform.
    ///
    /// - Parameters:
    ///   - glyph: The glyph whose ink sizes the growth.
    ///   - font: The face that carries it.
    ///   - origin: The pen the caller will draw at.
    ///   - boostCap: The multiplier before the plane caps it, at most.
    ///   - landing: Where the grown glyph's origin lands. The pen grid needs a
    ///     context whose only transform is this one.
    private func applyBoost(
        sizedBy glyph: CGGlyph,
        in font: CTFont,
        at origin: CGPoint,
        cappedTo boostCap: CGFloat,
        within bounds: CGSize? = nil,
        landing: BoostLanding
    ) {
        context.concatenate(
            boostTransform(sizedBy: glyph, in: font, at: origin, cappedTo: boostCap, within: bounds, landing: landing)
        )
    }

    /// How much a glyph grows in this plane, and the ink it grows about.
    ///
    /// - Parameters:
    ///   - glyph: The glyph whose ink sizes the growth.
    ///   - font: The face that carries it.
    ///   - boostCap: The multiplier before the plane caps it, at most.
    ///   - bounds: What the grown ink must fit, in the unscaled space the glyph is
    ///     measured in; the plane's own size when absent. A master drawn at a
    ///     scale is a plane that many times the slot, and the ink it holds is
    ///     that many times the glyph's, so the slot is the bound that stays true.
    /// - Returns: The scale, 1 for a glyph that does not grow, and its ink box.
    private func boostGrowth(
        sizedBy glyph: CGGlyph,
        in font: CTFont,
        cappedTo boostCap: CGFloat,
        within bounds: CGSize? = nil
    ) -> (scale: CGFloat, ink: CGRect) {
        // Before the bounds query, not after: the scale below is a min against
        // this cap, so a cap at or under 1 cannot pass the `scale > 1` guard
        // whatever the ink measures — and the query is a per-glyph CoreText
        // call. The cluster path hands every rasterisation through here with
        // the sheet's cap, which is 0 on the mono sheet, so without this gate
        // every combining cluster pays a bounds query that cannot change the
        // transform.
        guard boostCap > 1 else {
            return (1, .zero)
        }
        var glyphForInk = glyph
        let ink = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphForInk, nil, 1)
        guard ink.width > 0.5, ink.height > 0.5 else {
            return (1, ink)
        }
        var scale = boostCap
        scale = min(scale, (bounds?.width ?? CGFloat(width)) / ink.width)
        scale = min(scale, (bounds?.height ?? CGFloat(height)) / ink.height)
        return (max(scale, 1), ink)
    }

    /// The pen grid CoreText draws a glyph on once this plane has grown it.
    ///
    /// CoreText quantises a glyph's device origin in buckets chosen from its
    /// device size, and growth changes that size by a factor that depends on
    /// the glyph's own ink: one that already fills the plane grows less than
    /// the cap, or not at all, and a face whose em differs from the primary's
    /// starts from another size. So the bucket count is a property of the
    /// glyph, and a pen keyed at any other count is drawn in a neighbouring
    /// bucket on part of the pens.
    ///
    /// - Parameters:
    ///   - glyph: The glyph to draw.
    ///   - font: The face that carries it.
    ///   - boostCap: The multiplier before the plane caps it, at most.
    /// - Returns: How many pen positions one device pixel holds for it.
    func penGridPhaseCount(sizedBy glyph: CGGlyph, in font: CTFont, cappedTo boostCap: CGFloat) -> Int {
        let growth = boostGrowth(sizedBy: glyph, in: font, cappedTo: boostCap)
        return Int(Ubiquitty.Rendering.nativeSubpixelPhaseCount(Double(growth.scale * CTFontGetSize(font))))
    }

    private func boostTransform(
        sizedBy glyph: CGGlyph,
        in font: CTFont,
        at origin: CGPoint,
        cappedTo boostCap: CGFloat,
        within bounds: CGSize? = nil,
        landing: BoostLanding
    ) -> CGAffineTransform {
        let (scale, ink) = boostGrowth(sizedBy: glyph, in: font, cappedTo: boostCap, within: bounds)
        guard scale > 1 else {
            return .identity
        }
        let centreX = origin.x + ink.origin.x + ink.width * 0.5
        let centreY = origin.y + ink.origin.y + ink.height * 0.5
        var transform = CGAffineTransform.identity
        if landing == .onPenGrid {
            let shift = (1 - scale) * (ink.origin.x + ink.width * 0.5)
            let buckets = CGFloat(Ubiquitty.Rendering.nativeSubpixelPhaseCount(Double(scale * CTFontGetSize(font))))
            transform = transform.translatedBy(x: (shift * buckets).rounded() / buckets - shift, y: 0)
        }
        return transform.translatedBy(x: centreX, y: centreY).scaledBy(x: scale, y: scale).translatedBy(x: -centreX, y: -centreY)
    }

    /// Draws a shaped line with the growth its base glyph would take.
    ///
    /// The wide sheet grows a full-width glyph inside its two-cell slot, so a
    /// cluster drawn there without the same growth renders its base at a
    /// different size from the plain character beside it.
    ///
    /// - Parameters:
    ///   - line: The shaped line to draw.
    ///   - origin: The pen position, naming the baseline.
    ///   - boostCap: The multiplier before the plane caps it, at most.
    ///   - baseGlyph: The cluster's base, which sizes the growth.
    ///   - font: The face carrying the base.
    /// - Returns: Whether any pixel came back non-zero.
    @discardableResult
    func rasterise(
        line: CTLine,
        at origin: CGPoint,
        boostCappedTo boostCap: CGFloat,
        sizedBy baseGlyph: CGGlyph,
        in font: CTFont,
        style: Style = .heaviest
    ) -> Bool {
        clearPlane()
        context.saveGState()
        applyBoost(sizedBy: baseGlyph, in: font, at: origin, cappedTo: boostCap, landing: .onPenGrid)
        draw(line, at: origin, style: style)
        context.restoreGState()
        return captureCoverage()
    }

    @discardableResult
    func rasterise(line: CTLine, at origin: CGPoint, style: Style = .heaviest) -> Bool {
        clearPlane()
        draw(line, at: origin, style: style)
        return captureCoverage()
    }

    /// The line form of ``draw(_:in:at:style:)``: CTLineDraw pens at the
    /// context's text position and fills from the context's colour (the
    /// cluster's attributes say foreground-from-context), so the tier gray
    /// reaches it the same way. The position is set before each draw because
    /// a stale one from a prior cluster offsets the whole run.
    private func draw(_ line: CTLine, at origin: CGPoint, style: Style) {
        context.setFillColor(gray: Self.fillGray(forTier: style.tier), alpha: 1.0)
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    /// Clears the plane and captures it, for a slot that must hold nothing.
    ///
    /// A refusal is not a skip: the slot the cache assigned may hold a
    /// previous glyph, and only an upload of a blank plane evicts it from the
    /// sheet. This is the plane that upload reads.
    /// Fills the plane with a Unifont glyph, upscaled to tile the slot.
    ///
    /// The face is Core's embedded 1-bit Unifont and the fill is Core's, so a
    /// bitmap family draws the same bytes here as it does in the software
    /// renderer and the Vulkan grid — CoreText is not asked for a face whose
    /// glyphs Core already defines, and there is no second copy of the upscale to
    /// drift from this one.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - scale: The integer upscale the cell was cut for.
    ///   - nativeWidthInPixels: The source cell width Core cut the face for — 8
    ///     for one cell, 16 for two. Passed rather than assumed: a two-cell glyph
    ///     read at the one-cell width takes the left half of the bitmap and
    ///     upscales that across the whole slot.
    /// - Returns: Whether Unifont carried the code point; a miss leaves the plane
    ///   blank, which is the truthful raster for a glyph the face lacks.
    @discardableResult
    func rasteriseUnifont(_ codePoint: UInt32, scale: Int, nativeWidthInPixels: Int) -> Bool {
        clearPlane()
        var drew = false
        coverage.withUnsafeMutableBufferPointer { plane in
            // The buffer pointer carries its own extent, so the span is built
            // from the one value rather than from a base and a count that a
            // caller could disagree about.
            drew = Ubiquitty.Rendering.rasteriseUnifontIntoSlot(
                codePoint,
                Int32(scale),
                Int32(nativeWidthInPixels),
                16,
                Ubiquitty.Rendering.CoverageSlot(plane),
                Int32(width),
                Int32(height)
            )
        }
        return drew
    }

    /// Composites a bitmap cluster through the portable rasterizer.
    func rasteriseUnifontCluster(_ codePoints: Ubiquitty.Rendering.ClusterSpan, scale: Int) {
        var rasterizer = Ubiquitty.Rendering.UnifontRasterizer(Int32(scale), 0, 0)
        coverage.withUnsafeMutableBufferPointer { plane in
            _ = rasterizer.rasteriseCluster(
                codePoints,
                Int32(width),
                Int32(height),
                Ubiquitty.Rendering.CoverageSlot(plane)
            )
        }
    }

    /// Draws one proportional glyph of the bitmap tier's strike into the plane,
    /// through Core: the origin, phase and overhang are the reference sheet's,
    /// so the bytes are the reference's.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph, as Core's shaper named it.
    ///   - face: Regular or bold; italic resolves to its upright.
    ///   - variant: The subpixel phase and coverage tier.
    ///   - scale: The bitmap family's upscale.
    ///   - plan: The slot the plane is cut to.
    /// - Returns: Whether the glyph was drawn.
    func rasteriseUnifontProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        scale: Int,
        plan: Ubiquitty.Rendering.ProportionalGlyphSlotPlan
    ) -> Bool {
        clearPlane()
        var drew = false
        coverage.withUnsafeMutableBufferPointer { plane in
            drew = Ubiquitty.Rendering.rasteriseUnifontProportionalGlyph(
                Int32(scale),
                glyphID,
                face,
                variant,
                plan,
                Ubiquitty.Rendering.CoverageSlot(plane)
            )
        }
        return drew
    }

    /// Draws one window of a bitmap-tier proportional glyph drawn larger than
    /// its slot into the plane: Core's reference window
    /// (`rasteriseUnifontSizedProportionalGlyph`), so the bytes are the
    /// portable sheet's.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph, as Core's shaper named it.
    ///   - face: Regular or bold.
    ///   - variant: The sized origin's subpixel phase and coverage tier.
    ///   - tile: The scale, the band, the window and the doubling across.
    ///   - scale: The bitmap family's upscale.
    ///   - plan: The slot the plane is cut to.
    /// - Returns: Whether the window was drawn.
    func rasteriseUnifontSizedProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        tile: Ubiquitty.Rendering.SizedTile,
        scale: Int,
        plan: Ubiquitty.Rendering.ProportionalGlyphSlotPlan
    ) -> Bool {
        clearPlane()
        var drew = false
        coverage.withUnsafeMutableBufferPointer { plane in
            drew = Ubiquitty.Rendering.rasteriseUnifontSizedProportionalGlyph(
                Int32(scale),
                glyphID,
                face,
                variant,
                tile,
                plan,
                Ubiquitty.Rendering.CoverageSlot(plane)
            )
        }
        return drew
    }

    func rasteriseBlank() {
        clearPlane()
        _ = captureCoverage()
    }

    /// Clears the plane to blank and leaves the fill set for coverage ink.
    ///
    /// A slot the cache reassigned still holds the previous glyph, and a draw
    /// that misses would otherwise leave the old one visible under a new code
    /// point — which looks like a mapping bug rather than a rasterisation one.
    private func clearPlane() {
        // CTLineDraw leaves the text matrix wherever its last run put it, and
        // CTFontDrawGlyphs composes the pen with whatever matrix it finds — so
        // without this reset, every fresh glyph rasterised after a cluster
        // draws off the slot and uploads blank, while every cached glyph stays
        // correct. A defect gated on cache misses looks like missing
        // characters scattered by typing history rather than like a matrix.
        context.textMatrix = .identity
        context.setBlendMode(.copy)
        // Alpha zero, copied: the plane's clear is no coverage, and a fill of
        // opaque black would leave every pixel fully covered.
        context.setFillColor(gray: 0.0, alpha: 0.0)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setBlendMode(.normal)
        context.setFillColor(gray: 1.0, alpha: 1.0)
    }

    /// Copies the context's plane into ``coverage``.
    ///
    /// - Returns: Whether any pixel came back non-zero.
    private func captureCoverage() -> Bool {
        guard let base = context.data else {
            return false
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var inked = false
        for i in 0..<(width * height) {
            let v = bytes[i]
            coverage[i] = v
            if v != 0 {
                inked = true
            }
        }
        return inked
    }
}
