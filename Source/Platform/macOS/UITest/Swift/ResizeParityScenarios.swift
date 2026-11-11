// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ResizeParityScenarios — what a Swift surface's resize reports, keeps and
// draws.
//
// Core queues the DECSET 2048 in-band report and decides which rows a resize
// keeps; what these scenarios read is whether the Swift surface's resize
// reaches both — the report on the PTY before any keypress, the alternate
// screen's first rows surviving a top-edge drag — whether a scale change asks
// for a frame at all, whether a drag follows the pointer through the slack
// off the cell lattice, and whether every step draws whole rows from the top
// inset, as the settled frame does.

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit

/// The first pixel row, from the top, holding ink in a band of columns.
///
/// Ink is any pixel unlike the frame's last row's first pixel, which on a
/// screen whose content ends well above the bottom is the ground.
///
/// - Parameters:
///   - frame: A rendered frame, BGRA, top row first.
///   - columns: The pixel columns to look in.
/// - Returns: The row, or nil when the band holds no ink.
private func firstInkRow(in frame: (width: Int, height: Int, pixels: Data), columns: Range<Int>) -> Int? {
    let stride = frame.width * 4
    return frame.pixels.withUnsafeBytes { raw -> Int? in
        let ground = raw.loadUnaligned(fromByteOffset: (frame.height - 1) * stride, as: UInt32.self)
        let band = max(0, columns.lowerBound)..<min(frame.width, columns.upperBound)
        for row in 0..<frame.height {
            for column in band where raw.loadUnaligned(fromByteOffset: row * stride + column * 4, as: UInt32.self) != ground {
                return row
            }
        }
        return nil
    }
}

/// The top-left corner of a rendered frame, row by row, for comparing two
/// frames of different sizes over the region both hold.
///
/// - Parameters:
///   - frame: A rendered frame, BGRA, top row first.
///   - width: The corner's width in pixels, clamped to the frame's.
///   - height: The corner's height in pixels, clamped to the frame's.
/// - Returns: The corner's pixels, tightly packed.
private func topLeftCorner(of frame: (width: Int, height: Int, pixels: Data), width: Int, height: Int) -> Data {
    let columns = min(width, frame.width)
    var corner = Data(capacity: columns * 4 * min(height, frame.height))
    for row in 0..<min(height, frame.height) {
        let start = row * frame.width * 4
        corner.append(frame.pixels.subdata(in: start..<(start + columns * 4)))
    }
    return corner
}

/// The rows a surface's text area holds whole: the grid's row count is this,
/// and the height left over is blank under the last row.
///
/// - Parameter surface: The surface.
/// - Returns: The count, or zero before the surface has a cell.
@MainActor
private func fittingRows(_ surface: TerminalSurface) -> Int {
    guard let box = surface.gridFitBoxForTesting, box.cell.height > 0 else { return 0 }
    return Int(((surface.bounds.height - box.insets.top - box.insets.bottom) / box.cell.height).rounded(.down))
}

/// Writes a rendered frame as a PNG, for a reader comparing captures by eye.
///
/// - Parameters:
///   - frame: A rendered frame, BGRA, top row first.
///   - path: Where to write it.
private func writeFrame(_ frame: (width: Int, height: Int, pixels: Data), to path: String) {
    guard let provider = CGDataProvider(data: frame.pixels as CFData),
        let image = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return }
    try? data.write(to: URL(fileURLWithPath: path))
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

/// Opens a Swift-shell window on a program and finds its surface.
///
/// The window rather than the surface is what a scenario resizes: the
/// surface's frame is the window's to lay out, and a size set on the surface
/// alone is put back on the next layout pass.
@MainActor
private func spawnSurface(
    _ t: UBUITestContext,
    arguments: [String]
) -> (shell: TerminalWindowController, window: NSWindow, surface: TerminalSurface)? {
    guard let shell = TerminalWindowController.spawn(arguments: arguments, localePolicy: .auto, sessionLifetime: .outlivesChild),
        let window = shell.window,
        let content = window.contentView,
        let surface = terminalSurface(under: content)
    else {
        t.expect(false, desc: "a Swift-shell window opens on \(arguments.joined(separator: " ")) with a surface")
        return nil
    }
    t.pump(0.8)
    return (shell, window, surface)
}

/// Pumps until the grid's text satisfies the predicate, or a few seconds pass.
@MainActor
private func waitForGrid(_ t: UBUITestContext, of surface: TerminalSurface, _ predicate: (String) -> Bool) -> String {
    var text = surface.gridTextForTesting()
    var remaining = 30
    while !predicate(text), remaining > 0 {
        t.pump(0.1)
        remaining -= 1
        text = surface.gridTextForTesting()
    }
    return text
}

