// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PerfDiagnosticsScenarios.swift — the performance diagnostics, turned on
// against a Swift-shell window and read back.
//
// The measurement and the policy are Core's and Core's tests pin them; what a
// scenario can break that a Core test cannot is the wiring: the capture this
// arm takes reaching the heat shadow, the window this arm opens driving Core's
// decay and following the grid, the frames and deliveries this arm handles
// reaching the perf log, and the presented handler this arm arms reaching the
// present-leg ring. Each assertion reads what the diagnostic reports, so taking
// the wiring out turns it red.
//
// The harness pumps no display link, so frames are drawn with `display()`,
// which encodes and presents on the spot; a heat count is read before the
// window's refresh has had a turn to decay it.

import AppKit
import UbiquittyCore
import UbiquittyKit

/// Supplies compositor visibility while the harness keeps its windows offscreen.
@MainActor
private final class DiagnosticVisibilityWindow: NSWindow {
    var isUnoccluded = true {
        didSet {
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
        }
    }

    override var occlusionState: NSWindow.OcclusionState {
        isUnoccluded ? [.visible] : []
    }
}

@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Draws one frame now, rebuilding every row when asked to.
@MainActor
private func drawFrame(_ surface: TerminalSurface, rebuildingEveryRow: Bool) {
    if rebuildingEveryRow {
        surface.invalidateRetainedBaseline()
    }
    surface.needsDisplay = true
    surface.display()
}

/// Cells whose heat counter is not zero, over a grid.
@MainActor
private func heatedCells(rows: Int, columns: Int) -> [(row: Int, column: Int)] {
    var heated: [(row: Int, column: Int)] = []
    for row in 0..<rows {
        for column in 0..<columns where Ubiquitty.Diagnostics.PaintHeatmap.cellCount(Int32(row), Int32(column)) != 0 {
            heated.append((row, column))
        }
    }
    return heated
}

/// Opens a Swift-shell window over a session that writes nothing, so every
/// cell change on screen is one the scenario fed.
@MainActor
private func openQuietShell(_ t: UBUITestContext) -> (TerminalWindowController, NSWindow, TerminalSurface)? {
    guard
        let shell = TerminalWindowController.spawn(
            arguments: ["/bin/sh", "-c", "exec sleep 1000"],
            localePolicy: .auto,
            sessionLifetime: .outlivesChild
        ),
        let window = shell.window,
        let content = window.contentView,
        let surface = terminalSurface(under: content)
    else {
        t.expect(false, desc: "a Swift-shell window opens with a surface")
        return nil
    }
    window.orderFront(nil)
    t.pump(0.4)
    return (shell, window, surface)
}

