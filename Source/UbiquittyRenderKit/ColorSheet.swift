// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ColorSheet.swift — the RGBA sheet colour emoji live on.
//
// Coverage sheets carry ink for the shader to tint; this sheet carries the
// glyph's own colour, which is why it is RGBA and the pass that samples it
// blends against the framebuffer instead of against the cell's foreground.
//
// The slots are square at Core's destination square — the side
// `colourGlyphSquareInPixels` derives from the cell box, the same number the
// builder cuts the quad to. Slot equal to destination is the property that
// matters: a larger slot makes every colour glyph a resample on the way to the
// screen, through a filter the backends do not share. The shipping renderer
// cuts its colour slots with the same function, and the two arms sharing one
// number is what lets a pixel comparison hold them to zero.
//
// Core owns the slot policy and the UV arithmetic, exactly as with
// ``CoverageSheet``: the builder drives `GlyphSlotCache` through the binding —
// content-verified for clusters, so a hash collision re-rasterises instead of
// serving another cluster's pixels — and this sheet is reached only to draw a
// slot the cache had no pixels for.

import CoreGraphics
import CoreText
import Metal
import UbiquittyCore

/// An RGBA colour-glyph sheet and Core's slot cache over it.
///
/// Not thread-safe: the context and its plane are reused frame to frame,
/// which is what keeps a steady-state frame free of allocation.
final class ColorSheet {
    /// The sheet the colour pass samples.
    let texture: MTLTexture
    /// The staged path to the sheet; see ``AtlasUploader``.
    private let uploader: AtlasUploader

    /// Slots per texture row, after Core clamped the grid to the device limit.
    let columns: Int

    /// Rows of slots in the sheet, after the same clamp.
    let rows: Int

    /// One slot's edge in pixels; colour slots are square.
    let slotInPixels: Int

    /// Core's hash-and-LRU over the slots, content-verified for clusters.
    let cache: Ubiquitty.Rendering.GlyphSlotCache

    private let context: CGContext

    /// The plane a sized block's master is drawn into, kept for the next window
    /// of the block: every window asks the same edge.
    private var sizedMaster: CGContext?

    /// How many slots the sheet holds, after the clamp.
    var slotCapacity: Int { columns * rows }

