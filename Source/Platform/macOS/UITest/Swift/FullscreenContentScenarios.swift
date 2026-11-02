// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FullscreenContentScenarios — DECSET 7402 on the Swift arm, one layer above
// the model.
//
// Core pins the facts (test_terminal_frame_inputs: the capture drops its
// origin under a Color letterbox; test_runtime: the snapshot publishes the
// resolved bit). These scenarios assert what the FRAME did with them, on the
// origin the last frame was placed at and the insets the pointer maps
// through, because the ledger's entries were "partial" for exactly the gap a
// model-level probe cannot see: RenderKit plumbed an edge mode nothing fed,
// and the padding stayed wherever the style put it.

import AppKit
import UbiquittyKit

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

/// The Color letterbox, then the mode: what an image application sends.
private let colourLetterboxOn = "\u{1b}]7402;fill=1a2b3c\u{07}\u{1b}[?7402h"
/// The same mode bit with the terminal content left visible around the image.
private let passthroughLetterboxOn = "\u{1b}]7402;fill=pass\u{07}\u{1b}[?7402h"
private let fullscreenContentOff = "\u{1b}[?7402l"

/// Whether two device-pixel origins name the same corner.
///
/// A half pixel of tolerance: the padded origin is a point value times the
/// backing scale, rounded on one side and not the other.
private func sameOrigin(_ a: (x: Float, y: Float), _ b: (x: Float, y: Float)) -> Bool {
    abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
}

enum FullscreenContentScenarios {
    static func register() {
        UBUITestRegister("swift_shell_decset_7402_takes_the_frame_edge_to_edge_and_gives_the_padding_back") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the harness runs inside the app")
                    return
                }
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                // A padding this arm has something to drop. Restored to what the
                // run started with, read off the surface rather than guessed.
                guard let opening = surface.gridFitBoxForTesting else {
                    t.expect(false, desc: "the surface reports the box it fits a grid into")
                    return
                }
                let restoreLeft = Double(opening.insets.left)
                let restoreTop = Double(opening.insets.top)
                app.settingsSetWindowPaddingLeft(12.0)
                app.settingsSetWindowPaddingTop(10.0)
                defer {
                    app.settingsSetWindowPaddingLeft(restoreLeft)
                    app.settingsSetWindowPaddingTop(restoreTop)
                }
                surface.needsDisplay = true
                t.pump(0.4)

                guard let fit = surface.gridFitBoxForTesting,
                    let paddedOrigin = surface.lastFrameOriginForTesting,
                    let paddedInsets = surface.gridFrameInsetsForTesting
                else {
                    t.expect(false, desc: "the surface reports its fit, its frame origin and its frame insets")
                    return
                }
                let scale = Float(window.backingScaleFactor > 0 ? window.backingScaleFactor : 1)
                let expectedPadded = (x: Float(fit.insets.left) * scale, y: Float(fit.insets.top) * scale)
                t.expect(
                    fit.insets.left >= 12 && fit.insets.top >= 10,
                    desc: "the padding reached the fit (\(fit.insets.left), \(fit.insets.top))"
                )
                t.expect(
                    sameOrigin(paddedOrigin, expectedPadded),
                    desc: "before the mode the frame starts one padding in (\(paddedOrigin) vs \(expectedPadded))"
                )
                t.expect(
                    paddedInsets.left == fit.insets.left && paddedInsets.top == fit.insets.top,
                    desc: "and the pointer maps through the same padding"
                )
                let gridBefore = surface.drive.readSnapshot()

