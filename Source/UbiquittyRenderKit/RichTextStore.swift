// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// RichTextStore.swift — the rich text blocks a surface's frames composite
// (Docs/rich-text.md, "Rendering").
//
// Core places every grapheme of a block; this sets each one in the face its
// style resolves to, at Core's position, into a raster kept per block and
// drawn every frame as one quad over the blitted grid. The raster is redrawn
// only when the block's content key moves — another table, another automatic
// colour, another device cell — so a static block costs a quad. It is drawn at
// the drawable's device pixels and composited one texel per pixel, linear and
// premultiplied on a transparent ground, so the selection highlights drawn
// beneath it show through around every glyph.
//
import CoreText
import Metal
import UbiquittyCore

/// The rich-text pixels a capture presents, independent of grid damage.
/// Moving, replacing or removing a block must present even when the blank
/// cells beneath it and the terminal cursor have not changed.
struct RichTextPresentation: Equatable {
    private struct Block: Equatable {
        var content: UInt64
        var bounds: CGRect
    }

    private struct Highlight: Equatable {
        var bounds: CGRect
        var color: SIMD4<Float>
    }

    private var blocks: [Block]
    private var highlights: [Highlight]

    /// Reads the immutable capture's content identities and placement facts.
    /// - Parameter capture: The frame whose rich-text layer will be presented.
    init(_ capture: Ubiquitty.Rendering.FrameCapture) {
        blocks = capture.richTextQuads()
            .map {
                Block(
                    content: $0.contentKey,
                    bounds: CGRect(x: Double($0.left), y: Double($0.top), width: Double($0.width), height: Double($0.height))
                )
            }
        highlights = capture.richTextHighlights()
            .map {
                Highlight(
                    bounds: CGRect(x: Double($0.left), y: Double($0.top), width: Double($0.width), height: Double($0.height)),
                    color: SIMD4($0.red, $0.green, $0.blue, $0.alpha)
                )
            }
    }
}

/// The quads a frame draws for its rich text: backgrounds, native selection,
/// glyphs, then tint selection when that style is configured.
package struct RichTextLayer {
    /// One ``Ubiquitty/Rendering/ImageInstance`` per quad.
    unowned(unsafe) var buffer: MTLBuffer?
    /// One texture per quad, in the same order.
    var textures: [MTLTexture?]
    /// How many quads the layer draws.
    package var quadCount: Int { textures.count }
}

