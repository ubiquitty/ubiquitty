// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FrameEncoder.swift — the order the frame's passes reach the drawable in.
//
// Every pass is the same six calls over a different stream: bind a pipeline,
// hand it the frame uniform and one instance buffer, point it at a sheet, draw
// two triangles instanced. Only the operands change, so the passes are a table
// and the encode is a loop over it. Written out per pass instead, the ordering —
// which is the one thing here that is a decision — reads as an accident of
// which block came first, and a pass whose texture binding is a line off looks
// exactly like the pass above it.
//
// The order is the compositing contract: cells lay down backgrounds, box fills
// cover them, glyph sheets draw over both, decorations rule over the glyphs, and
// overlays sit on top. Two passes that swap places still draw every instance and
// still report every count.

import Metal
import UbiquittyCore

/// The glyph sheets a frame samples from.
///
/// Seven separate textures because the passes differ in what they sample rather
/// than in how: coverage for mono, wide, proportional glyphs, proportional
/// strips, and ligature glyphs,
/// colour for emoji, and a 2x master for DECDWL/DECDHL rows. A sheet left nil
/// skips its pass, which is what an atlas without that capability reports.
/// Every sheet is `unowned(unsafe)`, for the reason ``InstancePass`` gives: an
/// `MTLTexture` is an ObjC protocol type, so a stored copy is an `objc_retain`,
/// and this is built per frame. The atlas owns every sheet named here for as
/// long as the renderer exists, and this value dies inside `encode`.
struct AtlasSheets {
    /// Single-cell coverage glyphs, and the sheet the cell and decoration
    /// passes sample their ink from.
    unowned(unsafe) var mono: MTLTexture?
    /// Two-cell coverage glyphs.
    unowned(unsafe) var wide: MTLTexture?
    /// Glyphs shaped in the proportional face.
    unowned(unsafe) var proportional: MTLTexture?
    /// Bounded fallback strips shaped in the proportional face.
    unowned(unsafe) var proportionalStrip: MTLTexture?
    /// Colour emoji, sampled straight rather than tinted.
    unowned(unsafe) var color: MTLTexture?
    /// Double-width and double-height masters.
    unowned(unsafe) var double: MTLTexture?
    /// Shaped ligature strips.
    unowned(unsafe) var ligature: MTLTexture?

    /// Creates an empty set of sheets.
    init() {}
}

/// One instanced draw: a pipeline, a stream, and the sheet it samples.
///
/// A pass with no pipeline, no buffer or no instances is skipped rather than
/// treated as an error — a shader that failed to build costs its own pass, and
/// an empty stream is the ordinary state of most of them on most frames.
/// Every Metal reference here is `unowned(unsafe)`, which is a per-frame cost
/// rather than a style: these are ObjC protocol types, so a stored copy is an
/// `objc_retain`, and nine passes carrying three each put twenty-four atomic
/// reference-count operations into a frame that records its draw calls.
///
/// Unowned is sound here because a pass never outlives the call that builds it,
/// and every object it names is owned for longer by the renderer: the pipelines
/// by ``MetalPipelines``, the sheets by the glyph atlas, the buffers by the
/// instance streams. All three are reachable from the renderer for as long as it
/// exists, and a pass is a local that dies inside ``encode``.
///
/// What would break it is a pass outliving the encode call — stored in a
/// property, captured by an escaping closure, or handed to something that
/// retains it. None of those has a reason to exist here, and the type is
/// internal, so the blast radius is this file.
struct InstancePass {
    /// The pipeline state this pass draws under.
    unowned(unsafe) let pipeline: MTLRenderPipelineState?
    /// The instance buffer, as Core filled it.
    unowned(unsafe) let buffer: MTLBuffer?
    /// How many instances of it to draw.
    let count: Int
    /// The sheet bound at fragment texture 0.
    ///
    /// Nil means two different things and the encoder cannot tell them apart
    /// from this field alone, which is why ``samplesASheet`` exists: a pass that
    /// wants no sheet, and a pass whose sheet the atlas has not built.
    unowned(unsafe) let texture: MTLTexture?
    /// Whether this pass draws nothing without its sheet.
    ///
    /// True for the ink passes — glyph, wide, colour, double, ligature — whose
    /// every instance is a textured quad. False for passes that degrade: a cell
    /// still paints its background when the sheet is absent (a blank cell
    /// already carries `minUV == maxUV`), and a rule is geometry that samples
    /// only for skip-ink.
    ///
    /// The distinction is not tidiness. The fragment stage keeps whatever the
    /// previous pass bound, so an ink pass drawn without its own sheet samples
    /// the last one through UVs computed for a different grid — colour emoji as
    /// coverage, a wide glyph from the single-cell sheet — with every instance
    /// count correct and nothing to fail.
    let requiresSheet: Bool
    /// A second sheet at fragment texture 1. The rule pass uses it for
    /// proportional fallback strips.
    unowned(unsafe) var secondTexture: MTLTexture? = nil
    /// A third sheet at fragment texture 2. The rule pass uses it for
    /// ligature strips.
    unowned(unsafe) var thirdTexture: MTLTexture? = nil
    /// A fourth sheet at fragment texture 3. The rule pass uses it for the
    /// dedicated proportional sheet, under a run drawn glyph by glyph.
    unowned(unsafe) var fourthTexture: MTLTexture? = nil
    /// A fifth sheet at fragment texture 4. The rule pass uses it for the
    /// two-cell sheet, under a wide glyph's columns.
    unowned(unsafe) var fifthTexture: MTLTexture? = nil
    /// The first instance drawn, for a stream drawn in two segments: the head
    /// into the retained grid, the cursor tier's tail after the blit.
    var baseInstance: Int = 0
}

