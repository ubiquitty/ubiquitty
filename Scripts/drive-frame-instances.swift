// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-frame-instances.swift — Core builds a frame into Swift-owned memory.
//
// `FrameInstances` allocates the twelve streams, tells Core how much room they
// hold, calls `buildCellInstances`, and grows and rebuilds when a stream comes
// back over capacity. None of that is visible to a compiler: spans bound to the
// wrong buffer, a capacity reported in bytes instead of elements, and a retry
// that never fires all typecheck. So a frame is built and the counts are read.
//
// The glyph source here reports every glyph present and rasterises nothing. What
// is under test is the production of instance streams and the round trip through
// the C table, not the ink — a source that drew would make the check depend on
// installed fonts without covering a line more of this path.
//
// The retry is the part worth having a driver for. It only runs when a stream
// overruns, which the ordinary frame never does, so the branch that repairs a
// flood is the branch that never executes until a flood arrives.

import Metal
import UbiquittyCore

/// A glyph source that reports every glyph present at a fixed slot.
///
/// Enough for Core to build a frame: what is under test is the stream
/// production, not the ink.
final class StubGlyphSource: GlyphSource {
    var frames = 0
    func beginFrame() { frames += 1 }
    var primaryFacePitch: Ubiquitty.Rendering.FontMetrics.FacePitch { .Fixed }
    func shapePrimaryRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] { [] }
    func bindMonoAtlas(into binding: inout Ubiquitty.Rendering.MonoAtlasBinding) {
        binding.slotCapacity = 256
    }
    func monoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph {
        var g = Ubiquitty.Rendering.AtlasGlyph()
        g.present = codePoint != 0x20
        return g
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
enum FrameInstancesDriver {
    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("drive-frame-instances: no Metal device")
            exit(2)
        }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  ok   \(label) \(detail)")
            } else {
                failures += 1
                print("  FAIL \(label) \(detail)")
            }
        }

        let rows = 24
        let columns = 80
        let instances = FrameInstances(device: device)
        let source = StubGlyphSource()
        let box = GlyphBackendContext(source: source)
        var backend = Ubiquitty.Rendering.GlyphBackend()
        box.fillBackend(into: &backend)

        var cells = [Ubiquitty.Cell](repeating: Ubiquitty.Cell(), count: rows * columns)
        for i in 0..<cells.count { cells[i].codePoint = 0x41 }

        var palette = Ubiquitty.TermPalette()
        cells.withUnsafeBufferPointer { cellBuffer in
            var inputs = Ubiquitty.Rendering.BuildInputs()
            inputs.cells = cellBuffer.baseAddress
            inputs.rows = Int32(rows)
            inputs.columns = Int32(columns)
            inputs.palette = withUnsafePointer(to: &palette) { $0 }
            inputs.metrics.cellWidth = 10.0
            inputs.metrics.cellHeight = 20.0
            inputs.metrics.deviceScale = 2.0
            inputs.metrics.atlasToDevicePixels = 1.0

            let counts = instances.build(inputs, backend: backend)
            check("beginFrame reached the source", source.frames > 0, "frames=\(source.frames)")
            check("Core filled the cell stream", counts.cells > 0, "cells=\(counts.cells) of \(rows * columns)")
            check("every visible cell emitted", counts.cells == rows * columns, "\(counts.cells)")
            check(
                "the cell buffer was allocated",
                instances.cells.buffer != nil,
                "capacity=\(instances.cells.capacity)"
            )
            check("nothing truncated", !instances.didTruncate)
        }

        // The capture overload, which is the path a renderer uses. An empty
        // capture is the only frame Swift can build one from today, because
        // Ubiquitty::Terminal does not import and capture() cannot be reached
        // from here. It still proves the overload links, sizes its streams and
        // reaches the same truncation verdict as the inputs path.
        if let capture = Ubiquitty.Rendering.FrameCapture.make() {
            let empty = instances.build(capture, backend: backend)
            check("an empty capture builds no cells", empty.cells == 0)
            check("an empty capture truncates nothing", !instances.didTruncate)
            check("an empty capture has no grid", capture.rows() == 0 && capture.columns() == 0)
        } else {
            check("the capture allocated", false)
        }

        print(failures == 0 ? "drive-frame-instances: ok" : "drive-frame-instances: FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
