// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PerfDiagnosticsWindows.swift — the Paint Heatmap window and the Drawing
// Debug panel of one terminal window.
//
// Both are skins over Core: the heatmap's counters, decay, extent and colour
// ramp are `Ubiquitty::Diagnostics::PaintHeatmap`'s, and the panel's readout is
// `drawingDebugText`. What lives here is the AppKit around them — a window, a
// view that fills squares, a timer in the common modes so both keep refreshing
// while a menu tracks or a window resizes.

import AppKit
internal import UbiquittyCore

/// One filled square per cell, painted on Core's heat ramp.
final class PaintHeatmapView: NSView {
    /// The rows and columns the last refresh drew.
    var extent = Ubiquitty.Diagnostics.PaintHeatmapExtent()

    /// Row zero at the top, as in the grid.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let side = CGFloat(Ubiquitty.Diagnostics.PaintHeatmap.cellSizeInPoints())
        for row in 0..<Int(extent.rows) {
            for column in 0..<Int(extent.columns) {
                let packed = Ubiquitty.Diagnostics.PaintHeatmap.cellColor(Int32(row), Int32(column))
                NSColor(packedRGB: packed).setFill()
                NSRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side).fill()
            }
        }
    }
}

/// The Paint Heatmap window over one terminal window's active surface.
///
/// Opening clears the counters, so the picture is the activity since the window
/// opened. Each refresh asks Core to decay the counters and for the extent the
/// live grid now has, and reshapes the window to it, so a DECCOLM switch or a
/// resize is followed. The surface watched is the one the terminal window has
/// active at each refresh: focus moving to another pane moves the heat pass with
/// it, and the pane left stops paying for it.
@MainActor
package final class PaintHeatmapWindowController: NSWindowController, NSWindowDelegate {
    private let surfaceProvider: () -> TerminalSurface?
    private weak var watchedSurface: TerminalSurface?
    private var refreshTimer: Timer?
    private let heatmapView = PaintHeatmapView(frame: .zero)

    /// Makes the window, unshown.
    ///
    /// - Parameter surfaceProvider: Answers which surface to watch, asked at
    ///   every refresh.
    init(surfaceProvider: @escaping () -> TerminalSurface?) {
        self.surfaceProvider = surfaceProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paint Heatmap"
        window.isReleasedWhenClosed = false
        window.contentView = heatmapView
        super.init(window: window)
        window.delegate = self
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether the window is on screen.
    package var isShowing: Bool { window?.isVisible ?? false }

    /// The extent the last refresh drew, for a reader checking the window
    /// followed the grid.
    package var drawnExtent: Ubiquitty.Diagnostics.PaintHeatmapExtent { heatmapView.extent }

    /// The surface the heat pass runs on.
    package var surfaceWatched: TerminalSurface? { watchedSurface }

    /// Shows the window and starts the refresh.
    func open() {
        Ubiquitty.Diagnostics.PaintHeatmap.noteWindowOpened()
        window?.orderFront(nil)
        refresh()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Ubiquitty.Diagnostics.PaintHeatmap.refreshIntervalSeconds(), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Hides the window and stops the heat pass.
    func dismiss() {
        stopWatching()
        window?.orderOut(nil)
    }

    /// Decays the counters, follows the grid, and redraws.
    func refresh() {
        guard let window, window.isVisible else { return }
        let surface = surfaceProvider()
        if surface !== watchedSurface {
            watchedSurface?.disablePaintHeatmap()
            surface?.enablePaintHeatmap()
            watchedSurface = surface
        }
        guard let surface else { return }
        let grid = surface.paintHeatmapGrid
        let extent = Ubiquitty.Diagnostics.PaintHeatmap.refreshWindow(Int32(clamping: grid.rows), Int32(clamping: grid.columns))
        heatmapView.extent = extent
        let size = NSSize(width: extent.widthInPoints, height: extent.heightInPoints)
        if window.contentView?.bounds.size != size {
            window.setContentSize(size)
        }
        heatmapView.needsDisplay = true
    }

    package func windowWillClose(_ notification: Notification) {
        stopWatching()
    }

    private func stopWatching() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        watchedSurface?.disablePaintHeatmap()
        watchedSurface = nil
    }
}

/// The Drawing Debug panel over one terminal window's active surface: grid,
/// cursor, history, face, atlas and frame counts, re-read on Core's interval.
@MainActor
package final class DrawingDebugPanelController: NSWindowController, NSWindowDelegate {
    private let surfaceProvider: () -> TerminalSurface?
    private var refreshTimer: Timer?
    private let label = NSTextField(labelWithString: "")

    /// Makes the panel, unshown.
    ///
    /// - Parameter surfaceProvider: Answers which surface to report on, asked
    ///   at every refresh.
    init(surfaceProvider: @escaping () -> TerminalSurface?) {
        self.surfaceProvider = surfaceProvider
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Drawing Debug"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        label.frame = NSRect(x: 10, y: 8, width: 300, height: 204)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        panel.contentView?.addSubview(label)
        super.init(window: panel)
        panel.delegate = self
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether the panel is on screen.
    package var isShowing: Bool { window?.isVisible ?? false }

    /// The readout the panel shows.
    package var shownText: String { label.stringValue }

    /// Shows the panel and starts the refresh.
    func open() {
        window?.orderFront(nil)
        refresh()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Ubiquitty.Diagnostics.drawingDebugRefreshIntervalSeconds(), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Hides the panel and stops the refresh.
    func dismiss() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window?.orderOut(nil)
    }

    /// Re-reads the facts and shows them.
    func refresh() {
        guard let window, window.isVisible, let surface = surfaceProvider() else { return }
        label.stringValue = surface.drawingDebugText()
    }

    package func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