/// Which part of a pass's work one encoder records.
///
/// A bitmap frame that cannot read its target draws its box overlays in an
/// encoded pass between the fills and the ink, so the pass splits there;
/// every other frame records the whole of it at once.
enum PassPhase {
    /// Everything, box overlays inline.
    case whole
    /// The fills, up to and not including the box overlays.
    case fills
    /// Everything after the box overlays.
    case afterFills
}

/// Which part of a stream a pass draws.
///
/// Core builds the cursor tier — the cursor's cell re-emitted with the cursor's
/// colours — last, so it is each stream's tail
/// (``Ubiquitty/Rendering/InstanceCounts/cursorTier``). A backend keeping its
/// grid across frames draws the head into the grid and the tail after the
/// blit, before the overlays: the grid never holds a cursor, so a blink or a
/// move owes it no row.
enum StreamSegment {
    /// Everything but the tier.
    case head
    /// The tier alone.
    case cursorTier
}

/// The instances a segment covers within a stream of `count`, the last
/// `tail` of which are the tier's.
private func segmentRange(count: Int, tail: Int, _ segment: StreamSegment) -> (base: Int, count: Int) {
    let tier = min(max(tail, 0), count)
    switch segment {
    case .head:
        return (0, count - tier)
    case .cursorTier:
        return (count - tier, tier)
    }
}

/// One frame's inline-image placements, split into the two z bands.
///
/// Not an ``InstancePass``: every quad samples a different texture, so the band
/// is a draw per quad rather than one instanced draw, and the texture is bound
/// between them. The quads are already ordered by z, so the split is an index
/// rather than a predicate — everything below it draws under the text.
///
/// `unowned(unsafe)` for the same reason ``InstancePass`` gives: this is built
/// per frame and dies inside the encode, and the buffer and every texture are
/// owned for longer by the renderer and the frame's snapshot.
package struct ImageLayer {
    /// Which side of the text a band draws on.
    enum Band {
        /// Behind the glyphs — kitty placements with a negative z index.
        case underText
        /// In front of them, but still under the rules.
        case overText
    }

    /// The quad geometry, one ``Ubiquitty/Rendering/ImageInstance`` per
    /// placement.
    unowned(unsafe) var buffer: MTLBuffer?
    /// One texture per quad, in the same order.
    var textures: [MTLTexture?]
    /// Whether each quad is filtered, in the same order: Core's
    /// `Image::ImageFilter` for it, `Smooth` as true.
    var isFiltered: [Bool]
    /// How many quads the layer carries — the frame-probe's read, so the
    /// texture array itself stays internal.
    package var quadCount: Int { textures.count }
    /// Where the negative-z run ends and the positive-z run begins.
    var split: Int
}

/// Draws one frame's instance streams into a render command encoder.
///
/// The instance streams and shaders share this binding contract:
///
///     every pass          vertex bytes: uniforms at 0; vertex buffer:
///                         instances at 1
///     cell, glyph, wide,  fragment bytes: uniforms at 0; fragment texture:
///     double, ligature    the pass's sheet at 0; the atlas sampler at 0
///     colorGlyph          sheet and sampler, no fragment uniforms
///     boxFills, overlays  no fragment state at all
///     decorations         the mono sheet, for skip-ink
///
/// This encoder binds the uniforms to both stages once for the whole frame —
/// a fragment function that declares no buffer 0 ignores the binding — so a
/// pass cannot be added with the vertex half and not the fragment half.
///
/// Holds no per-frame state: the pipelines and samplers are fixed for a drawable
/// format, and everything else arrives as an argument. Two frames may be encoded
/// through one of these concurrently.
final class FrameEncoder {
    private let pipelines: MetalPipelines
    private let samplers: MetalSamplers

    /// Creates an encoder over one drawable format's pipelines.
    ///
    /// - Parameters:
    ///   - pipelines: The states each pass draws under.
    ///   - samplers: How each bound sheet is filtered.
    init(pipelines: MetalPipelines, samplers: MetalSamplers) {
        self.pipelines = pipelines
        self.samplers = samplers
    }

