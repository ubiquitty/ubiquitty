// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-frame-encoder.swift — the Swift renderer's passes reach the GPU.
//
// FrameEncoder binds a pipeline, a uniform, an instance buffer and a sheet per
// pass and draws two triangles instanced. Every mistake available there is
// silent: a pass bound to the wrong buffer draws the wrong stream, a uniform
// with a stale viewport puts every quad off-screen, and a pass whose count is
// read from the wrong stream draws nothing. All of it compiles, and all of it
// produces a command buffer that completes without error.
//
// So the target is read back. The pass clears to magenta, which no cell resolves
// to, and the check is that no magenta survives: a pixel still carrying it was
// never covered.
//
// Headless, into an ordinary texture rather than a drawable. The renderer needs
// no window to draw a frame, and a check that needed one could not run here.

import CoreText
import Metal
import UbiquittyCore

// Swift 6.4 imports a lifetime-bound accessor that returns a reference under its
// own name; Swift 6.3 imports it only as `__<name>Unsafe`. Both return the
// unsafe reference the fixture owns, so the driver spells each accessor one way
// on either compiler.
#if !compiler(>=6.4)
extension FrameEncoderFixture {
    /// Borrows the terminal until this fixture is destroyed or moved.
    mutating func terminal() -> Ubiquitty.Terminal { __terminalUnsafe() }
    /// Borrows the renderer until this fixture is destroyed or moved.
    mutating func renderer() -> Ubiquitty.Rendering.SoftwareRenderer { __rendererUnsafe() }
}
#endif

#if FRAME_ENCODER_LIFETIME_NEGATIVE
private func escapedAtlas() -> Ubiquitty.Rendering.SoftwareRenderer.AtlasView {
    var fixture = FrameEncoderFixture(48)
    return fixture.renderer().__monoAtlasUnsafe()
}
#endif

private func uploadCoverage(
    _ view: borrowing Ubiquitty.Rendering.SoftwareRenderer.AtlasView,
    device: MTLDevice
) -> MTLTexture? {
    guard let pixels = view.pixels, view.width > 0, view.height > 0 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm,
        width: Int(view.width),
        height: Int(view.height),
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    // The upload copies the borrowed view before any subsequent glyph fault.
    texture.replace(
        region: MTLRegionMake2D(0, 0, Int(view.width), Int(view.height)),
        mipmapLevel: 0,
        withBytes: pixels,
        bytesPerRow: Int(view.width)
    )
    return texture
}

