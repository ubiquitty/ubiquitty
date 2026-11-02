// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+PerfDiagnostics.swift — View > Drawing Debug and
// View > Paint Heatmap, against a Kit-hosted window.
//
// The menu items exist only in a build carrying UBIQUITTY_PERF_DIAG, and the
// actions ask Core whether this is one: a shipping build answers no and they do
// nothing. The windows report
// on the pane the reader is in, for the reason every other action here targets
// the focused surface.

import AppKit
internal import UbiquittyCore

extension TerminalWindowController {
    /// View > Paint Heatmap (Shift-Cmd-H): opens or closes the window showing
    /// where this window's active pane repaints changed content.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func toggleHeatmap(_ sender: Any?) {
        guard Ubiquitty.Diagnostics.isPerfDiagnosticsBuild() else { return }
        if let heatmap = paintHeatmapWindow, heatmap.isShowing {
            heatmap.dismiss()
            return
        }
        let heatmap =
            paintHeatmapWindow
            ?? PaintHeatmapWindowController { [weak self] in
                self?.activeSurface
            }
        paintHeatmapWindow = heatmap
        heatmap.open()
    }

    /// View > Drawing Debug (Ctrl-Cmd-D): opens or closes the panel reading
    /// out this window's active pane.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func toggleDrawingDebug(_ sender: Any?) {
        guard Ubiquitty.Diagnostics.isPerfDiagnosticsBuild() else { return }
        if let panel = drawingDebugPanel, panel.isShowing {
            panel.dismiss()
            return
        }
        let panel =
            drawingDebugPanel
            ?? DrawingDebugPanelController { [weak self] in
                self?.activeSurface
            }
        drawingDebugPanel = panel
        panel.open()
    }

    /// Closes both diagnostics windows, for a terminal window going away.
    package func closePerfDiagnostics() {
        paintHeatmapWindow?.dismiss()
        paintHeatmapWindow = nil
        drawingDebugPanel?.dismiss()
        drawingDebugPanel = nil
    }
}