    /// Builds a sheet of square colour slots.
    ///
    /// - Parameters:
    ///   - device: The device the sheet allocates on.
    ///   - columns: Slots per texture row, before clamping.
    ///   - slotInPixels: The square slot edge — the cell height, so an emoji
    ///     fills the line.
    ///   - slotCapacity: How many slots to make room for, before clamping.
    ///   - maxTextureDimension: The API's largest 2D texture edge.
    init?(
        device: MTLDevice,
        uploader: AtlasUploader,
        columns: Int,
        slotInPixels: Int,
        slotCapacity: Int,
        maxTextureDimension: Int
    ) {
        guard columns > 0, slotCapacity > 0, slotInPixels > 0 else {
            return nil
        }
        let wantedRows = (slotCapacity + columns - 1) / columns
        let fit = Ubiquitty.Rendering.clampAtlasGridToTextureLimit(
            Ubiquitty.GridSize(columns: Int32(columns), rows: Int32(wantedRows)),
            Ubiquitty.IntSize(width: Int32(slotInPixels), height: Int32(slotInPixels)),
            Int32(maxTextureDimension)
        )
        guard fit.valid else {
            return nil
        }
        let fitColumns = Int(fit.columns)
        let fitRows = Int(fit.rows)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: fitColumns * slotInPixels,
            height: fitRows * slotInPixels,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        // Premultiplied-last, big-endian 32-bit, in sRGB — the layout and,
        // as much, the space the shipping renderer rasterises into. The space is part of
        // the pixel values: an emoji's colours are converted into the
        // context's space on the way down, so two contexts differing here
        // produce planes that differ across the glyph's whole body, not at
        // its edges. CoreText composites colour glyphs, so the bytes are a
        // premultiplied product by construction, and the colour pass blends
        // them as such. The context owns its plane (data: nil): a pointer
        // into Swift-managed storage is pinned only inside a with-closure,
        // and the context outlives every one of them.
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        guard let texture = device.makeTexture(descriptor: descriptor),
            let cache = Ubiquitty.Rendering.makeGlyphSlotCache(
                Int32(fitColumns * fitRows),
                Ubiquitty.Rendering.recommendedHashBuckets(Int32(fitColumns * fitRows)),
                Int32(fitColumns)
            ),
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: slotInPixels,
                height: slotInPixels,
                bitsPerComponent: 8,
                bytesPerRow: slotInPixels * 4,
                space: sRGB,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            return nil
        }
        // Stated rather than inherited: a bitmap context's font-smoothing
        // default is not the screen context's, and the other arm sets both.
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        self.texture = texture
        self.uploader = uploader
        self.columns = fitColumns
        self.rows = fitRows
        self.slotInPixels = slotInPixels
        self.cache = cache
        self.context = context
    }

    /// Opens a frame, after which touched slots survive eviction within it.
    func beginFrame() {
        cache.beginFrame()
    }

    /// Draws a colour cluster into a slot the cache has already assigned.
    ///
    /// Ports the shipping renderer's contract piece for piece, because the two
    /// arms fill one kind of slot and a golden compares them:
    /// - the emoji face at 0.92 of the slot edge;
    /// - a line whose shaping fell to LastResort leaves the slot TRANSPARENT —
    ///   a baked ?-box sticks in every frame that blits the cached pixels;
    /// - a single-glyph line is centred on its bounding box;
    /// - a shaped run (flags, families) is scaled to fit the edge minus a
    ///   one-pixel gap per side and centred on its ink, pixel-aligned so a
    ///   fractional offset cannot soften it.
    ///
    /// Uploaded whether or not the draw put down ink: a reassigned slot still
    /// holds its predecessor, and a blank must overwrite it.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster; one code point is a lone emoji.
    ///   - slot: The slot the cache assigned.
    /// Clears one slot in the sheet.
    ///
    /// For a raster that cannot produce pixels. The cache has already handed the
    /// key over, so leaving the slot untouched serves whatever the evicted glyph
    /// left there under this key's name — defined and blank beats undefined and
    /// another glyph's ink.
    ///
    /// - Parameter slot: The slot the cache assigned.
    func blankSlot(_ slot: Int32) {
        let box = Ubiquitty.Rendering.atlasSlotRegion(
            Int32(slot),
            Int32(columns),
            Int32(slotInPixels),
            Int32(slotInPixels)
        )
        let bytesPerRow = Int(box.width) * 4
        let blank = [UInt8](repeating: 0, count: bytesPerRow * Int(box.height))
        blank.withUnsafeBytes { bytes in
            uploader.stage(
                bytes.baseAddress!,
                bytesPerRow: bytesPerRow,
                region: MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height)),
                into: texture
            )
        }
    }

    func rasterise(_ codePoints: UnsafeBufferPointer<UInt32>, font: CTFont, slot: Int32) -> Bool {
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(slotInPixels), height: CGFloat(slotInPixels)))
        let cluster = Self.string(of: codePoints)
        if !cluster.isEmpty {
            drawCluster(cluster, font: font, targetSide: CGFloat(slotInPixels), into: context)
        }
        return upload(from: context, slot: slot)
    }

    /// Draws one square window of a cluster rendered at an OSC 66 scale.
    ///
    /// The cluster is drawn once into a plane the size Core names for the
    /// block (``Ubiquitty/Rendering/sizedColorMasterSide``), laid out for the
    /// whole square, and Core's cut lifts the window `(band, tile)` out of it,
    /// so a window is the slot-sized square that many slots across and down.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster; one code point is a lone emoji.
    ///   - font: The face selected by Core's routing policy.
    ///   - slot: The slot the cache assigned.
    ///   - tile: The block's scale, fraction, band and window.
    /// - Returns: Whether the slot was written.
    func rasteriseSized(
        _ codePoints: UnsafeBufferPointer<UInt32>,
        font: CTFont,
        slot: Int32,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Bool {
        let side = Int(Ubiquitty.Rendering.sizedColorMasterSide(tile, Int32(slotInPixels)))
        guard side > 0, let master = masterContext(side: side) else {
            blankSlot(slot)
            return true
        }
        master.clear(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        let cluster = Self.string(of: codePoints)
        if !cluster.isEmpty {
            drawCluster(cluster, font: font, targetSide: CGFloat(side), into: master)
        }
        guard let plane = master.data else {
            blankSlot(slot)
            return true
        }
        let rowBytes = slotInPixels * 4
        var window = [UInt8](repeating: 0, count: rowBytes * slotInPixels)
        // The context's plane, read in place: the data is borrowed for the cut
        // and nothing keeps it.
        Data(bytesNoCopy: plane, count: side * side * 4, deallocator: .none)
            .withUnsafeBytes { masterBytes in
                window.withUnsafeMutableBufferPointer { windowBuffer in
                    Ubiquitty.Rendering.cutSizedColorWindow(
                        Ubiquitty.Rendering.SizedMasterBytes(masterBytes.bindMemory(to: UInt8.self)),
                        Int32(side),
                        tile,
                        Int32(slotInPixels),
                        Ubiquitty.Rendering.SizedWindowBytes(windowBuffer)
                    )
                }
            }
        let box = Ubiquitty.Rendering.atlasSlotRegion(slot, Int32(columns), Int32(slotInPixels), Int32(slotInPixels))
        window.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height)),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: rowBytes
            )
        }
        return true
    }

    /// The UTF-16 string a cluster of code points is laid out as.
    ///
    /// - Parameter codePoints: The cluster.
    /// - Returns: The string, empty for an empty cluster.
    private static func string(of codePoints: some Collection<UInt32>) -> String {
        var characters: [UInt16] = []
        characters.reserveCapacity(codePoints.count * 2)
        for codePoint in codePoints {
            if codePoint <= 0xFFFF {
                characters.append(UInt16(codePoint))
            } else {
                let value = codePoint - 0x10000
                characters.append(UInt16(0xD800 + (value >> 10)))
                characters.append(UInt16(0xDC00 + (value & 0x3FF)))
            }
        }
        return String(utf16CodeUnits: characters, count: characters.count)
    }

    /// The plane a sized master of this edge is drawn into, made on first use.
    ///
    /// Made as the slot's own context is, so a cluster draws the same in both.
    /// One is kept: a block asks the same edge of every window it cuts.
    ///
    /// - Parameter side: The master's edge.
    /// - Returns: The context, or `nil` when one that size cannot be made.
    private func masterContext(side: Int) -> CGContext? {
        if let master = sizedMaster, master.width == side {
            return master
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let made = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: sRGB,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                )
                .rawValue
            )
        else {
            return nil
        }
        made.setShouldAntialias(true)
        made.setShouldSmoothFonts(true)
        sizedMaster = made
        return made
    }

    /// Uploads a context's plane to a slot, or blanks the slot when it has no plane.
    ///
    /// - Parameters:
    ///   - source: The slot-sized context just drawn.
    ///   - slot: The slot the cache assigned.
    /// - Returns: True, so a blanked slot is this key's and is not re-drawn every frame.
    private func upload(from source: CGContext, slot: Int32) -> Bool {
        guard let plane = source.data else {
            // The cache has already handed this key over, so a return that leaves
            // the slot alone leaves the previous tenant's pixels under this key's
            // name — served as this glyph for as long as the slot stays resident,
            // with every count in the frame correct. Nothing can be uploaded
            // without the plane, so the slot is blanked instead: defined and
            // wrong-looking beats undefined and another glyph's ink.
            blankSlot(slot)
            // Blanked, so defined, so this key's: true rather than a refusal
            // that would re-raster every frame for contents already correct.
            return true
        }
        let box = Ubiquitty.Rendering.atlasSlotRegion(
            slot,
            Int32(columns),
            Int32(slotInPixels),
            Int32(slotInPixels)
        )
        texture.replace(
            region: MTLRegionMake2D(Int(box.x), Int(box.y), Int(box.width), Int(box.height)),
            mipmapLevel: 0,
            withBytes: plane,
            bytesPerRow: source.bytesPerRow
        )
        return true
    }

    /// Draws a cluster laid out for a square, centred in it.
    ///
    /// The code points only LastResort draws are left out, and nothing is drawn
    /// when no other code point remains.
    ///
    /// - Parameters:
    ///   - cluster: The cluster.
    ///   - font: The face selected by Core's routing policy.
    ///   - targetSide: The square's edge: the slot, or a sized master.
    ///   - context: The plane to draw into.
    private func drawCluster(_ cluster: String, font: CTFont, targetSide: CGFloat, into context: CGContext) {
        // Every measurement below is against the layout square, the whole
        // master: the slot at scale 1 and the block's size above it. The plane
        // is drawn once for the square and Core's cutSizedColorWindow lifts the
        // slot-sized window out of it.
        let side = targetSide
        let sizedFont = CTFontCreateCopyWithAttributes(font, side * 0.92, nil, nil)
        func shape(_ string: String) -> CTLine {
            CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: string,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): sizedFont]
                )
            )
        }
        var line = shape(cluster)
        if ctLineHasLastResortRun(line) {
            let kept = stringOutsideLastResort(cluster, shapedAs: line)
            guard !kept.isEmpty else {
                return
            }
            line = shape(kept)
            guard !ctLineHasLastResortRun(line) else {
                return
            }
        }

        // A single-glyph line centres on the glyph's bounding box; asking the
        // shaped line for image bounds instead would round-trip through the
        // context for the same rectangle.
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        if runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1 {
            let run = runs[0]
            var glyph = CGGlyph(0)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
            let attributes = CTRunGetAttributes(run) as! [CFString: Any]
            if glyph != 0, let runFont = attributes[kCTFontAttributeName] {
                let resolved = runFont as! CTFont
                var box = CGRect.zero
                CTFontGetBoundingRectsForGlyphs(resolved, .horizontal, &glyph, &box, 1)
                var position = CGPoint(
                    x: ((side - box.size.width) * 0.5 - box.origin.x).rounded(),
                    y: ((side - box.size.height) * 0.5 - box.origin.y).rounded()
                )
                context.textPosition = .zero
                CTFontDrawGlyphs(resolved, &glyph, &position, 1, context)
                return
            }
        }

        // Anchor at the origin before measuring: the image bounds use the
        // context's current text position as the pen, and a stale position
        // from a previous draw would offset the measurement and push the
        // glyph out of the slot.
        context.textPosition = .zero
        let ink = CTLineGetImageBounds(line, context)
        guard ink.size.width > 0, ink.size.height > 0 else {
            return
        }
        // A one-pixel gap per side so neighbours never glue, and a
        // pixel-aligned scale-and-place so a fractional offset cannot soften
        // the raster.
        let target = side - 2.0
        let scale = min(target / ink.size.width, target / ink.size.height)
        let drawWidth = ink.size.width * scale
        let drawHeight = ink.size.height * scale
        context.saveGState()
        context.translateBy(
            x: ((side - drawWidth) * 0.5 - ink.origin.x * scale).rounded(),
            y: ((side - drawHeight) * 0.5 - ink.origin.y * scale).rounded()
        )
        context.scaleBy(x: scale, y: scale)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