                // The Color letterbox: the frame goes to the drawable's edge,
                // the pointer follows it, and the grid keeps its count — the
                // mode moves no column, so the application is not resized.
                surface.feed(Data(colourLetterboxOn.utf8))
                surface.needsDisplay = true
                t.pump(0.4)
                let edgeOrigin = surface.lastFrameOriginForTesting ?? (x: -1, y: -1)
                t.expect(
                    sameOrigin(edgeOrigin, (x: 0, y: 0)),
                    desc: "under a Color letterbox the frame starts at the drawable's corner (\(edgeOrigin))"
                )
                let edgeInsets = surface.gridFrameInsetsForTesting
                t.expect(
                    edgeInsets?.left == 0 && edgeInsets?.top == 0 && edgeInsets?.right == 0 && edgeInsets?.bottom == 0,
                    desc: "and the pointer maps through no padding (\(String(describing: edgeInsets)))"
                )
                let fitUnderMode = surface.gridFitBoxForTesting
                t.expect(
                    fitUnderMode?.insets.left == fit.insets.left && fitUnderMode?.insets.top == fit.insets.top,
                    desc: "the padding itself is untouched: the mode paints it rather than editing it"
                )
                let gridUnderMode = surface.drive.readSnapshot()
                t.expect(
                    gridUnderMode.rows == gridBefore.rows && gridUnderMode.columns == gridBefore.columns,
                    desc: "the grid keeps its \(gridBefore.rows)x\(gridBefore.columns) (got \(gridUnderMode.rows)x\(gridUnderMode.columns))"
                )
                t.expect(
                    gridUnderMode.isEdgeToEdge && gridUnderMode.letterboxColor == 0x1a2b3c,
                    desc: "the snapshot the pointer reads carries the resolved bit and the fill"
                )

                // Off: the padding the mode painted over is where it was.
                surface.feed(Data(fullscreenContentOff.utf8))
                surface.needsDisplay = true
                t.pump(0.4)
                let restoredOrigin = surface.lastFrameOriginForTesting ?? (x: -1, y: -1)
                t.expect(
                    sameOrigin(restoredOrigin, expectedPadded),
                    desc: "after the reset the frame starts one padding in again (\(restoredOrigin))"
                )
                let restoredInsets = surface.gridFrameInsetsForTesting
                t.expect(
                    restoredInsets?.left == fit.insets.left && restoredInsets?.top == fit.insets.top,
                    desc: "and the pointer maps through the padding again"
                )

