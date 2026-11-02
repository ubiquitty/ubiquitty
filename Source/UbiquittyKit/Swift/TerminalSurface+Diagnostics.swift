// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Diagnostics.swift — the surface's side of the performance
// diagnostics: the drawing-debug readout a panel shows, the grid a heatmap
// window tracks, and the perf log and present leg a scenario turns on and
// reads. The policies are Core's; this gathers the surface's facts for them.

internal import CxxStdlib
import Foundation
internal import UbiquittyCore

extension TerminalSurface {
    /// What the drawing-debug panel reports about this surface.
    ///
    /// Core reads the terminal's half under the model lock; the renderer's
    /// half comes from the frame renderer that draws this surface.
    ///
    /// - Returns: The facts, ready for Core's readout.
    package func drawingDebugFacts() -> Ubiquitty.Diagnostics.DrawingDebugFacts {
        var facts = Ubiquitty.Diagnostics.DrawingDebugFacts()
        _ = drive.withTerminal { terminal in
            Ubiquitty.Diagnostics.readTerminalFacts(&facts, terminal)
        }
        facts.viewOffset = Int32(clamping: viewOffset)
        facts.themeIndex = drive.currentThemeIndex()
        if let rendererFacts = (renderer as? SurfaceRenderer)?.drawingDebugRendererFacts(for: self) {
            facts.fontName = std.string(rendererFacts.fontName)
            facts.fontSizeInPoints = rendererFacts.pointSize
            facts.cellWidthInPoints = Double(rendererFacts.cellSize.width)
            facts.cellHeightInPoints = Double(rendererFacts.cellSize.height)
            facts.atlasSlotsUsed = Int32(clamping: rendererFacts.atlasSlotsUsed)
            facts.atlasSlotCapacity = Int32(clamping: rendererFacts.atlasSlotCapacity)
            facts.cellsPerFrame = UInt64(max(0, rendererFacts.cellsPerFrame))
            facts.overlaysPerFrame = UInt64(max(0, rendererFacts.overlaysPerFrame))
        }
        return facts
    }

    /// The drawing-debug panel's text for this surface, in Core's words.
    package func drawingDebugText() -> String {
        String(Ubiquitty.Diagnostics.drawingDebugText(drawingDebugFacts()))
    }

    /// The grid a paint heatmap window over this surface tracks.
    package var paintHeatmapGrid: (rows: Int, columns: Int) {
        let snapshot = drive.readSnapshot()
        return (Int(snapshot.rows), Int(snapshot.columns))
    }

    /// Turns the process's perf log on, for a scenario reading what it
    /// reports without UBIQUITTY_PERFLOG in the environment.
    package static func activateFramePerfLogForTesting() {
        SurfaceRenderer.framePerfLog.activate()
    }

    /// Turns the process's perf log off again after such a scenario.
    package static func deactivateFramePerfLogForTesting() {
        SurfaceRenderer.framePerfLog.deactivate()
    }

    /// Whether the process's perf log is on.
    package static var isFramePerfLogActiveForTesting: Bool {
        SurfaceRenderer.framePerfLog.isActive()
    }

    /// The perf log's windows so far: how many flushed, the last flushed, and
    /// the one being aggregated.
    package static var framePerfLogForTesting:
        (
            reportCount: UInt64,
            lastReport: Ubiquitty.Diagnostics.PerfWindowReport,
            currentWindow: Ubiquitty.Diagnostics.PerfWindowReport
        )
    {
        (
            SurfaceRenderer.framePerfLog.reportCount(),
            SurfaceRenderer.framePerfLog.lastReport(),
            SurfaceRenderer.framePerfLog.currentWindow()
        )
    }

    /// When the perf log last heard the frame clock resume, on the clock
    /// `CACurrentMediaTime` reads.
    package static var framePerfLogLastResumeForTesting: Double {
        SurfaceRenderer.framePerfLog.lastResumeSeconds()
    }

    /// The present legs this surface's renderer collected, the presents its
    /// handler reported with no presented time, and the last report it closed.
    package var presentLegForTesting: (samples: UInt64, unshown: UInt64, reportCount: Int, medianMilliseconds: Double) {
        guard let renderer = renderer as? SurfaceRenderer else { return (0, 0, 0, 0) }
        let report = renderer.presentLeg.lastReport()
        return (
            renderer.presentLeg.samplesRecorded(), renderer.presentLeg.unshownPresents(), Int(report.count), report.p50
        )
    }
}