enum ResizeParityScenarios {
    static func register() {
        registerLiveResizeCensus()
        // Zoom to the screen requires real display coordinates.
        if MainActor.assumeIsolated({ !WindowContainment.isOffscreen }) {
            UBUITestRegister("zoom_keeps_primary_row_zero_through_animation_and_edge_slack") { context in
                guard let t = context else { return }
                MainActor.assumeIsolated {
                    let saved = t.configureAppending("[appearance]\nhide_title_bar = false\n")
                    defer { t.restoreConfiguration(saved) }
                    guard let spawned = spawnSurface(t, arguments: ["/bin/sh", "-c", "while IFS= read -r line; do :; done"]),
                        let window = spawned.window as? ZoomTrackingWindow,
                        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
                    else {
                        t.expect(false, desc: "a native terminal window has a visible screen")
                        return
                    }
                    defer { window.close() }
                    let surface = spawned.surface
                    t.expect(
                        t.wait(until: { surface.drive.isForegroundLocalShell }, timeout: 4),
                        desc: "the shell remains the foreground process for primary-screen reflow"
                    )
                    window.makeKeyAndOrderFront(nil)
                    window.setFrame(
                        NSRect(x: visible.minX + 80, y: visible.minY, width: visible.width * 0.55, height: visible.height * 0.55),
                        display: true
                    )
                    t.pump(0.2)
                    var text = "\u{1b}[?1049l\u{1b}[?25l\u{1b}[2J\u{1b}[H"
                    for row in 0..<300 { text += "history row \(row)\r\n" }
                    text += "$ ready"
                    surface.feed(Data(text.utf8))
                    t.pump(0.2)
                    t.expect(surface.drive.withTerminal { $0.scrollbackCount > 0 } ?? false, desc: "the primary screen has older history")
                    t.expect(
                        surface.drive.withTerminal { Ubiquitty.shouldReflowOnResize($0, surface.drive.isForegroundLocalShell) } ?? false,
                        desc: "zoom exercises the primary shell's reflow path"
                    )
                    @MainActor
                    func firstRow() -> String {
                        String(surface.gridTextForTesting().split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
                    }
                    let expectedRow = firstRow()
                    let openingFrame = window.frame
                    let openingRows = Int(surface.drive.readSnapshot().rows)
                    let openingOrigin = surface.lastFrameOriginForTesting
                    t.expect(expectedRow.hasPrefix("history row "), desc: "row zero contains identifiable primary text")
                    t.expect(openingOrigin != nil, desc: "the primary screen has a rendered origin")
                    var firstDifferentRow: String?
                    var sampledRows: Set<Int> = [openingRows]
                    var lostZoomIntent = false
                    var movedOrigin = false
                    var drawnAnimationFrames = 0
                    surface.frameEncodedObserverForTesting = { _ in
                        if window.inLiveResize { drawnAnimationFrames += 1 }
                    }
                    defer { surface.frameEncodedObserverForTesting = nil }
                    @MainActor
                    func sample() {
                        sampledRows.insert(Int(surface.drive.readSnapshot().rows))
                        let row = firstRow()
                        if row != expectedRow, firstDifferentRow == nil { firstDifferentRow = row }
                        if window.inLiveResize && !window.isZoomResizeInProgress { lostZoomIntent = true }
                        if let origin = surface.lastFrameOriginForTesting, let openingOrigin, origin != openingOrigin {
                            movedOrigin = true
                        }
                    }
                    window.performZoom(nil)
                    let filled = t.wait(
                        until: {
                            sample()
                            return !window.isZoomResizeInProgress && !window.inLiveResize
                                && abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
                        },
                        timeout: 4
                    )
                    t.pump(0.1)
                    sample()
                    t.expect(filled, desc: "zoom finishes at the screen edges")
                    t.expect(
                        sampledRows.count >= 2 && (sampledRows.max() ?? 0) > openingRows,
                        desc: "snapshots cover the opening and the grown grid"
                    )
                    t.expect(
                        firstDifferentRow == nil,
                        desc: "zoom preserves row zero through growth and settle: \(firstDifferentRow ?? expectedRow)"
                    )
                    t.expect(!lostZoomIntent, desc: "every live zoom step retains its programmatic resize intent")
                    t.expect(!movedOrigin, desc: "zoom leaves the rendered grid at its top-left inset")
                    t.expect(
                        drawnAnimationFrames >= 4,
                        desc:
                            "zoom presents intermediate frames instead of holding its opening picture until settle (\(drawnAnimationFrames) frames)"
                    )
                    if let box = surface.gridFitBoxForTesting {
                        let grid = surface.drive.readSnapshot()
                        let slackWidth = surface.bounds.width - box.insets.left - box.insets.right - CGFloat(grid.columns) * box.cell.width
                        let slackHeight = surface.bounds.height - box.insets.top - box.insets.bottom - CGFloat(grid.rows) * box.cell.height
                        t.expect(
                            slackWidth >= -0.01 && slackWidth < box.cell.width && slackHeight >= -0.01 && slackHeight < box.cell.height,
                            desc: "the filled screen leaves only a partial cell on the right and bottom"
                        )
                    }
                    drawnAnimationFrames = 0
                    window.performZoom(nil)
                    let restored = t.wait(
                        until: {
                            sample()
                            return !window.isZoomResizeInProgress && !window.inLiveResize
                                && abs(window.frame.width - openingFrame.width) < 2 && abs(window.frame.height - openingFrame.height) < 2
                        },
                        timeout: 4
                    )
                    t.expect(restored, desc: "unzoom completes and clears its intent")
                    t.expect(!lostZoomIntent, desc: "unzoom retains its resize intent")
                    t.expect(
                        firstDifferentRow == nil && !movedOrigin,
                        desc: "unzoom preserves the visible top-left through its steps and settle"
                    )
                    t.expect(
                        drawnAnimationFrames >= 4,
                        desc: "unzoom presents intermediate terminal frames (\(drawnAnimationFrames) frames)"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_a_resize_reports_in_band_before_any_keypress") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The program asks for in-band resize reports and then prints
                // every byte it reads in caret notation, so a report that
                // reached the PTY is a line on the grid and one that waited for
                // a keypress is not.
                guard
                    let spawned = spawnSurface(
                        t,
                        arguments: ["/bin/sh", "-c", "printf '\\033[?2048h'; LC_ALL=C exec cat -v"]
                    )
                else { return }
                let (window, surface) = (spawned.window, spawned.surface)
                defer { window.close() }
                let grid = surface.drive.readSnapshot()
                t.expect(grid.rows > 4, desc: "the window holds a grid (\(grid.rows) rows)")

                var frame = window.frame
                frame.origin.y += 40
                frame.size.height -= 40
                window.setFrame(frame, display: true)
                t.pump(0.3)
                let after = surface.drive.readSnapshot()
                t.expect(after.rows < grid.rows, desc: "the resize moved the grid (\(grid.rows) to \(after.rows) rows)")
                let report = "^[[48;\(after.rows);\(after.columns);"
                let text = waitForGrid(t, of: surface) { $0.contains(report) }
                t.expect(
                    text.contains(report),
                    desc: "the in-band report reached the program on the resize itself, with no keypress (grid: \(text.debugDescription))"
                )
            }
        }

        UBUITestRegister("swift_shell_a_top_edge_drag_keeps_the_alternate_screens_top_rows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A quiet child: a shell would redraw its prompt on the resize
                // and the redraw, not the anchor, would be what the grid shows.
                guard let spawned = spawnSurface(t, arguments: ["/bin/sh", "-c", "exec sleep 1000"]) else { return }
                let (window, surface) = (spawned.window, spawned.surface)
                defer { window.close() }
                let rows = Int(surface.drive.readSnapshot().rows)
                t.expect(rows > 6, desc: "the window holds enough rows to lose some (\(rows))")
                // A full-screen program: the alternate screen, every row numbered.
                var script = "\u{1b}[?1049h\u{1b}[H"
                for row in 1...rows {
                    script += "row \(row)" + (row < rows ? "\r\n" : "")
                }
                surface.feed(Data(script.utf8))
                let before = waitForGrid(t, of: surface) { $0.hasSuffix("row \(rows)") }
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let lastBefore = before.last.map(String.init) ?? "?"
                t.expect(lastBefore == "row \(rows)", desc: "the last row is on screen before the drag (\(lastBefore))")

                // A top-edge drag: the live-resize latch opens on the window's
                // frame, the frame shrinks with its bottom edge still, and the
                // surface reads the fixed edge off that — the same verdict a
                // real drag gets. A full-screen program lays out from row 0
                // and repaints the rest, so the alternate screen keeps its
                // first rows and loses its last.
                let cell = surface.gridFitBoxForTesting?.cell ?? .zero
                t.expect(cell.height > 0, desc: "the surface knows its cell (\(cell))")
                surface.viewWillStartLiveResize()
                var frame = window.frame
                frame.size.height -= cell.height * 3
                window.setFrame(frame, display: true)
                t.pump(0.3)
                surface.viewDidEndLiveResize()
                let rowsAfter = Int(surface.drive.readSnapshot().rows)
                t.expect(rowsAfter < rows && rowsAfter >= rows - 3, desc: "the drag took up to three rows (\(rows) to \(rowsAfter))")
                let after = surface.gridTextForTesting().split(separator: "\n", omittingEmptySubsequences: false)
                let first = after.first.map(String.init) ?? "?"
                let last = after.last.map(String.init) ?? "?"
                t.expect(
                    first == "row 1" && last == "row \(rowsAfter)",
                    desc: "the alternate screen kept its top (first \(first), last \(last); wanted row 1 to row \(rowsAfter))"
                )
                surface.feed(Data("\u{1b}[?1049l".utf8))
                t.pump(0.2)
            }
        }

        UBUITestRegister("swift_shell_a_drag_from_a_filled_window_follows_the_slack_and_keeps_the_grid_at_its_top_inset") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let spawned = spawnSurface(t, arguments: ["/bin/sh", "-c", "exec sleep 1000"]) else { return }
                let (shell, window, surface) = (spawned.shell, spawned.window, spawned.surface)
                defer { window.close() }
                surface.feed(welcomeScreenBytes(for: surface))
                t.pump(0.3)

                // Filled to the screen, as a zoom leaves it: an extent the
                // drag's quantiser never chose, so the grid has a fraction of a
                // cell left under its last row. A drag gives that fraction back
                // by following the pointer through it, and gives none of it
                // from above the first row.
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
                    let box = surface.gridFitBoxForTesting, box.cell.height > 0
                else {
                    t.expect(false, desc: "the surface has a screen to fill and a cell to fit")
                    return
                }
                var filled = visible
                window.setFrame(filled, display: true)
                t.pump(0.3)
                let cell = box.cell
                @MainActor
                func remainder() -> CGFloat {
                    let fit = surface.gridFitBoxForTesting?.insets ?? box.insets
                    let rows = CGFloat(surface.drive.readSnapshot().rows)
                    return surface.bounds.height - fit.top - fit.bottom - rows * cell.height
                }
                if remainder() < 1 {
                    filled.origin.y -= (cell.height / 2).rounded(.up)
                    filled.size.height += (cell.height / 2).rounded(.up)
                    window.setFrame(filled, display: true)
                    t.pump(0.3)
                }
                let filledRemainder = remainder()
                t.expect(filledRemainder >= 1, desc: "the filled window leaves part of a cell under the grid (\(filledRemainder) pt)")

                let captureDirectory = ProcessInfo.processInfo.environment["UBIQUITTY_RESIZE_ANCHOR_CAPTURES"]
                // The logo's corner: eight rows of cells by forty columns, which
                // every step of the drag below still holds whole.
                let scale = surface.metalLayer.contentsScale
                let cornerWidth = Int((cell.width * 40 * scale).rounded())
                let cornerHeight = Int((cell.height * 8 * scale).rounded())
                @MainActor
                func capture(_ name: String) -> (ink: Int?, originY: Float?, corner: Data) {
                    t.pump(0.05)
                    guard let frame = surface.renderedFrameForTesting() else {
                        return (nil, nil, Data())
                    }
                    if let captureDirectory {
                        writeFrame(frame, to: "\(captureDirectory)/\(name).png")
                    }
                    return (
                        firstInkRow(in: frame, columns: 0..<frame.width),
                        surface.lastFrameOriginForTesting?.y,
                        topLeftCorner(of: frame, width: cornerWidth, height: cornerHeight)
                    )
                }
                let settledBefore = capture("0-filled")
                guard let inkBefore = settledBefore.ink, let originBefore = settledBefore.originY else {
                    t.expect(false, desc: "the filled window draws the Welcome screen")
                    return
                }
                t.expect(inkBefore > 0, desc: "the logo's frame starts below the frame's top edge (row \(inkBefore))")

                // The lattice the quantiser snaps to on each axis: a whole
                // number of cells plus everything that is not grid, rounded up
                // to a whole point, the unit AppKit applies a frame extent in.
                // The filled frame's slack is what lies beyond its grid's
                // lattice extent.
                // The quantiser is a preference; the drag under test is the
                // one a reader who has it on makes.
                shell.snapsWindowResizeForTesting = true
                let start = window.frame
                let fit = surface.gridFitBoxForTesting?.insets ?? box.insets
                let reserve = (
                    width: start.width - surface.bounds.width + fit.left + fit.right,
                    height: start.height - surface.bounds.height + fit.top + fit.bottom
                )
                @MainActor
                func lattice(_ cells: Int, _ extent: CGFloat, _ reserve: CGFloat) -> CGFloat {
                    (CGFloat(cells) * extent + reserve).rounded(.up)
                }
                // Within a point: the lattice and an applied frame are both on
                // whole points, so an extent off the lattice is a point or
                // more from it.
                @MainActor
                func isOnLattice(_ extent: CGFloat, _ cellExtent: CGFloat, _ reserve: CGFloat) -> Bool {
                    let cells = Int(((extent - reserve) / cellExtent).rounded())
                    return abs(extent - lattice(cells, cellExtent, reserve)) < 1
                }
                let rowsBefore = Int(surface.drive.readSnapshot().rows)
                let columnsBefore = Int(surface.drive.readSnapshot().columns)
                // On whole points, for the same reason, and rounded down so the
                // slack's last step still holds every row.
                let slack = (
                    width: (start.width - lattice(columnsBefore, cell.width, reserve.width)).rounded(.down),
                    height: (start.height - lattice(rowsBefore, cell.height, reserve.height)).rounded(.down)
                )
                t.expect(slack.height >= 1, desc: "the filled frame holds slack above its grid's lattice height (\(slack.height) pt)")

                @MainActor
                func expectDrawnAsSettled(_ step: (ink: Int?, originY: Float?, corner: Data), _ name: String) {
                    t.expect(
                        surface.metalLayer.contentsGravity == .topLeft,
                        desc: "\(name) pins a stale drawable to the top-left (\(surface.metalLayer.contentsGravity.rawValue))"
                    )
                    t.expect(
                        Int(surface.drive.readSnapshot().rows) == fittingRows(surface),
                        desc: "\(name) holds the rows that fit whole (\(surface.drive.readSnapshot().rows) of \(fittingRows(surface)))"
                    )
                    t.expect(
                        step.originY == originBefore,
                        desc:
                            "\(name) draws the first row at the text area's top (origin \(step.originY.map { "\($0)" } ?? "nil") px, settled \(originBefore) px)"
                    )
                    t.expect(
                        step.ink == inkBefore,
                        desc:
                            "\(name) keeps the logo's frame whole at its row (\(step.ink.map { "\($0)" } ?? "nil") px, settled \(inkBefore) px)"
                    )
                    t.expect(
                        step.corner == settledBefore.corner,
                        desc: "\(name) draws the logo's corner pixel for pixel as the settled frame does"
                    )
                }

                // A top-left drag, pressed on the top-left corner: each step is
                // the frame the shell's quantiser hands AppKit, applied with the
                // bottom and right edges still.
                shell.beginLiveResize(pressedAt: NSPoint(x: start.minX, y: start.maxY))
                surface.viewWillStartLiveResize()
                @MainActor
                func dragTopLeft(to proposed: NSSize) -> NSSize {
                    let size = shell.snappedFrameSize(for: window, proposed: proposed, isLiveResize: true)
                    window.setFrame(
                        NSRect(x: start.maxX - size.width, y: start.minY, width: size.width, height: size.height),
                        display: true
                    )
                    // A drag moves the grid at most once per display frame;
                    // the step is held as long as a pointer holds it.
                    t.pump(0.05)
                    return size
                }

                // Through the slack the edge follows the pointer, on whole
                // device pixels, and the grid keeps every row: the slack is not
                // a cell.
                for (index, share) in [0.25, 0.5, 0.75, 1.0].enumerated() {
                    let name = "slack step \(index + 1)"
                    let proposed = NSSize(
                        width: start.width - (slack.width * share).rounded(),
                        height: start.height - (slack.height * share).rounded()
                    )
                    let size = dragTopLeft(to: proposed)
                    t.expect(
                        size == proposed && window.frame.size == proposed,
                        desc: "\(name) follows the pointer (proposed \(proposed), quantised \(size), applied \(window.frame.size))"
                    )
                    t.expect(
                        Int(surface.drive.readSnapshot().rows) == rowsBefore,
                        desc: "\(name) keeps the grid's \(rowsBefore) rows (\(surface.drive.readSnapshot().rows))"
                    )
                    t.expect(surface.isLiveResizeBottomFixed, desc: "\(name) is a drag whose bottom edge stands still")
                    expectDrawnAsSettled(capture("slack-\(index + 1)"), name)
                }
                t.expect(
                    isOnLattice(window.frame.height, cell.height, reserve.height),
                    desc: "the slack's last step lands on the lattice (\(window.frame.height) pt)"
                )

                // Past the lattice the drag snaps to whole cells, and the rows
                // go into history one cell at a time.
                var rowsBeforeStep = rowsBefore
                for (index, cells) in [1.5, 2.5, 4.25, 6.75].enumerated() {
                    let name = "cell step \(index + 1)"
                    let size = dragTopLeft(
                        to: NSSize(width: start.width - cell.width * cells, height: start.height - cell.height * cells)
                    )
                    t.expect(
                        isOnLattice(size.height, cell.height, reserve.height) && isOnLattice(size.width, cell.width, reserve.width),
                        desc: "\(name) snaps to whole cells (\(size))"
                    )
                    let rows = Int(surface.drive.readSnapshot().rows)
                    t.expect(
                        rows < rowsBeforeStep && rows == fittingRows(surface),
                        desc: "\(name) gives up whole rows (\(rowsBeforeStep) to \(rows), \(fittingRows(surface)) fit)"
                    )
                    rowsBeforeStep = rows
                    t.expect(surface.isLiveResizeBottomFixed, desc: "\(name) is a drag whose bottom edge stands still")
                    expectDrawnAsSettled(capture("\(index + 1)-live-step"), name)
                }
                surface.viewDidEndLiveResize()
                shell.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                expectDrawnAsSettled(capture("5-released"), "the released drag")

                // Growing toward the screen: a window on the lattice, lifted off
                // the bottom of the visible frame by a distance that is not a
                // whole number of cells, dragged by its bottom edge down to the
                // Dock. Short of the last whole cell it snaps; through the
                // partial cell it follows the pointer; at the edge it lands
                // flush; past the edge it stays there.
                let lifted = window.frame.offsetBy(dx: 0, dy: (cell.height * 2.5).rounded())
                window.setFrame(lifted, display: true)
                t.pump(0.1)
                t.expect(
                    isOnLattice(lifted.height, cell.height, reserve.height) && lifted.maxY <= visible.maxY,
                    desc: "the window to grow is on the lattice and on the screen (\(lifted))"
                )
                let available = lifted.maxY - visible.minY
                shell.beginLiveResize(pressedAt: NSPoint(x: lifted.midX, y: lifted.minY))
                surface.viewWillStartLiveResize()
                @MainActor
                func dragBottom(to height: CGFloat) -> CGFloat {
                    let size = shell.snappedFrameSize(
                        for: window,
                        proposed: NSSize(width: lifted.width, height: height),
                        isLiveResize: true
                    )
                    window.setFrame(
                        NSRect(x: lifted.minX, y: lifted.maxY - size.height, width: size.width, height: size.height),
                        display: true
                    )
                    // A drag moves the grid at most once per display frame.
                    t.pump(0.05)
                    return size.height
                }
                let lastFitting = lattice(
                    Int(((available - reserve.height) / cell.height).rounded(.down)),
                    cell.height,
                    reserve.height
                )
                let shortOfIt = dragBottom(to: lastFitting - cell.height * 0.7)
                t.expect(
                    isOnLattice(shortOfIt, cell.height, reserve.height),
                    desc: "a drag short of the last whole cell snaps (\(shortOfIt) pt)"
                )
                if available - lastFitting >= 2 {
                    let partial = ((lastFitting + available) / 2).rounded(.down)
                    let followed = dragBottom(to: partial)
                    t.expect(
                        followed == partial,
                        desc: "the partial cell follows the pointer (\(partial) pt asked, \(followed) pt applied)"
                    )
                }
                let flush = dragBottom(to: available)
                t.expect(
                    flush == available && window.frame.minY == visible.minY,
                    desc: "a drag to the Dock ends flush with it (\(window.frame.minY) pt, the visible frame's bottom \(visible.minY) pt)"
                )
                let past = dragBottom(to: available + cell.height * 3)
                t.expect(past == available, desc: "a drag past the Dock stays at it (\(past) pt, \(available) pt available)")
                let grown = capture("6-grown-to-the-dock")
                t.expect(
                    grown.originY == originBefore,
                    desc: "the grown window draws the first row at the text area's top (\(grown.originY.map { "\($0)" } ?? "nil") px)"
                )
                surface.viewDidEndLiveResize()
                shell.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                t.pump(0.1)
                t.expect(window.frame.minY == visible.minY, desc: "the released window stays flush with the Dock (\(window.frame))")
            }
        }

        // Snap Resize to Cells, as the setting states it: a drag away from the
        // screen's edges moves the window in whole cells and nothing finer, and
        // only the partial cell before a screen edge or the Dock follows the
        // pointer. The lattice is on whole points because AppKit applies a
        // frame extent on whole points, rounding up. On a lattice of device
        // pixels every other cell count stands on a half point, the applied
        // frame reads back half a point above it, and the quantiser takes the
        // window for one off the lattice: each step then follows the pointer
        // through the cell and snaps at its end.
        UBUITestRegister("swift_shell_a_drag_away_from_the_screen_edge_moves_in_whole_cells_only") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let spawned = spawnSurface(t, arguments: ["/bin/sh", "-c", "exec sleep 1000"]) else { return }
                let (shell, window, surface) = (spawned.shell, spawned.window, spawned.surface)
                defer { window.close() }
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
                    let box = surface.gridFitBoxForTesting, box.cell.width > 0, box.cell.height > 0
                else {
                    t.expect(false, desc: "the surface has a screen and a cell to fit")
                    return
                }
                shell.snapsWindowResizeForTesting = true
                let cell = box.cell
                // Everything along each axis that is not grid, as the quantiser
                // reserves it: the window's chrome and the padding.
                let reserve = (
                    width: window.frame.width - surface.bounds.width + box.insets.left + box.insets.right,
                    height: window.frame.height - surface.bounds.height + box.insets.top + box.insets.bottom
                )
                // An extent on the lattice holds whole cells with less than a
                // point to spare: the rounding up to the point AppKit applies a
                // frame on, and nothing of the pointer's.
                @MainActor
                func isOnLattice(_ extent: CGFloat, _ cellExtent: CGFloat, _ reserve: CGFloat) -> Bool {
                    let cells = ((extent - reserve) / cellExtent).rounded()
                    return abs(extent - (cells * cellExtent + reserve).rounded(.up)) < 1
                }
                @MainActor
                func isOnLattice(_ size: NSSize) -> Bool {
                    isOnLattice(size.width, cell.width, reserve.width) && isOnLattice(size.height, cell.height, reserve.height)
                }

                // Clear of every edge: the window stands in the middle of the
                // screen's height, cells of room to the Dock and the menu bar,
                // and the harness parks it a desktop's width from the screen's
                // sides.
                let centred = NSRect(
                    x: window.frame.minX,
                    y: (visible.midY - window.frame.height / 2).rounded(.down),
                    width: window.frame.width,
                    height: window.frame.height
                )
                window.setFrame(centred, display: true)
                t.pump(0.2)
                let start = window.frame
                t.expect(
                    isOnLattice(start.size),
                    desc: "the window a drag starts from holds whole cells (\(start.size), cell \(cell), reserve \(reserve))"
                )
                t.expect(
                    start.minY - visible.minY > cell.height * 5 && visible.maxY - start.maxY > cell.height * 5,
                    desc: "the window is clear of the Dock and the menu bar (\(start), visible \(visible))"
                )

                // A bottom-right corner drag, in by four cells and back out, a
                // point at a time, as a pointer slower than the display delivers
                // it; the top-left corner stays put. Each step is judged on the
                // extent the quantiser chooses and on the one the window takes.
                shell.beginLiveResize(pressedAt: NSPoint(x: start.maxX, y: start.minY))
                surface.viewWillStartLiveResize()
                let travel = Int((4 * max(cell.width, cell.height)).rounded(.up))
                var offLattice: [String] = []
                var notApplied: [String] = []
                var gridMismatches: [String] = []
                var heights = Set<CGFloat>()
                var widths = Set<CGFloat>()
                @MainActor
                func dragCorner(to proposed: NSSize, _ name: String) {
                    let size = shell.snappedFrameSize(for: window, proposed: proposed, isLiveResize: true)
                    window.setFrame(
                        NSRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height),
                        display: true
                    )
                    t.pump(0.01)
                    if !isOnLattice(size) {
                        offLattice.append("\(name): asked \(proposed), quantised \(size)")
                    }
                    if window.frame.size != size {
                        notApplied.append("\(name): quantised \(size), applied \(window.frame.size)")
                    }
                    heights.insert(window.frame.height)
                    widths.insert(window.frame.width)
                    let rows = Int(surface.drive.readSnapshot().rows)
                    if rows != fittingRows(surface) {
                        gridMismatches.append("\(name): \(rows) rows, \(fittingRows(surface)) fit")
                    }
                }
                for step in 1...travel {
                    dragCorner(to: NSSize(width: start.width - CGFloat(step), height: start.height - CGFloat(step)), "in \(step)")
                }
                for step in stride(from: travel - 1, through: 0, by: -1) {
                    dragCorner(to: NSSize(width: start.width - CGFloat(step), height: start.height - CGFloat(step)), "out \(step)")
                }
                surface.viewDidEndLiveResize()
                shell.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                t.expect(
                    offLattice.isEmpty,
                    desc:
                        "every step away from the edges lands on whole cells"
                        + " (\(offLattice.count) of \(2 * travel) did not: \(offLattice.prefix(4).joined(separator: "; ")))"
                )
                t.expect(
                    notApplied.isEmpty,
                    desc: "every extent the quantiser chose is one the window takes (\(notApplied.prefix(4).joined(separator: "; ")))"
                )
                t.expect(
                    heights.count >= 4 && widths.count >= 4,
                    desc: "the drag crossed whole cells rather than holding the window (\(heights.count) heights, \(widths.count) widths)"
                )
                t.expect(
                    gridMismatches.isEmpty,
                    desc: "the grid holds the rows that fit at every step (\(gridMismatches.prefix(3).joined(separator: "; ")))"
                )
                t.expect(window.frame.size == start.size, desc: "out and back lands where it started (\(window.frame.size), \(start.size))")