/// One surface's block rasters and the layer its next frame draws.
package final class RichTextStore {
    private struct Entry {
        var key: UInt64 = 0
        var texture: MTLTexture?
        var background: MTLTexture?
        var isSeenThisFrame = false
    }

    private let device: MTLDevice
    private let faces: RichTextFaces
    private var entries: [UInt32: Entry] = [:]
    private var instances: GrowableBuffer
    private var textures: [MTLTexture?] = []
    /// One-texel highlight textures by colour: one per block background a
    /// selection washes over, bounded so a palette that keeps moving cannot
    /// grow it.
    private var highlightTextures: [SIMD4<Float>: MTLTexture] = [:]
    private static let maxHighlightTextures = 16

    /// How many block rasters this store has drawn, for the retained-rendering
    /// contract: a frame that shows only blocks it has drawn adds none.
    package private(set) var rasterCount = 0

    /// Builds a store over the device and the faces the surface draws with.
    ///
    /// - Parameters:
    ///   - device: The Metal device.
    ///   - faces: The faces blocks are set in, the ones their table measured.
    package init(device: MTLDevice, faces: RichTextFaces) {
        self.device = device
        self.faces = faces
        self.instances = GrowableBuffer(
            device: device,
            growth: .geometric,
            stride: MemoryLayout<Ubiquitty.Rendering.ImageInstance>.stride
        )
    }

    /// Builds the frame's rich text layer from the immutable capture.
    ///
    /// - Parameter capture: The frame's capture.
    /// - Returns: The layer, or nil when the frame shows no block.
    package func layer(for capture: Ubiquitty.Rendering.FrameCapture) -> RichTextLayer? {
        let quads = capture.richTextQuads()
        if !quads.isEmpty { faces.prepareCatalog() }
        for key in entries.keys {
            entries[key]?.isSeenThisFrame = false
        }
        defer { entries = entries.filter { $0.value.isSeenThisFrame } }
        guard !quads.isEmpty else {
            return nil
        }
        var retainedBytes = 0
        for (index, quad) in quads.enumerated() {
            // Whole device pixels, so the raster lands one texel per pixel.
            let left = quad.left.rounded()
            let top = quad.top.rounded()
            let width = Int(quad.width.rounded())
            let height = Int(quad.height.rounded())
            guard width > 0, height > 0 else { continue }
            let hasBackground = capture.richTextStyles(index).contains { $0.hasBackground != 0 }
            let bytes = width * height * 8 * (hasBackground ? 2 : 1)
            guard bytes <= 64 * 1024 * 1024 - retainedBytes else { continue }
            retainedBytes += bytes
            var entry = entries[quad.serial] ?? Entry()
            entry.isSeenThisFrame = true
            if entry.texture == nil || entry.key != quad.contentKey || entry.texture?.width != width || entry.texture?.height != height {
                entry.texture = raster(
                    capture,
                    block: index,
                    quad: quad,
                    width: width,
                    height: height,
                    offset: (Double(quad.left - left), Double(quad.top - top)),
                    drawsBackgrounds: false
                )
                entry.background =
                    hasBackground
                    ? raster(
                        capture,
                        block: index,
                        quad: quad,
                        width: width,
                        height: height,
                        offset: (Double(quad.left - left), Double(quad.top - top)),
                        drawsBackgrounds: true
                    )
                    : nil
                entry.key = quad.contentKey
                rasterCount += 1
            }
            entries[quad.serial] = entry
        }
        let highlights = capture.richTextHighlights()
        let count = highlights.count + (0..<quads.count).reduce(0) { $0 + 2 * max(1, capture.richTextVisibleRects($1).count) }
        guard instances.ensure(count), let destination = instances.elements(as: Ubiquitty.Rendering.ImageInstance.self) else {
            return nil
        }
        textures.removeAll(keepingCapacity: true)
        var written = 0
        func emitBlocks(backgrounds: Bool) {
            for (index, quad) in quads.enumerated() {
                guard let entry = entries[quad.serial], entry.isSeenThisFrame,
                    let texture = backgrounds ? entry.background : entry.texture
                else { continue }
                let left = quad.left.rounded()
                let top = quad.top.rounded()
                let width = texture.width
                let height = texture.height
                let clips = capture.richTextVisibleRects(index)
                let cell = capture.uniforms().cellSizeInPixels
                let rectangles =
                    clips.isEmpty
                    ? [CGRect(x: 0, y: 0, width: width, height: height)]
                    : clips.map {
                        let x = (quad.left + Float($0.x) * cell.x).rounded() - left
                        let y = (quad.top + Float($0.y) * cell.y).rounded() - top
                        let right = (quad.left + Float($0.x + $0.width) * cell.x).rounded() - left
                        let bottom = (quad.top + Float($0.y + $0.height) * cell.y).rounded() - top
                        return CGRect(x: Double(x), y: Double(y), width: Double(right - x), height: Double(bottom - y))
                    }
                for rectangle in rectangles {
                    var instance = Ubiquitty.Rendering.ImageInstance()
                    instance.topLeftInPixels = Ubiquitty.Rendering.Vec2(x: left + Float(rectangle.minX), y: top + Float(rectangle.minY))
                    instance.bottomRightInPixels = Ubiquitty.Rendering.Vec2(x: left + Float(rectangle.maxX), y: top + Float(rectangle.maxY))
                    instance.uv0 = Ubiquitty.Rendering.Vec2(
                        x: Float(rectangle.minX) / Float(width),
                        y: Float(rectangle.minY) / Float(height)
                    )
                    instance.uv1 = Ubiquitty.Rendering.Vec2(
                        x: Float(rectangle.maxX) / Float(width),
                        y: Float(rectangle.maxY) / Float(height)
                    )
                    destination[written] = instance
                    textures.append(texture)
                    written += 1
                }
            }
        }
        func emitHighlights() {
            for highlight in highlights {
                guard let texture = highlightTexture(for: SIMD4(highlight.red, highlight.green, highlight.blue, highlight.alpha))
                else { continue }
                let left = highlight.left.rounded()
                let top = highlight.top.rounded()
                let right = (highlight.left + highlight.width).rounded()
                let bottom = (highlight.top + highlight.height).rounded()
                var instance = Ubiquitty.Rendering.ImageInstance()
                instance.topLeftInPixels = Ubiquitty.Rendering.Vec2(x: left, y: top)
                instance.bottomRightInPixels = Ubiquitty.Rendering.Vec2(
                    x: right,
                    y: bottom
                )
                instance.uv0 = Ubiquitty.Rendering.Vec2(x: 0.5, y: 0.5)
                instance.uv1 = Ubiquitty.Rendering.Vec2(x: 0.5, y: 0.5)
                destination[written] = instance
                textures.append(texture)
                written += 1
            }
        }
        emitBlocks(backgrounds: true)
        if capture.isSelectionBehindText() { emitHighlights() }
        emitBlocks(backgrounds: false)
        if !capture.isSelectionBehindText() { emitHighlights() }
        return RichTextLayer(buffer: instances.buffer, textures: textures)
    }

    /// The one-texel texture a highlight samples, premultiplied linear.
    private func highlightTexture(for wanted: SIMD4<Float>) -> MTLTexture? {
        if let texture = highlightTextures[wanted] {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let alpha = wanted.w > 0 ? wanted.w : 1
        var texel: [Float16] = [
            Float16(Self.linear(wanted.x) * alpha), Float16(Self.linear(wanted.y) * alpha),
            Float16(Self.linear(wanted.z) * alpha), Float16(alpha),
        ]
        texel.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: 8)
        }
        if highlightTextures.count >= Self.maxHighlightTextures {
            highlightTextures.removeAll(keepingCapacity: true)
        }
        highlightTextures[wanted] = texture
        return texture
    }

    /// Draws a block's graphemes at Core's positions into a fresh texture.
    private func raster(
        _ capture: Ubiquitty.Rendering.FrameCapture,
        block index: Int,
        quad: Ubiquitty.RichText.BlockQuad,
        width: Int,
        height: Int,
        offset: (x: Double, y: Double),
        drawsBackgrounds: Bool
    ) -> MTLTexture? {
        guard
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            )
        else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        let styles = capture.richTextStyles(index)
        let clusters = capture.richTextClusters(index)
        let text = capture.richTextCodePoints(index)
        let shapedLines = capture.richTextShapedLines(index)
        let unitsX = Double(quad.pixelsPerUnitX)
        let unitsY = Double(quad.pixelsPerUnitY)
        // Pixels per point: a layout unit is 1/4096 point.
        let pixelsPerPoint = unitsX * 4096
        var fontCache: [Int: CTFont] = [:]
        // Every grapheme is set up first and drawn last: the rules go down
        // before the glyphs, so skip-ink can clear them where the ink crosses
        // and the glyphs then draw over what is left.
        var unshaped: [(line: CTLine, x: Double, baselineDown: Double)] = []
        for cluster in clusters where Int(cluster.style) < styles.count {
            let style = styles[Int(cluster.style)]
            if drawsBackgrounds {
                let x = Double(cluster.x) * unitsX + offset.x
                if style.hasBackground != 0 {
                    // Quantize the shared edges, not each rectangle's width. Two
                    // adjacent selections then cover exactly the same device-pixel
                    // boundary even when their shaped advances are fractional.
                    let left = x.rounded()
                    let right = (Double(cluster.x + cluster.advance) * unitsX + offset.x).rounded()
                    let top = (Double(cluster.top) * unitsY + offset.y).rounded()
                    let bottom = (Double(cluster.top + cluster.height) * unitsY + offset.y).rounded()
                    context.saveGState()
                    context.setShouldAntialias(false)
                    context.setFillColor(
                        CGColor(
                            srgbRed: CGFloat(style.backgroundRed) / 255,
                            green: CGFloat(style.backgroundGreen) / 255,
                            blue: CGFloat(style.backgroundBlue) / 255,
                            alpha: 1
                        )
                    )
                    context.fill(CGRect(x: left, y: Double(height) - bottom, width: right - left, height: bottom - top))
                    context.restoreGState()
                }
                continue
            }
            let font: CTFont
            if let cached = fontCache[Int(cluster.style)] {
                font = cached
            } else {
                font = faces.font(
                    style.familyClass,
                    familyName: String(style.familyName()),
                    isBold: style.styles & 1 != 0,
                    isItalic: style.styles & 2 != 0,
                    size: CGFloat(Double(style.halfPoints) / 2 * pixelsPerPoint)
                )
                fontCache[Int(cluster.style)] = font
            }
            let color =
                style.isAutomaticColor != 0
                ? CGColor(srgbRed: CGFloat(quad.red) / 255, green: CGFloat(quad.green) / 255, blue: CGFloat(quad.blue) / 255, alpha: 1)
                : CGColor(srgbRed: CGFloat(style.red) / 255, green: CGFloat(style.green) / 255, blue: CGFloat(style.blue) / 255, alpha: 1)
            var scalars = String.UnicodeScalarView()
            if cluster.isEllipsis != 0 {
                scalars.append("\u{2026}")
            } else {
                for position in Int(cluster.first)..<Int(cluster.end) where position < text.count {
                    if let scalar = Unicode.Scalar(text[position]), scalar != "\t" {
                        scalars.append(scalar)
                    }
                }
            }
            if !scalars.isEmpty && shapedLines.isEmpty {
                let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
                let string = CFAttributedStringCreate(nil, String(scalars) as CFString, attributes as CFDictionary)!
                unshaped.append(
                    (
                        line: CTLineCreateWithAttributedString(string),
                        x: Double(cluster.x) * unitsX + offset.x,
                        baselineDown: (Double(cluster.baseline) * unitsY + offset.y).rounded()
                    )
                )
            }
        }
        if !drawsBackgrounds {
            var shaped: [(line: CTLine, origin: Double, baselineDown: Double)] = []
            if !shapedLines.isEmpty {
                let typesetter = RichTextTypesetter(
                    text: Array(text),
                    styles: Array(styles),
                    faces: faces,
                    automaticColor: CGColor(
                        srgbRed: CGFloat(quad.red) / 255,
                        green: CGFloat(quad.green) / 255,
                        blue: CGFloat(quad.blue) / 255,
                        alpha: 1
                    ),
                    tabWidth: CGFloat(capture.uniforms().cellSizeInPixels.x) / pixelsPerPoint * 8
                )
                for line in shapedLines {
                    shaped.append(
                        (
                            line: typesetter.line(first: Int(line.first), end: Int(line.end)),
                            origin: Double(line.origin) / 4096,
                            baselineDown: (Double(line.top + line.baseline) * unitsY + offset.y).rounded()
                        )
                    )
                }
            }
            // Each grapheme sits on a whole-pixel baseline, as the grid's do:
            // a fractional one puts a round letter's overshoot into the row the
            // rule hangs from, and skip-ink then cuts the rule under every bowl.
            // A shaped line is set in points, so its baseline goes back through
            // the points-to-pixels scale.
            func drawGlyphs(in target: CGContext) {
                for glyph in unshaped {
                    target.textPosition = CGPoint(x: glyph.x, y: Double(height) - glyph.baselineDown)
                    CTLineDraw(glyph.line, target)
                }
                guard !shaped.isEmpty else { return }
                target.saveGState()
                target.translateBy(x: offset.x, y: Double(height) - offset.y)
                target.scaleBy(x: unitsX * 4096, y: unitsY * 4096)
                for line in shaped {
                    target.textPosition = CGPoint(x: line.origin, y: (offset.y - line.baselineDown) / (unitsY * 4096))
                    CTLineDraw(line.line, target)
                }
                target.restoreGState()
            }
            var underlines: [(pixels: Ubiquitty.RichText.PixelRect, top: Double, color: CGColor)] = []
            var strikes: [(pixels: Ubiquitty.RichText.PixelRect, color: CGColor)] = []
            // One rule per decorated stretch, never per grapheme: two abutting
            // antialiased rectangles leave a seam wherever their shared edge
            // falls inside a pixel.
            for rule in capture.richTextRules(index) where Int(rule.style) < styles.count {
                let style = styles[Int(rule.style)]
                let font =
                    fontCache[Int(rule.style)]
                    ?? faces.font(
                        style.familyClass,
                        familyName: String(style.familyName()),
                        isBold: style.styles & 1 != 0,
                        isItalic: style.styles & 2 != 0,
                        size: CGFloat(Double(style.halfPoints) / 2 * pixelsPerPoint)
                    )
                let color =
                    style.isAutomaticColor != 0
                    ? CGColor(
                        srgbRed: CGFloat(quad.red) / 255,
                        green: CGFloat(quad.green) / 255,
                        blue: CGFloat(quad.blue) / 255,
                        alpha: 1
                    )
                    : CGColor(
                        srgbRed: CGFloat(style.red) / 255,
                        green: CGFloat(style.green) / 255,
                        blue: CGFloat(style.blue) / 255,
                        alpha: 1
                    )
                // Core places the rows as the cell builder places grid text's
                // rules, from what CoreText measures of the run's face; the
                // stretch's ends land on whole pixels too.
                let left = (Double(rule.x) * unitsX + offset.x).rounded()
                let right = (Double(rule.x + rule.width) * unitsX + offset.x).rounded()
                guard right > left else { continue }
                let rows = Ubiquitty.RichText.decorationRows(
                    Self.decorationFace(font),
                    Float((Double(rule.baseline) * unitsY + offset.y).rounded()),
                    quad
                )
                if style.styles & 4 != 0,
                    let pixels = Self.rulePixels(
                        left: left,
                        right: right,
                        top: rows.underlineTop,
                        bottom: rows.underlineBottom,
                        width: width,
                        height: height
                    )
                {
                    underlines.append((pixels, Double(rows.underlineTop), color))
                }
                if style.styles & 8 != 0,
                    let pixels = Self.rulePixels(
                        left: left,
                        right: right,
                        top: rows.strikeTop,
                        bottom: rows.strikeBottom,
                        width: width,
                        height: height
                    )
                {
                    strikes.append((pixels, color))
                }
            }
            // Skip-ink cuts the underline by the grid's ink test, which Core
            // owns: each pixel of the rule loses the strongest glyph coverage
            // within the grid's reach of it, so a descender breaks the rule and
            // a letter on the baseline leaves it whole.
            let ink =
                quad.isSkippingInk != 0 && !underlines.isEmpty ? Self.inkCoverage(width: width, height: height, drawing: drawGlyphs) : nil
            for underline in underlines {
                let rect = Self.rowRect(underline.pixels, height: height)
                context.setFillColor(underline.color)
                if let ink,
                    let mask = Self.skipInkMask(
                        underline.pixels,
                        top: underline.top,
                        ink: ink,
                        width: width,
                        height: height,
                        padding: quad.skipInkPadding
                    )
                {
                    context.saveGState()
                    context.clip(to: rect, mask: mask)
                    context.fill(rect)
                    context.restoreGState()
                } else {
                    context.fill(rect)
                }
            }
            for strike in strikes {
                context.setFillColor(strike.color)
                context.fill(Self.rowRect(strike.pixels, height: height))
            }
            drawGlyphs(in: context)
        }
        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.cpuWrittenTextureStorageMode
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 8)
        return texture
    }

    /// A run's face as CoreText measures it at the size the raster sets it,
    /// in device pixels: what Core places its underline and strike from.
    private static func decorationFace(_ font: CTFont) -> Ubiquitty.RichText.DecorationFace {
        var face = Ubiquitty.RichText.DecorationFace()
        face.em = Float(CTFontGetSize(font))
        face.underlineThickness = Float(CTFontGetUnderlineThickness(font))
        face.ascent = Float(CTFontGetAscent(font))
        face.descent = Float(CTFontGetDescent(font))
        face.leading = Float(CTFontGetLeading(font))
        face.xHeight = Float(CTFontGetXHeight(font))
        return face
    }

    /// The coverage of a block's glyphs, one byte a pixel, rows from the
    /// raster's top: the alpha they leave on a transparent ground, whatever
    /// their colour.
    private static func inkCoverage(width: Int, height: Int, drawing draw: (CGContext) -> Void) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let isDrawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let target = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            target.setShouldSmoothFonts(false)
            draw(target)
            return true
        }
        guard isDrawn else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        for index in coverage.indices {
            coverage[index] = pixels[index * 4 + 3]
        }
        return coverage
    }

    /// The rule's alpha with skip-ink applied, by Core's ink test: the grid's
    /// reach about each pixel, so a rule under a block is cut where the rule
    /// under a cell would be.
    private static func skipInkMask(
        _ rule: Ubiquitty.RichText.PixelRect,
        top: Double,
        ink: [UInt8],
        width: Int,
        height: Int,
        padding: Float
    ) -> CGImage? {
        let ruleWidth = Int(rule.width)
        let ruleHeight = Int(rule.height)
        guard ruleWidth > 0, ruleHeight > 0,
            let rasterWidth = Int32(exactly: width), let rasterHeight = Int32(exactly: height)
        else { return nil }
        // The rectangle was clipped before narrowing. Its mask cannot have
        // more pixels than the already bounded block raster.
        var alpha = [UInt8](repeating: 255, count: ruleWidth * ruleHeight)
        ink.withUnsafeBufferPointer { coverage in
            alpha.withUnsafeMutableBufferPointer { output in
                Ubiquitty.RichText.skipInkRuleAlpha(
                    Ubiquitty.RichText.InkCoverage(coverage),
                    rasterWidth,
                    rasterHeight,
                    rule,
                    top,
                    padding,
                    Ubiquitty.RichText.RuleAlpha(output)
                )
            }
        }
        guard let provider = CGDataProvider(data: Data(alpha) as CFData) else { return nil }
        // A grey image clips as alpha: white paints, black does not.
        return CGImage(
            width: ruleWidth,
            height: ruleHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: ruleWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Clips a configured rule before any integer conversion or mask allocation.
    /// A rule outside the raster, or one with nonfinite edges, draws nothing.
    private static func rulePixels(
        left: Double,
        right: Double,
        top: Float,
        bottom: Float,
        width: Int,
        height: Int
    ) -> Ubiquitty.RichText.PixelRect? {
        guard let rasterWidth = Int32(exactly: width), let rasterHeight = Int32(exactly: height) else { return nil }
        let rule = Ubiquitty.RichText.clippedRuleRect(left, Double(top), right, Double(bottom), rasterWidth, rasterHeight)
        return rule.width > 0 && rule.height > 0 ? rule : nil
    }

    /// Visible pixel rows in the context's bottom-up coordinates.
    private static func rowRect(_ rule: Ubiquitty.RichText.PixelRect, height: Int) -> CGRect {
        CGRect(x: Int(rule.left), y: height - Int(rule.top) - Int(rule.height), width: Int(rule.width), height: Int(rule.height))
    }

    private static func linear(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
}
