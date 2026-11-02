// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-terminal-renderer.swift — one render call, cells to pixels.
//
// The four drivers beside this one each cover a piece: the catalogue resolves
// faces, the rasteriser inks a plane, the atlas maps slots, the instances come
// from Core and the encoder draws them. Every one can pass while the assembly
// is wrong — a renderer that never opens the glyph frame, binds the sheet it
// did not fill, or encodes before building produces a texture either way.
//
// So this drives the whole object once and reads the target back. A frame of
// 'A' has to paint every pixel of the grid, and the glyph pass has to put ink
// somewhere: cells alone would cover the target too, which is why the check is
// not only that the magenta is gone.

import CoreText
import Metal
import UbiquittyCore

@testable import SurfaceOverlayModel

@main
enum TerminalRendererDriver {
    @MainActor
    static func main() {
        runTerminalRendererDriver()
    }
}

// The synchronous driver has no actor hops. Keeping its body outside the
// `@main` type prevents actor-isolated captures of the non-Sendable Core handles.
private func runTerminalRendererDriver() {
    var failures = 0
    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  ok   \(label) \(detail)")
        } else {
            failures += 1
            print("  FAIL \(label) \(detail)")
        }
    }

    let libraryPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    guard let device = MTLCreateSystemDefaultDevice(),
        let library = try? device.makeLibrary(URL: URL(fileURLWithPath: libraryPath)),
        let faces = FontFaces(family: "Menlo", size: 16.0, pixelsPerPoint: 1)
    else {
        print("drive-terminal-renderer: no device, shaders or font")
        exit(2)
    }

    var geometry = Ubiquitty.Rendering.GlyphSlotGeometry()
    geometry.columns = 16
    geometry.slotWidthInPixels = 16
    geometry.slotHeightInPixels = 24
    geometry.glyphWidthInPixels = 12
    geometry.glyphMarginInPixels.width = 2
    geometry.glyphMarginInPixels.height = 4

    let format = MTLPixelFormat.bgra8Unorm
    guard
        let renderer = TerminalRenderer(
            device: device,
            pixelFormat: format,
            pipelines: MetalPipelines(device: device, pixelFormat: format, library: library),
            faces: faces,
            geometry: geometry,
            slotCapacity: 256,
            baselinePenInPixels: Double(geometry.glyphMarginInPixels.height) + CTFontGetDescent(faces[.Regular]),
            // Core's own default, so this driver draws what a run with the
            // setting untouched draws.
            wideGlyphBoostCap: 1.1,
            unifontScale: 0
        )
    else {
        print("drive-terminal-renderer: renderer would not build")
        exit(2)
    }

    func sharedRenderer(_ key: String) -> TerminalRenderer? {
        TerminalRenderer(
            device: device,
            pixelFormat: format,
            pipelines: renderer.pipelines,
            faces: faces,
            geometry: geometry,
            slotCapacity: 256,
            baselinePenInPixels: Double(geometry.glyphMarginInPixels.height) + CTFontGetDescent(faces[.Regular]),
            wideGlyphBoostCap: 1.1,
            unifontScale: 0,
            sheetKey: key
        )
    }
    guard let firstShared = sharedRenderer("driver-shared-glyph-order"),
        let secondShared = sharedRenderer("driver-shared-glyph-order"),
        let independent = sharedRenderer("driver-independent-glyph-order")
    else {
        print("drive-terminal-renderer: shared renderers would not build")
        exit(2)
    }
    check("matching renderers share glyph storage", firstShared.atlas === secondShared.atlas)
    check("shared glyph uploads and every consumer have one command order", firstShared.queue === secondShared.queue)
    check("independent glyph storage retains an independent queue", firstShared.queue !== independent.queue)

    let rows = 12
    let columns = 40
    let cellWidth = 12
    let cellHeight = 24
    let width = columns * cellWidth
    let height = rows * cellHeight

    // The image store stages while Core's model lock is held, then uploads
    // after that lock is released. Exercise that split repeatedly at -O:
    // the RGB source changes on every pass, so a stale or escaped scratch
    // pointer shows up as the wrong pixel even when the texture is reused.
    let imageStore = SurfaceImageStore(device: device)
    let imageTerminal = Ubiquitty.Terminal()
    Ubiquitty.resize(imageTerminal, Int32(rows), Int32(columns), .Reflow, .top, .Settled)
    let red = [UInt8](arrayLiteral: 255, 0, 0, 255)
    let green = [UInt8](arrayLiteral: 0, 255, 0, 255)
    var allRGB24UploadsMatched = true
    let repeatedUploadCount = 256
    for iteration in 0..<repeatedUploadCount {
        let payload = iteration.isMultiple(of: 2) ? "/wAA" : "AP8A"
        let command = "\u{1b}_Ga=T,t=d,f=24,s=1,v=1,c=1,r=1,C=1,i=9001;\(payload)\u{1b}\\"
        command.withCString { bytes in
            Ubiquitty.processBytes(imageTerminal, std.string_view(bytes))
        }
        let layer = imageStore.layer(
            for: imageTerminal,
            cellSizeInPixels: Ubiquitty.FloatSize(width: Float(cellWidth), height: Float(cellHeight)),
            origin: Ubiquitty.FloatPoint(x: 0, y: 0),
            scale: 1,
            viewOffset: 0,
            drawableSizeInPixels: Ubiquitty.FloatSize(width: Float(width), height: Float(height)),
            isHoldingForResize: false
        )
        imageStore.uploadStagedPixels()
        guard let texture = layer?.textures.first ?? nil else {
            allRGB24UploadsMatched = false
            continue
        }
        var uploaded = [UInt8](repeating: 0, count: 4)
        uploaded.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 4,
                from: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0
            )
        }
        allRGB24UploadsMatched = allRGB24UploadsMatched && uploaded == (iteration.isMultiple(of: 2) ? red : green)
    }
    check(
        "RGB24 staging survives repeated optimized uploads",
        allRGB24UploadsMatched && imageStore.offLockUploadCount == repeatedUploadCount,
        "\(imageStore.offLockUploadCount) of \(repeatedUploadCount)"
    )

    let maximumImageBytes = Int(Ubiquitty.Image.maxDecodedImageBytes)
    check(
        "empty RGB24 staging is refused",
        SurfaceImageStore.stagingByteCounts(width: 0, height: 1, format: 24, sourceLength: 0) == nil
    )
    check(
        "a short RGB24 payload is refused",
        SurfaceImageStore.stagingByteCounts(width: 2, height: 1, format: 24, sourceLength: 5) == nil
    )
    let maximumCounts = SurfaceImageStore.stagingByteCounts(
        width: 16_384,
        height: 1_024,
        format: 32,
        sourceLength: maximumImageBytes
    )
    check(
        "the maximum decoded payload has exact staging bounds",
        maximumCounts?.source == maximumImageBytes && maximumCounts?.rgba == maximumImageBytes
    )
    check(
        "a payload beyond the decoded-image ceiling is refused",
        SurfaceImageStore.stagingByteCounts(
            width: 16_384,
            height: 1_025,
            format: 32,
            sourceLength: maximumImageBytes + 65_536
        ) == nil
    )
    check(
        "staging arithmetic refuses overflow",
        SurfaceImageStore.stagingByteCounts(
            width: Int.max,
            height: 2,
            format: 24,
            sourceLength: Int.max
        ) == nil
    )

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else {
        print("drive-terminal-renderer: no target")
        exit(2)
    }

    var cells = [Ubiquitty.Cell](repeating: Ubiquitty.Cell(), count: rows * columns)
    for i in 0..<cells.count {
        cells[i].codePoint = 0x41
    }
    var palette = Ubiquitty.TermPalette()

    var uniforms = Ubiquitty.Rendering.FrameUniforms()
    uniforms.viewportSizeInPixels.x = Float(width)
    uniforms.viewportSizeInPixels.y = Float(height)
    uniforms.cellSizeInPixels.x = Float(cellWidth)
    uniforms.cellSizeInPixels.y = Float(cellHeight)
    uniforms.backgroundOpacity = 1.0
    // The default-background opacity factor, which every frame fold sets
    // to one. Left at the zero a fresh struct carries, it asks the cell
    // pass for fully transparent default-background cells, and the blit
    // then shows the clear colour through every one of them.
    uniforms.defaultBackground = Ubiquitty.Rendering.Vec4(x: 0, y: 0, z: 0, w: 1)

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
    pass.colorAttachments[0].storeAction = .store

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

            let commands = renderer.render(inputs, uniforms: uniforms, into: pass)
            check("the frame committed", commands != nil)
            commands?.waitUntilCompleted()
            check("no command buffer error", commands?.error == nil)
        }
    }

    check(
        "Core built every cell",
        renderer.counts.cells == rows * columns,
        "\(renderer.counts.cells) of \(rows * columns)"
    )
    check("nothing truncated", !renderer.didTruncate)

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
    check("the grid covered the target", cleared == 0, "\(width * height - cleared) painted")

    // The one-call surface, end to end: a terminal in, pixels out. This is
    // the path a frontend uses, and it is the only case here that proves the
    // capture, the build and the encode agree — the case above hands over
    // inputs a caller assembled, so it cannot fail if the capture is wrong.
    let terminal = Ubiquitty.Terminal()
    Ubiquitty.resize(terminal, Int32(rows), Int32(columns), .Reflow, .top, .Settled)
    "hello"
        .withCString { bytes in
            Ubiquitty.processBytes(terminal, std.string_view(bytes))
        }
    var captureMetrics = Ubiquitty.Rendering.CellMetrics()
    captureMetrics.cellWidth = Float(cellWidth)
    captureMetrics.cellHeight = Float(cellHeight)
    captureMetrics.deviceScale = 1.0
    captureMetrics.atlasToDevicePixels = 1.0
    let options = Ubiquitty.Rendering.TerminalSnapshotOptions()

    if let second = device.makeTexture(descriptor: descriptor) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = second
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        let commands = renderer.render(
            terminal,
            options: options,
            metrics: captureMetrics,
            uniforms: uniforms,
            into: pass
        )
        commands?.waitUntilCompleted()
        check("the terminal frame committed", commands != nil)
        // The grid's own cells, with the cursor's tail excluded. The builder
        // walks the grid without the cursor and then re-emits its claim at the
        // TAIL of each stream, so a focused block adds instances that are not
        // grid coverage — counting them as coverage would let a frame that
        // missed a cell pass on the strength of the cursor.
        let gridCells = renderer.counts.cells - renderer.counts.cursorTier.cells
        check(
            "Core captured the grid Swift never assembled",
            gridCells == rows * columns,
            "\(gridCells) of \(rows * columns), cursor tail \(renderer.counts.cursorTier.cells)"
        )
        check("the terminal frame truncated nothing", !renderer.didTruncate)
    } else {
        check("the second target allocated", false)
    }

    // Colours, asserted for the first time. Every case above counts painted
    // pixels, and a frame that paints every quad in the wrong colour passes
    // all of them — which is exactly what the app's first genuine Swift
    // frame did. A red-background run of spaces has no ink to composite, so
    // the cell pass must show pure background: red pixels, or the arm is
    // reading the instance wrong.
    "\u{1B}[41m      \u{1B}[0m"
        .withCString { bytes in
            Ubiquitty.processBytes(terminal, std.string_view(bytes))
        }
    if let third = device.makeTexture(descriptor: descriptor) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = third
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        let commands = renderer.render(
            terminal,
            options: options,
            metrics: captureMetrics,
            uniforms: uniforms,
            into: pass
        )
        commands?.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            third.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        var red = 0
        for i in stride(from: 0, to: pixels.count, by: 4)
        where pixels[i + 2] > 150 && pixels[i + 1] < 80 && pixels[i] < 80 {
            red += 1
        }
        check(
            "a red background run shows red pixels",
            red >= cellWidth * cellHeight / 2,
            "red=\(red) needed=\(cellWidth * cellHeight / 2)"
        )
    } else {
        check("the third target allocated", false)
    }

    let selection = SurfaceSelectionModel()
    var overlayOptions = Ubiquitty.Rendering.TerminalSnapshotOptions()
    overlayOptions.drawCursor = false
    overlayOptions.viewportSizeInPixels = Ubiquitty.FloatSize(width: Float(width), height: Float(height))
    var overlayCalls = 0
    func checkEmptyTiers(_ options: Ubiquitty.Rendering.TerminalSnapshotOptions) {
        check("empty focused tier", options.searchMatchSpans == nil && options.searchMatchSpanCount == 0)
        check("empty other-search tier", options.otherSearchMatchSpans == nil && options.otherSearchMatchSpanCount == 0)
        check("empty trigger tier", options.triggerHighlightSpans == nil && options.triggerHighlightSpanCount == 0)
        check("empty DEC tier", options.hiliteRegionSpans == nil && options.hiliteRegionSpanCount == 0)
    }
    let emptyResult = selection.withOverlayTiers(terminal, viewOffset: 0, rows: rows, options: overlayOptions) { options in
        overlayCalls += 1
        checkEmptyTiers(options)
        return 42
    }
    check("empty tiers invoke the consumer once and return its result", overlayCalls == 1 && emptyResult == 42)

    func publishSearch(_ terminal: Ubiquitty.Terminal, pattern: String) -> Int32 {
        var request = Ubiquitty.Search.Request()
        request.pattern = std.string(pattern)
        request.form = .Regex
        request.sensitivity = .Sensitive
        request.normalization = Ubiquitty.Screen.ScrollSearch.normalizationForm()
        let status = Ubiquitty.Search.searchScrollbackAndWait(terminal, request, 30_000)
        check("overlay search completed", status.isComplete && !status.isPatternInvalid)
        return Int32(clamping: status.foundCount)
    }
    func denseTerminal(matches: Int) -> Ubiquitty.Terminal {
        let terminal = Ubiquitty.Terminal()
        Ubiquitty.resize(terminal, 3, 40, .Reflow, .top, .Settled)
        let words = Array("ABCDEFGHIJKLMNOP").prefix(matches).map { "\($0)x" }
        for word in words {
            let added = word.withCString { pattern in
                "highlight:red"
                    .withCString { action in
                        Ubiquitty.Triggers.addRuleSpec(terminal, pattern, action, .Sensitive)
                    }
            }
            check("dense trigger rule accepted", added, word)
        }
        (words.joined(separator: " ") + "\r\n\u{1B}[?1001h\u{1B}[1;2;1;1;3T")
            .withCString { bytes in
                Ubiquitty.processBytes(terminal, std.string_view(bytes))
            }
        let found = publishSearch(terminal, pattern: "[A-Z]x")
        check("all dense search matches published", found == matches, "\(found) of \(matches)")
        check("all dense trigger matches published", Ubiquitty.Triggers.highlightCount(terminal) == matches)
        return terminal
    }

    func spanKeys(_ spans: Ubiquitty.Rendering.ConstRowSpans) -> Set<String> {
        Set(spans.map { "\($0.visibleRow):\($0.column0):\($0.column1)" })
    }
    selection.spanScratch = Array(repeating: Ubiquitty.Rendering.SelectionRowSpan(), count: 3)
    selection.spanScratch[0].visibleRow = 1
    selection.spanScratch[0].column0 = 0
    selection.spanScratch[0].column1 = 2
    func encodeDense(_ terminal: Ubiquitty.Terminal, matches: Int) -> [UInt] {
        selection.withOverlayTiers(terminal, viewOffset: 0, rows: 3, options: overlayOptions) { options in
            check("one focused match survives", options.searchMatchSpanCount == 1)
            check("all other matches survive one dense row", options.otherSearchMatchSpanCount == matches - 1)
            check("all triggers survive one dense row", options.triggerHighlightSpanCount == matches)
            check("the DEC band covers every row", options.hiliteRegionSpanCount == 3)
            let expected = Set((0..<matches).map { "0:\($0 * 3):\($0 * 3 + 1)" })
            let focused = spanKeys(.init(Span(_unsafeStart: options.searchMatchSpans, count: Int(options.searchMatchSpanCount))))
            let others = spanKeys(.init(Span(_unsafeStart: options.otherSearchMatchSpans, count: Int(options.otherSearchMatchSpanCount))))
            check(
                "focused and other matches partition the dense row",
                focused.isDisjoint(with: others) && focused.union(others) == expected
            )
            check(
                "trigger spans preserve their exact columns",
                spanKeys(.init(Span(_unsafeStart: options.triggerHighlightSpans, count: Int(options.triggerHighlightSpanCount))))
                    == expected
            )
            check("focused match carries its tint", options.searchMatchHighlight.w > 0)
            check("overlay collection preserves unrelated options", !options.drawCursor)

            // The selection borrow is nested just as in SurfaceRenderer;
            // checked exclusivity must permit the independent scratch tiers.
            selection.spanScratch.withUnsafeBufferPointer { spans in
                var options = options
                options.selectionSpans = spans.baseAddress
                options.selectionSpanCount = 1
                // Building and encoding are separate steps: buildFrame answers with
                // the frame to present, encode puts it in the pass. A caller that
                // owns presentation still ends with an uncommitted buffer, which is
                // what the commit below depends on.
                let commands = renderer.buildFrame(terminal, options: options, metrics: captureMetrics)
                    .flatMap { renderer.encode($0, into: pass) }
                check("borrowed overlay frame encoded", commands != nil)
                check("encoding consumes every tinted span", renderer.counts.overlays >= UInt(2 * matches + 2))
                check("dense overlays do not truncate the frame", !renderer.didTruncate)
                commands?.commit()
                commands?.waitUntilCompleted()
                check("borrowed overlay frame completed without an error", commands?.error == nil)
            }
            // Only address values leave the borrow, never dereferenceable pointers.
            return [options.searchMatchSpans, options.otherSearchMatchSpans, options.triggerHighlightSpans, options.hiliteRegionSpans]
                .map { UInt(bitPattern: $0) }
        }
    }
    let dense = denseTerminal(matches: 8)
    let firstAddresses = encodeDense(dense, matches: 8)
    check("steady frames reuse every overlay buffer", encodeDense(dense, matches: 8) == firstAddresses)
    let denser = denseTerminal(matches: 12)
    let grownAddresses = encodeDense(denser, matches: 12)
    check("grown overlay buffers are reused", encodeDense(denser, matches: 12) == grownAddresses)
    check("smaller tiers retain their grown capacity", encodeDense(dense, matches: 8) == grownAddresses)

    let wrapped = Ubiquitty.Terminal()
    Ubiquitty.resize(wrapped, 3, 8, .Reflow, .top, .Settled)
    "abcdefghijklmnop".withCString { Ubiquitty.processBytes(wrapped, std.string_view($0)) }
    check("wrapped search is one logical match", publishSearch(wrapped, pattern: "abcdefghijklmnop") == 1)
    selection.withOverlayTiers(wrapped, viewOffset: 0, rows: 3, options: overlayOptions) { options in
        check("focused search preserves both wrapped spans", options.searchMatchSpanCount == 2)
        check(
            "focused wrapped spans keep their rows",
            spanKeys(.init(Span(_unsafeStart: options.searchMatchSpans, count: Int(options.searchMatchSpanCount)))) == ["0:0:7", "1:0:7"]
        )
        check("a wrapped focused match is absent from the other tier", options.otherSearchMatchSpanCount == 0)
    }

    // Nonzero incoming counts and retained scratch must not leak a tier
    // into a zero-row capture or an empty terminal.
    overlayOptions.searchMatchSpanCount = 99
    overlayOptions.otherSearchMatchSpanCount = 99
    overlayOptions.triggerHighlightSpanCount = 99
    overlayOptions.hiliteRegionSpanCount = 99
    for visibleRows in [0, -1] {
        let result = selection.withOverlayTiers(dense, viewOffset: 0, rows: visibleRows, options: overlayOptions) { options in
            overlayCalls += 1
            checkEmptyTiers(options)
            return visibleRows
        }
        check("nonpositive rows return the consumer's result", result == visibleRows)
    }
    selection.withOverlayTiers(terminal, viewOffset: 0, rows: rows, options: overlayOptions) { options in
        overlayCalls += 1
        checkEmptyTiers(options)
    }
    check("zero and empty paths each invoke the consumer once", overlayCalls == 4)
    check("the caller's options remain unchanged", overlayOptions.searchMatchSpanCount == 99)
    check("empty frames retain overlay capacity", encodeDense(denser, matches: 12) == grownAddresses)

    print(failures == 0 ? "drive-terminal-renderer: ok" : "drive-terminal-renderer: FAILED \(failures)")
    exit(failures == 0 ? 0 : 1)
}