private func readFrame(
    instances: FrameInstances,
    uniforms: Ubiquitty.Rendering.FrameUniforms,
    sheets: AtlasSheets,
    device: MTLDevice,
    queue: MTLCommandQueue,
    frameEncoder: FrameEncoder
) -> [UInt8]? {
    let width = Int(uniforms.viewportSizeInPixels.x)
    let height = Int(uniforms.viewportSizeInPixels.y)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = .renderTarget
    guard let texture = device.makeTexture(descriptor: descriptor),
        let commands = queue.makeCommandBuffer()
    else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    frameEncoder.encode(instances, uniforms: uniforms, sheets: sheets, into: encoder)
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    guard commands.error == nil else { return nil }
    var result = [UInt8](repeating: 0, count: width * height * 4)
    result.withUnsafeMutableBytes {
        texture.getBytes(
            $0.baseAddress!,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    for index in stride(from: 0, to: result.count, by: 4) {
        result.swapAt(index, index + 2)
    }
    return result
}

private func checkProportionalFrames(
    device: MTLDevice,
    queue: MTLCommandQueue,
    frameEncoder: FrameEncoder,
    check: (String, Bool, String) -> Void
) {
    for columns in [48, 1024] {
        for alignment: UInt8 in [0, 2, 3] {
            var fixture = FrameEncoderFixture(Int32(columns))
            let terminal = fixture.terminal()
            let renderer = fixture.renderer()
            let text =
                "\u{1B}[?25lmono grid stays fixed\r\n\u{1B}]66;p=1:c=20;"
                + String(repeating: "i", count: 48) + "\u{07}\r\n"
                + "\u{1B}[38;2;237;157;43m\u{1B}]66;p=1:c=\(columns):h=\(alignment);"
                + String(repeating: "WWii j ", count: columns == 48 ? 8 : 172) + "W\u{07}"
            text.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
            var options = Ubiquitty.Rendering.TerminalSnapshotOptions()
            options.drawCursor = false
            options.style.unifontScale = 1
            options.viewportSizeInPixels.width = Float(columns * 8)
            options.viewportSizeInPixels.height = 64
            // No line spacing and no letter tracking: the cell this driver measures
            // against is the bitmap face's own, so a nudge to either would move the
            // grid it compares the encoder's output to.
            let metrics = Ubiquitty.Rendering.unifontCellMetricsForScale(1, 0, 0)
            var width: Int32 = 0
            var height: Int32 = 0
            let cpu = Array(
                Ubiquitty.Rendering.renderTerminalSnapshotRGBA(
                    terminal,
                    options,
                    &width,
                    &height,
                    Ubiquitty.Rendering.ChromeLayers(),
                    nil,
                    renderer,
                    nil
                )
            )
            let label = "proportional Metal columns=\(columns) h=\(alignment)"
            var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
            geometry.glyphWidthInPixels = 8
            guard let capture = Ubiquitty.Rendering.FrameCapture.make(),
                capture.capture(terminal, options, metrics, geometry, Ubiquitty.Rendering.ChromeLayers())
            else {
                check(label, false, "Core capture failed")
                continue
            }
            let instances = FrameInstances(device: device)
            let counts = instances.build(capture, backend: renderer.__glyphBackendUnsafe())
            check(
                label + " streams",
                !instances.didTruncate && counts.proportionalGlyphs >= 48 && counts.proportionalStrips > 1,
                "dedicated=\(counts.proportionalGlyphs) tiles=\(counts.proportionalStrips)"
            )
            let mono = uploadCoverage(renderer.__monoAtlasUnsafe(), device: device)
            let wide = uploadCoverage(renderer.__wideAtlasUnsafe(), device: device)
            let proportional = uploadCoverage(renderer.__proportionalAtlasUnsafe(), device: device)
            let proportionalStrip = uploadCoverage(renderer.__proportionalStripAtlasUnsafe(), device: device)
            let ligature = uploadCoverage(renderer.__ligatureAtlasUnsafe(), device: device)
            withExtendedLifetime((mono, wide, proportional, proportionalStrip, ligature)) {
                var sheets = AtlasSheets()
                sheets.mono = mono
                sheets.wide = wide
                sheets.proportional = proportional
                sheets.proportionalStrip = proportionalStrip
                sheets.ligature = ligature
                let uniforms = capture.uniforms()
                let gpu = readFrame(
                    instances: instances,
                    uniforms: uniforms,
                    sheets: sheets,
                    device: device,
                    queue: queue,
                    frameEncoder: frameEncoder
                )
                let differing =
                    gpu.map { pixels in
                        pixels.count == cpu.count ? zip(pixels, cpu).filter { $0 != $1 }.count : -1
                    } ?? -1
                check(
                    label + " exact RGBA",
                    differing == 0 && !cpu.isEmpty && width == columns * 8 && height == 64,
                    "differing bytes=\(differing) cpu=\(Array(cpu.prefix(4))) gpu=\(Array((gpu ?? []).prefix(4)))"
                )
                sheets.proportional = mono
                let wrongAtlas = readFrame(
                    instances: instances,
                    uniforms: uniforms,
                    sheets: sheets,
                    device: device,
                    queue: queue,
                    frameEncoder: frameEncoder
                )
                check(label + " wrong-atlas control", wrongAtlas != nil && wrongAtlas != gpu, "")
                sheets.proportional = proportional
                sheets.proportionalStrip = mono
                let wrongStripAtlas = readFrame(
                    instances: instances,
                    uniforms: uniforms,
                    sheets: sheets,
                    device: device,
                    queue: queue,
                    frameEncoder: frameEncoder
                )
                check(label + " wrong-strip-atlas control", wrongStripAtlas != nil && wrongStripAtlas != gpu, "")
                sheets.proportionalStrip = proportionalStrip
                if counts.proportionalStrips > 0,
                    let strips = instances.proportionalStrips.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
                {
                    // The tail is the last strip that draws. A line spread across its
                    // width ends in a tile past its last glyph, and zeroing that one
                    // changes nothing, which says nothing about whether strips are drawn
                    // at all. So the walk starts at the end and stops at the first
                    // removal the frame shows; a walk that reaches the front is the
                    // failure this control exists to catch.
                    var tailDetected = false
                    var index = Int(counts.proportionalStrips) - 1
                    while index >= 0 && !tailDetected {
                        let original = strips[index]
                        strips[index].sizeInPixels = Ubiquitty.Rendering.Vec2()
                        let missingTile = readFrame(
                            instances: instances,
                            uniforms: uniforms,
                            sheets: sheets,
                            device: device,
                            queue: queue,
                            frameEncoder: frameEncoder
                        )
                        strips[index] = original
                        tailDetected = missingTile != nil && missingTile != gpu
                        index -= 1
                    }
                    check(label + " missing-tile control", tailDetected, "")
                }
            }
            // This read keeps the unique C++ owner alive beyond every completed GPU command.
            check(label + " owner lifetime", fixture.renderer().cellWidth() == 8, "")
        }
    }
}

private struct NativeFrameEvidence {
    let atlas: GlyphAtlas
    let instances: FrameInstances
    let uniforms: Ubiquitty.Rendering.FrameUniforms
    let pixels: [UInt8]

    var sheets: AtlasSheets {
        var result = AtlasSheets()
        result.mono = atlas.texture
        result.wide = atlas.wideTexture
        result.proportional = atlas.proportionalTexture
        result.proportionalStrip = atlas.proportionalStripTexture
        result.ligature = atlas.ligatureTexture
        return result
    }
}

/// Draws the complete source into one unbounded coverage plane, without atlas tiles or Core placements.
private func nativeFrameReference(
    texts: [String],
    font: CTFont,
    regularFont: CTFont,
    monoFont: CTFont,
    columns: Int,
    cellWidth: Int,
    cellHeight: Int,
    alignment: UInt8
) -> [UInt8]? {
    let width = columns * cellWidth
    let height = 4 * cellHeight
    guard
        let reference = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        )
    else { return nil }
    reference.setShouldAntialias(true)
    reference.setFillColor(gray: 1, alpha: 1)
    for (row, text) in texts.enumerated() {
        let baseline = Double(height - (row + 1) * cellHeight) + CTFontGetDescent(monoFont)
        reference.saveGState()
        if row == 0 {
            var characters = Array(text.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(monoFont, &characters, &glyphs, characters.count) else { return nil }
            var positions = characters.indices.map { CGPoint(x: Double($0 * cellWidth), y: baseline) }
            CTFontDrawGlyphs(monoFont, &glyphs, &positions, glyphs.count, reference)
        } else {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): row == 1 ? regularFont : font,
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ]
                )
            )
            let available = Double((row == 1 ? 48 : columns) * cellWidth)
            let naturalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            let rowAlignment: UInt8 = row == 1 ? 0 : alignment
            let utf16 = Array(text.utf16)
            let firstInked = utf16.firstIndex(where: { $0 != 32 }) ?? utf16.count
            let lastInked = utf16.lastIndex(where: { $0 != 32 }).map { $0 + 1 } ?? firstInked
            let gaps = utf16[firstInked..<lastInked].filter { $0 == 32 }.count
            let extra = rowAlignment == 3 && gaps > 0 ? max(0, available - naturalWidth) / Double(gaps) : 0
            let left = rowAlignment == 2 ? max(0, available - naturalWidth) / 2 : 0
            reference.clip(to: CGRect(x: 0, y: 0, width: available, height: Double(height)))
            for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
                let count = CTRunGetGlyphCount(run)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
                CTRunGetPositions(run, CFRangeMake(0, count), &positions)
                CTRunGetStringIndices(run, CFRangeMake(0, count), &indices)
                for index in 0..<count {
                    let boundary = min(max(indices[index], firstInked), lastInked)
                    let precedingGaps = extra > 0 ? utf16[firstInked..<boundary].filter { $0 == 32 }.count : 0
                    positions[index] = positions[index].applying(CTFontGetMatrix(runFont))
                    positions[index].x += left + Double(precedingGaps) * extra
                    positions[index].y += baseline
                }
                CTFontDrawGlyphs(runFont, &glyphs, &positions, count, reference)
            }
        }
        reference.restoreGState()
    }
    guard let coverage = reference.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    // White text over opaque black is the coverage byte in every encoded RGB channel.
    for index in 0..<(width * height) {
        for channel in 0..<3 { rgba[4 * index + channel] = coverage[index] }
    }
    return rgba
}

