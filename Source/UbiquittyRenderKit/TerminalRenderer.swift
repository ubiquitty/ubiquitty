// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalRenderer.swift — one frame, from Core's cells to the drawable.
//
// The whole renderer in one object, and a thin one. It owns the
// device-scoped things a frame needs — pipelines, samplers, the glyph sheet, the
// instance streams — and its render entry point does three things in order: ask
// Core to build the instances, encode the passes, commit.
//
// Nothing here decides what a frame looks like. Which glyph a cell gets, where a
// rule sits, what colour a selection resolves to, whether a row is doubled — all
// of that is `buildCellInstances`, and this file would be the wrong place to
// second-guess any of it. What it contributes is the part Core cannot: Metal
// memory, a CoreText sheet, and the order the passes composite in.
//
// That thinness is the point of the design rather than a side effect of it. A
// renderer that owns the frame's decisions has to be ported per platform and
// re-verified per platform; one that owns only the GPU is the same object on
// every backend with the middle swapped out.

import CoreGraphics
import Metal
import UbiquittyCore

/// Draws terminal frames through Core.
///
/// One per view. Not thread-safe: the streams and the glyph sheet are reused
/// frame to frame, which is what keeps a steady-state frame free of allocation.
package final class TerminalRenderer {
    let queue: MTLCommandQueue
    private let pixelFormat: MTLPixelFormat
    /// Immutable GPU states retained across font changes.
    package let pipelines: MetalPipelines
    let samplers: MetalSamplers
    private let encoder: FrameEncoder
    private let instances: FrameInstances

    /// The glyph sheet, and the source Core calls back into for it.
    ///
    /// The box is held rather than rebuilt per frame because the table it
    /// produces carries a raw pointer to it: a box created for the call and
    /// released after it would hand Core a context that dies mid-build.
    let atlas: GlyphAtlas

    /// The inline images this renderer's frames composite, one texture per
    /// image the model stores; the surface syncs and resolves it under the
    /// model lock and hands the layer to ``encodeFrame``.
    package let imageStore: SurfaceImageStore
    /// The rich text blocks this view's frames composite, kept as rasters
    /// drawn once per block content.
    package let richTextStore: RichTextStore
    package let richTextFaces: RichTextFaces

    /// The atlas slot layout, for a caller registering the session's
    /// boundary-capture geometry.
    package var atlasSlotGeometry: Ubiquitty.Rendering.GlyphSlotGeometry { atlas.slotGeometry }

    /// The atlas, for the surface's proportional-text measurement handoff.
    package var measuringAtlas: GlyphAtlas { atlas }

    /// The atlas facts the frame options carry, for ``applyFrameRaster``.
    public var frameRasterInputs: FrameRasterInputs { FrameRasterInputs(atlas: atlas) }
    private let backendBox: GlyphBackendContext
    /// This view's retained-slot pins on the shared sheets — the frame the
    /// retained grid keeps sampling stays unevictable while other views mint.
    private let viewRetainLease: GlyphAtlas.ViewRetainLease
    /// Set when a sheet refused a slot for want of an evictable one: the pins
    /// have accumulated slack from content that scrolled away, and the next
    /// frame must rebuild every row so the re-baselined pins are exact. The
    /// frame that carries the flag draws correct but softer; the one after it
    /// is whole again.
    public private(set) var wantsFullRebuild = false
    /// Refusal-triggered re-baselines are rate-limited: a working set that
    /// genuinely exceeds the sheets refuses again right after a re-baseline,
    /// and granting a full-damage frame for every such refusal would rebuild
    /// every row on every frame — a drag or a scroll then stutters on work
    /// that cannot help. One re-baseline per interval keeps the recovery and
    /// caps its cost; between them, refusals draw the documented fallback.
    private var pressureThrottle = Ubiquitty.Rendering.SheetPressureThrottle()
    /// The crowding re-baseline has its own, much shorter interval. A refusal
    /// means the sheets are genuinely too small and repeating the rebuild
    /// cannot help, so that path waits; crowding is a forecast made while
    /// every cell still draws, and waiting on it is what lets the pins reach
    /// the refusal it was raised to avoid.
    /// Whether a frame reports what its sheets refused. A blinking cell and a
    /// sheet that refused it are indistinguishable from outside the process,
    /// so the diagnostic is what separates them.
    private let sheetPressureLogging = ProcessInfo.processInfo.environment["UBQ_SHEETLOG"] != nil
    private var sheetLogFrame = 0

    /// Per-pass GPU spans, printed per frame. Nil unless UBIQUITTY_PASS_GPU=1
    /// armed the diagnostic at init.
    private let passProbe: PassGPUProbe?

    /// The Tek pass's streams, created on the first Tektronix frame.
    ///
    /// Optional because most sessions never enter Tek mode, and the pass's
    /// buffers would otherwise sit allocated in every drive.
    var tekStreams: TekPassStreams?

    /// The cursor motion clock, ticked between a frame's capture and its build.
    ///
    /// Exposed so the owner can set the mode, the duration and the Reduce
    /// Motion answer — the three inputs that are settings rather than
    /// animation, which is the split ``CursorAnimator`` exists to state.
    let cursorAnimator = CursorAnimator()

    /// The deadline for presenting a pending cursor move, if any.
    package var cursorPresentationDeadline: Double? { cursorAnimator.presentationDeadline }

    /// Configures cursor-only coalescing for a windowed presentation.
    ///
    /// - Parameters:
    ///   - interval: One display interval; zero disables coalescing.
    ///   - bypassUntil: The monotonic deadline for immediate input feedback.
    package func configureCursorPresentation(interval: Double, bypassUntil: Double) {
        cursorAnimator.presentationInterval = interval
        cursorAnimator.presentationBypassUntil = bypassUntil
    }

    /// Pins the presentation clock for deterministic rendering probes.
    package var cursorPresentationTimeForTesting: Double? {
        get { cursorAnimator.timeForTesting }
        set { cursorAnimator.timeForTesting = newValue }
    }

    /// The cursor handed to the builder by the most recent prepared frame.
    package private(set) var drawnCursorForTesting: (row: Int, column: Int, mixAlpha: Float)?

    private func prepareCursor(_ capture: Ubiquitty.Rendering.FrameCapture) {
        let isAnimating = cursorAnimator.apply(to: capture)
        if isCursorSliding && !isAnimating {
            lastPresentedOverlay = nil
        }
        isCursorSliding = isAnimating
        drawnCursorForTesting = (
            row: Int(capture.cursorRow()), column: Int(capture.cursorColumn()), mixAlpha: capture.cursorMixAlpha()
        )
    }

    /// Whether a cursor presentation hold or slide needs another frame.
    ///
    /// The pending cursor is the frame drive's reason to present again: an animation
    /// only advances when a frame asks for the time, so a drive that stops
    /// presenting on quiet freezes the glide wherever the last frame left it —
    /// until an unrelated redraw finishes someone else's animation.
    package private(set) var isCursorSliding = false

    /// The boundary route's last verdict: whether its Delta Loaded the
    /// retained grid, and the rows its capture owned when it did.
    package private(set) var didBoundaryFrameReuseGrid = false
    package private(set) var boundaryFrameDirtyRows = 0

    /// Whether the last encode declined because the frame reproduced the
    /// glass: the caller presents nothing and asks for no retry.
    package private(set) var didLastFramePresentNothing = false

    /// Whether every frame must reach the layer this pass: a layer presenting
    /// with its transaction expects one per transaction, so nothing is skipped.
    package var isEveryPresentOwed = false
    package var preparesVisibleFonts = false
    package private(set) var didDeferForFontPreparation = false

    private func prepareVisibleFonts(_ capture: Ubiquitty.Rendering.FrameCapture) -> Bool {
        didDeferForFontPreparation = preparesVisibleFonts && !atlas.prepareVisibleFonts(capture)
        if didDeferForFontPreparation { didLastFramePresentNothing = false }
        return !didDeferForFontPreparation
    }

    /// The bell flash weight the surface resolved for this frame. The capture
    /// does not carry it and the boundary route draws none, so the surface
    /// states it before either encode and the glass comparison reads it here.
    package var frameBellFlashAlpha: Float = 0

    /// The overlay facts the last presented frame carried. A frame whose mask
    /// owes no row and whose facts equal these draws the pixels already on the
    /// glass.
    private struct PresentedOverlay: Equatable {
        var cursorRow: Int
        var cursorColumn: Int
        var cursorShape: UInt8
        var cursorMixAlpha: Float
        var isCursorFocused: Bool
        var bellFlashAlpha: Float
        var richText: RichTextPresentation
    }

    private var lastPresentedOverlay: PresentedOverlay?

    /// Records that the frame last built reached no drawable, so the glass
    /// still shows the frame before it.
    ///
    /// The baseline a build compares against is set when the frame is built,
    /// ahead of the drawable wait; a frame built and not presented would
    /// otherwise stand as what the glass shows, and the pass that retries it
    /// would read its own capture as reproducing the glass and present
    /// nothing — a pane whose first drawable arrived late stays blank.
    package func noteFrameNotPresented() {
        lastPresentedOverlay = nil
    }

    private var preparedViewportClip: CGRect?

    /// Invalidates retained pixels before capture when the visible viewport changes.
    /// A new clip can exclude old pixels without changing the grid origin.
    /// - Parameter clip: The next frame's local presentation clip, or nil.
    package func prepareViewportClip(_ clip: CGRect?) {
        guard preparedViewportClip != clip else { return }
        preparedViewportClip = clip
        wantsFullRebuild = true
        lastPresentedOverlay = nil
    }

    private func overlay(of capture: Ubiquitty.Rendering.FrameCapture) -> PresentedOverlay {
        PresentedOverlay(
            cursorRow: Int(capture.cursorRow()),
            cursorColumn: Int(capture.cursorColumn()),
            cursorShape: capture.cursorShape(),
            cursorMixAlpha: capture.cursorMixAlpha(),
            isCursorFocused: capture.isCursorFocused(),
            bellFlashAlpha: frameBellFlashAlpha,
            richText: RichTextPresentation(capture)
        )
    }

    /// Whether the capture owes no row and its overlay facts are the presented
    /// ones. A bouncing match moves every frame and is never identical; a
    /// transaction-bound pass owes every frame.
    private func reproducesGlass(_ capture: Ubiquitty.Rendering.FrameCapture) -> Bool {
        guard let presented = lastPresentedOverlay, !isFocusedMatchBouncing, !isEveryPresentOwed else {
            return false
        }
        return !capture.hasDirtyRowsInMask() && overlay(of: capture) == presented
    }
    /// Whether the focused search match's pill was mid-bounce on the last
    /// capture, so the frame clock keeps its smooth cadence until it rests.
    public private(set) var isFocusedMatchBouncing = false
    /// Whether the last built frame captured any row that differs from the
    /// shadow baseline — net change, not bytes or writes. The surface stamps
    /// the presentation driver's screen-change rate from it.
    package private(set) var lastFrameHadNetChange = false
    /// Whether the last boundary frame built with a baked view tier, so the
    /// next Delta cannot trust the retained rows that tier touched.
    private var hadBakedViewTiers = false

    /// What the capture phase leaves for the build phase, which runs once the
    /// caller has released the model lock. Held here rather than handed across
    /// that release because both are the capture's own facts: a caller holding
    /// them could pair a plan with a later capture, and the scroll bands would
    /// then describe a frame nobody took.
    private var capturedPlan = Ubiquitty.Rendering.makeFullRebuildPlan()
    private var capturedImages: ImageLayer?
    private var capturedHadTiersLastFrame = false

    /// The retained grid texture the content passes target.
    ///
    /// The drawable gets a blit of this plus the overlays, which is what makes
    /// a partial frame possible at all: a Load pass over retained pixels
    /// repaints only the dirty rows, and the cursor moves without dirtying
    /// anything because it never lands in here.
    /// Whether the grid texture's pixels survive between frames.
    ///
    /// Core's decision for the process (``isRetainedGridCacheEnabled``): true
    /// in every shipping frame, false when the diagnostic switch turns the
    /// cache off, which also makes every capture Full. It decides whether the
    /// grid passes are confined to the content rectangle: a retained target
    /// never repaints its margins, so overhanging ink left there would stay,
    /// while a target cleared every frame refreshes the margins and may draw
    /// the overhang the same way an uncached arm does.
    private let retainsGridCache = Ubiquitty.Rendering.isRetainedGridCacheEnabled()

    private var gridTexture: MTLTexture?
    /// The retained grid, exposed for the comparison harness's dump only.
    var retainedGridTextureForDump: MTLTexture? { gridTexture }
    /// The scroll partner: a shift blits the surviving bands from the front
    /// texture into this one, the content pass repaints the dirty rows over
    /// it, and the two swap. Allocated with the front and always its size.
    private var gridTextureBack: MTLTexture?
    private var secondaryTexture: MTLTexture?
    private var secondaryTextureBack: MTLTexture?
    private var vibrantBackgroundTexture: MTLTexture?
    private var vibrantBackgroundTextureBack: MTLTexture?

    /// Reads the retained native background after earlier frames complete on its queue.
    package func nativeBackgroundPixelsForTesting() -> Data? {
        retainedPixelsForTesting(in: vibrantBackgroundTexture)
    }

    /// Reads ordinary grid pixels without changing the live frame's material routing.
    package func retainedGridPixelsForTesting() -> Data? {
        retainedPixelsForTesting(in: gridTexture)
    }

    private func retainedPixelsForTesting(in texture: MTLTexture?) -> Data? {
        guard let source = texture else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.storageMode = queue.device.cpuWrittenTextureStorageMode
        guard let target = queue.device.makeTexture(descriptor: descriptor),
            let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(from: source, to: target)
        #if os(macOS)
        if target.storageMode == .managed {
            blit.synchronize(resource: target)
        }
        #endif
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        var pixels = Data(count: source.width * source.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            target.getBytes(
                base,
                bytesPerRow: source.width * 4,
                from: MTLRegionMake2D(0, 0, source.width, source.height),
                mipmapLevel: 0
            )
        }
        return pixels
    }
    /// The cell the retained grid's pixels were laid out on, stamped whenever
    /// the grid is built whole.
    ///
    /// The reuse verdict reaching this arm is `isTargetMatching`, and that is
    /// answered by ``gridMatches`` from the DRAWABLE's pixel size alone. A font
    /// size change on a held window — the reflowing branch of
    /// `resizeWindowToGrid:` — moves the cell and the row/column count while
    /// leaving the drawable exactly as it was, so the verdict cannot see it and
    /// says the texture still matches. It does not: every retained pixel sits on
    /// the old cell. Loading it and repainting only the dirty rows leaves the
    /// clean ones showing the previous cell's ink where the new geometry expects
    /// none, anchored at the origin and growing with each partial frame.
    private var gridCellWidthInPixels: Float?
    private var gridCellHeightInPixels: Float?

    /// Reused across frames rather than allocated per encode: an encoder
    /// copies the descriptor's state at creation, and every field a pass
    /// consumes is re-set before its encoder is made.
    private let gridPassDescriptor = MTLRenderPassDescriptor()
    /// The scroll-shift clear's descriptor, on the same terms.
    private let scrollClearDescriptor = MTLRenderPassDescriptor()

    /// The frame this renderer captures into, reused across frames.
    ///
    /// Held rather than made per frame so its row, attribute and mark storage is
    /// allocated once. A reference type for a reason no other property here has:
    /// the capture it owns is non-escapable, and Swift rejects a stored property
    /// of a non-escapable type — not for the field, but because the property's
    /// accessors cannot return one.
    private let capture: Ubiquitty.Rendering.FrameCapture

    /// The mono coverage sheet, for the comparison harness's slot dump.
    var monoSheetTexture: MTLTexture { atlas.texture }
    /// The ligature strip sheet, exposed for the comparison harness's dump only.
    var ligatureSheetTextureForDump: MTLTexture? { atlas.ligatureTexture }

    /// How many instances each stream held on the last ``render(_:uniforms:into:)``.
    package var counts: Ubiquitty.Rendering.InstanceCounts { instances.counts }

    /// The rules the last build cut around ink, and the widest clearance any
    /// of them keeps from that ink, in device pixels.
    package var skipInkRules: (count: Int, widestPadInPixels: Float) { instances.skipInkRules }

    /// The mono sheet's filled slots against its capacity, for the
    /// drawing-debug panel.
    package var monoSheetOccupancy: (used: Int, capacity: Int) { atlas.monoOccupancy }

    /// Whether this renderer's captures feed the paint heatmap.
    ///
    /// The pass is Core's capture's; turning it on resyncs Core's shadow and
    /// clears the counters, so the next capture is a baseline.
    package var isPaintHeatmapEnabled: Bool {
        get { capture.isPaintHeatmapEnabled() }
        set {
            guard newValue != capture.isPaintHeatmapEnabled() else { return }
            if newValue {
                capture.enablePaintHeatmap()
            } else {
                capture.disablePaintHeatmap()
            }
        }
    }

    /// Feeds a frame this renderer presents from a capture it did not take —
    /// a synchronized-output boundary frame — to its paint heatmap.
    ///
    /// - Parameter shown: The boundary capture about to be built.
    // swift-only: the shared capture is passed only between in-package Swift renderers
    package func notePaintHeat(of shown: Ubiquitty.Rendering.FrameCapture) {
        guard capture.isPaintHeatmapEnabled() else { return }
        capture.notePaintHeatOf(shown)
    }

    /// The foreground alpha of the last frame's cell instance at a cell, or
    /// nil when the frame built none there. The cells stream is read as the
    /// frame left it: the ring advances before the next build writes, so
    /// until then the slot holds what was drawn.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - column: The column.
    /// - Returns: The instance's foreground alpha, 0...1.
    package func cellForegroundAlphaForTesting(row: Int, column: Int) -> Float? {
        let count = Int(instances.counts.cells)
        guard count > 0, let cells = instances.cells.elements(as: Ubiquitty.Rendering.CellInstance.self) else {
            return nil
        }
        for index in 0..<count {
            let cell = cells[index]
            if Int(cell.gridPosition.x) == column, Int(cell.gridPosition.y) == row {
                return cell.foreground.w
            }
        }
        return nil
    }

    /// Returns the semantic ink of a terminal mark routed to native compositing.
    package func nativeTerminalMarkInkForTesting() -> SIMD4<Float>? {
        guard let overlays = instances.overlays.elements(as: Ubiquitty.Rendering.OverlayInstance.self) else { return nil }
        for index in 0..<Int(instances.counts.overlays) {
            let color = overlays[index].color
            if color.w < 0 { return SIMD4(color.x, color.y, color.z, color.w) }
        }
        return nil
    }

    /// Overlay quads the last frame built in the padding gutters — left of
    /// the grid's origin or right of its last column — which is where OSC 133
    /// prompt marks live and nothing else draws. Read as the frame left the
    /// stream, as `cellForegroundAlphaForTesting` reads the cells.
    ///
    /// - Returns: How many overlay instances lie wholly outside the grid's
    ///   columns, or nil before a frame built any overlays.
    package func gutterOverlayCountForTesting() -> Int? {
        let count = Int(instances.counts.overlays)
        guard count > 0, let overlays = instances.overlays.elements(as: Ubiquitty.Rendering.OverlayInstance.self) else {
            return nil
        }
        let uniforms = capture.uniforms()
        let gridLeft = uniforms.originInPixels.x
        let gridRight = gridLeft + uniforms.cellSizeInPixels.x * Float(instances.builtColumns)
        var inGutter = 0
        for index in 0..<count {
            let quad = overlays[index]
            if quad.bottomRightInPixels.x <= gridLeft || quad.topLeftInPixels.x >= gridRight {
                inGutter += 1
            }
        }
        return inGutter
    }

    /// The history offset represented by the last captured frame.
    package var lastCapturedViewOffsetForTesting: Int { Int(capture.viewOffset()) }

    /// The column under a point along a captured row the frame laid out as
    /// proportional runs (LetterLayout.h), or nil for a row on the grid.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - xInCells: The point along the row, in cells from the grid's left edge.
    /// - Returns: The column, or nil where the grid's arithmetic answers.
    package func letterColumn(row: Int, xInCells: Double) -> Int? {
        guard capture.isRowLaidOutAsLetters(Int32(row)) else { return nil }
        return Int(capture.columnAt(Int32(row), xInCells * Double(capture.cellWidthInPixels())))
    }

    /// Where a point is along such a row in cells — the column plus the
    /// fraction of its letter crossed — or nil for a row on the grid.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - xInCells: The point along the row, in cells from the grid's left edge.
    /// - Returns: The position, or nil where the grid's arithmetic answers.
    package func letterXInCells(row: Int, xInCells: Double) -> Double? {
        guard capture.isRowLaidOutAsLetters(Int32(row)) else { return nil }
        return capture.xInCellsAt(Int32(row), xInCells * Double(capture.cellWidthInPixels()))
    }

    /// Where a column's letter stands on a captured row, in cells from the
    /// grid's left edge, for a scenario that reads the layout it drew.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - column: The column.
    /// - Returns: The letter's left edge and advance in cells, and whether the
    ///   row was laid out as letters at all.
    package func letterExtentForTesting(row: Int, column: Int) -> (left: Double, advance: Double, isLetterRow: Bool) {
        let extent = capture.letterExtent(Int32(row), Int32(column))
        let cell = Double(capture.cellWidthInPixels())
        guard cell > 0 else { return (0, 0, false) }
        return (Double(extent.leftInPixels) / cell, Double(extent.advanceInPixels) / cell, capture.isRowLaidOutAsLetters(Int32(row)))
    }

    /// The uniforms the last capture derived — the alpha and colour the frame
    /// was drawn with — for a scenario that reads the frame rather than the
    /// style it was asked for.
    package var lastCaptureUniformsForTesting: Ubiquitty.Rendering.FrameUniforms { capture.uniforms() }

    /// Whether the last frame overran a stream it could not grow.
    var didTruncate: Bool { instances.didTruncate }

    /// Whether the retained grid holds pixels a partial frame may keep.
    ///
    /// False until a frame has rendered at this drawable size — the caller
    /// folds this into its reuse verdict before it captures, so a frame that
    /// cannot reuse is captured full rather than built with holes.
    ///
    /// The cell is half the question and the drawable size cannot answer it. A
    /// font size change on a held window moves the cell and the row and column
    /// counts while leaving the drawable exactly as it was, and every retained
    /// pixel then sits on the old cell. Asked here, where the answer still
    /// reaches the capture; asked after it, the capture has already skipped the
    /// clean rows on the strength of a target the encode is about to clear.
    ///
    /// - Parameters:
    ///   - widthInPixels: The drawable width.
    ///   - heightInPixels: The drawable height.
    ///   - cellWidthInPixels: The cell width this frame will draw on, in the
    ///     same units the uniforms carry.
    ///   - cellHeightInPixels: The cell height, on the same terms.
    /// - Returns: Whether the retained texture matches.
    package func gridMatches(
        widthInPixels: Int,
        heightInPixels: Int,
        cellWidthInPixels: Float,
        cellHeightInPixels: Float
    ) -> Bool {
        guard let grid = gridTexture else { return false }
        return grid.width == widthInPixels && grid.height == heightInPixels
            && gridCellWidthInPixels == cellWidthInPixels
            && gridCellHeightInPixels == cellHeightInPixels
    }

    /// Whether the last encode refused a target its caller had already trusted.
    ///
    /// Zero on a build that agrees with itself. It counts the frames whose
    /// capture was told to skip the clean rows and whose encode then cleared
    /// the ground under them — the disagreement that puts a prompt on an empty
    /// screen. Nothing in the frame can repair it by then, so this exists to be
    /// asserted at zero rather than acted on.
    package private(set) var retainedCellRefusalsAfterTrust = 0

    /// Frames encoded over a Loaded retained target, for a measurement of how
    /// often the partial lane is taken.
    package private(set) var partialFrameCount = 0

    /// Whether this arm could shift its grid by whole device rows.
    ///
    /// A scroll is served by blitting the retained texture up or down, which
    /// moves whole rows of device pixels — so it needs the back texture the blit
    /// targets, and the row height and the grid's top edge both on integer
    /// boundaries. A caller asks so it can decide whether to drain a frame's
    /// damage at all: the drain acknowledges the pending scroll, and a scroll
    /// acknowledged by an arm that cannot shift it is a scroll nobody performs.
    ///
    /// Answers for the frame last encoded, which is the footing the caller reads
    /// it on — the capture that consults it runs before the encode that would
    /// refresh it.
    private(set) var canShiftGridByWholeRows = false

    /// Applies the user's ligature toggle for the coming frames.
    ///
    /// - Parameter isEnabled: Whether rows shape at all.
    func setLigaturesEnabled(_ isEnabled: Bool) {
        atlas.setLigaturesEnabled(isEnabled)
    }

    /// Builds a renderer for one drawable format and one font.
    ///
    /// - Parameters:
    ///   - device: The device everything is allocated on.
    ///   - pixelFormat: The drawable's colour format; every pipeline matches it.
    ///   - pipelines: Immutable pipeline states for this device and drawable format.
    ///   - faces: The family glyphs are drawn from.
    ///   - geometry: The atlas slot layout.
    ///   - slotCapacity: How many glyph slots the sheet holds.
    ///   - proportionalFamilyName: The family proportional runs are set in,
    ///     or empty for the platform's UI face.
    ///   - proportionalPointSize: The em size proportional runs are set at,
    ///     or zero for one optical step over the grid's.
    package init?(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        pipelines: MetalPipelines,
        faces: FontFaces,
        geometry: Ubiquitty.Rendering.GlyphSlotGeometry,
        slotCapacity: Int,
        baselinePenInPixels: Double,
        wideGlyphBoostCap: Double,
        unifontScale: Int,
        router: FontRouter? = nil,
        ligatureFeatureSpec: String = "",
        fontLigates: Bool = false,
        sheetKey: String? = nil,
        proportionalFamilyName: String = "",
        proportionalPointSize: Double = 0
    ) {
        // With a key, the glyph sheets come from the shared registry so views
        // showing one font rasterise each glyph once between them; without one,
        // the atlas is private — the harnesses that build two renderers on one
        // configuration and must not couple them pass no key.
        let sharedOrPrivate =
            sheetKey.flatMap {
                GlyphAtlas.shared(
                    key: $0,
                    device: device,
                    faces: faces,
                    geometry: geometry,
                    slotCapacity: slotCapacity,
                    baselinePenInPixels: baselinePenInPixels,
                    wideGlyphBoostCap: wideGlyphBoostCap,
                    unifontScale: unifontScale,
                    router: router,
                    ligatureFeatureSpec: ligatureFeatureSpec,
                    fontLigates: fontLigates,
                    proportionalFamilyName: proportionalFamilyName,
                    proportionalPointSize: proportionalPointSize
                )
            }
            ?? GlyphAtlas(
                device: device,
                faces: faces,
                geometry: geometry,
                slotCapacity: slotCapacity,
                baselinePenInPixels: baselinePenInPixels,
                wideGlyphBoostCap: wideGlyphBoostCap,
                unifontScale: unifontScale,
                router: router,
                ligatureFeatureSpec: ligatureFeatureSpec,
                fontLigates: fontLigates,
                proportionalFamilyName: proportionalFamilyName,
                proportionalPointSize: proportionalPointSize
            )
        guard let samplers = MetalSamplers(device: device),
            let atlas = sharedOrPrivate
        else {
            return nil
        }
        self.queue = atlas.commandQueue
        self.pixelFormat = pixelFormat
        self.samplers = samplers
        self.atlas = atlas
        self.imageStore = SurfaceImageStore(device: device)
        let richTextFaces = RichTextFaces(grid: faces, proportionalFamilyName: proportionalFamilyName)
        self.richTextFaces = richTextFaces
        self.richTextStore = RichTextStore(
            device: device,
            faces: richTextFaces
        )
        self.pipelines = pipelines
        self.encoder = FrameEncoder(pipelines: self.pipelines, samplers: samplers)
        self.instances = FrameInstances(device: device)
        self.backendBox = GlyphBackendContext(source: atlas)
        self.viewRetainLease = atlas.acquireViewRetainLease()
        self.passProbe = PassGPUProbe(device: device)
        guard let capture = Ubiquitty.Rendering.FrameCapture.make() else {
            return nil
        }
        self.capture = capture
    }

    deinit {
        atlas.releaseViewRetainLease(viewRetainLease)
    }

    /// Records what the sheets reported about the frame just built.
    ///
    /// Crowding is read first: it is raised while the frame still drew every
    /// cell, and acting on it is what keeps the refusal — a blank cell that
    /// stays blank until the interval expires — from happening at all.
    private func noteSheetPressure() {
        if sheetPressureLogging {
            sheetLogFrame += 1
            let report = atlas.pressureReport()
            // A heartbeat, because silence otherwise reads the same whether
            // the sheets are healthy or this code never ran — the reader
            // cannot tell an exonerated cache from an instrument that was
            // never reached, and would trust the wrong one.
            if !report.isEmpty {
                FileHandle.standardError.write(Data("[perf] sheet frame=\(sheetLogFrame) \(report)\n".utf8))
            } else if sheetLogFrame % 240 == 0 {
                FileHandle.standardError.write(
                    Data("[perf] sheet frame=\(sheetLogFrame) healthy \(atlas.occupancyReport())\n".utf8)
                )
            }
        }
        // Core's throttle decides; this side only reports the three facts.
        // Spelled per arm, the decision drifted: the two-counter loop that
        // lived here answered refusals on a two-second throttle, which is a
        // hundred frames of unhealed text after the sheet already refused.
        if pressureThrottle.wantsCorrection(
            atlas.pinsCrowdOutNextFrame(),
            atlas.pinsNearRefusal(),
            atlas.frameHadRefusals()
        ) {
            wantsFullRebuild = true
        }
    }

    /// Drops this view's accumulated pins ahead of a frame that rebuilds
    /// every row, so the retention that follows the build is exact.
    ///
    /// The caller grants the full rebuild — damage covering every row — and
    /// calls this first; a re-baseline without that grant would strip the
    /// clean rows' protection while their quads still sample the sheets.
    public func rebaselineRetainedFrame() {
        atlas.rebaselineViewRetainLease(viewRetainLease)
        wantsFullRebuild = false
        pressureThrottle.noteRebaselined()
    }

    /// Captures `terminal` and draws it, in one call.
    ///
    /// The surface a frontend is meant to use: it hands over a terminal and a
    /// place to draw, and names none of the frame's parts. Which cells are
    /// visible, what each resolves to, which slot a glyph occupies and how the
    /// instances batch into passes are all Core's, reached through the capture
    /// this owns rather than assembled by the caller.
    ///
    /// A degenerate terminal — no active screen, no rows or no columns —
    /// captures nothing and draws nothing, reporting nil rather than an empty
    /// frame that looks like a black one.
    ///
    /// - Parameters:
    ///   - terminal: The terminal to draw. Borrowed for the call: Core imports
    ///     it as a reference it does not manage, so it must outlive this.
    ///   - options: The frame's view offset, style and cursor decisions.
    ///   - metrics: From the rasterizer that faults the glyphs, so decorations
    ///     land at the geometry the glyphs were rasterized at.
    ///   - uniforms: The constants every pass reads.
    ///   - descriptor: The pass to encode into.
    /// - Returns: The committed command buffer, or nil if the terminal captured
    ///   nothing or a command buffer could not be made.
    @discardableResult
    func render(
        _ terminal: Ubiquitty.Terminal,
        options: Ubiquitty.Rendering.TerminalSnapshotOptions,
        metrics: Ubiquitty.Rendering.CellMetrics,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        didLastFramePresentNothing = false
        // This entry builds every row, so it carries the grant the re-baseline
        // needs; see the plan-gated call in `encodeFrame`.
        if wantsFullRebuild {
            rebaselineRetainedFrame()
        }
        guard capture.capture(terminal, options, metrics, atlas.slotGeometry, Ubiquitty.Rendering.ChromeLayers()) else {
            return nil
        }
        isFocusedMatchBouncing = capture.isFocusedMatchBouncing()
        // Between the capture and the build, because the tick faces both ways:
        // its target is the cursor cell this capture resolved, and its result
        // must reach the builder that runs next — a slide restated a frame
        // late draws the moving block against last frame's grid. While the
        // slide is in flight the builder builds no tier for the block on its
        // own; settled or off, this writes the same false the options carried.
        prepareCursor(capture)
        var backend = Ubiquitty.Rendering.GlyphBackend()
        backendBox.fillBackend(into: &backend)
        buildWithMeasuredInk { instances.build(capture, backend: backend, scope: .Damaged) }
        atlas.retainFrame(viewRetainLease)
        noteSheetPressure()
        lastPresentedOverlay = overlay(of: capture)
        return encode(uniforms: uniforms, into: descriptor)
    }

    /// Captures `terminal` and encodes it without committing.
    ///
    /// The one-call surface for a caller that owns presentation: a drawable's
    /// present must be scheduled on the buffer before the commit, so the
    /// committing variant above cannot serve it. The uniforms are the
    /// capture's own — Core's one derivation over the facts the capture
    /// resolved — because a caller assembling them beside the capture holds a
    /// second spelling of the same frame.
    ///
    /// - Parameters:
    ///   - terminal: The terminal to draw. Borrowed for the call: Core imports
    ///     it as a reference it does not manage, so it must outlive this.
    ///   - options: The frame's view offset, style and cursor decisions.
    ///   - metrics: From the rasterizer that faults the glyphs, so decorations
    ///     land at the geometry the glyphs were rasterized at.
    ///   - plan: The retained-frame plan for this frame, from Core. Its verdict
    ///     decides whether the target is Loaded and whether the capture keeps
    ///     the rows the drain called clean, and the two travel together on
    ///     purpose: Loading a target while rebuilding every cell repaints all of
    ///     it over pixels that were already right. A default plan is the full
    ///     frame, which is what a caller with no damage tracking passes.
    ///   - descriptor: The pass to encode into.
    /// - Returns: The encoded, uncommitted command buffer, or nil if the
    ///   terminal captured nothing or a command buffer could not be made.
    /// The window backdrop image for the next encoded frame, or nil for
    /// none. Internal state rather than a parameter: the package entry cannot
    /// name the encoder's internal Backdrop type, and the callers that supply
    /// one live in this module.
    var backdrop: FrameEncoder.Backdrop?

    /// Hands this renderer a decoded backdrop, or clears it with nil texture.
    /// Framework types only, so a caller outside this module — where the
    /// encoder's Backdrop is not a name — can supply one.
    ///
    /// A frame with a backdrop never Loads the retained target, but the frame
    /// after one is removed or replaced would Load pixels the old picture is
    /// part of, so a change asks the next frame to build whole.
    package func setBackdrop(texture: (any MTLTexture)?, opacity: Double, mode: Int32, pixelWidth: Int32, pixelHeight: Int32) {
        let wasShowing = backdrop.map { (ObjectIdentifier($0.texture), $0.opacity, $0.mode) }
        defer {
            let isShowing = backdrop.map { (ObjectIdentifier($0.texture), $0.opacity, $0.mode) }
            if wasShowing?.0 != isShowing?.0 || wasShowing?.1 != isShowing?.1 || wasShowing?.2 != isShowing?.2 {
                wantsFullRebuild = true
            }
        }
        guard let texture else {
            backdrop = nil
            return
        }
        backdrop = FrameEncoder.Backdrop(
            texture: texture,
            opacity: Float(opacity),
            mode: mode,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    /// Copies the frame's model state into capture-owned storage. Caller holds
    /// the model lock.
    ///
    /// The capture is the only half that needs the lock. Core's live capture
    /// reads the display rows directly into storage it owns, so everything after
    /// this returns reads that copy rather than the model — and the builder,
    /// which is the expensive half, must not be holding the lock while it runs.
    /// A frame built under the lock blocks the ingest thread for the whole frame
    /// instead of for the copy, which starves the parser exactly when it has the
    /// most to do.
    ///
    /// Pairs with ``buildCapturedFrame()``: the plan and the image layer are held
    /// rather than handed back, so a caller across a lock release never names
    /// them and cannot pair a plan with the wrong capture.
    ///
    /// - Returns: Whether the capture holds a frame.
    // The header printer cannot represent a default argument or an optional Swift
    // class, and no C++ caller exists: both phases are this package's Swift.
    // swift-only: in-package Swift, absent from the generated header by design.
    package func captureFrame(
        _ terminal: Ubiquitty.Terminal,
        options: Ubiquitty.Rendering.TerminalSnapshotOptions,
        metrics: Ubiquitty.Rendering.CellMetrics,
        plan: Ubiquitty.Rendering.RetainedFramePlan = Ubiquitty.Rendering.makeFullRebuildPlan(),
        images: ImageLayer? = nil
    ) -> Bool {
        // The pins are re-baselined here for a caller that tracks no damage of
        // its own. The drive raises `wantsFullRebuild` when its pinned sheets
        // refuse a slot, and a path that never answers it holds every pin it
        // ever took: the sheet fills, refusals start, and a refused slot draws
        // a blank cell. Gated on the plan rebuilding every row, which is the
        // grant `rebaselineRetainedFrame` requires — stripping the clean rows'
        // protection while their quads still sample the sheets is the one way
        // this makes things worse.
        didLastFramePresentNothing = false
        if wantsFullRebuild, !plan.shouldLoadRetainedTarget {
            rebaselineRetainedFrame()
        }
        guard capture.capture(terminal, options, metrics, atlas.slotGeometry, plan.refresh, Ubiquitty.Rendering.ChromeLayers()) else {
            return false
        }
        isFocusedMatchBouncing = capture.isFocusedMatchBouncing()
        // Net change against the shadow baseline, not bytes or writes: an
        // identical rewrite captures no dirty row and reads as no change. Read
        // off the mask, not the record kind: a live capture commits no record
        // and keeps the default Full header, which reads as every row dirty.
        lastFrameHadNetChange = capture.hasDirtyRowsInMask()
        // A tier baked by this live frame sits in the retained pixels; the
        // next boundary Delta must not Load them.
        capturedHadTiersLastFrame = hadBakedViewTiers
        hadBakedViewTiers =
            options.selectionSpanCount > 0 || options.searchMatchSpanCount > 0
            || options.otherSearchMatchSpanCount > 0 || options.triggerHighlightSpanCount > 0
            || options.hiliteRegionSpanCount > 0
        // Held for the build, which runs once the caller has let the lock go.
        // The options are not: every tier they carry is a borrow of the model or
        // of the caller's scratch, and both die at that release — the capture has
        // already taken what it needs from them.
        capturedPlan = plan
        capturedImages = images
        return true
    }

    /// Builds the frame the last ``captureFrame(_:options:metrics:plan:images:)``
    /// took. Caller must have RELEASED the model lock.
    ///
    /// - Returns: The frame to encode once a target is had, or nil when nothing
    ///   is to be presented.
    package func buildCapturedFrame() -> PendingFrame? {
        guard prepareVisibleFonts(capture) else { return nil }
        let plan = capturedPlan
        let images = capturedImages
        let hadTiersLastFrame = capturedHadTiersLastFrame
        // Between the capture and the build, for the reason the committing
        // variant states: the tick's target is this capture's cursor cell and
        // its verdict must reach the builder that runs next.
        prepareCursor(capture)
        // A frame that reproduces the glass is not encoded: the plan Loads the
        // retained grid and owes it no row, no tier is baked this frame or was
        // last frame, no image is on the layer, and the cursor is settled at
        // the presented cell, shape, weight and focus with the bell at its
        // presented weight. The drawable goes back unpresented.
        if plan.shouldLoadRetainedTarget, !isCursorSliding, !hadTiersLastFrame, !hadBakedViewTiers,
            (images?.quadCount ?? 0) == 0, reproducesGlass(capture)
        {
            didLastFramePresentNothing = true
            return nil
        }
        var backend = Ubiquitty.Rendering.GlyphBackend()
        backendBox.fillBackend(into: &backend)
        buildWithMeasuredInk { instances.build(capture, backend: backend, scope: .Damaged) }
        let reusesGrid = keepsRowInkContained(capture, backend: backend, isLoading: plan.shouldLoadRetainedTarget)
        atlas.retainFrame(viewRetainLease)
        noteSheetPressure()
        // The scroll the plan laid out, not one derived here: Core marked the
        // exposed band dirty at drain time against these same bands, so a second
        // derivation could shift pixels the capture did not refresh.
        var scroll = GridScroll()
        if reusesGrid {
            scroll.topRow = plan.damage.scrollTop
            scroll.bottomRow = plan.damage.scrollBottom
            scroll.deltaRows = plan.damage.scrollDelta
        }
        lastPresentedOverlay = overlay(of: capture)
        return PendingFrame(
            rows: capture.rows(),
            columns: capture.columns(),
            isFullscreenContentActive: capture.isFullscreenContentActive(),
            uniforms: capture.uniforms(),
            canReuseGrid: reusesGrid,
            scroll: scroll,
            images: images,
            backdrop: backdrop,
            richText: richTextStore.layer(for: capture)
        )
    }

    /// Captures and builds in one call, for a caller that holds the model lock
    /// across both.
    ///
    /// The offscreen and snapshot paths render against a model nothing else is
    /// parsing, so releasing the lock between the phases would free no thread. A
    /// frontend drawing a live session calls the two phases separately.
    ///
    /// - Returns: The frame to encode once a target is had, or nil when nothing
    ///   is to be presented.
    // The header printer cannot represent a default argument or an optional Swift
    // class, and no C++ caller exists: both phases are this package's Swift.
    // swift-only: in-package Swift, absent from the generated header by design.
    package func buildFrame(
        _ terminal: Ubiquitty.Terminal,
        options: Ubiquitty.Rendering.TerminalSnapshotOptions,
        metrics: Ubiquitty.Rendering.CellMetrics,
        plan: Ubiquitty.Rendering.RetainedFramePlan = Ubiquitty.Rendering.makeFullRebuildPlan(),
        images: ImageLayer? = nil
    ) -> PendingFrame? {
        guard captureFrame(terminal, options: options, metrics: metrics, plan: plan, images: images) else {
            return nil
        }
        return buildCapturedFrame()
    }

    /// Runs a build, and runs it again once the glyphs it faulted have landed.
    ///
    /// A glyph rasterised for the first time is queued into a batch, and its
    /// ink is measured only when the batch lands, after the build that faulted
    /// it. That build drew it from the whole slot and knew nothing of its ink:
    /// the rule that follows the ink stopped at the cell, the crossings named
    /// the slot's margins. Landing the batch and building again draws the
    /// frame from measured ink. The second build faults nothing, so it is the
    /// frame's last; a frame that faulted nothing builds once.
    ///
    /// - Parameter build: The build, run once or twice.
    private func buildWithMeasuredInk(_ build: () -> Void) {
        let queuedBefore = atlas.enqueuedRasterCount
        build()
        if atlas.enqueuedRasterCount != queuedBefore {
            atlas.flushStagedUploads()
            build()
        }
    }

    /// Where the retained target's ink crosses from one row into the next, as
    /// the last frame that built every row drew it; empty before one has.
    ///
    /// A partial frame moves it with its scroll: it may stand only where it
    /// borders no crossing, so the crossings it keeps are the clean rows' own.
    private var targetRowInkCrossings: [UInt8] = []

    /// Settles whether a frame built from its dirty rows may Load the target,
    /// and rebuilds it whole where it may not.
    ///
    /// Ink a glyph carries across a row edge — a stacked accent above, a tall
    /// fallback glyph below — is drawn by neither row's repaint alone, so Core
    /// refuses a partial frame that borders a crossing (``settleRowInkCrossings``)
    /// and the frame is built again over every row, with the pins re-baselined
    /// for the full build as any refused frame is. A frame that builds every
    /// row records the crossings its target now holds.
    ///
    /// - Parameters:
    ///   - capture: The capture just built from its dirty rows.
    ///   - backend: The glyph source the build ran against.
    ///   - view: The tiers a boundary build composites, or nil for a live one.
    ///   - isLoading: Whether the frame was to Load the target.
    /// - Returns: Whether the frame Loads the target.
    private func keepsRowInkContained(
        _ capture: Ubiquitty.Rendering.FrameCapture,
        backend: Ubiquitty.Rendering.GlyphBackend,
        view: Ubiquitty.Rendering.FrameCapture.ViewTierOverrides? = nil,
        isLoading: Bool
    ) -> Bool {
        var reusesGrid = isLoading
        if reusesGrid {
            let isContainedNow = {
                self.instances.rowInkCrossings.withUnsafeBufferPointer { built in
                    self.targetRowInkCrossings.withUnsafeMutableBufferPointer { target in
                        capture.settleRowInkCrossings(
                            Ubiquitty.Rendering.RowBytesToWrite(target),
                            Ubiquitty.Rendering.RowBytes(built)
                        )
                    }
                }
            }
            if !isContainedNow() {
                rebaselineRetainedFrame()
                if let view {
                    buildWithMeasuredInk { instances.build(capture, backend: backend, view: view, scope: .Whole) }
                } else {
                    buildWithMeasuredInk { instances.build(capture, backend: backend, scope: .Whole) }
                }
                reusesGrid = false
            }
        }
        if !reusesGrid {
            targetRowInkCrossings = instances.rowInkCrossings
        }
        return reusesGrid
    }

    /// Draws one boundary-captured frame without committing, compositing the
    /// caller's present-time view tiers over the frozen grid.
    ///
    /// The sibling of the live-capture entry above with the capture step
    /// removed: the session took this frame at a DECSET-2026 boundary under
    /// the model lock, which is the coherence the live read cannot offer
    /// mid-flood. The cursor tick runs against the captured cursor, so glide
    /// carries across the two sources.
    ///
    /// - Parameters:
    ///   - capture: The boundary capture to present.
    ///   - view: The tiers composited over the captured grid.
    /// - Returns: The frame to encode once a target is had, or nil when
    ///   nothing is to be presented.
    // The header printer cannot represent a default argument or an optional Swift
    // class, and no C++ caller exists: both phases are this package's Swift.
    // swift-only: in-package Swift, absent from the generated header by design.
    package func buildFrame(
        captured capture: Ubiquitty.Rendering.FrameCapture,
        view: Ubiquitty.Rendering.FrameCapture.ViewTierOverrides
    ) -> PendingFrame? {
        guard prepareVisibleFonts(capture) else { return nil }
        didLastFramePresentNothing = false
        prepareCursor(capture)
        lastFrameHadNetChange = capture.hasCapturedDirtyRows()
        // A Delta reuses the retained grid only while nothing baked outside
        // its mask can have moved: selection and search tiers are baked into
        // the grid pixels at build time, so a tier active now or last frame,
        // or a pending full rebuild, builds the whole capture. A cursor is
        // never the grid's — the settled block is the tier and a sliding one
        // the overlay's — so a slide refuses nothing.
        let hasBakedViewTiers =
            view.selectionSpanCount > 0 || view.searchMatchSpanCount > 0
            || view.otherSearchMatchSpanCount > 0 || view.triggerHighlightSpanCount > 0
            || view.hiliteRegionSpanCount > 0
        let hasImages = !capture.imageQuads().isEmpty
        let imagesMayChange = hasImages || imageStore.hasResolvedImages
        // The window backdrop is composited under every frame, this route's
        // included; drawn again over a Loaded target it builds up on every row
        // the Delta keeps, so a frame with one rebuilds whole as the live
        // route's plan does.
        var reusesGrid =
            !capture.isFullFrame() && !hasBakedViewTiers && !hadBakedViewTiers
            && !wantsFullRebuild && !imagesMayChange && backdrop == nil
        hadBakedViewTiers = hasBakedViewTiers
        didBoundaryFrameReuseGrid = reusesGrid
        boundaryFrameDirtyRows = reusesGrid ? Int(capture.capturedDirtyRowCount()) : Int(capture.rows())
        // A Delta that reproduces the glass is consumed and not encoded: it
        // owes no row, no tier is baked either frame, and the overlay's facts
        // are the presented ones. The bell, a bouncing match and an animating
        // image render on the live route, which the next tick reaches once the
        // slot is empty. The drawable goes back unpresented.
        if reusesGrid, !isCursorSliding, reproducesGlass(capture) {
            didLastFramePresentNothing = true
            return nil
        }
        if wantsFullRebuild, !reusesGrid {
            rebaselineRetainedFrame()
        }
        var backend = Ubiquitty.Rendering.GlyphBackend()
        backendBox.fillBackend(into: &backend)
        buildWithMeasuredInk { instances.build(capture, backend: backend, view: view, scope: reusesGrid ? .Damaged : .Whole) }
        if !keepsRowInkContained(capture, backend: backend, view: view, isLoading: reusesGrid) {
            reusesGrid = false
            didBoundaryFrameReuseGrid = false
            boundaryFrameDirtyRows = Int(capture.rows())
        }
        atlas.retainFrame(viewRetainLease)
        noteSheetPressure()
        var scroll = GridScroll()
        if reusesGrid {
            scroll.topRow = capture.scrollTop()
            scroll.bottomRow = capture.scrollBottom()
            scroll.deltaRows = capture.scrollDelta()
        }
        let images = imageStore.layer(for: capture)
        imageStore.uploadStagedPixels()
        lastPresentedOverlay = overlay(of: capture)
        return PendingFrame(
            rows: capture.rows(),
            columns: capture.columns(),
            isFullscreenContentActive: capture.isFullscreenContentActive(),
            uniforms: capture.uniforms(),
            canReuseGrid: reusesGrid,
            scroll: scroll,
            images: images,
            backdrop: backdrop,
            richText: richTextStore.layer(for: capture)
        )
    }

    /// Draws one frame and commits it.
    ///
    /// The glyph source's frame is opened by Core rather than here — the builder
    /// calls `beginFrame` through the table as its first act, after checking the
    /// backend is drawable, so a backend missing a required hook is never asked
    /// to open a frame it cannot fill. A renderer that opened it too would open
    /// it twice and lose a frame of eviction protection.
    ///
    /// - Parameters:
    ///   - inputs: The frame Core builds from.
    ///   - uniforms: The constants every pass reads.
    ///   - descriptor: The pass to encode into.
    /// - Returns: The committed command buffer, or nil if one could not be made.
    @discardableResult
    func render(
        _ inputs: Ubiquitty.Rendering.BuildInputs,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        var backend = Ubiquitty.Rendering.GlyphBackend()
        backendBox.fillBackend(into: &backend)
        buildWithMeasuredInk { instances.build(inputs, backend: backend) }
        atlas.retainFrame(viewRetainLease)
        noteSheetPressure()

        return encode(uniforms: uniforms, into: descriptor)
    }

    /// Builds and encodes one frame without committing it.
    ///
    /// For a caller that owns presentation: the app's frame drive schedules the
    /// drawable present on the buffer before committing, and a buffer committed
    /// here could no longer take one.
    ///
    /// - Parameters:
    ///   - inputs: The frame Core builds from.
    ///   - uniforms: The constants every pass reads.
    ///   - descriptor: The pass to encode into.
    /// - Returns: The encoded, uncommitted command buffer, or nil.
    func encodeFrame(
        _ inputs: Ubiquitty.Rendering.BuildInputs,
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        canReuseGrid: Bool = false,
        scroll: GridScroll = GridScroll(),
        images: ImageLayer? = nil,
        backdrop: FrameEncoder.Backdrop? = nil,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        var backend = Ubiquitty.Rendering.GlyphBackend()
        backendBox.fillBackend(into: &backend)
        buildWithMeasuredInk { instances.build(inputs, backend: backend) }
        atlas.retainFrame(viewRetainLease)
        noteSheetPressure()
        return encodeWithoutCommit(
            uniforms: uniforms,
            canReuseGrid: canReuseGrid,
            scroll: scroll,
            images: images,
            backdrop: backdrop,
            into: descriptor
        )
    }

    /// Encodes whatever the last build put in the streams, and commits it.
    ///
    /// - Parameters:
    ///   - uniforms: The constants every pass reads.
    ///   - descriptor: The pass to encode into.
    /// - Returns: The committed command buffer, or nil if one could not be made.
    private func encode(
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        guard
            let commands = encodeWithoutCommit(uniforms: uniforms, canReuseGrid: false, scroll: GridScroll(), images: nil, into: descriptor)
        else {
            return nil
        }
        commands.commit()
        return commands
    }

    private func encodeWithoutCommit(
        uniforms: Ubiquitty.Rendering.FrameUniforms,
        canReuseGrid: Bool,
        scroll: GridScroll,
        images: ImageLayer?,
        backdrop: FrameEncoder.Backdrop? = nil,
        richText: RichTextLayer? = nil,
        viewportClipInPixels: CGRect? = nil,
        secondaryDescriptor: MTLRenderPassDescriptor? = nil,
        backgroundDescriptor: MTLRenderPassDescriptor? = nil,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        let width = Int(uniforms.viewportSizeInPixels.x)
        let height = Int(uniforms.viewportSizeInPixels.y)
        guard width > 0, height > 0,
            var grid = ensureGridTexture(width: width, height: height),
            let commands = queue.makeCommandBuffer()
        else {
            return nil
        }
        let viewportScissor: MTLScissorRect?
        if let clip = viewportClipInPixels {
            guard clip.minX.isFinite, clip.minY.isFinite, clip.maxX.isFinite, clip.maxY.isFinite else { return nil }
            let clipped = clip.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if clipped.isNull || clipped.isEmpty || ceil(clipped.minX) >= floor(clipped.maxX) || ceil(clipped.minY) >= floor(clipped.maxY) {
                viewportScissor = nil
            } else {
                // Round inward: no host cell may paint a reserved padding pixel.
                viewportScissor = MTLScissorRect(
                    x: Int(ceil(clipped.minX)),
                    y: Int(ceil(clipped.minY)),
                    width: Int(floor(clipped.maxX) - ceil(clipped.minX)),
                    height: Int(floor(clipped.maxY) - ceil(clipped.minY))
                )
            }
        } else {
            viewportScissor = nil
        }
        func prepareNativeTextures(_ front: inout MTLTexture?, _ back: inout MTLTexture?, enabled: Bool) -> Bool {
            guard enabled else {
                front = nil
                back = nil
                return true
            }
            if front?.width != width || front?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                front = queue.device.makeTexture(descriptor: descriptor)
                back = queue.device.makeTexture(descriptor: descriptor)
            }
            return front != nil && back != nil
        }
        guard prepareNativeTextures(&secondaryTexture, &secondaryTextureBack, enabled: secondaryDescriptor != nil),
            prepareNativeTextures(&vibrantBackgroundTexture, &vibrantBackgroundTextureBack, enabled: backgroundDescriptor != nil)
        else { return nil }
        if viewportClipInPixels != nil && viewportScissor == nil {
            // Padding may consume the entire view. Present an empty frame,
            // rather than leaving the previously visible host content on glass.
            func clear(_ texture: MTLTexture?, into target: MTLRenderPassDescriptor? = nil, color: MTLClearColor) -> Bool {
                guard texture != nil || target != nil else { return true }
                let pass = target ?? MTLRenderPassDescriptor()
                if let texture { pass.colorAttachments[0].texture = texture }
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = color
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
                encoder.endEncoding()
                return true
            }
            let ground = Self.premultipliedClear(
                uniforms.defaultBackground,
                opacity: uniforms.backgroundOpacity,
                straight: uniforms.bitmapTier != 0
            )
            let transparent = MTLClearColorMake(0, 0, 0, 0)
            guard clear(grid, color: ground), clear(nil, into: descriptor, color: ground),
                clear(secondaryTexture, color: transparent), clear(nil, into: secondaryDescriptor, color: transparent),
                clear(vibrantBackgroundTexture, color: transparent), clear(nil, into: backgroundDescriptor, color: transparent)
            else { return nil }
            gridCellWidthInPixels = uniforms.cellSizeInPixels.x
            gridCellHeightInPixels = uniforms.cellSizeInPixels.y
            canShiftGridByWholeRows = false
            instances.noteRead(by: commands)
            return commands
        }
        // Before the frame's own buffer is committed: the strips this build
        // rasterised reach the sheet on their own buffer, so a frame that is
        // built and then dropped cannot take them with it.
        atlas.flushStagedUploads()

        // The same comparison the verdict made, against the cell actually
        // going into the uniforms. It agrees by construction when the caller
        // asked `gridMatches` with these numbers; when it does not, the capture
        // was built against a target that is about to be cleared and the clean
        // rows exist nowhere. The frame cannot be repaired here — they were
        // never read — so the disagreement is counted and the safe half taken.
        let cellWidth = uniforms.cellSizeInPixels.x
        let cellHeight = uniforms.cellSizeInPixels.y
        let matchesRetainedCell = gridCellWidthInPixels == cellWidth && gridCellHeightInPixels == cellHeight
        let reusesGrid = canReuseGrid && matchesRetainedCell
        if reusesGrid {
            partialFrameCount += 1
        }
        if canReuseGrid && !matchesRetainedCell {
            retainedCellRefusalsAfterTrust += 1
            // The clean rows of this frame are drawn nowhere, so the target it
            // leaves is not one a later frame may Load.
            wantsFullRebuild = true
        }
        if !reusesGrid {
            gridCellWidthInPixels = cellWidth
            gridCellHeightInPixels = cellHeight
        }

        // A pending scroll shifts the retained pixels before the dirty rows
        // repaint over them: clear the back texture, blit the surviving bands
        // shifted, and swap. The drain marked the exposed band dirty at drain
        // time, so the content pass repaints the rows the shift uncovered. The
        // padding beside and below them is never repainted and keeps this
        // clear, so it must store the byte a full frame's grid-pass clear
        // stores there, which ``premultipliedClear`` holds it to.
        if reusesGrid, scroll.deltaRows != 0, let back = gridTextureBack {
            let scrolledCellHeight = Int(uniforms.cellSizeInPixels.y.rounded())
            let originY = Int(uniforms.originInPixels.y.rounded())
            let clearPass = scrollClearDescriptor
            clearPass.colorAttachments[0].texture = back
            clearPass.colorAttachments[0].loadAction = .clear
            clearPass.colorAttachments[0].clearColor = Self.premultipliedClear(
                uniforms.defaultBackground,
                opacity: uniforms.backgroundOpacity,
                straight: uniforms.bitmapTier != 0
            )
            clearPass.colorAttachments[0].storeAction = .store
            if let clear = commands.makeRenderCommandEncoder(descriptor: clearPass) {
                clear.endEncoding()
            }
            var damage = Ubiquitty.Rendering.FrameDamage()
            damage.scrollTop = scroll.topRow
            damage.scrollBottom = scroll.bottomRow
            damage.scrollDelta = scroll.deltaRows
            // Core lays out the bands: the same three copies Vulkan performs,
            // and the band edges are exactly the arithmetic a second writer
            // gets almost right — clamped against the wrong edge, the tear
            // sits at the bottom of the scroll region where a full-height
            // scene never looks.
            let rowsTotal = scrolledCellHeight > 0 ? (grid.height - originY) / scrolledCellHeight : 0
            let plan = Ubiquitty.Rendering.scrollBlitPlan(
                damage,
                Int32(rowsTotal),
                Int32(scrolledCellHeight),
                Int32(originY),
                Int32(grid.height)
            )
            if plan.bandCount > 0, let blit = commands.makeBlitCommandEncoder() {
                // Indexed rather than sequenced: `for band in` a C++ span boxes
                // the iterator in a heap-allocated CxxSequenceBox, which is one
                // allocation per scrolling frame to walk at most three bands.
                let bands = plan.activeBands()
                for index in 0..<bands.size() {
                    let band = bands[index]
                    blit.copy(
                        from: grid,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: Int(band.sourceYInPixels), z: 0),
                        sourceSize: MTLSize(
                            width: grid.width,
                            height: Int(band.heightInPixels),
                            depth: 1
                        ),
                        to: back,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: Int(band.destinationYInPixels), z: 0)
                    )
                }
                blit.endEncoding()
            }
            func shiftNativeTextures(_ front: inout MTLTexture?, _ back: inout MTLTexture?) -> Bool {
                guard let source = front, let destination = back else { return true }
                let clear = MTLRenderPassDescriptor()
                clear.colorAttachments[0].texture = destination
                clear.colorAttachments[0].loadAction = .clear
                clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                clear.colorAttachments[0].storeAction = .store
                guard let pass = commands.makeRenderCommandEncoder(descriptor: clear) else { return false }
                pass.endEncoding()
                if plan.bandCount > 0 {
                    guard let blit = commands.makeBlitCommandEncoder() else { return false }
                    let bands = plan.activeBands()
                    for index in 0..<bands.size() {
                        let band = bands[index]
                        blit.copy(
                            from: source,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: Int(band.sourceYInPixels), z: 0),
                            sourceSize: MTLSize(width: width, height: Int(band.heightInPixels), depth: 1),
                            to: destination,
                            destinationSlice: 0,
                            destinationLevel: 0,
                            destinationOrigin: MTLOrigin(x: 0, y: Int(band.destinationYInPixels), z: 0)
                        )
                    }
                    blit.endEncoding()
                }
                front = destination
                back = source
                return true
            }
            guard shiftNativeTextures(&secondaryTexture, &secondaryTextureBack),
                shiftNativeTextures(&vibrantBackgroundTexture, &vibrantBackgroundTextureBack)
            else { return nil }
            gridTextureBack = grid
            gridTexture = back
            grid = back
        }

        canShiftGridByWholeRows =
            gridTextureBack != nil
            && Double(uniforms.cellSizeInPixels.y) == Double(uniforms.cellSizeInPixels.y).rounded(.down)
            && Double(uniforms.originInPixels.y) == Double(uniforms.originInPixels.y).rounded(.down)

        var sheets = AtlasSheets()
        sheets.mono = atlas.texture
        sheets.wide = atlas.wideTexture
        sheets.proportional = atlas.proportionalTexture
        sheets.proportionalStrip = atlas.proportionalStripTexture
        sheets.color = atlas.colorTexture
        sheets.double = atlas.doubleTexture
        sheets.ligature = atlas.ligatureTexture

        // Pass one: the grid content, into the retained texture. Clear on a
        // full frame; Load keeps last frame's clean rows, which the builder
        // never re-emitted.
        let gridPass = gridPassDescriptor
        gridPass.colorAttachments[0].texture = grid
        gridPass.colorAttachments[0].loadAction = reusesGrid ? .load : .clear
        gridPass.colorAttachments[0].clearColor = Self.premultipliedClear(
            uniforms.defaultBackground,
            opacity: uniforms.backgroundOpacity,
            straight: uniforms.bitmapTier != 0
        )
        gridPass.colorAttachments[0].storeAction = .store
        let probeBuffer = passProbe?.makeFrameSampleBuffer()
        // Attach on every probed frame, the absent buffer included: gridPass
        // is one descriptor reused across frames, so a frame whose allocation
        // failed must clear the stored attachment rather than sample into the
        // previous frame's buffer while its completion handler resolves it.
        if let passProbe {
            passProbe.attach(to: gridPass, buffer: probeBuffer, slot: 0)
            passProbe.attach(to: descriptor, buffer: probeBuffer, slot: 2)
        }
        // Confine the grid passes to the content rectangle. A retained target
        // Loads its margins and never repaints them, so overhanging ink left
        // there — a combining stack above row zero, a left side bearing on
        // column zero — would stay for the life of the texture. Core's
        // rectangle rather than one derived here: derived twice, the two
        // differ in the last pixel on the one edge no frame cleans.
        let content =
            retainsGridCache
            ? Ubiquitty.Rendering.retainedContentRect(
                Ubiquitty.FloatPoint(x: uniforms.originInPixels.x, y: uniforms.originInPixels.y),
                Ubiquitty.FloatSize(width: uniforms.cellSizeInPixels.x, height: uniforms.cellSizeInPixels.y),
                Ubiquitty.GridSize(columns: Int32(instances.builtColumns), rows: Int32(instances.builtRows)),
                Ubiquitty.IntSize(width: Int32(grid.width), height: Int32(grid.height)),
                // The glyph slot's margins: as far as a glyph's ink may reach
                // past its cell, and what the builder repaints per rebuilt row.
                Ubiquitty.IntSize(
                    width: atlas.slotGeometry.glyphMarginInPixels.width,
                    height: atlas.slotGeometry.glyphMarginInPixels.height
                )
            ) : Ubiquitty.Rendering.RetainedContentRect()
        var contentScissor: MTLScissorRect? =
            content.isEmpty()
            ? nil
            : MTLScissorRect(
                x: Int(content.x),
                y: Int(content.y),
                width: Int(content.width),
                height: Int(content.height)
            )
        if let viewportScissor {
            if let contentScissorValue = contentScissor {
                let x = max(viewportScissor.x, contentScissorValue.x)
                let y = max(viewportScissor.y, contentScissorValue.y)
                let endX = min(viewportScissor.x + viewportScissor.width, contentScissorValue.x + contentScissorValue.width)
                let endY = min(viewportScissor.y + viewportScissor.height, contentScissorValue.y + contentScissorValue.height)
                guard endX > x, endY > y else { return nil }
                contentScissor = MTLScissorRect(x: x, y: y, width: endX - x, height: endY - y)
            } else {
                contentScissor = viewportScissor
            }
        }
        // A bitmap frame that cannot read its target draws its box overlays
        // in an encoded pass between the fills and the ink (FrameEncoder's
        // PassPhase), so the grid's work splits into three passes there.
        let splitsAtBoxOverlays = encoder.drawsBitmapPassesEncoded(uniforms) && instances.counts.boxFills > 0
        guard let contentPass = commands.makeRenderCommandEncoder(descriptor: gridPass) else { return nil }
        encoder.encodeGrid(
            instances,
            uniforms: uniforms,
            sheets: sheets,
            images: images,
            backdrop: backdrop,
            confinedTo: contentScissor,
            phase: splitsAtBoxOverlays ? .fills : .whole,
            into: contentPass
        )
        contentPass.endEncoding()
        if splitsAtBoxOverlays {
            guard let encodedGrid = encoder.encodedOverlayTarget(for: grid) else { return nil }
            let boxPass = MTLRenderPassDescriptor()
            boxPass.colorAttachments[0].texture = encodedGrid
            boxPass.colorAttachments[0].loadAction = .load
            boxPass.colorAttachments[0].storeAction = .store
            guard let boxes = commands.makeRenderCommandEncoder(descriptor: boxPass) else { return nil }
            if let contentScissor { boxes.setScissorRect(contentScissor) }
            encoder.encodeEncodedBoxOverlays(instances, uniforms: uniforms, segment: .head, into: boxes)
            boxes.endEncoding()
            let inkPass = MTLRenderPassDescriptor()
            inkPass.colorAttachments[0].texture = grid
            inkPass.colorAttachments[0].loadAction = .load
            inkPass.colorAttachments[0].storeAction = .store
            guard let ink = commands.makeRenderCommandEncoder(descriptor: inkPass) else { return nil }
            encoder.encodeGrid(
                instances,
                uniforms: uniforms,
                sheets: sheets,
                images: images,
                backdrop: backdrop,
                confinedTo: contentScissor,
                phase: .afterFills,
                into: ink
            )
            ink.endEncoding()
        }
        // A bitmap frame that cannot read its target draws the grid's rules
        // here, into a linear-format view of the retained grid, so the blend
        // mixes the stored bytes as the software renderer's rule mix does.
        if encoder.drawsBitmapPassesEncoded(uniforms), instances.counts.decorations > 0 {
            guard let encodedGrid = encoder.encodedOverlayTarget(for: grid) else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = encodedGrid
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let rules = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            if let contentScissor { rules.setScissorRect(contentScissor) }
            encoder.encodeEncodedRules(instances, uniforms: uniforms, sheets: sheets, segment: .head, into: rules)
            rules.endEncoding()
        }

        if let backgroundDescriptor, let background = vibrantBackgroundTexture {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = background
            pass.colorAttachments[0].loadAction = reusesGrid ? .load : .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            guard let fill = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            if let contentScissor { fill.setScissorRect(contentScissor) }
            encoder.encodeVibrantBackground(instances, uniforms: uniforms, into: fill)
            fill.endEncoding()
            guard let present = commands.makeRenderCommandEncoder(descriptor: backgroundDescriptor) else { return nil }
            encoder.blit(background, into: present)
            present.endEncoding()
        }
        if let secondaryDescriptor, let secondary = secondaryTexture {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = secondary
            pass.colorAttachments[0].loadAction = reusesGrid ? .load : .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            guard let ink = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            if let contentScissor { ink.setScissorRect(contentScissor) }
            encoder.encodeSecondaryInk(instances, uniforms: uniforms, sheets: sheets, into: ink)
            ink.endEncoding()
            guard let presentInk = commands.makeRenderCommandEncoder(descriptor: secondaryDescriptor) else { return nil }
            encoder.blit(secondary, into: presentInk)
            if let viewportScissor { presentInk.setScissorRect(viewportScissor) }
            encoder.clearSecondaryCursor(instances, uniforms: uniforms, sheets: sheets, into: presentInk)
            encoder.encodeSecondaryOverlays(instances, uniforms: uniforms, into: presentInk)
            presentInk.endEncoding()
        }

        // The frame's allocations are read by this buffer and by nothing after
        // it: the ring will not hand them out again until it has completed.
        instances.noteRead(by: commands)

        // Pass two: blit the grid into the drawable, overlays on top — the
        // cursor and selection move without dirtying rows, so they never land
        // in the retained texture.
        let encodesBitmapPasses = encoder.drawsBitmapPassesEncoded(uniforms)
        let overlayTarget =
            (uniforms.bitmapTier == 0 && instances.counts.overlays > 0)
                || (encodesBitmapPasses && (instances.counts.overlays > 0 || instances.counts.cursorTier.decorations > 0))
            ? descriptor.colorAttachments[0].texture.flatMap { encoder.encodedOverlayTarget(for: $0) }
            : nil
        guard let drawablePass = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            return nil
        }
        encoder.blit(grid, into: drawablePass)
        if let viewportScissor { drawablePass.setScissorRect(viewportScissor) }
        encoder.drawRichText(richText, uniforms: uniforms, into: drawablePass)
        let splitsCursorTier = encodesBitmapPasses && instances.counts.cursorTier.boxFills > 0
        encoder.encodeOverlays(
            instances,
            uniforms: uniforms,
            sheets: sheets,
            includesFloatingOverlays: overlayTarget == nil,
            phase: splitsCursorTier ? .fills : .whole,
            into: drawablePass
        )
        drawablePass.endEncoding()
        if splitsCursorTier, let target = descriptor.colorAttachments[0].texture {
            guard let encodedTarget = encoder.encodedOverlayTarget(for: target) else { return nil }
            let boxPass = MTLRenderPassDescriptor()
            boxPass.colorAttachments[0].texture = encodedTarget
            boxPass.colorAttachments[0].loadAction = .load
            boxPass.colorAttachments[0].storeAction = .store
            guard let boxes = commands.makeRenderCommandEncoder(descriptor: boxPass) else { return nil }
            if let viewportScissor { boxes.setScissorRect(viewportScissor) }
            encoder.encodeEncodedBoxOverlays(instances, uniforms: uniforms, segment: .cursorTier, into: boxes)
            boxes.endEncoding()
            let inkPass = MTLRenderPassDescriptor()
            inkPass.colorAttachments[0].texture = target
            inkPass.colorAttachments[0].loadAction = .load
            inkPass.colorAttachments[0].storeAction = .store
            guard let ink = commands.makeRenderCommandEncoder(descriptor: inkPass) else { return nil }
            if let viewportScissor { ink.setScissorRect(viewportScissor) }
            encoder.encodeOverlays(
                instances,
                uniforms: uniforms,
                sheets: sheets,
                includesFloatingOverlays: overlayTarget == nil,
                phase: .afterFills,
                into: ink
            )
            ink.endEncoding()
        }
        if let overlayTarget {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = overlayTarget
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let highlight = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            if let viewportScissor { highlight.setScissorRect(viewportScissor) }
            encoder.encodeEncodedOverlays(instances, uniforms: uniforms, sheets: sheets, into: highlight)
            highlight.endEncoding()
        }
        if let passProbe, let probeBuffer {
            passProbe.scheduleReport(on: commands, buffer: probeBuffer, isReusingGrid: reusesGrid)
        }
        return commands
    }

    /// The retained texture pair, rebuilt when the drawable size moves.
    private func ensureGridTexture(width: Int, height: Int) -> MTLTexture? {
        if let grid = gridTexture, grid.width == width, grid.height == height {
            return grid
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        gridTexture = queue.device.makeTexture(descriptor: descriptor)
        gridTextureBack = queue.device.makeTexture(descriptor: descriptor)
        gridTextureAllocations += 1
        return gridTexture
    }

    /// How many times the retained pair was allocated: once per drawn size.
    package private(set) var gridTextureAllocations = 0

    /// Lets the retained grid go, for a pane nobody can see.
    ///
    /// Two screens' worth of pixels — a hundred-odd megabytes at 5K — holding
    /// an image nothing composites. The next frame finds no target to reuse
    /// and builds whole: the caller's reuse verdict reads ``gridMatches``,
    /// which answers false with no texture, so the caller must also drop its
    /// damage baseline before it captures, or a capture that trusted the
    /// baseline hands the dirty rows to a frame with nothing under them.
    package func releaseRetainedGrid() {
        gridTexture = nil
        gridTextureBack = nil
        secondaryTexture = nil
        secondaryTextureBack = nil
        vibrantBackgroundTexture = nil
        vibrantBackgroundTextureBack = nil
    }

    /// A frame built from the grid and not yet encoded: the instances are in
    /// the ring, and these are the facts the encode needs beside them.
    ///
    /// The build reads the terminal and so runs under the model lock; the
    /// encode reads only the ring and the retained texture, so it runs after
    /// the lock is released and after the drawable is acquired — the wait for
    /// a drawable then never delays the capture, and a program's redraw that
    /// lands during that wait is not caught half-drawn. A caller encodes the
    /// frame it built before building another.
    package struct PendingFrame {
        package var rows: Int32
        package var columns: Int32
        package var isFullscreenContentActive: Bool
        package var cellSizeInPixels: CGSize {
            CGSize(width: Double(uniforms.cellSizeInPixels.x), height: Double(uniforms.cellSizeInPixels.y))
        }
        package var originInPixels: CGPoint {
            CGPoint(x: Double(uniforms.originInPixels.x), y: Double(uniforms.originInPixels.y))
        }
        package var isEdgeToEdge: Bool { uniforms.edgeToEdge != 0 }
        package var imageQuadCount: Int { images?.quadCount ?? 0 }
        var uniforms: Ubiquitty.Rendering.FrameUniforms
        var canReuseGrid: Bool
        var scroll: GridScroll
        var images: ImageLayer?
        var backdrop: FrameEncoder.Backdrop?
        var richText: RichTextLayer? = nil
        /// Presentation-only clipping, owned with this frame through encode.
        package var viewportClipInPixels: CGRect? = nil
    }

    /// Encodes a built frame into a pass; the command buffer is left
    /// uncommitted for the caller to present.
    ///
    /// A frame that stops part-way never reaches the retained texture, while
    /// the plan it was built from has already advanced Core's baseline past
    /// it, and a scroll may already have swapped the texture pair to a back
    /// texture nothing wrote. The retained grid is let go on that path, so the
    /// next frame finds no target to Load and builds every row.
    package func encode(
        _ pending: PendingFrame,
        secondaryDescriptor: MTLRenderPassDescriptor? = nil,
        backgroundDescriptor: MTLRenderPassDescriptor? = nil,
        into descriptor: MTLRenderPassDescriptor
    ) -> MTLCommandBuffer? {
        let commands = encodeWithoutCommit(
            uniforms: pending.uniforms,
            canReuseGrid: pending.canReuseGrid,
            scroll: pending.scroll,
            images: pending.images,
            backdrop: pending.backdrop,
            richText: pending.richText,
            viewportClipInPixels: pending.viewportClipInPixels,
            secondaryDescriptor: secondaryDescriptor,
            backgroundDescriptor: backgroundDescriptor,
            into: descriptor
        )
        if commands == nil {
            releaseRetainedGrid()
            noteFrameNotPresented()
        }
        return commands
    }

    /// One frame's pending scroll, in rows. Zero delta means none survived the
    /// drain's bounds check.
    struct GridScroll {
        var topRow: Int32 = 0
        var bottomRow: Int32 = -1
        var deltaRows: Int32 = 0
    }

    /// The clear colour, premultiplied the way a bare cell is stored.
    ///
    /// The cell pass stores the encoded background times the opacity, rounded
    /// to a whole code, and lets the sRGB target's encode-on-store undo its
    /// decode, so the byte the compositor reads is `round(encode(bg) × a)` —
    /// premultiplied on the encoded components, which is what Core Animation
    /// un-premultiplies by. A clear bypasses the shader, so it applies the same
    /// arithmetic here: the premultiply on the encoded value, the rounding to a
    /// code, then the linearise the target's encode undoes. Premultiplying in
    /// linear light stores a brighter byte, and a cleared margin then
    /// un-premultiplies past white next to cells that do not.
    ///
    /// The rounding is what makes the clear one byte however it is stored.
    /// Handed a colour between two codes, the target's encode may land on
    /// either, and nothing holds two paths to the same choice: a pass that only
    /// clears, as the scroll's back texture takes, and a pass that clears and
    /// then draws need not agree. A scrolled retained frame keeps the first's
    /// ground in the padding beside the rows the shift uncovered, where its
    /// full rebuild has the second's, so a channel past the middle of a code —
    /// Noir's ground at an opacity of 0.502613 is 10.55 and 11.56 of 255 in
    /// red and green — would make the two frames differ there. A whole code is
    /// stored as itself on every path. The alpha is rounded the same way, as
    /// the software renderer rounds its own.
    ///
    /// - Parameters:
    ///   - background: The default background, sRGB-encoded components.
    ///   - opacity: The frame's background opacity.
    ///   - straight: Whether the frame holds straight colour rather than
    ///     premultiplied — the bitmap tier, whose cell pass stores the software
    ///     renderer's bytes and whose margins must hold what its margins hold:
    ///     the background at the frame's alpha, not the background scaled by it.
    /// - Returns: The clear for a pass writing the sRGB target.
    package static func premultipliedClear(
        _ background: Ubiquitty.Rendering.Vec4,
        opacity: Float,
        straight: Bool = false
    ) -> MTLClearColor {
        // In single precision, as the cell pass forms `background × opacity ×
        // 255`, so the two round the same product.
        func code(_ value: Float) -> Double {
            Double((value * 255).rounded()) / 255
        }
        func stored(_ c: Float) -> Double {
            Ubiquitty.Rendering.SRGBGamma.linearize(code(straight ? c : c * opacity))
        }
        return MTLClearColor(
            red: stored(background.x),
            green: stored(background.y),
            blue: stored(background.z),
            alpha: code(opacity)
        )
    }
}
