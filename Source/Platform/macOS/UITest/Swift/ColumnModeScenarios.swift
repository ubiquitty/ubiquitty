// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ColumnModeScenarios — DECCOLM owns the columns on the Swift arm.
//
// Under CSI ?3h the application owns the column count. A window resize there
// moves the rows alone and the cells compress to the width; recomputing the
// columns from the width snapped a 132-column screen back to the ~80 the window
// happened to fit and corrupted every double-width and double-height line drawn
// against it. Core's grid fit holds the count and Core's frame resolver
// compresses the advance; this scenario reads what the surface did with both,
// one layer above the model.

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

enum ColumnModeScenarios {
    static func register() {
        UBUITestRegister("swift_shell_deccolm_owns_the_columns_across_a_resize") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content),
                    let renderer = surface.renderer
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a renderer")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                let scale = surface.metalLayer.contentsScale > 0 ? surface.metalLayer.contentsScale : 1
                let natural = renderer.cellSize(for: surface)
                let opening = surface.drive.readSnapshot()
                t.expect(
                    opening.columns > 0 && !opening.isColumnCountHeld,
                    desc: "the window opens on a grid the width decides (\(opening.columns) columns)"
                )
                guard let fit = surface.gridFitBoxForTesting else {
                    t.expect(false, desc: "the surface reports the box it fits a grid into")
                    return
                }

                // DECCOLM: Core takes the grid to 132 columns and publishes
                // that the count is held; the window follows at the natural
                // advance through the queued window request.
                surface.feed(Data("\u{1b}[?40h\u{1b}[?3h".utf8))
                surface.needsDisplay = true
                let took132 = t.wait(
                    until: { surface.drive.readSnapshot().columns == 132 && surface.publishedGrid.columns == 132 },
                    timeout: 3.0
                )
                t.expect(took132, desc: "CSI ?3h takes the grid to 132 columns (\(surface.publishedGrid.columns) published)")
                t.expect(surface.drive.readSnapshot().isColumnCountHeld, desc: "and Core publishes that the count is held")
                t.pump(0.3)
                let heldRows = surface.publishedGrid.rows

                // A window a hundred cells wide and three rows shorter: the
                // count holds, the rows follow the height, and the drawn cell
                // compresses so 132 columns fit — the frame builds with that
                // advance, and the pointer maps through it.
                let narrowWidth = natural.width * 100 + fit.insets.left + fit.insets.right
                let shorterHeight = content.frame.height - natural.height * 3
                window.setContentSize(NSSize(width: narrowWidth, height: shorterHeight))
                surface.needsDisplay = true
                t.pump(0.5)
                let narrowed = surface.drive.readSnapshot()
                t.expect(
                    narrowed.columns == 132 && surface.publishedGrid.columns == 132,
                    desc:
                        "a resize to a hundred cells' width keeps 132 columns (\(narrowed.columns) in the model, \(surface.publishedGrid.columns) published)"
                )
                t.expect(
                    surface.publishedGrid.rows == heldRows - 3,
                    desc: "while the rows follow the height (\(surface.publishedGrid.rows), were \(heldRows))"
                )
                let drawn = surface.drawnCellSizeForTesting ?? .zero
                t.expect(
                    drawn.width < natural.width - 0.01 && abs(drawn.height - natural.height) < 0.01,
                    desc: "the drawn cell compresses to fit: \(drawn.width) of \(natural.width) points wide"
                )
                let built = surface.lastFramePhaseInputsForTesting
                t.expect(
                    built.map { $0.cellWidth < Float(natural.width * scale) - 0.5 } ?? false,
                    desc:
                        "and the frame built with the compressed advance (\(built?.cellWidth ?? -1) of \(Float(natural.width * scale)) atlas pixels)"
                )

                // A live drag leaves the width free while the mode holds: a
                // width quantised to whole natural cells would be quantised
                // to a grid the mode is not going to cut. The drag snap is off
                // by default and is not what is under test, so it is turned on
                // for this window and put back afterwards.
                let snapWasOn = shell.snapsWindowResizeForTesting
                shell.snapsWindowResizeForTesting = true
                defer { shell.snapsWindowResizeForTesting = snapWasOn }
                let nudge = natural.width * 0.4
                let proposed = NSSize(width: window.frame.width - nudge, height: window.frame.height)
                let snapped = shell.snappedFrameSize(for: window, proposed: proposed, isLiveResize: true)
                t.expect(
                    abs(snapped.width - proposed.width) < 0.001,
                    desc: "a drag's width is not quantised while DECCOLM holds the count (\(snapped.width) for \(proposed.width))"
                )

                // Off: the width decides the count again, the drawn cell is
                // the natural one, and a drag's width snaps to whole cells.
                surface.feed(Data("\u{1b}[?3l".utf8))
                surface.needsDisplay = true
                let took80 = t.wait(
                    until: { surface.drive.readSnapshot().columns == 80 && surface.publishedGrid.columns == 80 },
                    timeout: 3.0
                )
                t.expect(took80, desc: "CSI ?3l takes the grid back to 80 columns (\(surface.publishedGrid.columns) published)")
                t.expect(!surface.drive.readSnapshot().isColumnCountHeld, desc: "and the count is the width's again")
                t.pump(0.3)
                let restored = surface.drawnCellSizeForTesting ?? .zero
                t.expect(
                    abs(restored.width - natural.width) < 0.001,
                    desc: "the drawn cell is the natural one again (\(restored.width) of \(natural.width))"
                )
                let proposedAgain = NSSize(width: window.frame.width - nudge, height: window.frame.height)
                let snappedAgain = shell.snappedFrameSize(for: window, proposed: proposedAgain, isLiveResize: true)
                t.expect(
                    abs(snappedAgain.width - proposedAgain.width) > 0.001,
                    desc: "and a drag's width is quantised to whole cells again (\(snappedAgain.width) for \(proposedAgain.width))"
                )
            }
        }
    }
}