private func checkNativeProportionalFrames(
    device: MTLDevice,
    queue: MTLCommandQueue,
    frameEncoder: FrameEncoder,
    check: (String, Bool, String) -> Void
) {
    for columns in [48, 1024] {
        for alignment: UInt8 in [0, 2, 3] {
            for face in [Ubiquitty.Rendering.FontFace.Regular, .Italic] {
                var retained: NativeFrameEvidence?
                for scale in [1, 2] {
                    let label = "CoreText Metal columns=\(columns) h=\(alignment) face=\(face.rawValue) scale=\(scale)"
                    let cellWidth = 8 * scale
                    let cellHeight = 16 * scale
                    guard let faces = FontFaces(family: "Menlo", size: CGFloat(12 * scale), pixelsPerPoint: CGFloat(scale)) else {
                        check(label, false, "native face unavailable")
                        continue
                    }
                    var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
                    geometry.columns = 16
                    geometry.glyphWidthInPixels = Int32(cellWidth)
                    geometry.glyphMarginInPixels = Ubiquitty.IntSize(width: Int32(2 * scale), height: Int32(4 * scale))
                    geometry.slotWidthInPixels = Int32(cellWidth + 4 * scale + 1)
                    geometry.slotHeightInPixels = Int32(cellHeight + 8 * scale)
                    geometry.wideSlotWidthInPixels = Int32(2 * cellWidth + 4 * scale + 1)
                    geometry.wideSlotHeightInPixels = geometry.slotHeightInPixels
                    geometry.ligatureSlotWidthInPixels = Int32(128 * scale)
                    geometry.ligatureSlotHeightInPixels = geometry.slotHeightInPixels
                    geometry.referenceAdvanceInPixels = Float(cellWidth)
                    geometry.referenceLineHeightInPixels = Float(cellHeight)
                    let baseline = Double(4 * scale) + CTFontGetDescent(faces[.Regular])
                    let fontProviderUploader = AtlasUploader(queue: queue)
                    guard
                        let atlas = GlyphAtlas(
                            device: device,
                            faces: faces,
                            geometry: geometry,
                            slotCapacity: 4096,
                            baselinePenInPixels: baseline,
                            wideGlyphBoostCap: 1,
                            unifontScale: 0
                        ),
                        let fontProvider = LigatureSheet(
                            device: device,
                            uploader: fontProviderUploader,
                            faces: faces,
                            slotWidthInPixels: 128 * scale,
                            slotHeightInPixels: Int(geometry.slotHeightInPixels),
                            marginXInPixels: Double(2 * scale),
                            baselinePenInPixels: baseline,
                            cellAdvanceInPixels: Double(cellWidth),
                            featureSpec: "",
                            doesLigate: false,
                            maxTextureDimension: device.maximumTexture2DDimension
                        )
                    else {
                        check(label, false, "native atlas unavailable")
                        continue
                    }
                    let texts = [
                        "mono grid stays fixed",
                        String(repeating: "1", count: 48),
                        String(repeating: "i", count: 512) + String(repeating: "W", count: 88),
                        String(repeating: " i 𝄞 W ", count: columns == 48 ? 8 : 80),
                    ]
                    var fixture = FrameEncoderFixture(Int32(columns))
                    let terminal = fixture.terminal()
                    let slant = face == .Italic ? "\u{1B}[3m" : ""
                    let text =
                        "\u{1B}[?25l\u{1B}[38;2;255;255;255m\u{1B}[48;2;0;0;0m\u{1B}[2J" + texts[0] + "\r\n"
                        + "\u{1B}]66;p=1:c=48;" + texts[1] + "\u{07}\r\n"
                        + slant + "\u{1B}]66;p=1:c=\(columns):h=\(alignment);" + texts[2] + "\u{07}\r\n"
                        + "\u{1B}]66;p=1:c=\(columns):h=\(alignment);" + texts[3] + "\u{07}"
                    text.withCString { Ubiquitty.processBytes(terminal, std.string_view($0)) }
                    var metrics = Ubiquitty.Rendering.CellMetrics()
                    metrics.cellWidth = Float(cellWidth)
                    metrics.cellHeight = Float(cellHeight)
                    metrics.deviceScale = Float(scale)
                    metrics.atlasToDevicePixels = 1
                    var options = Ubiquitty.Rendering.TerminalSnapshotOptions()
                    options.drawCursor = false
                    options.shouldFloorSubpixelPhase = true
                    options.hasRasterTiers = true
                    options.subpixelPhaseCount = Int32(atlas.subpixelPhaseCount)
                    options.viewportSizeInPixels = Ubiquitty.FloatSize(width: Float(columns * cellWidth), height: Float(4 * cellHeight))
                    guard let capture = Ubiquitty.Rendering.FrameCapture.make(),
                        capture.capture(terminal, options, metrics, geometry, Ubiquitty.Rendering.ChromeLayers()),
                        let expected = nativeFrameReference(
                            texts: texts,
                            font: fontProvider.proportionalFont(forFace: face),
                            regularFont: fontProvider.proportionalFont(forFace: .Regular),
                            monoFont: faces[.Regular],
                            columns: columns,
                            cellWidth: cellWidth,
                            cellHeight: cellHeight,
                            alignment: alignment
                        )
                    else {
                        check(label, false, "capture or reference unavailable")
                        continue
                    }
                    let backendOwner = GlyphBackendContext(source: atlas)
                    var backend = Ubiquitty.Rendering.GlyphBackend()
                    backendOwner.fillBackend(into: &backend)
                    let instances = FrameInstances(device: device)
                    let counts = instances.build(capture, backend: backend)
                    atlas.flushStagedUploads()
                    var sheets = AtlasSheets()
                    sheets.mono = atlas.texture
                    sheets.wide = atlas.wideTexture
                    sheets.proportional = atlas.proportionalTexture
                    sheets.proportionalStrip = atlas.proportionalStripTexture
                    sheets.ligature = atlas.ligatureTexture
                    let uniforms = capture.uniforms()
                    check(
                        label + " routes",
                        !instances.didTruncate && counts.proportionalGlyphs >= 48 && counts.proportionalStrips >= 2,
                        "dedicated=\(counts.proportionalGlyphs) tiles=\(counts.proportionalStrips)"
                    )
                    guard
                        let pixels = readFrame(
                            instances: instances,
                            uniforms: uniforms,
                            sheets: sheets,
                            device: device,
                            queue: atlas.commandQueue,
                            frameEncoder: frameEncoder
                        )
                    else {
                        check(label, false, "GPU readback failed")
                        continue
                    }
                    let differing = zip(pixels, expected).filter { $0 != $1 }.count
                    check(
                        label + " independent RGBA",
                        pixels.count == expected.count && differing == 0,
                        "differing bytes=\(differing)"
                    )
                    if differing != 0 {
                        for row in 0..<4 {
                            let begin = row * cellHeight * columns * cellWidth * 4
                            let end = begin + cellHeight * columns * cellWidth * 4
                            let differences = zip(pixels[begin..<end], expected[begin..<end]).filter { $0 != $1 }.count
                            print("    row=\(row) differing=\(differences)")
                        }
                    }
                    var wrong = sheets
                    wrong.proportional = atlas.texture
                    let wrongPixels = readFrame(
                        instances: instances,
                        uniforms: uniforms,
                        sheets: wrong,
                        device: device,
                        queue: queue,
                        frameEncoder: frameEncoder
                    )
                    check(label + " wrong-atlas control", wrongPixels != nil && wrongPixels != pixels, "")
                    wrong = sheets
                    wrong.proportionalStrip = atlas.texture
                    let wrongStripPixels = readFrame(
                        instances: instances,
                        uniforms: uniforms,
                        sheets: wrong,
                        device: device,
                        queue: queue,
                        frameEncoder: frameEncoder
                    )
                    check(label + " wrong-strip-atlas control", wrongStripPixels != nil && wrongStripPixels != pixels, "")
                    if counts.proportionalStrips > 0,
                        let strips = instances.proportionalStrips.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
                    {
                        // The tail is the last strip that draws. A line spread across its
                        // width ends in a tile past its last glyph, and zeroing that one
                        // changes nothing, which says nothing about whether strips are drawn
                        // at all. So the walk starts at the end and stops at the first
                        // removal the frame shows; a walk that reaches the front is the
                        // failure this control exists to catch.
                        var tailDetected = false
                        var index = Int(counts.proportionalStrips) - 1
                        while index >= 0 && !tailDetected {
                            let saved = strips[index]
                            strips[index].sizeInPixels = Ubiquitty.Rendering.Vec2()
                            let missing = readFrame(
                                instances: instances,
                                uniforms: uniforms,
                                sheets: sheets,
                                device: device,
                                queue: queue,
                                frameEncoder: frameEncoder
                            )
                            strips[index] = saved
                            tailDetected = missing != nil && missing != pixels
                            index -= 1
                        }
                        check(label + " missing-tail control", tailDetected, "")
                    }
                    if let retained {
                        let oldPixels = readFrame(
                            instances: retained.instances,
                            uniforms: retained.uniforms,
                            sheets: retained.sheets,
                            device: device,
                            queue: queue,
                            frameEncoder: frameEncoder
                        )
                        check(
                            label + " retained old resource",
                            retained.sheets.proportional !== sheets.proportional
                                && retained.sheets.proportionalStrip !== sheets.proportionalStrip
                                && retained.sheets.ligature !== sheets.ligature && oldPixels == retained.pixels,
                            ""
                        )
                        wrong = sheets
                        wrong.proportional = retained.sheets.proportional
                        wrong.proportionalStrip = retained.sheets.proportionalStrip
                        wrong.ligature = retained.sheets.ligature
                        let stale = readFrame(
                            instances: instances,
                            uniforms: uniforms,
                            sheets: wrong,
                            device: device,
                            queue: queue,
                            frameEncoder: frameEncoder
                        )
                        check(label + " stale-scale control", stale != nil && stale != pixels, "")
                    }
                    retained = NativeFrameEvidence(atlas: atlas, instances: instances, uniforms: uniforms, pixels: pixels)
                    withExtendedLifetime((backendOwner, atlas, fontProvider)) {
                        check(label + " source lifetime", fixture.terminal().columns == columns, "")
                    }
                }
            }
        }
    }
}