                // The exception: the partial cell before the Dock. Lifted off
                // the visible frame's bottom by a distance that is not a whole
                // number of cells and dragged down by its bottom edge, the window
                // snaps up to the last whole cell, follows the pointer through
                // the rest, lands flush with the Dock, and stays there.
                let lifted = NSRect(
                    x: start.minX,
                    y: visible.minY + (cell.height * 2.5).rounded(),
                    width: start.width,
                    height: start.height
                )
                window.setFrame(lifted, display: true)
                t.pump(0.2)
                let available = lifted.maxY - visible.minY
                let lastFitting = (((available - reserve.height) / cell.height).rounded(.down) * cell.height + reserve.height).rounded(.up)
                shell.beginLiveResize(pressedAt: NSPoint(x: lifted.midX, y: lifted.minY))
                surface.viewWillStartLiveResize()
                var edgeFaults: [String] = []
                var pointsFollowed = 0
                var asked = lifted.height
                while asked < available + 3 {
                    asked += 1
                    let size = shell.snappedFrameSize(
                        for: window,
                        proposed: NSSize(width: lifted.width, height: asked),
                        isLiveResize: true
                    )
                    window.setFrame(
                        NSRect(x: lifted.minX, y: lifted.maxY - size.height, width: size.width, height: size.height),
                        display: true
                    )
                    t.pump(0.01)
                    if asked <= lastFitting {
                        if !isOnLattice(size.height, cell.height, reserve.height) {
                            edgeFaults.append("short of the last whole cell, \(asked) pt asked, \(size.height) pt applied")
                        }
                    } else if asked <= available {
                        if size.height == asked {
                            pointsFollowed += 1
                        } else {
                            edgeFaults.append("in the partial cell, \(asked) pt asked, \(size.height) pt applied")
                        }
                    } else if size.height != available || window.frame.minY != visible.minY {
                        edgeFaults.append(
                            "past the Dock, \(asked) pt asked, \(size.height) pt applied, bottom at \(window.frame.minY) for \(visible.minY)"
                        )
                    }
                }
                surface.viewDidEndLiveResize()
                shell.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                t.expect(
                    edgeFaults.isEmpty,
                    desc:
                        "toward the Dock the drag snaps, then follows the pointer, then stops"
                        + " (\(edgeFaults.count) faults: \(edgeFaults.prefix(4).joined(separator: "; ")))"
                )
                t.expect(
                    pointsFollowed >= 1 || available - lastFitting < 1,
                    desc: "the partial cell before the Dock follows the pointer (\(pointsFollowed) points of \(available - lastFitting))"
                )
                t.pump(0.1)
                t.expect(window.frame.minY == visible.minY, desc: "the released window stays flush with the Dock (\(window.frame))")
            }
        }

        UBUITestRegister("swift_shell_every_live_resize_step_draws_whole_rows_from_the_top_inset") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let spawned = spawnSurface(t, arguments: ["/bin/sh", "-c", "exec sleep 1000"]) else { return }
                let (shell, window, surface) = (spawned.shell, spawned.window, spawned.surface)
                defer { window.close() }
                // Unquantised, so a step can land anywhere between two cell
                // counts; the rule under test is the grid's, whatever the drag.
                shell.snapsWindowResizeForTesting = false
                guard let box = surface.gridFitBoxForTesting, box.cell.height > 0 else {
                    t.expect(false, desc: "the surface has a cell to fit")
                    return
                }
                let cell = box.cell
                let scale = surface.metalLayer.contentsScale

                // A full-screen program's screen: a menu bar on row 0, a solid
                // band of reverse-video blanks, and a row number on every
                // other row. A program
                // repaints all of it on SIGWINCH; `paint` is that repaint.
                @MainActor
                func paint() {
                    let rows = Int(surface.drive.readSnapshot().rows)
                    let columns = Int(surface.drive.readSnapshot().columns)
                    var screen = "\u{1b}[H\u{1b}[2J\u{1b}[7m" + String(repeating: " ", count: columns) + "\u{1b}[0m"
                    for row in 2...max(2, rows) {
                        screen += "\u{1b}[\(row);1Hrow \(row)"
                    }
                    surface.feed(Data(screen.utf8))
                    t.pump(0.1)
                }
                surface.feed(Data("\u{1b}[?1049h".utf8))
                paint()

                guard let settled = surface.renderedFrameForTesting(), let originY = surface.lastFrameOriginForTesting?.y else {
                    t.expect(false, desc: "the surface draws a frame")
                    return
                }
                let origin = Int(originY)
                let cellPixels = Int((cell.height * scale).rounded())
                let probeX = Int(((box.insets.left + cell.width * 2.5) * scale).rounded())
                @MainActor
                func pixel(_ frame: (width: Int, height: Int, pixels: Data), _ x: Int, _ y: Int) -> UInt32 {
                    frame.pixels.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (y * frame.width + x) * 4, as: UInt32.self) }
                }
                let bar = pixel(settled, probeX, origin + cellPixels / 2)
                let ground = pixel(settled, settled.width - 1, settled.height - 1)
                t.expect(bar != ground, desc: "the menu bar is drawn in a colour of its own")

                // Every frame: the menu bar whole on the first row at the top
                // inset, nothing drawn above that inset nor under the last
                // whole row, the rows that fit and no more, and a stale
                // drawable pinned where a partial frame would only ever lose
                // its bottom.
                @MainActor
                func expectWholeRows(_ name: String) {
                    let rows = Int(surface.drive.readSnapshot().rows)
                    t.expect(rows == fittingRows(surface), desc: "\(name): \(rows) rows, \(fittingRows(surface)) fit whole")
                    t.expect(
                        surface.metalLayer.contentsGravity == .topLeft,
                        desc: "\(name): a stale drawable is pinned top-left (\(surface.metalLayer.contentsGravity.rawValue))"
                    )
                    guard let frame = surface.renderedFrameForTesting(), let drawnY = surface.lastFrameOriginForTesting?.y else {
                        t.expect(false, desc: "\(name): a frame is drawn")
                        return
                    }
                    t.expect(Int(drawnY) == origin, desc: "\(name): the first row is at the top inset (\(drawnY) px, \(origin) px)")
                    let barRows = (origin..<(origin + cellPixels)).filter { pixel(frame, probeX, $0) == bar }.count
                    t.expect(barRows == cellPixels, desc: "\(name): the menu bar is whole (\(barRows) of \(cellPixels) px rows)")
                    let above = (0..<origin).filter { pixel(frame, probeX, $0) != ground }.count
                    t.expect(above == 0, desc: "\(name): nothing is drawn above the top inset (\(above) px rows)")
                    let textBottom = min(frame.height, origin + Int((CGFloat(rows) * cell.height * scale).rounded(.up)))
                    var below = 0
                    for y in textBottom..<frame.height {
                        for x in stride(from: 0, to: frame.width, by: 3) where pixel(frame, x, y) != ground {
                            below += 1
                            break
                        }
                    }
                    t.expect(below == 0, desc: "\(name): nothing is drawn under the last whole row (\(below) px rows)")
                }
                expectWholeRows("settled")

                // Each edge a reader can drag, through heights between two cell
                // counts and across them, shrinking and growing, the step held
                // as the drag holds it: the edge opposite the handle stands.
                let start = window.frame
                let shares: [CGFloat] = [-0.3, -0.7, -1.2, -2.6, -1.9, -0.4, 0.6, 1.4]
                for (edge, press) in [
                    ("top edge", NSPoint(x: start.midX, y: start.maxY)),
                    ("top-left corner", NSPoint(x: start.minX, y: start.maxY)),
                    ("bottom edge", NSPoint(x: start.midX, y: start.minY)),
                ] {
                    window.setFrame(start, display: true)
                    paint()
                    shell.beginLiveResize(pressedAt: press)
                    surface.viewWillStartLiveResize()
                    for share in shares {
                        let height = (start.height + cell.height * share).rounded()
                        let width = edge == "top-left corner" ? (start.width + cell.width * share).rounded() : start.width
                        let isTopFixed = edge == "bottom edge"
                        window.setFrame(
                            NSRect(
                                x: start.maxX - width,
                                y: isTopFixed ? start.maxY - height : start.minY,
                                width: width,
                                height: height
                            ),
                            display: true
                        )
                        let name = "\(edge) at \(share) cells"
                        expectWholeRows(name + ", before the repaint")
                        paint()
                        expectWholeRows(name + ", after the repaint")
                    }
                    surface.viewDidEndLiveResize()
                    shell.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                    expectWholeRows("\(edge), released")
                }
                surface.feed(Data("\u{1b}[?1049l".utf8))
                t.pump(0.1)
            }
        }

        UBUITestRegister("swift_shell_a_backing_change_asks_for_a_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let spawned = spawnSurface(t, arguments: ["/bin/sh", "-c", "exec sleep 1000"]) else { return }
                let (window, surface) = (spawned.window, spawned.surface)
                defer { window.close() }
                // A quiet surface first, so a frame counted after the change is
                // the change's and not a blink's or a late prompt's.
                t.pump(0.5)
                let quietStart = surface.framesEncodedForTesting
                t.pump(0.5)
                let quietEnd = surface.framesEncodedForTesting
                t.expect(quietEnd == quietStart, desc: "an idle surface on a quiet child encodes no frames (\(quietStart) to \(quietEnd))")
                // The scale change AppKit reports when a window crosses to a
                // display of another scale, with the frame unchanged: nothing
                // moves the grid, so nothing but this asks for the frame that
                // draws at the new scale.
                surface.surfaceDidChangeBackingProperties()
                t.pump(0.5)
                let afterChange = surface.framesEncodedForTesting
                t.expect(afterChange > quietEnd, desc: "a backing change asks for a frame (\(quietEnd) to \(afterChange))")
            }
        }
    }
}

