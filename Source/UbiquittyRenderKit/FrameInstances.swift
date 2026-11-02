// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FrameInstances.swift — the twelve streams one frame's build writes.
//
// The renderer's only producer of instance data. It does not decide what a cell
// looks like, where a rule sits, or which glyph a cluster resolves to: Core's
// `buildCellInstances` decides all of that and writes the answers straight into
// Metal memory this type owns. What lives here is the part Core cannot do —
// allocating the memory, telling Core how much there is, and growing it when a
// frame needs more than it was offered.
//
// Core reports an overrun rather than failing: a count larger than the capacity
// it was given is the builder saying what it needed. So the build is a loop,
// not a call, and the second pass is the one that draws. That loop is the whole
// reason the streams are gathered into one type — separate ivars made the
// retry a thing each caller had to remember, and the frontends that forgot it
// dropped whatever overran.

import Metal
import UbiquittyCore

/// The instance streams for one frame, and the memory Core writes them into.
///
/// Growth policy per stream is chosen by what decides its length. Eight are
/// sized from the grid, so they settle after a resize and never grow again;
/// four follow frame content and climb under a flood. See ``BufferGrowth``.
final class FrameInstances {
    /// One cell quad per visible cell. Grid-sized.
    var cells: GrowableBuffer
    /// Mono coverage glyphs, for the subpixel text pass. Grid-sized.
    var glyphs: GrowableBuffer
    /// Two-cell glyphs, kept off the mono sheet. Grid-sized.
    var wideGlyphs: GrowableBuffer
    /// Glyphs shaped in the proportional face. Grid-sized.
    var proportionalGlyphs: GrowableBuffer
    /// Bounded proportional-run fallback strips. Grid-sized.
    var proportionalStrips: GrowableBuffer
    /// Colour emoji, sampled from the RGBA sheet. Grid-sized.
    var colorGlyphs: GrowableBuffer
    /// Shaped ligature strips. Grid-sized.
    var ligatureGlyphs: GrowableBuffer
    /// DECDWL/DECDHL 2x masters. Grid-sized.
    var doubleGlyphs: GrowableBuffer
    /// Underlines, strikethroughs, overlines and frames.
    ///
    /// Content-sized: a frame of plain text emits none and a frame of styled
    /// text emits one per run, so this climbs with what is on screen rather
    /// than with the grid.
    var decorations: GrowableBuffer
    /// Box-drawing and block-element fills. Content-sized, as ``decorations``.
    var boxFills: GrowableBuffer
    /// Margin-restore strips beside rebuilt rows, drawn without blending.
    var marginStrips: GrowableBuffer
    /// Cursor, selection and prompt-mark quads. Content-sized.
    var overlays: GrowableBuffer

    /// How many instances each stream held after the last ``build(_:backend:)``.
    ///
    /// Clamped to what was actually allocated, so these are safe to draw with
    /// even when a build overran and the regrow was refused.
    private(set) var counts = Ubiquitty.Rendering.InstanceCounts()

    /// The grid shape the last build was sized for.
    ///
    /// The renderer needs it for the content rectangle its passes are confined
    /// to, and the uniforms carry a cell size and an origin but not a row or
    /// column count. Recorded here rather than at each call site because every
    /// overload funnels through ``sizeGridStreams(rows:columns:)`` — a caller
    /// that set it itself would be the one entry point that forgot.
    /// Where the last build's ink crossed from one row into the next, one
    /// byte per row boundary (``InstanceBuffers/rowInkCrossings``).
    private(set) var rowInkCrossings: [UInt8] = [0]

    private(set) var builtRows = 0
    /// The column count the last build was sized for.
    private(set) var builtColumns = 0

    /// Whether the last build overran a stream and could not be given the room.
    ///
    /// The one condition that still costs a frame its accuracy, so it is
    /// reported rather than swallowed: the frame draws, short.
    private(set) var didTruncate = false