final class StubGlyphSource: GlyphSource {
    func beginFrame() {}
    var primaryFacePitch: Ubiquitty.Rendering.FontMetrics.FacePitch { .Fixed }
    func shapePrimaryRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] { [] }
    func bindMonoAtlas(into binding: inout Ubiquitty.Rendering.MonoAtlasBinding) { binding.slotCapacity = 256 }
    func monoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        Ubiquitty.Rendering.AtlasGlyph()
    }
    func rasteriseMonoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        slot: Int32
    ) -> Bool { true }
    func stageMonoCoverage(_ coverage: Ubiquitty.Rendering.CoveragePlaneSpan, slot: Int32) -> Bool { true }
}

@main
enum EncoderDriver {
    static func main() {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  ok   \(label) \(detail)")
            } else {
                failures += 1
                print("  FAIL \(label) \(detail)")
            }
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("drive-frame-encoder: no Metal device")
            exit(2)
        }
        let libraryPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        guard let library = try? device.makeLibrary(URL: URL(fileURLWithPath: libraryPath)) else {
            print("drive-frame-encoder: cannot load \(libraryPath)")
            exit(2)
        }
        guard let samplers = MetalSamplers(device: device) else {
            print("drive-frame-encoder: samplers unavailable")
            exit(2)
        }
        let format = MTLPixelFormat.bgra8Unorm_srgb
        let pipelines = MetalPipelines(device: device, pixelFormat: format, library: library)
        check("the cell pipeline built", pipelines.cell != nil)

        let rows = 24
        let columns = 80
        let cellWidth = 10
        let cellHeight = 20
        let width = columns * cellWidth
        let height = rows * cellHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else {
            print("drive-frame-encoder: no target texture")
            exit(2)
        }

        let instances = FrameInstances(device: device)
        let box = GlyphBackendContext(source: StubGlyphSource())
        var backend = Ubiquitty.Rendering.GlyphBackend()
        box.fillBackend(into: &backend)

        var cells = [Ubiquitty.Cell](repeating: Ubiquitty.Cell(), count: rows * columns)
        for i in 0..<cells.count { cells[i].codePoint = 0x20 }
        var palette = Ubiquitty.TermPalette()

        cells.withUnsafeBufferPointer { cellBuffer in
            withUnsafePointer(to: &palette) { palettePointer in
                var inputs = Ubiquitty.Rendering.BuildInputs()
                inputs.cells = cellBuffer.baseAddress
                inputs.rows = Int32(rows)
                inputs.columns = Int32(columns)
                inputs.palette = palettePointer
                inputs.metrics.cellWidth = Float(cellWidth)
                inputs.metrics.cellHeight = Float(cellHeight)
                inputs.metrics.deviceScale = 1.0
                inputs.metrics.atlasToDevicePixels = 1.0
                let counts = instances.build(inputs, backend: backend)
                check("Core built the cells", counts.cells == rows * columns, "\(counts.cells)")
            }
        }

        var uniforms = Ubiquitty.Rendering.FrameUniforms()
        uniforms.viewportSizeInPixels.x = Float(width)
        uniforms.viewportSizeInPixels.y = Float(height)
        uniforms.cellSizeInPixels.x = Float(cellWidth)
        uniforms.cellSizeInPixels.y = Float(cellHeight)
        uniforms.backgroundOpacity = 1.0
        // The default-background opacity factor every frame fold sets to one;
        // zero asks for transparent default-background cells.
        uniforms.defaultBackground = Ubiquitty.Rendering.Vec4(x: 0, y: 0, z: 0, w: 1)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        // Magenta: no cell resolves to it, so any pixel still carrying it was
        // never covered by the cell pass.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let commands = queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else {
            print("drive-frame-encoder: no encoder")
            exit(2)
        }
        FrameEncoder(pipelines: pipelines, samplers: samplers)
            .encode(instances, uniforms: uniforms, sheets: AtlasSheets(), into: encoder)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        check("the command buffer completed", commands.error == nil, "\(commands.error?.localizedDescription ?? "")")

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        var cleared = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] == 255 && pixels[i + 1] == 0 && pixels[i + 2] == 255 {
            cleared += 1
        }
        let covered = width * height - cleared
        check(
            "the cell pass covered the target",
            cleared == 0,
            "\(covered)/\(width * height) pixels painted"
        )

        checkRichTextFrames(device: device, check: check)
        checkProportionalFrames(
            device: device,
            queue: queue,
            frameEncoder: FrameEncoder(pipelines: pipelines, samplers: samplers),
            check: check
        )
        checkNativeProportionalFrames(
            device: device,
            queue: queue,
            frameEncoder: FrameEncoder(pipelines: pipelines, samplers: samplers),
            check: check
        )

        print(failures == 0 ? "drive-frame-encoder: ok" : "drive-frame-encoder: FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
