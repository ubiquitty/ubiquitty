// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// LocatorScenarios — the DEC locator on the Swift arm: DECELR arms it,
// DECSLE picks the transitions, a one-shot locator disarms on its first
// report, a DECEFR rectangle reports the move that leaves it, and the arm
// edge -- that one delivery, not every delivery the bit stands through --
// tells the locator where a pointer that has not moved stands.
//
// Everything the locator sends is read off the PTY: the program is `cat -v`,
// so each report is echoed onto the grid in caret notation. The held-button
// field is the hardware's, which a synthesised event does not press, so the
// reports are matched with that field left open.

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

/// The grid's text with its rows joined, so a report the echo wrapped across
/// a row boundary still reads as one.
@MainActor
private func joinedGrid(of surface: TerminalSurface) -> String {
    surface.gridTextForTesting().replacingOccurrences(of: "\n", with: "")
}

/// Pumps until the joined grid matches the pattern, or a few seconds pass.
@MainActor
private func waitForReport(_ t: UBUITestContext, on surface: TerminalSurface, matching pattern: String) -> Bool {
    for _ in 0..<40 {
        if joinedGrid(of: surface).range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        t.pump(0.1)
    }
    return joinedGrid(of: surface).range(of: pattern, options: .regularExpression) != nil
}

/// A DECLRP as `cat -v` echoes it, with the held-button field left open.
///
/// - Parameters:
///   - event: Pe, the event code.
///   - row: Pr, one-based.
///   - column: Pc, one-based.
/// - Returns: The pattern.
private func echoedReport(event: Int, row: Int, column: Int) -> String {
    "\\^\\[\\[\(event);[0-9]+;\(row);\(column);1&w"
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
        pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1
    )
}

enum LocatorScenarios {
    static func register() {
        UBUITestRegister("swift_shell_the_dec_locator_reports_where_its_pointer_is") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "LC_ALL=C exec cat -v"],
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
                window.makeKeyAndOrderFront(nil)
                t.pump(0.8)
                guard
                    let seedPoint = surface.viewPoint(forRow: 3, column: 7),
                    let walkPoint = surface.viewPoint(forRow: 9, column: 2),
                    let pressPoint = surface.viewPoint(forRow: 5, column: 10),
                    let oneShotPoint = surface.viewPoint(forRow: 7, column: 12),
                    let leavePoint = surface.viewPoint(forRow: 6, column: 12)
                else {
                    t.expect(false, desc: "the surface locates its cells")
                    return
                }
                // A DECRQLP fed to the model is answered into the reply
                // queue, which a drain flushes; a carriage return makes one,
                // and ends the echoed line so each report is read on its own.
                @MainActor
                func ask(_ bytes: String) {
                    surface.feed(Data(bytes.utf8))
                    t.pump(0.3)
                    surface.send("\r")
                }

                // The arm edge with the pointer off the surface: there is no
                // truthful position to publish, so DECRQLP answers Pe = 1
                // with the coordinates omitted.
                surface.locatorPointerOverrideForTesting = CGPoint(x: -40, y: -40)
                surface.feed(Data("\u{1b}[1;2'z".utf8))
                t.pump(0.3)
                ask("\u{1b}['|")
                t.expect(
                    waitForReport(t, on: surface, matching: "\\^\\[\\[1;0&w"),
                    desc:
                        "armed with the pointer elsewhere, the locator position is undefined (grid \(joinedGrid(of: surface).debugDescription))"
                )