/// Registers the performance-diagnostics scenarios with the UI-test runner.
enum PerfDiagnosticsScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("adaptive_drive_debug_polling_follows_window_visibility") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let window = DiagnosticVisibilityWindow(
                    contentRect: .zero,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                var polls = 0
                let controller = AdaptiveDriveDebugWindowController(window: window) {
                    polls += 1
                    return nil
                }
                defer { window.close() }

                t.pump(0.3)
                t.expect(polls == 0, desc: "constructing an unopened diagnostic window does not poll")

                controller.showWindow(nil)
                t.expect(
                    t.wait(until: { polls >= 2 }, timeout: 2),
                    desc: "the visible diagnostic's hosting view receives recurring readouts"
                )

                window.close()
                let afterClose = polls
                t.expect(controller.window === window, desc: "closing retains the window and its hosting view for reopening")
                t.pump(0.35)
                t.expect(polls == afterClose, desc: "the actual close callback cancels polling without a stale readout")

                controller.showWindow(nil)
                t.expect(
                    t.wait(until: { polls >= afterClose + 2 }, timeout: 2),
                    desc: "reopening the retained window resumes recurring readouts"
                )

                window.orderOut(nil)
                let afterOrderOut = polls
                t.pump(0.35)
                t.expect(polls == afterOrderOut, desc: "ordering out the diagnostic stops readouts")

                controller.showWindow(nil)
                t.expect(
                    t.wait(until: { polls >= afterOrderOut + 2 }, timeout: 2),
                    desc: "showing an ordered-out diagnostic resumes readouts"
                )

                window.isUnoccluded = false
                let afterOcclusion = polls
                t.pump(0.35)
                t.expect(polls == afterOcclusion, desc: "a covered diagnostic does no periodic readout work")

                window.isUnoccluded = true
                t.expect(
                    t.wait(until: { polls >= afterOcclusion + 2 }, timeout: 2),
                    desc: "an occlusion notification resumes readouts when the diagnostic becomes visible"
                )
            }
        }

        UBUITestRegister("swift_shell_paint_heatmap_counts_only_changed_cells") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let opened = openQuietShell(t) else { return }
                let (shell, window, surface) = opened
                defer {
                    shell.closePerfDiagnostics()
                    window.close()
                }
                t.expect(
                    Ubiquitty.Diagnostics.isPerfDiagnosticsBuild(),
                    desc: "premise: the harness build carries UBIQUITTY_PERF_DIAG"
                )
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                for row in 0..<8 {
                    surface.feed(Data("heat-row-\(row) \(String(repeating: "x", count: 30))\r\n".utf8))
                }
                drawFrame(surface, rebuildingEveryRow: true)
                let grid = surface.paintHeatmapGrid

                NSApp.sendAction(#selector(TerminalWindowController.toggleHeatmap(_:)), to: shell, from: nil)
                guard let heatmap = shell.paintHeatmapWindow, heatmap.isShowing else {
                    t.expect(false, desc: "View > Paint Heatmap opens the window on a Swift-shell window")
                    return
                }
                t.expect(surface.isPaintHeatmapEnabled, desc: "the window turns the active pane's heat pass on")

                // The frame after opening: a baseline, not a whole-grid flash.
                drawFrame(surface, rebuildingEveryRow: true)
                let afterBaseline = heatedCells(rows: grid.rows, columns: grid.columns)
                t.expect(
                    afterBaseline.isEmpty,
                    desc: "the first frame after opening records a baseline (\(afterBaseline.count) cells heated)"
                )

                // Wholesale redraws of the same content are not churn.
                for _ in 0..<3 {
                    drawFrame(surface, rebuildingEveryRow: true)
                }
                let afterRedraws = heatedCells(rows: grid.rows, columns: grid.columns)
                t.expect(
                    afterRedraws.isEmpty,
                    desc: "three full redraws of unchanged content heat nothing (\(afterRedraws.count) cells heated)"
                )

                // One cell's content changes, and only that cell heats.
                surface.feed(Data("\u{1b}[3;5HZ".utf8))
                drawFrame(surface, rebuildingEveryRow: true)
                let afterChange = heatedCells(rows: grid.rows, columns: grid.columns)
                t.expect(
                    afterChange.count == 1 && afterChange.first?.row == 2 && afterChange.first?.column == 4,
                    desc: "writing one cell heats that cell alone (heated: \(afterChange.map { "\($0.row),\($0.column)" }))"
                )

                // A pen change is a content change.
                let heatAfterChange = Ubiquitty.Diagnostics.PaintHeatmap.cellCount(2, 4)
                surface.feed(Data("\u{1b}[3;5H\u{1b}[31mZ\u{1b}[m".utf8))
                drawFrame(surface, rebuildingEveryRow: false)
                let heatAfterRecolour = Ubiquitty.Diagnostics.PaintHeatmap.cellCount(2, 4)
                t.expect(
                    heatAfterRecolour > heatAfterChange,
                    desc: "recolouring the same character heats the cell again (\(heatAfterChange) to \(heatAfterRecolour))"
                )

                // Closing stops the pass; reopening clears the counters and
                // resyncs, so content that changed while closed is no flash.
                NSApp.sendAction(#selector(TerminalWindowController.toggleHeatmap(_:)), to: shell, from: nil)
                t.expect(!heatmap.isShowing, desc: "the second toggle closes the window")
                t.expect(!surface.isPaintHeatmapEnabled, desc: "and turns the heat pass off")
                surface.feed(Data("\u{1b}[5;1Hchanged while nobody watched".utf8))
                drawFrame(surface, rebuildingEveryRow: true)
                NSApp.sendAction(#selector(TerminalWindowController.toggleHeatmap(_:)), to: shell, from: nil)
                t.expect(
                    heatedCells(rows: grid.rows, columns: grid.columns).isEmpty,
                    desc: "reopening clears the counters"
                )
                drawFrame(surface, rebuildingEveryRow: true)
                let afterReopen = heatedCells(rows: grid.rows, columns: grid.columns)
                t.expect(
                    afterReopen.isEmpty,
                    desc: "and the frame after reopening is a baseline again (\(afterReopen.count) cells heated)"
                )
                NSApp.sendAction(#selector(TerminalWindowController.toggleHeatmap(_:)), to: shell, from: nil)
            }
        }

        UBUITestRegister("swift_shell_paint_heatmap_window_follows_the_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let opened = openQuietShell(t) else { return }
                let (shell, window, surface) = opened
                defer {
                    surface.feed(Data("\u{1b}[?3l".utf8))
                    shell.closePerfDiagnostics()
                    window.close()
                }
                let side = Ubiquitty.Diagnostics.PaintHeatmap.cellSizeInPoints()

                NSApp.sendAction(#selector(TerminalWindowController.toggleHeatmap(_:)), to: shell, from: nil)
                guard let heatmap = shell.paintHeatmapWindow, let heatmapWindow = heatmap.window, heatmap.isShowing else {
                    t.expect(false, desc: "View > Paint Heatmap opens the window")
                    return
                }
                let opening = surface.paintHeatmapGrid
                t.expect(
                    Int(heatmap.drawnExtent.columns) == opening.columns && Int(heatmap.drawnExtent.rows) == opening.rows,
                    desc:
                        "the window draws the live grid (\(heatmap.drawnExtent.columns)x\(heatmap.drawnExtent.rows) of \(opening.columns)x\(opening.rows))"
                )
                t.expect(
                    heatmapWindow.contentView?.bounds.size
                        == NSSize(width: Double(opening.columns) * side, height: Double(opening.rows) * side),
                    desc: "one square per cell: \(heatmapWindow.contentView?.bounds.size ?? .zero)"
                )

                // DECCOLM widens the grid, and the window follows it.
                surface.feed(Data("\u{1b}[?40h\u{1b}[?3h".utf8))
                surface.needsDisplay = true
                let took132 = t.wait(until: { surface.paintHeatmapGrid.columns == 132 }, timeout: 3.0)
                t.expect(took132, desc: "premise: CSI ?3h takes the grid to 132 columns")
                t.pump(0.2)
                let wide = surface.paintHeatmapGrid
                t.expect(
                    heatmap.drawnExtent.columns == 132
                        && heatmapWindow.contentView?.bounds.size == NSSize(width: 132 * side, height: Double(wide.rows) * side),
                    desc:
                        "the window reshapes to 132 columns (\(heatmap.drawnExtent.columns) drawn, \(heatmapWindow.contentView?.bounds.size ?? .zero))"
                )

                // Core owns the decay, and the window's refresh is what runs it.
                drawFrame(surface, rebuildingEveryRow: true)
                surface.feed(Data("\u{1b}[2;2HQ".utf8))
                drawFrame(surface, rebuildingEveryRow: false)
                let fresh = Ubiquitty.Diagnostics.PaintHeatmap.cellCount(1, 1)
                t.expect(fresh > 0, desc: "premise: the written cell heats (\(fresh))")
                t.pump(0.7)
                let decayed = Ubiquitty.Diagnostics.PaintHeatmap.cellCount(1, 1)
                t.expect(decayed < fresh, desc: "the window's refresh decays it (\(fresh) to \(decayed))")

                // The drawing-debug panel reads the same pane, and keeps
                // reading it.
                NSApp.sendAction(#selector(TerminalWindowController.toggleDrawingDebug(_:)), to: shell, from: nil)
                guard let panel = shell.drawingDebugPanel, panel.isShowing else {
                    t.expect(false, desc: "View > Drawing Debug opens the panel")
                    return
                }
                t.expect(
                    panel.shownText.contains("grid        132\u{00D7}\(wide.rows) cols\u{00D7}rows"),
                    desc: "the panel reads the grid: \(panel.shownText.split(separator: "\n").first ?? "")"
                )
                t.expect(panel.shownText.contains("font        "), desc: "and the face it is drawn in")
                surface.feed(Data("\u{1b}[?3l".utf8))
                let took80 = t.wait(until: { surface.paintHeatmapGrid.columns != 132 }, timeout: 3.0)
                t.expect(took80, desc: "premise: CSI ?3l leaves 132 columns")
                t.pump(0.4)
                let narrow = surface.paintHeatmapGrid
                t.expect(
                    panel.shownText.contains("grid        \(narrow.columns)\u{00D7}\(narrow.rows) cols\u{00D7}rows"),
                    desc: "the panel's refresh follows the grid back: \(panel.shownText.split(separator: "\n").first ?? "")"
                )
                NSApp.sendAction(#selector(TerminalWindowController.toggleDrawingDebug(_:)), to: shell, from: nil)
                t.expect(!panel.isShowing, desc: "the second toggle closes the panel")
                NSApp.sendAction(#selector(TerminalWindowController.toggleHeatmap(_:)), to: shell, from: nil)
                t.expect(!heatmap.isShowing, desc: "and the heatmap window")
            }
        }

        UBUITestRegister("swift_shell_perf_log_reads_frames_deliveries_and_the_resume") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let wasActive = TerminalSurface.isFramePerfLogActiveForTesting
                TerminalSurface.activateFramePerfLogForTesting()
                defer {
                    if !wasActive {
                        TerminalSurface.deactivateFramePerfLogForTesting()
                    }
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: [
                            "/bin/sh", "-c",
                            "sleep 0.5; i=0; while [ $i -lt 3000 ]; do echo perf-log-line-$i; i=$((i+1)); done; exec sleep 1000",
                        ],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                window.orderFront(nil)

                var frames: UInt64 = 0
                var bytes: UInt64 = 0
                var drains: UInt64 = 0
                var reportsSeen = TerminalSurface.framePerfLogForTesting.reportCount
                let firstReport = reportsSeen
                for _ in 0..<150 {
                    drawFrame(surface, rebuildingEveryRow: false)
                    t.pump(0.02)
                    let log = TerminalSurface.framePerfLogForTesting
                    if log.reportCount != reportsSeen {
                        reportsSeen = log.reportCount
                        frames += UInt64(log.lastReport.frames)
                        bytes += log.lastReport.bytes
                        drains += UInt64(log.lastReport.drains)
                    }
                }
                let open = TerminalSurface.framePerfLogForTesting.currentWindow
                frames += UInt64(open.frames)
                bytes += open.bytes
                drains += UInt64(open.drains)
                t.expect(reportsSeen > firstReport, desc: "the log flushed windows while the shell wrote (\(reportsSeen - firstReport))")
                t.expect(frames > 0, desc: "the Swift arm's frames reach the log (\(frames))")
                t.expect(bytes > 30_000, desc: "the session's deliveries reach it with their bytes (\(bytes))")
                t.expect(drains > 0, desc: "counted as deliveries (\(drains))")

                // The frame clock's idle-to-active edge reaches the log, which
                // is what keeps an idle pause out of its drops.
                let beforeResume = CACurrentMediaTime()
                surface.resumeFrameClockForTesting()
                t.expect(
                    TerminalSurface.framePerfLogLastResumeForTesting >= beforeResume,
                    desc: "the clock's resume is noted (\(TerminalSurface.framePerfLogLastResumeForTesting) against \(beforeResume))"
                )
            }
        }

        UBUITestRegister("swift_shell_present_leg_reaches_the_perf_log") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let wasActive = TerminalSurface.isFramePerfLogActiveForTesting
                TerminalSurface.activateFramePerfLogForTesting()
                defer {
                    if !wasActive {
                        TerminalSurface.deactivateFramePerfLogForTesting()
                    }
                }
                guard let opened = openQuietShell(t) else { return }
                let (_, window, surface) = opened
                defer { window.close() }
                // The opening frames' handlers land before the count starts.
                t.pump(0.3)
                let before = surface.presentLegForTesting
                let framesBefore = surface.framesEncodedForTesting
                for _ in 0..<30 {
                    drawFrame(surface, rebuildingEveryRow: true)
                    t.pump(0.017)
                }
                let presented = surface.framesEncodedForTesting - framesBefore
                t.expect(presented > 0, desc: "premise: the window presented frames (\(presented))")
                // Every presented frame was armed, and its handler posts to the
                // meter's channel from the present thread: a leg when the
                // drawable reached the glass, an unshown present when it did
                // not. The harness's windows are never composited, so here it
                // is the second; the leg's arithmetic and its report are
                // test_present_leg_meter's.
                let posted = t.wait(
                    until: {
                        let leg = surface.presentLegForTesting
                        return (leg.samples - before.samples) + (leg.unshown - before.unshown) == UInt64(presented)
                    },
                    timeout: 3.0
                )
                let leg = surface.presentLegForTesting
                t.expect(
                    posted,
                    desc:
                        "each presented frame's handler reaches the meter (\(leg.samples - before.samples) legs and \(leg.unshown - before.unshown) unshown for \(presented) frames)"
                )
                t.expect(
                    leg.reportCount == 0 || (leg.medianMilliseconds > 0 && leg.medianMilliseconds < 1000),
                    desc: "a report that closed holds a model-to-glass time: p50 \(leg.medianMilliseconds) ms"
                )
            }
        }
    }
}