    /// Encodes every pass of one frame, in compositing order.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built, and the counts it wrote.
    ///   - uniforms: The frame constants every pass reads.
    ///   - sheets: The glyph sheets the passes sample.
    ///   - encoder: The command encoder the passes are recorded into.
    func encode(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        into encoder: MTLRenderCommandEncoder
    ) {
        encodeGrid(instances, uniforms: uniforms, sheets: sheets, into: encoder)
        encodeOverlays(instances, uniforms: uniforms, sheets: sheets, into: encoder)
    }

    /// Encodes the grid-content passes — everything that lands in the retained
    /// grid texture. Overlays stay out: the cursor and the selection move
    /// without dirtying rows, so they draw over the blit, not into the cache.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built, and the counts it wrote.
    ///   - uniforms: The frame constants every pass reads.
    ///   - sheets: The glyph sheets the passes sample.
    ///   - encoder: The command encoder the passes are recorded into.
    func encodeGrid(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        images: ImageLayer? = nil,
        backdrop: Backdrop? = nil,
        confinedTo contentScissor: MTLScissorRect? = nil,
        phase: PassPhase = .whole,
        into encoder: MTLRenderCommandEncoder
    ) {
        if let contentScissor {
            encoder.setScissorRect(contentScissor)
        }
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            // The fragment stage has its own buffer table, and every fragment
            // function reads the uniforms at its own index 0 — gamma, texel
            // size, background opacity. Bound only to the vertex stage, the
            // fragments read unbound memory: the composite mixes poisoned
            // colours, which paints foreground-tinted blocks where text is and
            // black where the background should be, with every count correct.
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        // Three segments rather than one list, because the image bands go
        // between them. A kitty placement carries a z index and the sign of it
        // is the whole feature: negative sits behind the text, positive in
        // front. So the under band draws once the fills are down, and the over
        // band draws before the rules — an underline is never covered by an
        // image, whichever side of the text the image is on.
        if phase != .afterFills {
            drawFillPasses(instances, sheets, uniforms: uniforms, segment: .head, phase: phase, into: encoder)
        }
        guard phase != .fills else { return }
        // After the fills and before the glyphs: destination-over slots the
        // image behind the translucent theme
        // the cell pass laid down, and a glyph's antialiased edge then blends
        // over the composed backdrop rather than the backdrop blending under
        // the composed glyph — the two orders differ at every edge pixel.
        if let backdrop {
            // The one draw that must escape the content scissor: the quad
            // spans the whole target, and margins hold only the translucent
            // clear, so a clipped backdrop leaves them bare where the other
            // renderer composites the image. Escaping is safe because a frame
            // with a backdrop never reuses the retained target — Core's reuse
            // verdict refuses one (RetainedTargetEligibility.hasBackdrop) — so
            // what lands in the margins here is redrawn from a clear every
            // frame, never inherited.
            if let contentScissor {
                let width = Int(uniforms.viewportSizeInPixels.x)
                let height = Int(uniforms.viewportSizeInPixels.y)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
                drawBackdrop(backdrop, uniforms: uniforms, into: encoder)
                encoder.setScissorRect(contentScissor)
            } else {
                drawBackdrop(backdrop, uniforms: uniforms, into: encoder)
            }
        }
        if let images {
            drawImages(images, band: .underText, uniforms: uniforms, into: encoder)
        }
        drawGlyphPasses(instances, sheets, uniforms: uniforms, segment: .head, into: encoder)
        if let images {
            drawImages(images, band: .overText, uniforms: uniforms, into: encoder)
        }
        drawRulePasses(instances, sheets, uniforms: uniforms, segment: .head, into: encoder)
    }

    /// Draws secondary ink using the same instances and atlas as the ordinary grid.
    func encodeSecondaryInk(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        draw(
            InstancePass(
                pipeline: pipelines.secondaryMarginRestore,
                buffer: instances.marginStrips.buffer,
                count: instances.counts.marginStrips,
                texture: sheets.mono,
                requiresSheet: false
            ),
            into: encoder
        )
        let cells = segmentRange(count: instances.counts.cells, tail: instances.counts.cursorTier.cells, .head)
        draw(
            InstancePass(
                pipeline: pipelines.secondaryCell,
                buffer: instances.cells.buffer,
                count: cells.count,
                texture: sheets.mono,
                requiresSheet: false,
                baseInstance: cells.base
            ),
            into: encoder
        )
        let boxFills = segmentRange(count: instances.counts.boxFills, tail: instances.counts.cursorTier.boxFills, .head)
        draw(
            InstancePass(
                pipeline: pipelines.secondaryOverlay,
                buffer: instances.boxFills.buffer,
                count: boxFills.count,
                texture: nil,
                requiresSheet: false,
                baseInstance: boxFills.base
            ),
            into: encoder
        )
        drawGlyphPasses(instances, sheets, uniforms: uniforms, segment: .head, secondaryOnly: true, into: encoder)
    }

