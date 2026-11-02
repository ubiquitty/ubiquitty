// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ProportionalRunScenarios — a proportional primary face on the Swift arm:
// the row is laid out as proportional runs (Docs/proportional-text.md), a
// press lands on the letter under it rather than on a column at the pitch,
// and a drag selects the letters it crossed. The letter positions come from
// the frame the renderer drew, through Core's capture, so the scenario reads
// them back rather than computing any of its own.

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

/// The view point a fraction of the way across a column's letter on a row,
/// from the layout the frame drew.
///
/// - Parameters:
///   - surface: The surface showing the row.
///   - row: The visible row.
///   - column: The column whose letter is asked about.
///   - fraction: How far across the letter's advance, 0 at its left edge.
/// - Returns: The point, or nil before a frame was drawn.
@MainActor
private func letterPoint(on surface: TerminalSurface, row: Int, column: Int, fraction: Double) -> CGPoint? {
    guard let extent = surface.letterExtentForTesting(row: row, column: column),
        let box = surface.gridFitBoxForTesting
    else {
        return nil
    }
    return CGPoint(
        x: box.insets.left + (extent.left + extent.advance * fraction) * box.cell.width,
        y: box.insets.top + (Double(row) + 0.5) * box.cell.height
    )
}

/// Drags between two view points and reports what was selected.
@MainActor
private func dragSelect(on surface: TerminalSurface, in window: NSWindow, from start: CGPoint, to end: CGPoint) -> String {
    let startInWindow = surface.convert(start, to: nil)
    let endInWindow = surface.convert(end, to: nil)
    if let press = mouseEvent(.leftMouseDown, in: window, at: startInWindow) {
        surface.mouseDown(with: press)
    }
    if let drag = mouseEvent(.leftMouseDragged, in: window, at: endInWindow) {
        surface.mouseDragged(with: drag)
    }
    if let release = mouseEvent(.leftMouseUp, in: window, at: endInWindow) {
        surface.mouseUp(with: release)
    }
    return surface.selectedText ?? ""
}

enum ProportionalRunScenarios {
    static func register() {
        UBUITestRegister("swift_shell_a_proportional_face_selects_and_hits_by_letter") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let content = window.contentView, let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a terminal window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                // SF Pro ships with macOS alone, and it is the face the ruling
                // was made on; a host without it has nothing to lay out.
                guard
                    surface.adoptFontForTesting(
                        familyName: "SF Pro",
                        pointSize: 14,
                        typography: surface.typographyForTesting ?? SurfaceTypography()
                    )
                else {
                    t.expect(false, desc: "SF Pro is adopted as the grid face")
                    return
                }
                t.pump(0.3)
                // Columns: W W W, a space, i i i, a space, then Hamburg from
                // column 8 — H a m b u r g — so m is column 10 and b column 11.
                surface.feed(Data("\u{1b}[H\u{1b}[2J\u{1b}[?25lWWW iii Hamburg\r\nsecond row\r\n".utf8))
                t.expect(
                    t.wait(
                        until: {
                            guard surface.gridTextForTesting().contains("WWW iii Hamburg") else { return false }
                            _ = surface.renderedFrameForTesting()
                            return surface.letterExtentForTesting(row: 0, column: 0)?.isLetterRow == true
                        },
                        timeout: 5
                    ),
                    desc: "the frame lays out the published SF Pro row as letters"
                )
                guard let w = surface.letterExtentForTesting(row: 0, column: 0),
                    let i = surface.letterExtentForTesting(row: 0, column: 4),
                    let m = surface.letterExtentForTesting(row: 0, column: 10)
                else {
                    t.expect(false, desc: "the frame reports its letters")
                    return
                }
                t.expect(w.isLetterRow, desc: "a row in SF Pro is laid out as letters")
                t.expect(w.advance > i.advance * 2, desc: "W advances more than twice an i (W \(w.advance), i \(i.advance) cells)")
                t.expect(w.advance > 1.2, desc: "a W is wider than the digit cell (\(w.advance) cells)")
                t.expect(i.advance < 0.8, desc: "an i is narrower than the digit cell (\(i.advance) cells)")
                t.expect(
                    abs(m.left - (w.left + 10 * w.advance)) > 0.5,
                    desc: "the letters do not stand on the pitch (m at \(m.left), pitch would put it at \(10 * w.advance))"
                )

                // A press on the middle of the m names column 10, where the pitch
                // would name a column well to its right of the narrow i's.
                guard let middleOfM = letterPoint(on: surface, row: 0, column: 10, fraction: 0.5) else {
                    t.expect(false, desc: "the m has a point")
                    return
                }
                let hit = surface.gridHitForTesting(atViewPoint: middleOfM)
                t.expect(
                    hit.strict?.column == 10 && hit.report?.column == 10,
                    desc:
                        "the pointer resolves to the letter under it (strict \(String(describing: hit.strict)), report \(String(describing: hit.report)))"
                )
                guard let lastI = letterPoint(on: surface, row: 0, column: 6, fraction: 0.5) else {
                    t.expect(false, desc: "the last i has a point")
                    return
                }
                t.expect(
                    surface.gridHitForTesting(atViewPoint: lastI).strict?.column == 6,
                    desc: "and a narrow letter is hit inside its own advance"
                )

                // A drag from the left of the a through the right of the b
                // selects the letters it crossed, a letter at a time.
                guard let fromA = letterPoint(on: surface, row: 0, column: 9, fraction: 0.2),
                    let toB = letterPoint(on: surface, row: 0, column: 11, fraction: 0.8)
                else {
                    t.expect(false, desc: "the a and the b have points")
                    return
                }
                let selected = dragSelect(on: surface, in: window, from: fromA, to: toB)
                t.expect(selected == "amb", desc: "the drag selects the letters it crossed: '\(selected)'")
            }
        }
    }
}