    /// Declares the twelve streams, allocating none of them.
    ///
    /// The strides are checked here rather than assumed. Core pins each with a
    /// `static_assert` against the shader's expectation, but that binds the C++
    /// side only: these buffers are strided by Swift's imported layout, so a
    /// disagreement would shift every instance after the first by a few bytes —
    /// a frame that draws, wrongly, with every count correct. Once per renderer,
    /// so it costs nothing per frame.
    ///
    /// - Parameter device: The device the streams allocate on.
    init(device: MTLDevice) {
        precondition(
            MemoryLayout<Ubiquitty.Rendering.CellInstance>.stride == 64
                && MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride == 64
                && MemoryLayout<Ubiquitty.Rendering.OverlayInstance>.stride == 112
                && MemoryLayout<Ubiquitty.Rendering.DecorationInstance>.stride == 160,
            "instance stride disagrees with Core/Rendering/CellInstance.h"
        )
        cells = GrowableBuffer(device: device, growth: .exactFit, stride: MemoryLayout<Ubiquitty.Rendering.CellInstance>.stride)
        glyphs = GrowableBuffer(device: device, growth: .exactFit, stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride)
        wideGlyphs = GrowableBuffer(device: device, growth: .exactFit, stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride)
        proportionalGlyphs = GrowableBuffer(
            device: device,
            growth: .exactFit,
            stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride
        )
        proportionalStrips = GrowableBuffer(
            device: device,
            growth: .exactFit,
            stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride
        )
        colorGlyphs = GrowableBuffer(device: device, growth: .exactFit, stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride)
        ligatureGlyphs = GrowableBuffer(device: device, growth: .exactFit, stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride)
        doubleGlyphs = GrowableBuffer(device: device, growth: .exactFit, stride: MemoryLayout<Ubiquitty.Rendering.GlyphInstance>.stride)
        decorations = GrowableBuffer(
            device: device,
            growth: .geometric,
            stride: MemoryLayout<Ubiquitty.Rendering.DecorationInstance>.stride
        )
        boxFills = GrowableBuffer(device: device, growth: .geometric, stride: MemoryLayout<Ubiquitty.Rendering.OverlayInstance>.stride)
        marginStrips = GrowableBuffer(device: device, growth: .geometric, stride: MemoryLayout<Ubiquitty.Rendering.OverlayInstance>.stride)
        overlays = GrowableBuffer(device: device, growth: .geometric, stride: MemoryLayout<Ubiquitty.Rendering.OverlayInstance>.stride)
    }

    /// Builds one frame's instances from a capture.
    ///
    /// The path a renderer uses: the capture owns the frame and Core reads it,
    /// so nothing here names `BuildInputs`. That is what lets a Swift type hold
    /// the frame across frames at all — the inputs are non-escapable and a
    /// stored property of one is rejected for its accessors.
    ///
    /// - Parameters:
    ///   - capture: The captured frame Core builds from.
    ///   - backend: The glyph source Core calls back into.
    @discardableResult
    func build(
        _ capture: Ubiquitty.Rendering.FrameCapture,
        backend: Ubiquitty.Rendering.GlyphBackend,
        scope: Ubiquitty.Rendering.BuildScope = .Damaged
    ) -> Ubiquitty.Rendering.InstanceCounts {
        advanceFrame()
        sizeGridStreams(rows: Int(capture.rows()), columns: Int(capture.columns()))
        var built = callCore(capture, backend, scope)
        if overran(built) {
            grow(toFit: built)
            built = callCore(capture, backend, scope)
        }
        return record(built)
    }