    /// Draws vibrant cell fills beneath the ordinary text and cursor plane.
    func encodeVibrantBackground(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        draw(
            InstancePass(
                pipeline: pipelines.secondaryMarginRestore,
                buffer: instances.marginStrips.buffer,
                count: instances.counts.marginStrips,
                texture: nil,
                requiresSheet: false
            ),
            into: encoder
        )
        let cells = segmentRange(count: instances.counts.cells, tail: instances.counts.cursorTier.cells, .head)
        draw(
            InstancePass(
                pipeline: pipelines.vibrantBackground,
                buffer: instances.cells.buffer,
                count: cells.count,
                texture: nil,
                requiresSheet: false,
                baseInstance: cells.base
            ),
            into: encoder
        )
        let boxFills = segmentRange(count: instances.counts.boxFills, tail: instances.counts.cursorTier.boxFills, .head)
        draw(
            InstancePass(
                pipeline: pipelines.nativeBackgroundTransition,
                buffer: instances.boxFills.buffer,
                count: boxFills.count,
                texture: nil,
                requiresSheet: false,
                baseInstance: boxFills.base
            ),
            into: encoder
        )
    }

    /// Draws semantic terminal marks above the retained native text.
    func encodeSecondaryOverlays(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        draw(
            InstancePass(
                pipeline: pipelines.secondaryOverlay,
                buffer: instances.overlays.buffer,
                count: instances.counts.overlays,
                texture: nil,
                requiresSheet: false
            ),
            into: encoder
        )
    }

    /// Removes native ink where the drawable's block cursor supplies its own glyph.
    func clearSecondaryCursor(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        let cells = segmentRange(count: instances.counts.cells, tail: instances.counts.cursorTier.cells, .cursorTier)
        draw(
            InstancePass(
                pipeline: pipelines.secondaryCursorClear,
                buffer: instances.cells.buffer,
                count: cells.count,
                texture: sheets.mono,
                requiresSheet: false,
                baseInstance: cells.base
            ),
            into: encoder
        )
    }

    /// Encodes the cursor tier and then the overlay pass over whatever the
    /// frame already holds.
    ///
    /// The tier goes first: the cursor's cell, re-emitted by Core with the
    /// cursor's colours as each stream's tail, drawn after the blit and before
    /// the overlays so the retained grid never holds a cursor and a blink or a
    /// move owes it no row. Cells, then ink, then rules — the grid passes'
    /// order, over the pixels the blit laid down — which is the compositing
    /// a bake into the cell would produce, drawn last instead of first.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built.
    ///   - uniforms: The frame constants.
    ///   - sheets: The glyph sheets the tier's ink samples.
    ///   - includesFloatingOverlays: Whether highlights share this pass with the cursor.
    ///   - encoder: The encoder for the pass that targets the drawable.
    func encodeOverlays(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        includesFloatingOverlays: Bool = true,
        phase: PassPhase = .whole,
        into encoder: MTLRenderCommandEncoder
    ) {
        let counts = instances.counts
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        if phase != .afterFills {
            drawFillPasses(instances, sheets, uniforms: uniforms, segment: .cursorTier, phase: phase, into: encoder)
        }
        guard phase != .fills else { return }
        drawGlyphPasses(instances, sheets, uniforms: uniforms, segment: .cursorTier, into: encoder)
        drawRulePasses(instances, sheets, uniforms: uniforms, segment: .cursorTier, into: encoder)
        guard includesFloatingOverlays else { return }
        draw(
            InstancePass(
                // The bitmap tier's overlays composite in the fragment like the
                // software renderer; that pipeline blends nothing.
                pipeline: uniforms.bitmapTier != 0 ? pipelines.overlayBitmap : pipelines.overlay,
                buffer: instances.overlays.buffer,
                count: counts.overlays,
                texture: nil,
                requiresSheet: false
            ),
            into: encoder
        )
    }