/// The program the live-resize census drives: a full-screen program that
/// answers every SIGWINCH as mc does, erasing the screen and repainting all of
/// it for the size it reads, in one buffer that reaches the terminal over many
/// reads. Every cell holds a glyph, so a frame caught between the erase and
/// the repaint is a frame of almost no ink. The first row names the size the
/// program last painted for.
private let repaintingProgramSource = """
    import fcntl, os, signal, struct, termios, time
    pending = True
    def winch(signum, frame):
        global pending
        pending = True
    signal.signal(signal.SIGWINCH, winch)
    os.write(1, b"\\x1b[?1049h\\x1b[?25l")
    painted = 0
    while True:
        if not pending:
            time.sleep(0.001)
            continue
        pending = False
        rows, columns = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\\0" * 8))[:2]
        painted += 1
        lines = []
        for row in range(rows):
            tag = "%dx%d #%d row %d " % (rows, columns, painted, row + 1)
            fill = (tag + "ubiquitty mc " * (columns // 13 + 2))[:columns]
            lines.append("\\x1b[%d;1H\\x1b[3%dm%s" % (row + 1, 1 + row % 6, fill))
        view = memoryview(("\\x1b[H\\x1b[2J" + "".join(lines) + "\\x1b[0m").encode())
        while view:
            view = view[os.write(1, view):]
    """