    /// Builds one boundary-captured frame's instances with the caller's
    /// present-time view tiers composited over the frozen grid.
    ///
    /// - Parameters:
    ///   - capture: The boundary capture Core builds from.
    ///   - backend: The glyph source Core calls back into.
    ///   - view: The tiers composited over the captured grid.
    @discardableResult
    func build(
        _ capture: Ubiquitty.Rendering.FrameCapture,
        backend: Ubiquitty.Rendering.GlyphBackend,
        view: Ubiquitty.Rendering.FrameCapture.ViewTierOverrides,
        scope: Ubiquitty.Rendering.BuildScope = .Damaged
    ) -> Ubiquitty.Rendering.InstanceCounts {
        advanceFrame()
        sizeGridStreams(rows: Int(capture.rows()), columns: Int(capture.columns()))
        var built = callCore(capture, backend, view, scope)
        if overran(built) {
            grow(toFit: built)
            built = callCore(capture, backend, view, scope)
        }
        return record(built)
    }

    /// Builds one frame's instances from inputs a caller assembled.
    ///
    /// Sizes the grid-derived streams, calls Core, and repeats once if any
    /// stream came back over its capacity — Core reports the count it needed, so
    /// the second pass is sized exactly and cannot overrun for the same reason.
    /// A stream whose regrow is refused leaves ``didTruncate`` set and its count
    /// clamped.
    ///
    /// - Parameters:
    ///   - inputs: The frame Core builds from.
    ///   - backend: The glyph source Core calls back into.
    @discardableResult
    func build(
        _ inputs: Ubiquitty.Rendering.BuildInputs,
        backend: Ubiquitty.Rendering.GlyphBackend
    ) -> Ubiquitty.Rendering.InstanceCounts {
        advanceFrame()
        sizeGridStreams(rows: Int(inputs.rows), columns: Int(inputs.columns))
        var built = callCore(inputs, backend)
        if overran(built) {
            grow(toFit: built)
            built = callCore(inputs, backend)
        }
        return record(built)
    }

    // MARK: - Building

    /// Sizes every grid-derived stream for a frame of `rows` x `columns`.
    ///
    /// Straight-line rather than a loop over an array of closures. At -O that
    /// array is a 128-byte heap allocation, a runtime metadata instantiation and
    /// fourteen atomic retain/release operations per call, all to reach six
    /// method calls — measured in the driver's disassembly. A stream added to
    /// ``InstanceBuffers`` and forgotten here draws nothing rather than drawing
    /// wrong, which is the hazard this list carries either way.
    ///
    /// - Parameters:
    ///   - rows: The frame's rows.
    ///   - columns: The frame's columns.
    /// Moves every stream onto the next allocation of its ring.
    ///
    /// Once per frame, before anything is written: the previous frames are
    /// still reading the allocations they were built into, and a stream that
    /// did not advance would have this build overwrite them mid-draw.
    func advanceFrame() {
        cells.advanceFrame()
        glyphs.advanceFrame()
        wideGlyphs.advanceFrame()
        proportionalGlyphs.advanceFrame()
        proportionalStrips.advanceFrame()
        colorGlyphs.advanceFrame()
        ligatureGlyphs.advanceFrame()
        doubleGlyphs.advanceFrame()
        decorations.advanceFrame()
        boxFills.advanceFrame()
        marginStrips.advanceFrame()
        overlays.advanceFrame()
    }

    /// Records the command buffer that reads this frame's allocations.
    ///
    /// - Parameter commands: The frame's command buffer.
    func noteRead(by commands: MTLCommandBuffer) {
        cells.noteRead(by: commands)
        glyphs.noteRead(by: commands)
        wideGlyphs.noteRead(by: commands)
        proportionalGlyphs.noteRead(by: commands)
        proportionalStrips.noteRead(by: commands)
        colorGlyphs.noteRead(by: commands)
        ligatureGlyphs.noteRead(by: commands)
        doubleGlyphs.noteRead(by: commands)
        decorations.noteRead(by: commands)
        boxFills.noteRead(by: commands)
        marginStrips.noteRead(by: commands)
        overlays.noteRead(by: commands)
    }

