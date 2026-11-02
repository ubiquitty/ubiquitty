// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TekPass.swift — the Swift arm's Tektronix 4014 storage-tube frame.
//
// Core owns the display list and the stroke walk, alpha glyphs included: the
// walk letters a glyph with the beam, as the tube did, so every arm draws the
// same strokes and none keeps a font for the tube. This pass owns what only
// the backend has — the line pipelines and the pass encoding. The platform
// half of the inputs (resolved colors, the backing scale) arrives from the owner,
// so the two macOS arms resolve them once in one place and the comparison
// harness diffs geometry rather than settings.

import Metal
import UbiquittyCore

/// The Tek pass's per-drive GPU streams and stroke scratch.
///
/// A class rather than fields on the renderer so the whole allocation is one
/// optional: a session that never enters Tek mode carries a nil.
final class TekPassStreams {
    /// The stroke quads: lines, dash runs, points, letters, crosshair arms, the pen.
    var lines: GrowableBuffer
    /// The stroke walk's output scratch, reused frame to frame.
    var strokeScratch: [Ubiquitty.Tek.StrokeRun] = []
    /// The halo table the glow pass looks a pixel's distance up in.
    var haloLevels: GrowableBuffer
    /// Core's fill of the halo table, copied into ``haloLevels``.
    var haloScratch: [Ubiquitty.Tek.HaloLevel] = []

    /// Creates the streams on a device, empty until the first frame sizes them.
    ///
    /// - Parameter device: The device the buffers are allocated on.
    init(device: MTLDevice) {
        lines = GrowableBuffer(
            device: device,
            growth: .exactFit,
            stride: MemoryLayout<Ubiquitty.Rendering.TekLineInstance>.stride
        )
        haloLevels = GrowableBuffer(
            device: device,
            growth: .exactFit,
            stride: MemoryLayout<Ubiquitty.Tek.HaloLevel>.stride
        )
    }
}