    /// Draws the frame's rich text over the blitted grid: the selection
    /// highlights, then each block's raster, every quad one texel per device
    /// pixel (Docs/rich-text.md).
    ///
    /// - Parameters:
    ///   - layer: The frame's rich text, or nil when it shows no block.
    ///   - uniforms: The frame constants the vertex stage reads.
    ///   - encoder: The pass that targets the drawable.
    func drawRichText(_ layer: RichTextLayer?, uniforms: Ubiquitty.Rendering.FrameUniforms, into encoder: MTLRenderCommandEncoder) {
        guard let layer, let pipeline = pipelines.richText, let buffer = layer.buffer, !layer.textures.isEmpty else {
            return
        }
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentSamplerState(samplers.image, index: 0)
        for (index, texture) in layer.textures.enumerated() {
            guard let texture else { continue }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1, baseInstance: index)
        }
    }

    /// Draws the bitmap tier's overlays into the encoded view in their order,
    /// a focused pill taking two draws: its shadow, then the pill over the
    /// bytes the shadow left, as the software renderer's two steps do. A
    /// shadow drawn ahead of every overlay would land under highlights the
    /// pill is drawn over.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built.
    ///   - encoder: The encoded pass.
    private func encodeBitmapOverlaysInOrder(_ instances: FrameInstances, into encoder: MTLRenderCommandEncoder) {
        let count = instances.counts.overlays
        guard count > 0, let overlays = instances.overlays.elements(as: Ubiquitty.Rendering.OverlayInstance.self) else { return }
        func drawRange(_ pipeline: MTLRenderPipelineState?, _ base: Int, _ length: Int) {
            guard length > 0 else { return }
            draw(
                InstancePass(
                    pipeline: pipeline,
                    buffer: instances.overlays.buffer,
                    count: length,
                    texture: nil,
                    requiresSheet: false,
                    baseInstance: base
                ),
                into: encoder
            )
        }
        var start = 0
        for index in 0..<count {
            let kind = overlays[index].shapeKind
            guard kind < -2.5, kind > -3.5 else { continue }
            drawRange(pipelines.encodedBitmapOverlay, start, index - start)
            drawRange(pipelines.encodedBitmapOverlayShadow, index, 1)
            drawRange(pipelines.encodedBitmapOverlay, index, 1)
            start = index + 1
        }
        drawRange(pipelines.encodedBitmapOverlay, start, count - start)
    }

    /// Whether a bitmap frame's overlays and rules go through the encoded pass.
    ///
    /// The bitmap tier composites in the encoded bytes, as the software
    /// renderer does. Its own states read the target to do so; where that is
    /// refused (the iOS simulator), the passes draw into a linear-format view
    /// of the target instead, where the hardware blend mixes those bytes.
    ///
    /// - Parameter uniforms: The frame constants, for the tier.
    /// - Returns: Whether this frame's bitmap overlays and rules draw encoded.
    func drawsBitmapPassesEncoded(_ uniforms: Ubiquitty.Rendering.FrameUniforms) -> Bool {
        uniforms.bitmapTier != 0 && !pipelines.isBitmapTargetReadable && pipelines.encodedBitmapOverlay != nil
            && pipelines.encodedBitmapDecoration != nil
    }

    /// Draws one segment's box overlays — Powerline shapes, mosaics, braille —
    /// into a linear-format view of their target, for a bitmap frame that
    /// cannot read it.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built.
    ///   - uniforms: The frame constants.
    ///   - segment: Which part of the box stream.
    ///   - encoder: A pass whose target is the encoded view.
    func encodeEncodedBoxOverlays(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        segment: StreamSegment,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        let boxFills = segmentRange(count: instances.counts.boxFills, tail: instances.counts.cursorTier.boxFills, segment)
        draw(
            InstancePass(
                pipeline: pipelines.encodedBitmapOverlay,
                buffer: instances.boxFills.buffer,
                count: boxFills.count,
                texture: nil,
                requiresSheet: false,
                baseInstance: boxFills.base
            ),
            into: encoder
        )
    }

    /// Draws one segment's rules into a linear-format view of their target,
    /// for a bitmap frame that cannot read it.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built.
    ///   - uniforms: The frame constants.
    ///   - sheets: The sheets the skip-ink taps sample.
    ///   - segment: Which part of the rule stream.
    ///   - encoder: A pass whose target is the encoded view.
    func encodeEncodedRules(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        segment: StreamSegment,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        drawRulePasses(instances, sheets, uniforms: uniforms, segment: segment, isEncodedPass: true, into: encoder)
    }

    /// Aliases the drawable's stored bytes without applying the sRGB transfer.
    ///
    /// Metal permits linear/sRGB aliases without `.pixelFormatView` usage, so
    /// the drawable keeps its render-target compression and needs no copy.
    func encodedOverlayTarget(for texture: MTLTexture) -> MTLTexture? {
        guard pipelines.encodedOverlay != nil || pipelines.encodedBitmapOverlay != nil,
            let format = pipelines.encodedOverlayFormat
        else { return nil }
        return texture.makeTextureView(pixelFormat: format)
    }

    /// Composites highlights in the same encoded domain as glyph antialiasing.
    func encodeEncodedOverlays(
        _ instances: FrameInstances,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        sheets: AtlasSheets,
        into encoder: MTLRenderCommandEncoder
    ) {
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        let isBitmap = drawsBitmapPassesEncoded(uniforms)
        // The tier's rules first, where the sRGB pass left them, so the
        // floating overlays still land over them.
        if isBitmap {
            drawRulePasses(instances, sheets, uniforms: uniforms, segment: .cursorTier, isEncodedPass: true, into: encoder)
            encodeBitmapOverlaysInOrder(instances, into: encoder)
            return
        }
        draw(
            InstancePass(
                pipeline: pipelines.encodedOverlay,
                buffer: instances.overlays.buffer,
                count: instances.counts.overlays,
                texture: nil,
                requiresSheet: false
            ),
            into: encoder
        )
    }

    /// The background image one frame composites behind the theme background.
    ///
    /// Carried per frame rather than stored: the texture is the caller's
    /// decode and its lifetime is the caller's, the same contract the image
    /// layer's textures ride on.
    struct Backdrop {
        let texture: MTLTexture
        let opacity: Float
        let mode: Int32
        let pixelWidth: Int32
        let pixelHeight: Int32
    }

    /// One quad matching the Metal `BackgroundImageInstance` layout.
    private struct BackdropInstance {
        var topLeftInPixels: SIMD2<Float>
        var bottomRightInPixels: SIMD2<Float>
        var uv0: SIMD2<Float>
        var uv1: SIMD2<Float>
        var opacity: Float
        var pad0: Float
        var pad1: SIMD2<Float>
    }

    /// Draws the backdrop behind whatever the pass already holds.
    ///
    /// Destination-over: the quad fills only the alpha the frame left open, so
    /// it slots behind the translucent theme background the cell pass laid
    /// down. The caller keeps grid reuse off while an image is set, so the
    /// backdrop baked into the content never outlives the setting.
    ///
    /// - Parameters:
    ///   - backdrop: The image, its opacity and its placement mode.
    ///   - uniforms: The frame constants, for the viewport extent.
    ///   - encoder: The drawable pass encoder.
    func drawBackdrop(
        _ backdrop: Backdrop,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into encoder: MTLRenderCommandEncoder
    ) {
        guard let pipeline = pipelines.backgroundImage else {
            return
        }
        let viewWidth = Float(uniforms.viewportSizeInPixels.x)
        let viewHeight = Float(uniforms.viewportSizeInPixels.y)
        guard viewWidth > 0, viewHeight > 0, backdrop.pixelWidth > 0, backdrop.pixelHeight > 0 else {
            return
        }
        // Core places the quad; this arm supplies scalars and draws.
        let placement = Ubiquitty.Rendering.backgroundImagePlacement(
            Ubiquitty.Rendering.BackgroundImageMode(rawValue: UInt8(clamping: backdrop.mode)) ?? .Fill,
            viewWidth,
            viewHeight,
            Float(backdrop.pixelWidth),
            Float(backdrop.pixelHeight)
        )
        var instance = BackdropInstance(
            topLeftInPixels: SIMD2(placement.leftInPixels, placement.topInPixels),
            bottomRightInPixels: SIMD2(placement.rightInPixels, placement.bottomInPixels),
            uv0: SIMD2(placement.u0, placement.v0),
            uv1: SIMD2(placement.u1, placement.v1),
            opacity: backdrop.opacity,
            pad0: 0,
            pad1: SIMD2(0, 0)
        )
        var frame = uniforms
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        withUnsafeBytes(of: &instance) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.setFragmentTexture(backdrop.texture, index: 0)
        encoder.setFragmentSamplerState(placement.shouldRepeat ? samplers.repeating : samplers.atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Blits a full-drawable texture over the pass target.
    ///
    /// One oversized triangle; the layer is already premultiplied and linear,
    /// so the fragment is a single sample.
    ///
    /// - Parameters:
    ///   - layer: The texture to blit.
    ///   - encoder: The encoder for the pass that targets the drawable.
    func blit(_ layer: MTLTexture, into encoder: MTLRenderCommandEncoder) {
        guard let pipeline = pipelines.fullscreenBlit else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(layer, index: 0)
        encoder.setFragmentSamplerState(samplers.atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: - Passes

    /// Draws one band of a frame's image placements.
    ///
    /// One draw per quad, because each binds its own texture. The uniforms are
    /// already bound for the frame and the vertex stage reads the quad by
    /// `baseInstance`, so the only per-quad state is the texture.
    ///
    /// - Parameters:
    ///   - images: The frame's placements, or nil when it carries none.
    ///   - band: Which side of the text to draw.
    ///   - encoder: The command encoder the draws are recorded into.
    private func drawImages(
        _ images: ImageLayer,
        band: ImageLayer.Band,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into encoder: MTLRenderCommandEncoder
    ) {
        let range = band == .underText ? 0..<images.split : images.split..<images.textures.count
        // The bitmap tier's images composite in the fragment like the software
        // renderer; that pipeline blends nothing.
        let chosen = uniforms.bitmapTier != 0 ? pipelines.imageBitmap : pipelines.image
        guard let pipeline = chosen, let buffer = images.buffer, !range.isEmpty else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        // A whole-number enlargement reads nearest: the bitmap tier repeats the
        // border texel past the edge, as the CPU's clamp does, and the native
        // tier keeps transparent black there. Every other quad is filtered on
        // either tier, as the CPU's filtered path is.
        let nearest = uniforms.bitmapTier != 0 ? samplers.imageEdge : samplers.image
        for index in range {
            guard let texture = images.textures[index] else {
                continue
            }
            var filtered: UInt32 = images.isFiltered[index] ? 1 : 0
            encoder.setFragmentSamplerState(images.isFiltered[index] ? samplers.imageFiltered : nearest, index: 0)
            encoder.setFragmentBytes(&filtered, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1, baseInstance: index)
        }
    }

    /// Draws the fills behind everything: cell backgrounds, then box-drawing
    /// quads, in compositing order.
    ///
    /// Encoded directly rather than returned as a list: an array returned
    /// here escapes and heap-allocates per frame, to be iterated once.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built, and the counts it wrote.
    ///   - sheets: The glyph sheets the passes sample.
    ///   - encoder: The pass to record into.
    private func drawFillPasses(
        _ instances: FrameInstances,
        _ sheets: AtlasSheets,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        segment: StreamSegment,
        phase: PassPhase = .whole,
        into encoder: MTLRenderCommandEncoder
    ) {
        let counts = instances.counts
        // Margins first, written not blended: the strips reset a rebuilt
        // row's overhang margins to the clear, and everything after them
        // composites on top. The tier restores no margin: a tail of zero.
        let margins = segmentRange(count: counts.marginStrips, tail: 0, segment)
        draw(
            InstancePass(
                pipeline: uniforms.bitmapTier != 0 ? pipelines.marginRestoreBitmap : pipelines.marginRestore,
                buffer: instances.marginStrips.buffer,
                count: margins.count,
                texture: sheets.mono,
                requiresSheet: false,
                baseInstance: margins.base
            ),
            into: encoder
        )
        let cells = segmentRange(count: counts.cells, tail: counts.cursorTier.cells, segment)
        draw(
            InstancePass(
                pipeline: pipelines.cell,
                buffer: instances.cells.buffer,
                count: cells.count,
                texture: sheets.mono,
                requiresSheet: false,
                baseInstance: cells.base
            ),
            into: encoder
        )
        let boxFills = segmentRange(count: counts.boxFills, tail: counts.cursorTier.boxFills, segment)
        draw(
            InstancePass(
                pipeline: pipelines.backgroundTransition,
                buffer: instances.boxFills.buffer,
                count: boxFills.count,
                texture: nil,
                requiresSheet: false,
                baseInstance: boxFills.base
            ),
            into: encoder
        )
        // The box overlays wait for their encoded pass when the phase splits.
        guard phase == .whole else { return }
        draw(
            InstancePass(
                pipeline: uniforms.bitmapTier != 0 ? pipelines.overlayBitmap : pipelines.overlay,
                buffer: instances.boxFills.buffer,
                count: boxFills.count,
                texture: nil,
                requiresSheet: false,
                baseInstance: boxFills.base
            ),
            into: encoder
        )
    }

    /// Draws the text itself — one pass per sheet the frame drew glyphs into,
    /// in compositing order, encoded directly as ``drawFillPasses`` is.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built, and the counts it wrote.
    ///   - sheets: The glyph sheets the passes sample.
    ///   - encoder: The pass to record into.
    private func drawGlyphPasses(
        _ instances: FrameInstances,
        _ sheets: AtlasSheets,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        segment: StreamSegment,
        secondaryOnly: Bool = false,
        into encoder: MTLRenderCommandEncoder
    ) {
        // The bitmap tier's glyphs replace the pixel as the software renderer
        // does; that pipeline blends nothing. Colour glyphs keep their pass.
        let glyphPipeline = secondaryOnly ? pipelines.secondaryGlyph : (uniforms.bitmapTier != 0 ? pipelines.glyphBitmap : pipelines.glyph)
        let counts = instances.counts
        let tier = counts.cursorTier
        let glyphs = segmentRange(count: counts.glyphs, tail: tier.glyphs, segment)
        draw(
            InstancePass(
                pipeline: glyphPipeline,
                buffer: instances.glyphs.buffer,
                count: glyphs.count,
                texture: sheets.mono,
                requiresSheet: true,
                baseInstance: glyphs.base
            ),
            into: encoder
        )
        let doubleGlyphs = segmentRange(count: counts.doubleGlyphs, tail: tier.doubleGlyphs, segment)
        draw(
            InstancePass(
                pipeline: glyphPipeline,
                buffer: instances.doubleGlyphs.buffer,
                count: doubleGlyphs.count,
                texture: sheets.double,
                requiresSheet: true,
                baseInstance: doubleGlyphs.base
            ),
            into: encoder
        )
        let wideGlyphs = segmentRange(count: counts.wideGlyphs, tail: tier.wideGlyphs, segment)
        draw(
            InstancePass(
                pipeline: glyphPipeline,
                buffer: instances.wideGlyphs.buffer,
                count: wideGlyphs.count,
                texture: sheets.wide,
                requiresSheet: true,
                baseInstance: wideGlyphs.base
            ),
            into: encoder
        )
        let proportionalGlyphs = segmentRange(count: counts.proportionalGlyphs, tail: tier.proportionalGlyphs, segment)
        draw(
            InstancePass(
                pipeline: glyphPipeline,
                buffer: instances.proportionalGlyphs.buffer,
                count: proportionalGlyphs.count,
                texture: sheets.proportional,
                requiresSheet: true,
                baseInstance: proportionalGlyphs.base
            ),
            into: encoder
        )
        let proportionalStrips = segmentRange(count: counts.proportionalStrips, tail: tier.proportionalStrips, segment)
        draw(
            InstancePass(
                pipeline: glyphPipeline,
                buffer: instances.proportionalStrips.buffer,
                count: proportionalStrips.count,
                texture: sheets.proportionalStrip,
                requiresSheet: true,
                baseInstance: proportionalStrips.base
            ),
            into: encoder
        )
        let colorGlyphs = segmentRange(count: counts.colorGlyphs, tail: tier.colorGlyphs, segment)
        draw(
            InstancePass(
                pipeline: secondaryOnly ? nil : pipelines.colorGlyph,
                buffer: instances.colorGlyphs.buffer,
                count: colorGlyphs.count,
                texture: sheets.color,
                requiresSheet: true,
                baseInstance: colorGlyphs.base
            ),
            into: encoder
        )
        let ligatureGlyphs = segmentRange(count: counts.ligatureGlyphs, tail: tier.ligatureGlyphs, segment)
        draw(
            InstancePass(
                pipeline: glyphPipeline,
                buffer: instances.ligatureGlyphs.buffer,
                count: ligatureGlyphs.count,
                texture: sheets.ligature,
                requiresSheet: true,
                baseInstance: ligatureGlyphs.base
            ),
            into: encoder
        )
    }

    /// Draws the rules over the text: underlines, strikethroughs and box
    /// strokes, encoded directly as ``drawFillPasses`` is.
    ///
    /// - Parameters:
    ///   - instances: The streams Core built, and the counts it wrote.
    ///   - sheets: The sheet the skip-ink taps sample.
    ///   - encoder: The pass to record into.
    private func drawRulePasses(
        _ instances: FrameInstances,
        _ sheets: AtlasSheets,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        segment: StreamSegment,
        isEncodedPass: Bool = false,
        into encoder: MTLRenderCommandEncoder
    ) {
        // A bitmap frame whose target cannot be read draws its rules in the
        // encoded pass alone; this sRGB pass leaves them out.
        if !isEncodedPass && drawsBitmapPassesEncoded(uniforms) { return }
        // The bitmap tier takes the pipeline that blends nothing: its fragment
        // composites like the software renderer and returns the finished byte.
        // Where it cannot read the target, the encoded pass blends the bytes.
        let pipeline =
            isEncodedPass
            ? pipelines.encodedBitmapDecoration
            : uniforms.bitmapTier != 0 ? pipelines.decorationBitmap : pipelines.decoration
        let counts = instances.counts
        let rules = segmentRange(count: counts.decorations, tail: counts.cursorTier.decorations, segment)
        draw(
            InstancePass(
                pipeline: pipeline,
                buffer: instances.decorations.buffer,
                count: rules.count,
                texture: sheets.mono,
                requiresSheet: false,
                secondTexture: sheets.proportionalStrip,
                thirdTexture: sheets.ligature,
                fourthTexture: sheets.proportional,
                fifthTexture: sheets.wide,
                baseInstance: rules.base
            ),
            into: encoder
        )
    }

    /// Records one pass, or nothing when it has no work or no shader.
    ///
    /// The uniform stays bound from ``encode(_:uniforms:sheets:into:)`` — it is
    /// the same bytes for every pass, and rebinding it per pass would be a
    /// buffer write per pass to say so.
    private func draw(_ pass: InstancePass, into encoder: MTLRenderCommandEncoder) {
        guard pass.count > 0, let pipeline = pass.pipeline, let buffer = pass.buffer else {
            return
        }
        // A sampling pass with no sheet draws nothing rather than inheriting
        // the last binding. Core built instances for a stream this backend has
        // no ink for; drawing them samples whichever sheet the pass before it
        // bound, which puts the wrong glyphs on screen with every count right.
        if pass.requiresSheet && pass.texture == nil {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        if let texture = pass.texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplers.atlas, index: 0)
        }
        // Optional sheets fall back to mono so every declared texture slot is
        // deterministic even on a frame carrying no corresponding run.
        if let second = pass.secondTexture ?? pass.texture, pass.secondTexture != nil || pass.texture != nil {
            encoder.setFragmentTexture(second, index: 1)
        }
        if let third = pass.thirdTexture ?? pass.texture, pass.thirdTexture != nil || pass.texture != nil {
            encoder.setFragmentTexture(third, index: 2)
        }
        if let fourth = pass.fourthTexture ?? pass.texture, pass.fourthTexture != nil || pass.texture != nil {
            encoder.setFragmentTexture(fourth, index: 3)
        }
        if let fifth = pass.fifthTexture ?? pass.texture, pass.fifthTexture != nil || pass.texture != nil {
            encoder.setFragmentTexture(fifth, index: 4)
        }
        // Two triangles as six vertices, positioned in the vertex shader from
        // the instance rather than from a vertex buffer, so the quad geometry
        // never crosses the bus.
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: pass.count,
            baseInstance: pass.baseInstance
        )
    }
}
