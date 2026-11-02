// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// PixelReportScenarios — the pixel space a program is told about on the
// Swift arm: a DECSET 1016 report measures from the padded grid's corner in
// the drawn scale, and the winsize pixels name the same drawn text area that
// CSI 14 t does.
//
// Both are read off the PTY: the program echoes what it received in caret
// notation, and the grid is read back through the surface.

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

/// Pumps until the grid's text satisfies the predicate, or a few seconds pass.
@MainActor
private func waitForGrid(_ t: UBUITestContext, of surface: TerminalSurface, _ predicate: (String) -> Bool) -> String {
    var text = surface.gridTextForTesting()
    var remaining = 40
    while !predicate(text), remaining > 0 {
        t.pump(0.1)
        remaining -= 1
        text = surface.gridTextForTesting()
    }
    return text
}

@MainActor
private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// Reads TIOCGWINSZ from inside the child and prints it as `winsize R C X Y`.
private let winsizeProbe =
    "import fcntl, struct, sys, termios; r, c, x, y = struct.unpack('HHHH', fcntl.ioctl(sys.stdout, termios.TIOCGWINSZ, b'\\0' * 8)); print('winsize', r, c, x, y)"

enum PixelReportScenarios {
    static func register() {
        UBUITestRegister("swift_shell_a_pixel_mouse_report_measures_from_the_padded_grid") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The program turns on pixel mouse reporting and then echoes
                // every byte it reads, so the report is a line on the grid.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "printf '\\033[?1000h\\033[?1006h\\033[?1016h'; LC_ALL=C exec cat -v"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens on cat -v with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.8)
                guard let box = surface.gridFitBoxForTesting else {
                    t.expect(false, desc: "the surface knows its grid box")
                    return
                }
                t.expect(box.insets.left > 0 && box.insets.top >= 0, desc: "padding is on (left \(box.insets.left), top \(box.insets.top))")
                let scale = surface.metalLayer.contentsScale
                t.expect(scale > 0, desc: "the layer draws at a scale (\(scale))")

                // A known cell, clicked at its centre. The report is the pixel
                // measured from the padded grid's corner, in the drawn scale,
                // one-based — the number a program dividing by the cell's
                // device size turns back into this cell.
                let row = 3
                let column = 7
                guard let point = surface.viewPoint(forRow: row, column: column) else {
                    t.expect(false, desc: "the surface locates the cell")
                    return
                }
                let expectedX = Int(((point.x - box.insets.left) * scale).rounded(.down)) + 1
                let expectedY = Int(((point.y - box.insets.top) * scale).rounded(.down)) + 1
                let inWindow = surface.convert(point, to: nil)
                if let press = mouseEvent(.leftMouseDown, in: window, at: inWindow) {
                    surface.mouseDown(with: press)
                }
                if let release = mouseEvent(.leftMouseUp, in: window, at: inWindow) {
                    surface.mouseUp(with: release)
                }
                let pressReport = "^[[<0;\(expectedX);\(expectedY)M"
                let releaseReport = "^[[<0;\(expectedX);\(expectedY)m"
                let text = waitForGrid(t, of: surface) { $0.contains(pressReport) && $0.contains(releaseReport) }
                t.expect(
                    text.contains(pressReport),
                    desc: "the press reports the pixel from the padded grid's corner (wanted \(pressReport); grid \(text.debugDescription))"
                )
                t.expect(
                    text.contains(releaseReport),
                    desc: "and the release names the same pixel (wanted \(releaseReport); grid \(text.debugDescription))"
                )
                // A report from the view's corner instead would sit a
                // padding-width past it: the drift the entry names.
                let driftedX = Int((point.x * scale).rounded(.down)) + 1
                t.expect(driftedX != expectedX, desc: "the padding tells the two bases apart (\(driftedX) vs \(expectedX))")
                t.expect(!text.contains("^[[<0;\(driftedX);"), desc: "no report measured from the view's corner")
            }
        }

        UBUITestRegister("swift_shell_the_winsize_pixels_and_csi14t_name_the_drawn_text_area") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The child reads its winsize and asks the terminal for the
                // text area in pixels, and echoes both onto the grid.
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: [
                            "/bin/sh", "-c",
                            "sleep 1; python3 -c \"\(winsizeProbe)\"; printf '\\033[14t'; LC_ALL=C exec cat -v",
                        ],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens on the probe with a surface")
                    return
                }
                defer { window.close() }
                let text = waitForGrid(t, of: surface) { $0.contains("winsize ") && $0.contains("^[[4;") }
                let grid = surface.drive.readSnapshot()
                guard let box = surface.gridFitBoxForTesting else {
                    t.expect(false, desc: "the surface knows its grid box")
                    return
                }
                let scale = surface.metalLayer.contentsScale
                let drawnWidth = Int((box.cell.width * CGFloat(grid.columns) * scale).rounded())
                let drawnHeight = Int((box.cell.height * CGFloat(grid.rows) * scale).rounded())
                let boundsWidth = Int((surface.bounds.width * scale).rounded())

                // `winsize R C X Y` from TIOCGWINSZ.
                let winsizeLine = text.split(separator: "\n").first { $0.hasPrefix("winsize ") }.map(String.init) ?? ""
                let fields = winsizeLine.split(separator: " ").compactMap { Int($0) }
                t.expect(fields.count == 4, desc: "the child read its winsize (\(winsizeLine.debugDescription))")
                if fields.count == 4 {
                    t.expect(
                        fields[0] == Int(grid.rows) && fields[1] == Int(grid.columns),
                        desc: "the winsize grid is the surface's (\(fields[0])x\(fields[1]) vs \(grid.rows)x\(grid.columns))"
                    )
                    t.expect(
                        fields[2] == drawnWidth && fields[3] == drawnHeight,
                        desc: "the winsize pixels are the drawn text area (\(fields[2])x\(fields[3]) vs \(drawnWidth)x\(drawnHeight))"
                    )
                    t.expect(
                        fields[2] != boundsWidth || box.insets.left + box.insets.right == 0,
                        desc: "and not the padded bounds (\(boundsWidth))"
                    )
                }
                // CSI 14 t answers `CSI 4 ; height ; width t`.
                t.expect(
                    text.contains("^[[4;\(drawnHeight);\(drawnWidth)t"),
                    desc: "CSI 14 t names the same drawn text area (grid \(text.debugDescription))"
                )
            }
        }
    }
}