    private func sizeGridStreams(rows: Int, columns: Int) {
        builtRows = rows
        builtColumns = columns
        if rowInkCrossings.count != rows + 1 {
            rowInkCrossings = [UInt8](repeating: 0, count: max(rows + 1, 1))
        }
        let gridCells = max(rows * columns, 1)
        // Every cell can emit one of each of these, and a row laid out as
        // letters one cell more, the quad that paints the pane past its last
        // cell, so the grid plus a row's worth is the bound and there is
        // nothing for a retry to discover.
        cells.ensure(gridCells + rows)
        glyphs.ensure(gridCells)

        // The rest are seeded rather than pre-sized. A null stream tells the
        // builder this backend has no such lane at all -- it is a capability
        // answer, not a capacity one -- so a box cell meeting a null box stream
        // is demoted to the text lane and drawn from the font's own glyph,
        // bearings and all, breaking the strokes at each cell boundary. A seed
        // of zero would leave the pointer null and say the lane is absent.
        //
        // A non-null stream with little room says something different: Core
        // reports the count a frame NEEDS, not the count it managed to write
        // (`emitBoxFill` counts past its capacity by contract, and
        // `buildCellInstances` accumulates that count), so an overrun names its
        // own remedy and `grow(toFit:)` reaches the exact size in one step.
        // These lanes are near-empty on the ASCII a terminal mostly shows, and
        // a grid-sized allocation each is wired memory per surface per scale.
        let seed = max(columns, 1)
        wideGlyphs.ensure(seed)
        proportionalGlyphs.ensure(seed)
        proportionalStrips.ensure(seed)
        colorGlyphs.ensure(seed)
        ligatureGlyphs.ensure(seed)
        doubleGlyphs.ensure(seed)
        boxFills.ensure(seed)
        // Two per row plus the strip above the first and below the last.
        marginStrips.ensure(rows * 2 + 2)
    }

    /// Records what a build reported, so both entry points reach the same
    /// truncation verdict rather than each deciding it.
    private func record(
        _ built: Ubiquitty.Rendering.InstanceCounts
    ) -> Ubiquitty.Rendering.InstanceCounts {
        didTruncate = overran(built)
        counts = clamped(built)
        if Self.isLigatureDumpEnabled {
            dumpLigatureStream()
        }
        if Self.isSkipInkDumpEnabled {
            dumpSkipInkStream()
        }
        if Self.isGlyphDumpEnabled {
            dumpGlyphRow()
        }
        return counts
    }

    /// Whether the ligature stream prints after every build.
    ///
    /// The retained-vs-direct discriminator: identical scenes through the two
    /// capture paths should build identical strip slices, and pixels cannot
    /// say which side of the encode a difference entered on.
    private static let isLigatureDumpEnabled = getenv("UBIQUITTY_DUMP_LIGATURE_INSTANCES") != nil
    private static let isSkipInkDumpEnabled = getenv("UBIQUITTY_DUMP_SKIP_INK") != nil
    private static let isGlyphDumpEnabled = getenv("UBIQUITTY_DUMP_GLYPH_ROW") != nil

    /// The rules the last build cut around ink, and the widest clearance any
    /// of them keeps from the ink it crosses.
    ///
    /// Walked on demand rather than tallied per build: a reader asking whether
    /// descenders break the rule is a probe, and the build is the hot path.
    package var skipInkRules: (count: Int, widestPadInPixels: Float) {
        let decorationCount = Int(counts.decorations)
        guard decorationCount > 0,
            let decorationBase = decorations.elements(as: Ubiquitty.Rendering.DecorationInstance.self)
        else {
            return (0, 0)
        }
        var count = 0
        var widestPad: Float = 0
        for index in 0..<decorationCount where decorationBase[index].skipInk != 0 {
            count += 1
            widestPad = max(widestPad, decorationBase[index].padInAtlas.x)
        }
        return (count, widestPad)
    }