/// What the live-resize census counts, frame by frame.
@MainActor
private final class LiveResizeCensus {
    var presented = 0
    var cleared = 0
    var partial = 0
    /// Where each cleared frame fell: the step it was drawn in, or "after"
    /// once the drag had ended.
    var clearedAt: [String] = []
    var step = 0
    private(set) var previousInk: Int

    init(previousInk: Int) {
        self.previousInk = previousInk
    }

    /// Counts one presented frame by its ink. A cleared frame keeps under a
    /// third of the ink the frame before it showed; a step shrinks the window
    /// by far less.
    func note(ink: Int, at place: String) {
        presented += 1
        if previousInk > 1000, ink * 3 < previousInk {
            cleared += 1
            clearedAt.append(place)
        } else if previousInk > 1000, ink * 10 < previousInk * 7 {
            partial += 1
        }
        previousInk = ink
    }
}

extension ResizeParityScenarios {
    /// A drag of the window's corner under a program that clears and repaints
    /// on every SIGWINCH, read frame by frame: the screen shows the previous
    /// frame or the program's new one, never the cleared screen between them;
    /// the program is told at most one size per step and always the last one.
    ///
    /// The drag starts from a window filling the screen. A repaint of a grid
    /// that size reaches the parser over many reads, so a step drawn while
    /// one is arriving finds the erase applied and most rows still blank; a
    /// small grid's repaint lands in the read that carries its erase.
    static func registerLiveResizeCensus() {
        UBUITestRegister("swift_shell_a_live_resize_under_a_repainting_program_never_presents_a_cleared_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let script = NSTemporaryDirectory() + "ubq-repainting-program-\(ProcessInfo.processInfo.processIdentifier).py"
                guard (try? repaintingProgramSource.write(toFile: script, atomically: true, encoding: .utf8)) != nil else {
                    t.expect(false, desc: "the repainting program is written")
                    return
                }
                defer { try? FileManager.default.removeItem(atPath: script) }
                // UBIQUITTY_RESIZE_CENSUS_PROGRAM runs a real program instead
                // (mc, say), for a census by hand; the assertion is the
                // fixture's, whose every cell is ink.
                let override = ProcessInfo.processInfo.environment["UBIQUITTY_RESIZE_CENSUS_PROGRAM"] ?? ""
                let arguments = override.isEmpty ? ["/usr/bin/python3", script] : ["/bin/sh", "-c", "exec " + override]
                guard let spawned = spawnSurface(t, arguments: arguments) else { return }
                let (shell, window, surface) = (spawned.shell, spawned.window, spawned.surface)
                defer {
                    surface.frameEncodedObserverForTesting = nil
                    window.close()
                }
                window.orderBack(nil)
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    window.setFrame(visible, display: true)
                }
                let start = window.frame
                let painted = waitForGrid(t, of: surface) { $0.contains(" row 2 ") || (!override.isEmpty && $0.count > 200) }
                t.expect(painted.contains(" row 2 ") || !override.isEmpty, desc: "the program paints its screen")
                t.pump(0.3)

                // Ink is any pixel unlike the retained grid's first, which is
                // the padding's ground. Sampled on a prime stride: a frame of
                // glyphs in every cell holds thousands of samples, a cleared
                // one a cursor's worth at most.
                @MainActor
                func ink() -> Int? {
                    guard let pixels = surface.retainedGridPixelsForTesting() else { return nil }
                    return pixels.withUnsafeBytes { raw -> Int in
                        let words = raw.bindMemory(to: UInt32.self)
                        guard let ground = words.first else { return 0 }
                        var count = 0
                        for index in stride(from: 0, to: words.count, by: 7) where words[index] != ground {
                            count += 1
                        }
                        return count
                    }
                }
                let census = LiveResizeCensus(previousInk: ink() ?? 0)
                t.expect(census.previousInk > 1000, desc: "the settled frame is ink in every cell (\(census.previousInk) samples)")
                surface.frameEncodedObserverForTesting = { _ in
                    guard let current = ink() else { return }
                    census.note(ink: current, at: window.inLiveResize ? "s\(census.step)" : "after")
                }

                // The corner drag, as AppKit runs it: its live resize opened
                // and closed around the steps, each proposal quantised as a
                // drag's is. Sixty steps over a second, each a pair of frame
                // changes inside one turn, as a pointer faster than the display
                // delivers them; out and back.
                let startLiveResize = NSSelectorFromString("_startLiveResize")
                let endLiveResize = NSSelectorFromString("_endLiveResize")
                guard window.responds(to: startLiveResize), window.responds(to: endLiveResize) else {
                    t.expect(false, desc: "AppKit's live resize can be opened")
                    return
                }
                let deliveriesBefore = surface.drive.windowSizeDeliveryCount
                let framesBefore = surface.framesEncodedForTesting
                let startedAt = ProcessInfo.processInfo.systemUptime
                window.perform(startLiveResize)
                shell.beginLiveResize(pressedAt: NSPoint(x: start.maxX, y: start.minY))
                t.expect(window.inLiveResize, desc: "the window is in a live resize")
                // A pointer's drag tells the views itself; the private entry
                // may not, and the surface's own latch is what makes a step a
                // drag's rather than a settled resize.
                let opensSurfaceLatch = !surface.isHoldingImageGapsForResize
                if opensSurfaceLatch {
                    surface.viewWillStartLiveResize()
                }
                let holdsBefore = surface.withheldForSyncOutputCount
                let deferralsBefore = surface.deferredForArrivingRedrawCount
                let steps = 60
                for step in 1...steps {
                    census.step = step
                    let share = sin(Double.pi * Double(step) / Double(steps))
                    for half in [0.5, 1.0] {
                        let reach = share * half + (step > 1 ? sin(Double.pi * Double(step - 1) / Double(steps)) * (1 - half) : 0)
                        let proposed = NSSize(width: (start.width + 260 * reach).rounded(), height: (start.height + 160 * reach).rounded())
                        let size = shell.snappedFrameSize(for: window, proposed: proposed, isLiveResize: true)
                        window.setFrame(
                            NSRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height),
                            display: true
                        )
                    }
                    t.pump(1.0 / Double(steps))
                }
                // Out a little further and held, so the drag ends at a size
                // of its own rather than the one it opened at.
                let last = shell.snappedFrameSize(
                    for: window,
                    proposed: NSSize(width: start.width + 90, height: start.height + 60),
                    isLiveResize: true
                )
                window.setFrame(NSRect(x: start.minX, y: start.maxY - last.height, width: last.width, height: last.height), display: true)
                t.pump(1.0 / Double(steps))
                let holdsDuringResize = surface.withheldForSyncOutputCount - holdsBefore
                let deferralsDuringResize = surface.deferredForArrivingRedrawCount - deferralsBefore
                if opensSurfaceLatch {
                    surface.viewDidEndLiveResize()
                }
                window.perform(endLiveResize)
                let dragSeconds = ProcessInfo.processInfo.systemUptime - startedAt
                let settled = waitForGrid(t, of: surface) { text in
                    let snapshot = surface.drive.readSnapshot()
                    return !override.isEmpty || text.hasPrefix("\(snapshot.rows)x\(snapshot.columns) ")
                }
                t.pump(0.3)
                surface.frameEncodedObserverForTesting = nil
                let deliveries = Int(surface.drive.windowSizeDeliveryCount - deliveriesBefore)
                let frames = surface.framesEncodedForTesting - framesBefore
                let snapshot = surface.drive.readSnapshot()
                print(
                    "[resize-census] program=\(override.isEmpty ? "fixture" : override) steps=\(steps) seconds=\(String(format: "%.2f", dragSeconds))"
                        + " frames=\(frames) presented=\(census.presented) cleared=\(census.cleared) partial=\(census.partial) winsizes=\(deliveries) holds=\(holdsDuringResize)"
                        + " deferred=\(deferralsDuringResize)"
                        + " clearedAt=\(census.clearedAt.joined(separator: ","))"
                        + " final=\(snapshot.rows)x\(snapshot.columns) latch=\(opensSurfaceLatch ? "harness" : "appkit")"
                )
                t.expect(census.presented > steps / 2, desc: "the drag presents frames (\(census.presented) for \(steps) steps)")
                t.expect(
                    census.cleared == 0,
                    desc:
                        "no presented frame is the cleared screen between an erase and its repaint (\(census.cleared) of \(census.presented))"
                )
                t.expect(
                    census.partial == 0,
                    desc: "no presented frame is a repaint caught part of the way down (\(census.partial) of \(census.presented))"
                )
                if override.isEmpty {
                    t.expect(holdsDuringResize == 0, desc: "the resize never waits for quiet output (\(holdsDuringResize) holds)")
                    t.expect(
                        settled.hasPrefix("\(snapshot.rows)x\(snapshot.columns) "),
                        desc:
                            "the program last painted for the size the drag ended at (\(snapshot.rows)x\(snapshot.columns), \(settled.prefix(24)))"
                    )
                }
                t.expect(window.frame.size == last, desc: "the drag ends at its last size (\(window.frame.size), \(last))")
            }
        }
    }
}