                // Passthrough: the same mode bit with the terminal content left
                // visible around the image keeps the grid where the user put it.
                surface.feed(Data(passthroughLetterboxOn.utf8))
                surface.needsDisplay = true
                t.pump(0.4)
                let passthroughOrigin = surface.lastFrameOriginForTesting ?? (x: -1, y: -1)
                t.expect(
                    sameOrigin(passthroughOrigin, expectedPadded),
                    desc: "a Passthrough letterbox leaves the frame padded (\(passthroughOrigin))"
                )
                t.expect(
                    surface.drive.readSnapshot().modes.isFullscreenContentActive
                        && !surface.drive.readSnapshot().isEdgeToEdge,
                    desc: "while the mode itself is published"
                )
                surface.feed(Data(fullscreenContentOff.utf8))
                t.pump(0.2)
            }
        }

        UBUITestRegister("swift_shell_decset_7402_measures_the_drawable_for_the_program") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the harness runs inside the app")
                    return
                }
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                // A padding, so the drawable and the grid are two different
                // extents and the case can tell which one the program is told.
                guard let opening = surface.gridFitBoxForTesting else {
                    t.expect(false, desc: "the surface reports the box it fits a grid into")
                    return
                }
                let restoreLeft = Double(opening.insets.left)
                let restoreTop = Double(opening.insets.top)
                app.settingsSetWindowPaddingLeft(12.0)
                app.settingsSetWindowPaddingTop(10.0)
                defer {
                    app.settingsSetWindowPaddingLeft(restoreLeft)
                    app.settingsSetWindowPaddingTop(restoreTop)
                }
                surface.needsDisplay = true
                t.pump(0.4)

                guard let fit = surface.gridFitBoxForTesting,
                    let gridExtent = surface.reportedTextAreaPixelsForTesting
                else {
                    t.expect(false, desc: "the surface reports its fit and the extent the program is told")
                    return
                }
                let scale = surface.metalLayer.contentsScale > 0 ? surface.metalLayer.contentsScale : 1
                let grid = surface.drive.readSnapshot()
                // The extent the grid is drawn in: the columns times the cell
                // in points, scaled, rounded once — not the per-cell product,
                // which rounds each cell and drifts at a fractional advance.
                let gridPixels = (
                    width: Int((fit.cell.width * CGFloat(grid.columns) * scale).rounded()),
                    height: Int((fit.cell.height * CGFloat(grid.rows) * scale).rounded())
                )
                let drawable = (
                    width: Int((fit.bounds.width * scale).rounded()),
                    height: Int((fit.bounds.height * scale).rounded())
                )
                t.expect(
                    gridExtent.width == gridPixels.width && gridExtent.height == gridPixels.height,
                    desc: "out of the mode the program is told the grid's extent (\(gridExtent) vs \(gridPixels))"
                )
                t.expect(
                    drawable.width > gridPixels.width && drawable.height > gridPixels.height,
                    desc: "the padding makes the drawable the larger extent, so the two answers differ (\(drawable) vs \(gridPixels))"
                )
                // A point ten points inside the grid's corner: measured from the
                // grid's origin out of the mode, from the drawable's under it.
                let inside = CGPoint(x: fit.insets.left + 10, y: fit.insets.top + 10)
                let fromGrid = (x: Int((10 * scale).rounded(.down)) + 1, y: Int((10 * scale).rounded(.down)) + 1)
                let fromCorner = (
                    x: Int(((fit.insets.left + 10) * scale).rounded(.down)) + 1,
                    y: Int(((fit.insets.top + 10) * scale).rounded(.down)) + 1
                )
                let paddedPixel = surface.reportPixelForTesting(atViewPoint: inside)
                t.expect(
                    paddedPixel.x == fromGrid.x && paddedPixel.y == fromGrid.y,
                    desc: "out of the mode a pixel report measures from the grid's corner (\(paddedPixel) vs \(fromGrid))"
                )

                surface.feed(Data(colourLetterboxOn.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                let modeExtent = surface.reportedTextAreaPixelsForTesting ?? (width: -1, height: -1)
                t.expect(
                    modeExtent.width == drawable.width && modeExtent.height == drawable.height,
                    desc: "under DECSET 7402 the program is told the drawable (\(modeExtent) vs \(drawable))"
                )
                let modePixel = surface.reportPixelForTesting(atViewPoint: inside)
                t.expect(
                    modePixel.x == fromCorner.x && modePixel.y == fromCorner.y,
                    desc: "and a pixel report measures from the drawable's corner (\(modePixel) vs \(fromCorner))"
                )

                // The reset precedes the next frame, whose last Color fill
                // carried zero grid insets. Input still uses the restored grid.
                surface.feed(Data(fullscreenContentOff.utf8))
                let directResetPixel = surface.reportPixelForTesting(atViewPoint: inside)
                t.expect(
                    directResetPixel.x == fromGrid.x && directResetPixel.y == fromGrid.y,
                    desc: "a direct Color reset reports from the grid before a redraw (\(directResetPixel) vs \(fromGrid))"
                )

                // Passthrough: the picture fills the drawable under either
                // letterbox, so the space it is measured in is the same.
                surface.feed(Data(passthroughLetterboxOn.utf8))
                t.pump(0.2)
                let passthroughExtent = surface.reportedTextAreaPixelsForTesting ?? (width: -1, height: -1)
                t.expect(
                    passthroughExtent.width == drawable.width && passthroughExtent.height == drawable.height,
                    desc: "a Passthrough letterbox measures the drawable too (\(passthroughExtent))"
                )
                let passthroughPixel = surface.reportPixelForTesting(atViewPoint: inside)
                t.expect(
                    passthroughPixel.x == fromCorner.x && passthroughPixel.y == fromCorner.y,
                    desc: "from its corner (\(passthroughPixel) vs \(fromCorner))"
                )

                surface.feed(Data(fullscreenContentOff.utf8))
                t.pump(0.2)
                let restoredExtent = surface.reportedTextAreaPixelsForTesting ?? (width: -1, height: -1)
                t.expect(
                    restoredExtent.width == gridPixels.width && restoredExtent.height == gridPixels.height,
                    desc: "the reset restores the grid's extent without a republish (\(restoredExtent) vs \(gridPixels))"
                )
                let restoredPixel = surface.reportPixelForTesting(atViewPoint: inside)
                t.expect(
                    restoredPixel.x == fromGrid.x && restoredPixel.y == fromGrid.y,
                    desc: "and the grid's corner (\(restoredPixel) vs \(fromGrid))"
                )
            }
        }

        UBUITestRegister("swift_shell_decset_7402_skips_the_grid_copy_under_the_opaque_letterbox") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                surface.feed(Data("\u{1b}[H\u{1b}[2Jbefore the letterbox".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                guard let skipsBefore = surface.gridCaptureSkipsForTesting else {
                    t.expect(false, desc: "the surface counts the frames that skipped the grid")
                    return
                }
                t.expect(skipsBefore == 0, desc: "out of the mode no frame skips the grid (\(skipsBefore) did)")

                // Output keeps arriving under the opaque letterbox. Each write
                // asks for a frame, and each of those frames reads no cell.
                surface.feed(Data(colourLetterboxOn.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                for line in 1...3 {
                    surface.feed(Data("\r\nunder the letterbox \(line)".utf8))
                    surface.needsDisplay = true
                    t.pump(0.2)
                }
                let skipsUnderMode = surface.gridCaptureSkipsForTesting ?? -1
                t.expect(
                    skipsUnderMode - skipsBefore >= 3,
                    desc: "frames under the opaque letterbox skip the drain and the copy (\(skipsUnderMode - skipsBefore) skipped)"
                )
                let skipped = surface.lastFramePhaseInputsForTesting
                t.expect(
                    skipped?.dirtyRows == 0 && skipped?.didReuseLastFrame == false,
                    desc: "a skipped frame owes no row and loads no target (\(String(describing: skipped)))"
                )
                // A skipped frame keeps its rows rather than re-reading them:
                // the full re-reads are counted so the frame after the mode
                // can be told apart from the settled frames that follow it,
                // which a read of the last frame's census alone cannot do.
                let rereadsUnderMode = surface.gridFullRereadsForTesting ?? -1

                // Off: the first frame re-reads every row, so the writes made
                // under the letterbox reach the screen.
                surface.feed(Data(fullscreenContentOff.utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                let skipsAfter = surface.gridCaptureSkipsForTesting ?? -1
                t.expect(skipsAfter == skipsUnderMode, desc: "no frame skips once the mode clears (\(skipsAfter - skipsUnderMode) more)")
                let rereadsAfter = surface.gridFullRereadsForTesting ?? -1
                t.expect(
                    rereadsAfter >= rereadsUnderMode + 1,
                    desc: "the first frame after the mode re-reads every row (\(rereadsAfter - rereadsUnderMode) full re-reads)"
                )
                // And the arm settles: a later write owes only its own rows
                // against the baseline that re-read left behind.
                surface.feed(Data("\r\nafter the letterbox".utf8))
                surface.needsDisplay = true
                t.pump(0.3)
                let settled = surface.lastFramePhaseInputsForTesting
                t.expect(
                    settled.map { $0.didReuseLastFrame && $0.dirtyRows < $0.plannedRows } ?? false,
                    desc: "a later frame loads the target and owes only its dirty rows (\(String(describing: settled)))"
                )
            }
        }
    }
}