    /// Prints every skip-ink decoration beside the phased glyph of its cell, for
    /// a reader checking that the rule's coverage tap lands on the ink it skips.
    private func dumpSkipInkStream() {
        let decorationCount = Int(counts.decorations)
        let glyphCount = Int(counts.glyphs)
        guard decorationCount > 0,
            let decorationBase = decorations.elements(as: Ubiquitty.Rendering.DecorationInstance.self),
            let glyphBase = glyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        else {
            return
        }
        var lines = "[skipink] decorations=\(decorationCount) glyphs=\(glyphCount)\n"
        for index in 0..<decorationCount where decorationBase[index].skipInk != 0 {
            let d = decorationBase[index]
            lines +=
                "[skipink]   rule x=\(d.topLeftInPixels.x)..\(d.bottomRightInPixels.x) y=\(d.topLeftInPixels.y)..\(d.bottomRightInPixels.y) ink uv=\(d.inkTopLeft.x)..\(d.inkBottomRight.x) v=\(d.inkTopLeft.y)..\(d.inkBottomRight.y) slot=\(d.glyphSlotTopLeftUV.x)..\(d.glyphSlotBottomRightUV.x) pad=\(d.padInAtlas.x),\(d.padInAtlas.y)\n"
            for g in 0..<glyphCount where abs(glyphBase[g].originInPixels.x - d.topLeftInPixels.x) < 40 {
                let i = glyphBase[g]
                lines +=
                    "[skipink]     glyph o=\(i.originInPixels.x),\(i.originInPixels.y) s=\(i.sizeInPixels.x),\(i.sizeInPixels.y) uv=\(i.atlasTopLeft.x)..\(i.atlasBottomRight.x) v=\(i.atlasTopLeft.y)..\(i.atlasBottomRight.y)\n"
            }
        }
        fputs(lines, stderr)
    }

