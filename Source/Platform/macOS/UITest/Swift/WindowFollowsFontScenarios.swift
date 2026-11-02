// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// WindowFollowsFontScenarios — a window that chose its own size
// follows the font and keeps its grid; a split holds its frame and reflows.
//
// Core pins the classification (test_padding_geometry); these scenarios read
// what the window did with it, because the window's frame is exactly the
// half a model probe cannot see: a controller that touches its frame only at
// creation moves the grid on a font change and leaves the window, the
// opposite of what a reader who sized a window to 80 by 24 expects.

import AppKit
import UbiquittyKit

@MainActor
private func terminalSurfaces(under view: NSView) -> [TerminalSurface] {
    if let surface = view as? TerminalSurface {
        return [surface]
    }
    return view.subviews.flatMap { terminalSurfaces(under: $0) }
}

/// The configured size every scenario starts from, so a run inherits no size.
private let baseFontSize = 13.0
/// The size the change lands on: two steps up, enough to move every cell.
private let grownFontSize = 17.0

private func near(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 0.5) -> Bool {
    abs(a - b) <= tolerance
}

enum WindowFollowsFontScenarios {
    static func register() {
        UBUITestRegister("swift_line_spacing_sends_one_final_pty_size") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a terminal with a PTY opens")
                    return
                }
                let spacing = settingDouble(.FontLineSpacing)
                defer {
                    app.settingsSetLineSpacing(spacing)
                    shell.window?.close()
                }
                t.pump(0.5)
                shell.resizeWindow(toColumns: 80, rows: 24)
                t.pump(0.5)
                let before = surface.drive.windowSizeDeliveryCount
                app.settingsSetLineSpacing(spacing + 2)
                t.pump(0.6)
                let deliveries = surface.drive.windowSizeDeliveryCount - before
                t.expect(deliveries <= 1, desc: "one edit delivers at most one PTY size (\(deliveries))")
                t.expect(surface.publishedGrid.columns == 80 && surface.publishedGrid.rows == 24, desc: "the grid remains 80 by 24")
                let socket = "ubiquitty-uitest-spacing"
                t.killTmuxServer(onSocket: socket)
                defer { t.killTmuxServer(onSocket: socket) }
                shell.shellSendProbe("tmux -L \(socket) new-session -s spacing\r")
                guard t.wait(until: { surface.drive.foregroundProcessName.contains("tmux") }, timeout: 8) else {
                    t.expect(false, desc: "tmux becomes the foreground program")
                    return
                }
                t.pump(0.8)
                let beforeTmux = surface.drive.windowSizeDeliveryCount
                app.settingsSetLineSpacing(spacing + 4)
                t.pump(0.8)
                let tmuxDeliveries = surface.drive.windowSizeDeliveryCount - beforeTmux
                t.expect(tmuxDeliveries <= 1, desc: "one edit with tmux delivers at most one PTY size (\(tmuxDeliveries))")
                t.expect(surface.publishedGrid.columns == 80 && surface.publishedGrid.rows == 24, desc: "tmux keeps its 80 by 24 grid")
                NSLog("Line spacing PTY deliveries: shell=%llu tmux=%llu", deliveries, tmuxDeliveries)
            }
        }

        UBUITestRegister("swift_shell_a_font_size_change_grows_the_window_and_keeps_the_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the harness runs inside the app")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }
                app.settingsSetFontSize(baseFontSize)
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurfaces(under: content).first,
                    let renderer = surface.renderer
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface and a renderer")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
                // A window placed from frame memory carries a remembered size,
                // not its grid's, so it is first sized to the grid it holds —
                // the state a reader who sized a window to 80 by 24 is in.
                let opening = surface.publishedGrid
                shell.resizeWindow(toColumns: opening.columns, rows: opening.rows)
                t.pump(0.4)
                let gridBefore = surface.publishedGrid
                let frameBefore = window.frame
                let cellBefore = renderer.cellSize(for: surface)
                t.expect(
                    gridBefore.columns == opening.columns && gridBefore.rows == opening.rows,
                    desc: "the window sits at its grid's size (\(gridBefore))"
                )

                // The window is at its grid's size: the size is the terminal's,
                // so a bigger font grows the window and keeps the grid,
                // top-left anchored.
                app.settingsSetFontSize(grownFontSize)
                t.pump(0.6)
                let cellAfter = renderer.cellSize(for: surface)
                let gridAfter = surface.publishedGrid
                let frameAfter = window.frame
                t.expect(
                    cellAfter.height > cellBefore.height + 0.5,
                    desc: "the cell grew (\(cellBefore.height) to \(cellAfter.height) points)"
                )
                t.expect(
                    gridAfter.columns == gridBefore.columns && gridAfter.rows == gridBefore.rows,
                    desc: "the grid is kept across the font change (\(gridBefore) to \(gridAfter))"
                )
                t.expect(
                    frameAfter.width > frameBefore.width + 1 && frameAfter.height > frameBefore.height + 1,
                    desc: "and the window grew to hold it (\(frameBefore.size) to \(frameAfter.size))"
                )
                // The corner rule can only be read on a window that is on a
                // screen: the harness keeps its windows off every screen, and
                // AppKit answers a frame nudged onto the main one with its own
                // placement. Off-screen the rule is Core's, pinned by
                // test_padding_geometry, and this run says so rather than
                // reading a frame AppKit rewrote.
                if frameBefore.intersects(visible) {
                    let keptLeft = near(frameAfter.minX, frameBefore.minX) || near(frameAfter.maxX, visible.maxX)
                    let keptTop = near(frameAfter.maxY, frameBefore.maxY) || near(frameAfter.maxY, visible.maxY)
                    t.expect(
                        keptLeft && keptTop,
                        desc:
                            "anchored at its top-left corner, or flush against the screen where it could not be (\(frameBefore) to \(frameAfter) in \(visible))"
                    )
                } else {
                    NSLog(
                        "WindowFollowsFontScenarios: the window sits off every screen (%@), so the corner rule is not read here",
                        NSStringFromRect(frameBefore)
                    )
                }
                if let fit = surface.gridFitBoxForTesting {
                    let wanted = Ubiquitty.Rendering.viewportForGrid(
                        Ubiquitty.GridSize(columns: Int32(gridAfter.columns), rows: Int32(gridAfter.rows)),
                        Ubiquitty.FloatSize(width: Float(fit.cell.width), height: Float(fit.cell.height)),
                        Ubiquitty.Rendering.EdgeInsets(
                            left: Float(fit.insets.left),
                            right: Float(fit.insets.right),
                            top: Float(fit.insets.top),
                            bottom: Float(fit.insets.bottom)
                        ),
                        0
                    )
                    let contentSize = window.contentRect(forFrameRect: frameAfter).size
                    t.expect(
                        near(contentSize.width, CGFloat(wanted.width), within: 1.5)
                            && near(contentSize.height, CGFloat(wanted.height), within: 1.5),
                        desc: "the content is the grid's extent at the new cell again (\(contentSize) for \(wanted.width)x\(wanted.height))"
                    )
                    // The row height is whole device pixels when the line
                    // height snaps, which it does by default: a fractional row
                    // would drift the grid off the backing pixels.
                    let rowPixels = fit.cell.height * scale
                    t.expect(
                        near(rowPixels, rowPixels.rounded(), within: 0.001),
                        desc: "the row height is whole device pixels (\(rowPixels))"
                    )
                }

                // Features substitute glyphs in place: no cell moves, so
                // neither the grid nor the window does.
                let savedFeatures = String(Ubiquitty.Preferences.Effective.liveRenderConfiguration().fontFeatures.string())
                defer { app.settingsSetFontFeatures(savedFeatures) }
                app.settingsSetFontFeatures(savedFeatures.isEmpty ? "liga=0" : "")
                t.pump(0.5)
                t.expect(
                    surface.publishedGrid.columns == gridAfter.columns && surface.publishedGrid.rows == gridAfter.rows,
                    desc: "a feature change keeps the grid (\(surface.publishedGrid))"
                )
                t.expect(
                    near(window.frame.width, frameAfter.width) && near(window.frame.height, frameAfter.height),
                    desc: "and the window (\(window.frame.size))"
                )

                // Back to the base size: the window shrinks back to where it was.
                app.settingsSetFontSize(baseFontSize)
                t.pump(0.6)
                t.expect(
                    surface.publishedGrid.columns == gridBefore.columns && surface.publishedGrid.rows == gridBefore.rows,
                    desc: "the grid is kept on the way back too (\(surface.publishedGrid))"
                )
                t.expect(
                    near(window.frame.width, frameBefore.width, within: 1.5) && near(window.frame.height, frameBefore.height, within: 1.5),
                    desc: "and the window is back at its size (\(window.frame.size) for \(frameBefore.size))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_split_holds_its_frame_and_reflows_on_a_font_change") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the harness runs inside the app")
                    return
                }
                let savedSize = Ubiquitty.Preferences.Effective.fontSize(Ubiquitty.Preferences.values().pointee)
                defer { app.settingsSetFontSize(savedSize) }
                app.settingsSetFontSize(baseFontSize)
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)
                shell.splitRight(nil)
                t.pump(0.5)
                let surfaces = terminalSurfaces(under: content)
                t.expect(surfaces.count == 2, desc: "the window holds two panes (\(surfaces.count))")
                let frameBefore = window.frame
                let gridsBefore = surfaces.map { $0.publishedGrid }
                t.expect(gridsBefore.allSatisfy { $0.columns > 0 }, desc: "both panes have a grid (\(gridsBefore))")

                // A split has no single grid to preserve: the window holds and
                // every pane reflows into the room it has.
                app.settingsSetFontSize(grownFontSize)
                t.pump(0.6)
                t.expect(
                    near(window.frame.width, frameBefore.width) && near(window.frame.height, frameBefore.height),
                    desc: "a split holds its frame across the font change (\(frameBefore.size) to \(window.frame.size))"
                )
                let gridsAfter = surfaces.map { $0.publishedGrid }
                let reflowed = zip(gridsBefore, gridsAfter)
                    .allSatisfy { before, after in after.columns < before.columns && after.columns > 0 }
                t.expect(reflowed, desc: "and its panes reflow to fewer columns at the bigger cell (\(gridsBefore) to \(gridsAfter))")
            }
        }
    }
}