                // Disarmed, then armed again with the pointer standing over
                // row 3, column 7: the edge publishes it without a move, and
                // DECRQLP answers it one-based.
                surface.feed(Data("\u{1b}[0'z".utf8))
                t.pump(0.3)
                surface.locatorPointerOverrideForTesting = seedPoint
                surface.feed(Data("\u{1b}[1;2'z".utf8))
                t.pump(0.3)
                ask("\u{1b}['|")
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 1, row: 4, column: 8)),
                    desc: "the arm edge tells the locator where the still pointer stands (grid \(joinedGrid(of: surface).debugDescription))"
                )

                // The mirrored bit is a latch, and the edge is the only moment
                // the surface seeds: the pointer stands somewhere else while
                // the locator stays armed and deliveries keep running -- the
                // echoed carriage return is the output they run on -- and
                // DECRQLP still answers the cell the edge published. A
                // reconcile that seeded on every delivery would answer 10;3,
                // where the pointer stands now. The grid is wiped first so the
                // answer is read on its own rather than off the earlier report.
                surface.locatorPointerOverrideForTesting = walkPoint
                surface.send("\r")
                t.pump(0.5)
                surface.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
                ask("\u{1b}['|")
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 1, row: 4, column: 8)),
                    desc: "the armed locator keeps the edge's cell (grid \(joinedGrid(of: surface).debugDescription))"
                )
                t.expect(
                    joinedGrid(of: surface).range(of: echoedReport(event: 1, row: 10, column: 3), options: .regularExpression) == nil,
                    desc: "and never answers the cell the pointer walked to (grid \(joinedGrid(of: surface).debugDescription))"
                )
                surface.locatorPointerOverrideForTesting = seedPoint

                // DECSLE selects both transitions: a press and its release at
                // row 5, column 10 report Pe 2 and Pe 3 in cells.
                surface.feed(Data("\u{1b}[1;3'{".utf8))
                t.pump(0.3)
                if let press = mouseEvent(.leftMouseDown, in: window, at: surface.convert(pressPoint, to: nil)) {
                    surface.mouseDown(with: press)
                }
                if let release = mouseEvent(.leftMouseUp, in: window, at: surface.convert(pressPoint, to: nil)) {
                    surface.mouseUp(with: release)
                }
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 2, row: 6, column: 11)),
                    desc: "the press is reported in the locator's cells (grid \(joinedGrid(of: surface).debugDescription))"
                )
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 3, row: 6, column: 11)),
                    desc: "and so is its release"
                )
                surface.send("\r")

                // One-shot: the press reports and disarms, so the release
                // that follows is not the locator's.
                surface.feed(Data("\u{1b}[2;2'z".utf8))
                t.pump(0.3)
                if let press = mouseEvent(.leftMouseDown, in: window, at: surface.convert(oneShotPoint, to: nil)) {
                    surface.mouseDown(with: press)
                }
                if let release = mouseEvent(.leftMouseUp, in: window, at: surface.convert(oneShotPoint, to: nil)) {
                    surface.mouseUp(with: release)
                }
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 2, row: 8, column: 13)),
                    desc: "a one-shot locator reports its first transition"
                )
                t.pump(0.3)
                t.expect(
                    joinedGrid(of: surface).range(of: echoedReport(event: 3, row: 8, column: 13), options: .regularExpression) == nil,
                    desc: "and nothing after it (grid \(joinedGrid(of: surface).debugDescription))"
                )
                surface.send("\r")

                // A rectangle around the arm edge's cell, then a move out of
                // it: the only motion the locator reports, Pe 10 where the
                // pointer went.
                surface.feed(Data("\u{1b}[1;2'z".utf8))
                t.pump(0.3)
                surface.feed(Data("\u{1b}[3;7;5;9'w".utf8))
                t.pump(0.3)
                if let move = mouseEvent(.mouseMoved, in: window, at: surface.convert(leavePoint, to: nil)) {
                    surface.mouseMoved(with: move)
                }
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 10, row: 7, column: 13)),
                    desc: "leaving the rectangle is reported where the pointer went (grid \(joinedGrid(of: surface).debugDescription))"
                )
                surface.send("\r")

                // A rectangle armed in the same drain as the locator, with the
                // still pointer already outside it: the edge's seed owes the
                // leave, and sends it rather than dropping it.
                surface.feed(Data("\u{1b}[0'z".utf8))
                t.pump(0.3)
                surface.feed(Data("\u{1b}[1;2'z\u{1b}[1;1;1;1'w".utf8))
                t.expect(
                    waitForReport(t, on: surface, matching: echoedReport(event: 10, row: 4, column: 8)),
                    desc: "a seed outside a rectangle armed beside it reports the leave (grid \(joinedGrid(of: surface).debugDescription))"
                )
                surface.locatorPointerOverrideForTesting = nil
            }
        }
    }
}