    /// Prints one build's first glyph row: each quad origin beside the atlas
    /// slot it samples.
    ///
    /// The subpixel design places every quad on the pixel grid and expresses
    /// the pen's fraction by choosing among the pre-shifted phase VARIANTS in
    /// the atlas — so with a fractional advance, consecutive cells of one
    /// letter must sample DIFFERENT slots, cycling through the phase count.
    /// A frame whose ink sits wrong while its quads are right shows up here as
    /// the cycle collapsing: many origins, one uv. The uv is the witness the
    /// per-frame phase log cannot carry, because the log reads the options and
    /// the variant is chosen after them.
    private func dumpGlyphRow() {
        let glyphCount = Int(counts.glyphs)
        guard glyphCount > 0, let base = glyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self) else {
            return
        }
        // Every glyph the build emitted, each with its own y — no banding.
        //
        // No grouping by equal originInPixels.y: that y is the GLYPH's ink top,
        // not a row baseline. 's', 'R' and 't' in one row sit at three
        // different values, so such a filter slices arbitrary subsets of a
        // single row and calls them rows, dropping glyphs and whole coloured
        // spans without a word.
        //
        // So this reports what the build contains and lets the reader group.
        // The cap is generous rather than tight: a truncated dump reads as a
        // short row, which is the same lie one layer down.
        var lines = "[glyphrow] n=\(glyphCount)\n"
        for index in 0..<min(glyphCount, 96) {
            let instance = base[index]
            // The foreground BYTES, not a tier derived from them. The tier is
            // rasterTierForByte in CellInstanceBuilder.cpp — sRGB linearised
            // through SRGBGamma::linearize, then Rec.709 weighted — and it is
            // file-scope there, unreachable from here. A second derivation
            // written in this file would be a second chance to disagree with
            // the one that keys the slot: weighting the sRGB values directly
            // reports the same tier for default and red text. The reader
            // derives; the dump reports.
            let foreground = instance.foreground
            let byte = { (v: Float) in Int((min(max(v, 0), 1) * 255).rounded()) }
            lines +=
                "[glyphrow]   o=(\(instance.originInPixels.x),\(instance.originInPixels.y))"
                + " uv=(\(instance.atlasTopLeft.x),\(instance.atlasTopLeft.y))"
                + " fg=(\(byte(foreground.x)),\(byte(foreground.y)),\(byte(foreground.z)))\n"
        }
        if glyphCount > 96 {
            lines += "[glyphrow]   ... \(glyphCount - 96) more not printed\n"
        }
        fputs(lines, stderr)
    }

    private func dumpLigatureStream() {
        let count = Int(counts.ligatureGlyphs)
        guard count > 0, let base = ligatureGlyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self) else {
            return
        }
        var lines = "[dump] ligature n=\(count)\n"
        for index in 0..<count {
            let instance = base[index]
            lines +=
                "[dump]   o=(\(instance.originInPixels.x),\(instance.originInPixels.y))"
                + " s=(\(instance.sizeInPixels.x),\(instance.sizeInPixels.y))"
                + " uv=(\(instance.atlasTopLeft.x),\(instance.atlasTopLeft.y))-(\(instance.atlasBottomRight.x),\(instance.atlasBottomRight.y))\n"
        }
        fputs(lines, stderr)
    }

    private func callCore(
        _ inputs: Ubiquitty.Rendering.BuildInputs,
        _ backend: Ubiquitty.Rendering.GlyphBackend
    ) -> Ubiquitty.Rendering.InstanceCounts {
        // The crossings are written beside the streams, into storage the
        // build borrows for the call.
        rowInkCrossings.withUnsafeMutableBufferPointer { crossings in
            var out = Ubiquitty.Rendering.InstanceBuffers()
            fillBuffers(into: &out)
            out.rowInkCrossings = crossings.baseAddress
            out.rowInkCrossingCapacity = crossings.count
            return Ubiquitty.Rendering.buildCellInstances(inputs, backend, out)
        }
    }

    private func callCore(
        _ capture: Ubiquitty.Rendering.FrameCapture,
        _ backend: Ubiquitty.Rendering.GlyphBackend,
        _ scope: Ubiquitty.Rendering.BuildScope
    ) -> Ubiquitty.Rendering.InstanceCounts {
        // The crossings are written beside the streams, into storage the
        // build borrows for the call.
        rowInkCrossings.withUnsafeMutableBufferPointer { crossings in
            var out = Ubiquitty.Rendering.InstanceBuffers()
            fillBuffers(into: &out)
            out.rowInkCrossings = crossings.baseAddress
            out.rowInkCrossingCapacity = crossings.count
            return capture.build(backend, out, scope)
        }
    }

    private func callCore(
        _ capture: Ubiquitty.Rendering.FrameCapture,
        _ backend: Ubiquitty.Rendering.GlyphBackend,
        _ view: Ubiquitty.Rendering.FrameCapture.ViewTierOverrides,
        _ scope: Ubiquitty.Rendering.BuildScope
    ) -> Ubiquitty.Rendering.InstanceCounts {
        // The crossings are written beside the streams, into storage the
        // build borrows for the call.
        rowInkCrossings.withUnsafeMutableBufferPointer { crossings in
            var out = Ubiquitty.Rendering.InstanceBuffers()
            fillBuffers(into: &out)
            out.rowInkCrossings = crossings.baseAddress
            out.rowInkCrossingCapacity = crossings.count
            return capture.build(backend, out, view, scope)
        }
    }

    /// Points `out` at the twelve streams, pointer and capacity per stream.
    ///
    /// Filled through an `inout` rather than returned because `InstanceBuffers`
    /// is non-escapable and a method cannot return one. One list, because a
    /// stream added to it and forgotten in a second copy draws nothing while
    /// every count stays right.
    ///
    /// - Parameter out: The buffer table to point at this frame's streams.
    private func fillBuffers(into out: inout Ubiquitty.Rendering.InstanceBuffers) {
        out.cells = cells.elements(as: Ubiquitty.Rendering.CellInstance.self)
        out.cellCapacity = cells.capacity
        out.glyphs = glyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.glyphCapacity = glyphs.capacity
        out.wideGlyphs = wideGlyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.wideGlyphCapacity = wideGlyphs.capacity
        out.proportionalGlyphs = proportionalGlyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.proportionalGlyphCapacity = proportionalGlyphs.capacity
        out.proportionalStrips = proportionalStrips.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.proportionalStripCapacity = proportionalStrips.capacity
        out.colorGlyphs = colorGlyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.colorGlyphCapacity = colorGlyphs.capacity
        out.ligatureGlyphs = ligatureGlyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.ligatureGlyphCapacity = ligatureGlyphs.capacity
        out.doubleGlyphs = doubleGlyphs.elements(as: Ubiquitty.Rendering.GlyphInstance.self)
        out.doubleGlyphCapacity = doubleGlyphs.capacity
        out.decorations =
            decorations.elements(as: Ubiquitty.Rendering.DecorationInstance.self)
        out.decorationCapacity = decorations.capacity
        out.boxFills = boxFills.elements(as: Ubiquitty.Rendering.OverlayInstance.self)
        out.boxFillCapacity = boxFills.capacity
        out.marginStrips = marginStrips.elements(as: Ubiquitty.Rendering.OverlayInstance.self)
        out.marginStripCapacity = marginStrips.capacity
        out.overlays = overlays.elements(as: Ubiquitty.Rendering.OverlayInstance.self)
        out.overlayCapacity = overlays.capacity
    }

    private func overran(_ built: Ubiquitty.Rendering.InstanceCounts) -> Bool {
        built.cells > cells.capacity
            || built.glyphs > glyphs.capacity
            || built.wideGlyphs > wideGlyphs.capacity
            || built.proportionalGlyphs > proportionalGlyphs.capacity
            || built.proportionalStrips > proportionalStrips.capacity
            || built.colorGlyphs > colorGlyphs.capacity
            || built.ligatureGlyphs > ligatureGlyphs.capacity
            || built.doubleGlyphs > doubleGlyphs.capacity
            || built.decorations > decorations.capacity
            || built.boxFills > boxFills.capacity
            || built.marginStrips > marginStrips.capacity
            || built.overlays > overlays.capacity
    }

    private func grow(toFit built: Ubiquitty.Rendering.InstanceCounts) {
        cells.ensure(built.cells)
        glyphs.ensure(built.glyphs)
        wideGlyphs.ensure(built.wideGlyphs)
        proportionalGlyphs.ensure(built.proportionalGlyphs)
        proportionalStrips.ensure(built.proportionalStrips)
        colorGlyphs.ensure(built.colorGlyphs)
        ligatureGlyphs.ensure(built.ligatureGlyphs)
        doubleGlyphs.ensure(built.doubleGlyphs)
        decorations.ensure(built.decorations)
        boxFills.ensure(built.boxFills)
        marginStrips.ensure(built.marginStrips)
        overlays.ensure(built.overlays)
    }

    /// Caps each count at the room that exists, so a refused regrow draws a
    /// short frame rather than reading past a buffer.
    private func clamped(_ built: Ubiquitty.Rendering.InstanceCounts) -> Ubiquitty.Rendering.InstanceCounts {
        var out = built
        out.cells = min(built.cells, cells.capacity)
        out.glyphs = min(built.glyphs, glyphs.capacity)
        out.wideGlyphs = min(built.wideGlyphs, wideGlyphs.capacity)
        out.proportionalGlyphs = min(built.proportionalGlyphs, proportionalGlyphs.capacity)
        out.proportionalStrips = min(built.proportionalStrips, proportionalStrips.capacity)
        out.colorGlyphs = min(built.colorGlyphs, colorGlyphs.capacity)
        out.ligatureGlyphs = min(built.ligatureGlyphs, ligatureGlyphs.capacity)
        out.doubleGlyphs = min(built.doubleGlyphs, doubleGlyphs.capacity)
        out.decorations = min(built.decorations, decorations.capacity)
        out.boxFills = min(built.boxFills, boxFills.capacity)
        out.marginStrips = min(built.marginStrips, marginStrips.capacity)
        out.overlays = min(built.overlays, overlays.capacity)
        return out
    }
}