extension TerminalRenderer {
    /// Encodes one Tektronix frame from Core's display list.
    ///
    /// Strokes come from Core's one walk (`buildStrokeRuns`), so a dash
    /// pattern, a point's extent or a letter's strokes can never disagree
    /// with the other arm's. The GIN crosshair and the bright writing spot
    /// draw in the cursor colour, the crosshair spanning the fitted Tek rect.
    ///
    /// - Parameters:
    ///   - uniforms: The frame constants, with the resolved Tek background.
    ///   - primitives: The display list's base, or nil when it is empty.
    ///   - primitiveCount: How many primitives are live at the base.
    ///   - tekWidth: The Tek coordinate space's width.
    ///   - tekHeight: The Tek coordinate space's height.
    ///   - isGINActive: Whether the graphics-input crosshair is up.
    ///   - ginX: The crosshair's horizontal position, in Tek space.
    ///   - ginY: The crosshair's vertical position, in Tek space.
    ///   - drawsBrightPen: Whether the writing spot draws at the beam's rest.
    ///   - beam: The stroke colour, letters included.
    ///   - cursor: The crosshair and writing-spot colour.
    ///   - deviceScale: Device pixels per point, from which Core's
    ///     ``Ubiquitty/Tek/beamGeometry(_:)`` sizes the stroke, the spot, the
    ///     halo and the projection's edge inset.
    ///   - drawsGlow: Whether the bloom pass runs under the display list's
    ///     strokes; the crosshair and the writing spot are not the phosphor's
    ///     trace and do not bloom.
    ///   - descriptor: The pass to encode into; its clear is set here.
    /// - Returns: The encoded, uncommitted command buffer, or nil.
    // swift-only: a member of the package-scoped renderer, which the generated C++ header never prints, and only the Swift surface renderer encodes through it
    package func encodeTekFrame(
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        primitives: UnsafePointer<Ubiquitty.Tek.Primitive>?,
        primitiveCount: Int32,
        tekWidth: Int32,
        tekHeight: Int32,
        isGINActive: Bool,
        ginX: Int32,
        ginY: Int32,
        drawsBrightPen: Bool,
        beam: Ubiquitty.Rendering.Vec4,
        cursor: Ubiquitty.Rendering.Vec4,
        deviceScale: Float,
        drawsGlow: Bool,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        let width = uniforms.viewportSizeInPixels.x
        let height = uniforms.viewportSizeInPixels.y
        guard width > 0, height > 0 else {
            return nil
        }
        let streams = tekStreams ?? TekPassStreams(device: queue.device)
        tekStreams = streams

        let count = Int(primitiveCount)
        let beamGeometry = Ubiquitty.Tek.beamGeometry(deviceScale)
        let halfThickness = beamGeometry.halfThickness
        let projection = Ubiquitty.Tek.makeBeamProjection(tekWidth, tekHeight, 0.0, 0.0, width, height, deviceScale)

        // One budget for the stroke walk and the line buffer, sized the way
        // the other arm sizes it: a dash-run cap per primitive, which also
        // covers a glyph's strokes, plus the two crosshair arms and the
        // writing spot.
        let lineBudget = count * Int(Ubiquitty.Tek.maxStrokeRunsPerLine) + 3
        streams.lines.ensure(lineBudget)
        let lineCapacity = min(lineBudget, streams.lines.capacity)
        if streams.strokeScratch.count < lineBudget {
            streams.strokeScratch = [Ubiquitty.Tek.StrokeRun](
                repeating: Ubiquitty.Tek.StrokeRun(),
                count: lineBudget
            )
        }
        var lineCount = 0
        guard let lineBase = streams.lines.elements(as: Ubiquitty.Rendering.TekLineInstance.self) else {
            return nil
        }
        func emitSegment(
            _ start: Ubiquitty.Tek.DevicePoint,
            _ end: Ubiquitty.Tek.DevicePoint,
            _ color: Ubiquitty.Rendering.Vec4,
            _ half: Float
        ) {
            guard lineCount < lineCapacity else {
                return
            }
            var line = Ubiquitty.Rendering.TekLineInstance()
            line.startInPixels = Ubiquitty.Rendering.Vec2(x: start.x, y: start.y)
            line.endInPixels = Ubiquitty.Rendering.Vec2(x: end.x, y: end.y)
            line.halfThickness = half
            line.pad0 = 0
            line.color = color
            lineBase[lineCount] = line
            lineCount += 1
        }

        if let primitives, count > 0 {
            let strokeCount = streams.strokeScratch.withUnsafeMutableBufferPointer { scratch -> Int32 in
                Ubiquitty.Tek.buildStrokeRuns(
                    Ubiquitty.Tek.PrimitiveSpan(UnsafeBufferPointer(start: primitives, count: Int(count))),
                    projection,
                    Ubiquitty.Tek.StrokeRunSpan(scratch)
                )
            }
            for index in 0..<Int(strokeCount) {
                let run = streams.strokeScratch[index]
                emitSegment(run.start, run.end, beam, halfThickness)
            }
        }
        // Only the display list's runs bloom; everything emitted after them
        // is the pointer's or the pen's.
        let glowingCount = lineCount

        if isGINActive {
            let position = Ubiquitty.Tek.project(projection, ginX, ginY)
            let left = projection.devX + projection.offsetX
            let right = projection.devX + projection.offsetX + projection.scale * Float(projection.tekWidth)
            let top = projection.devY + projection.offsetY
            let bottom = projection.devY + projection.offsetY + projection.scale * Float(projection.tekHeight)
            emitSegment(
                Ubiquitty.Tek.DevicePoint(x: left, y: position.y),
                Ubiquitty.Tek.DevicePoint(x: right, y: position.y),
                cursor,
                halfThickness
            )
            emitSegment(
                Ubiquitty.Tek.DevicePoint(x: position.x, y: top),
                Ubiquitty.Tek.DevicePoint(x: position.x, y: bottom),
                cursor,
                halfThickness
            )
        }

        if drawsBrightPen, let primitives, count > 0 {
            let last = primitives[count - 1]
            let isLine = last.kind == Ubiquitty.Tek.PrimitiveKind.Line
            let pen = Ubiquitty.Tek.project(
                projection,
                Int32(isLine ? last.x1 : last.x0),
                Int32(isLine ? last.y1 : last.y0)
            )
            // A round spot two and a half beam widths across, at the pen.
            let bright = Ubiquitty.Rendering.Vec4(
                x: cursor.x + (1.0 - cursor.x) * 0.7,
                y: cursor.y + (1.0 - cursor.y) * 0.7,
                z: cursor.z + (1.0 - cursor.z) * 0.7,
                w: 1.0
            )
            emitSegment(pen, pen, bright, halfThickness * 2.5)
        }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = Self.premultipliedClear(
            uniforms.defaultBackground,
            opacity: uniforms.backgroundOpacity
        )
        guard let commands = queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return nil
        }
        var frame = uniforms
        withUnsafeBytes(of: &frame) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        if drawsGlow, glowingCount > 0, let glow = pipelines.tektronixGlow, let buffer = streams.lines.buffer,
            let table = fillHaloTable(streams: streams, beamGeometry: beamGeometry, beam: beam),
            let levels = streams.haloLevels.buffer
        {
            var tableHeader = table
            encoder.setRenderPipelineState(glow)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            withUnsafeBytes(of: &tableHeader) { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 2)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
            }
            encoder.setFragmentBuffer(levels, offset: 0, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: glowingCount)
        }
        // The bitmap tier mixes coverage into the target's bytes as the
        // software compositor does; a real font's tier blends in linear light.
        // Where the device refuses a pipeline that reads the render target —
        // the iOS simulator does — the bitmap tier blends instead: the same
        // capsule, a byte off the software reference at its antialiased edge,
        // rather than no beam.
        // Where it cannot read the target, the bitmap tier's beam draws in a
        // second pass on a linear-format view of it, so the blend mixes the
        // stored bytes as the software compositor does.
        if uniforms.bitmapTier != 0, !pipelines.isBitmapTargetReadable, let encodedLine = pipelines.encodedBitmapTekLine,
            let format = pipelines.encodedOverlayFormat, let target = descriptor.colorAttachments[0].texture,
            let view = target.makeTextureView(pixelFormat: format)
        {
            encoder.endEncoding()
            guard lineCount > 0, let buffer = streams.lines.buffer else { return commands }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = view
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let beam = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            withUnsafeBytes(of: &frame) { bytes in
                beam.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                beam.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            beam.setRenderPipelineState(encodedLine)
            beam.setVertexBuffer(buffer, offset: 0, index: 1)
            beam.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lineCount)
            beam.endEncoding()
            return commands
        }
        let bitmapPipeline = uniforms.bitmapTier != 0 ? pipelines.tektronixLineBitmap : nil
        let linePipeline = bitmapPipeline ?? pipelines.tektronixLine
        if lineCount > 0, let line = linePipeline, let buffer = streams.lines.buffer {
            encoder.setRenderPipelineState(line)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lineCount)
        }
        encoder.endEncoding()
        return commands
    }

    /// The glow fragment's view of the halo table: the reach its quads grow
    /// by and how many levels the table holds.
    private struct TekHaloTable {
        var reach: Float
        var levelCount: Int32
    }

    /// Fills the halo table for this frame's beam colour from Core.
    ///
    /// - Parameters:
    ///   - streams: The pass's streams, whose table buffer is filled.
    ///   - beamGeometry: The beam at this frame's backing scale.
    ///   - beam: The beam colour, sRGB-encoded in 0...1.
    /// - Returns: The table's header, or nil when there is no halo to draw.
    private func fillHaloTable(
        streams: TekPassStreams,
        beamGeometry: Ubiquitty.Tek.BeamGeometry,
        beam: Ubiquitty.Rendering.Vec4
    ) -> TekHaloTable? {
        let count = Int(Ubiquitty.Tek.haloLevelCount(beamGeometry))
        guard count > 0, streams.haloLevels.ensure(count), streams.haloLevels.capacity >= count,
            let base = streams.haloLevels.elements(as: Ubiquitty.Tek.HaloLevel.self)
        else {
            return nil
        }
        func byte(_ channel: Float) -> UInt8 {
            UInt8((min(max(channel, 0), 1) * 255).rounded())
        }
        if streams.haloScratch.count < count {
            streams.haloScratch = [Ubiquitty.Tek.HaloLevel](repeating: Ubiquitty.Tek.HaloLevel(), count: count)
        }
        let written = streams.haloScratch.withUnsafeMutableBufferPointer { scratch -> Int32 in
            Ubiquitty.Tek.fillHaloLevels(
                beamGeometry,
                byte(beam.x),
                byte(beam.y),
                byte(beam.z),
                Ubiquitty.Tek.HaloLevelSpan(scratch)
            )
        }
        base.update(from: streams.haloScratch, count: Int(written))
        return TekHaloTable(reach: beamGeometry.haloReach, levelCount: written)
    }
}
