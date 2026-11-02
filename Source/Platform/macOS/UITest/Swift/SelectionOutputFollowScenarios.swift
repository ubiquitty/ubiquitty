// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// SelectionOutputFollowScenarios.swift — a held drag against a real, running
// shell whose output keeps arriving.
//
// Every other proof of this behaviour is headless: Core's own tests drive
// `Selection::updateAfterOutput` directly against a `Terminal` a test wrote
// bytes into by hand. None of them answers whether real `NSEvent`s reach the
// gesture at all, or whether output the real PTY drain delivers asynchronously
// -- not a test harness's synchronous `feed()` -- reaches the same call. This
// is that answer: a real window, a real spawned shell, a real held
// `leftMouseDown`, and real command output arriving while the mouse never
// moves again.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
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

/// A mouse event at a point in the window.
///
/// - Parameters:
///   - type: Which mouse event.
///   - window: The window the point is in.
///   - point: The location, in window coordinates.
/// - Returns: The event, or nil when AppKit refuses it.
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

/// Registers the selection/output-follow scenarios with the UI-test runner.
enum SelectionOutputFollowScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_held_drag_follows_real_output_with_a_stationary_mouse") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let trigger = NSTemporaryDirectory() + "ubiquitty-drag-output-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: trigger) }
                let script =
                    "import os, sys, time\n"
                    + "for i in range(200): os.write(1, f'filler-{i + 1}\\r\\n'.encode())\n"
                    + "os.write(1, b'anchor\\r\\nmiddle\\r\\npointer\\r\\n')\n"
                    + "while not os.path.exists(sys.argv[1]): time.sleep(0.02)\n"
                    + "os.write(1, b'tail-line\\r\\nTAIL-WRITE-COMPLETE\\r\\n')\n"
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/usr/bin/python3", "-u", "-c", script, trigger],
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
                t.pump(0.3)

                let rows = surface.publishedGrid.rows
                guard rows >= 4 else {
                    t.expect(false, desc: "the spawned window has room for the scenario's 3 marker rows (has \(rows))")
                    return
                }

                // The writer fills beyond the grid and parks after its three
                // markers, so no login prompt can move the selection anchor.
                var scrollback = 0
                for _ in 0..<80 {
                    t.pump(0.1)
                    scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
                    if scrollback >= 15 && surface.gridTextForTesting().contains("pointer") { break }
                }
                guard scrollback >= 15 && surface.gridTextForTesting().contains("pointer") else {
                    t.expect(false, desc: "the writer produced its marker rows and scrollback (got \(scrollback))")
                    return
                }
                t.expect(surface.viewOffset == 0, desc: "the view stayed at the live tail while it filled")

                // The final newline leaves the pointer one row above the tail.
                let anchorRow = rows - 4
                let pointerRow = rows - 2
                guard let anchorViewPoint = surface.viewPoint(forRow: anchorRow, column: 0),
                    let nextColumnPoint = surface.viewPoint(forRow: anchorRow, column: 1),
                    let pointerViewPoint = surface.viewPoint(forRow: pointerRow, column: 6)
                else {
                    t.expect(false, desc: "the surface has measured cell geometry")
                    return
                }
                // A quarter cell left of the first column's centre. The press
                // anchors at the caret NEAREST it, so a centre would put the
                // anchor after the first character and leave it out of the
                // span this scenario is about.
                let cellWidth = nextColumnPoint.x - anchorViewPoint.x
                let anchorPoint = surface.convert(
                    CGPoint(x: anchorViewPoint.x - cellWidth / 4, y: anchorViewPoint.y),
                    to: nil
                )
                let pointerPoint = surface.convert(pointerViewPoint, to: nil)

                // Plain clickCount-1 press-and-drag: the same gesture a user's
                // first click-drag opens, driven by the caret model on both
                // shells.
                guard let down = mouseEvent(.leftMouseDown, in: window, at: anchorPoint),
                    let dragged = mouseEvent(.leftMouseDragged, in: window, at: pointerPoint)
                else {
                    t.expect(false, desc: "AppKit synthesises the press and drag events")
                    return
                }
                surface.mouseDown(with: down)
                t.pump(0.05)
                surface.mouseDragged(with: dragged)
                t.pump(0.1)

                t.expect(surface.hasSelection, desc: "the held drag opened a selection")
                let selectedBeforeOutput = surface.selectedText ?? ""
                t.expect(
                    selectedBeforeOutput.contains("anchor") && selectedBeforeOutput.contains("pointer"),
                    desc: "the drag spans from the press to the release point (got \(selectedBeforeOutput.debugDescription))"
                )

                // The mouse does not move again. The marker follows the complete
                // tail line, with no shell echo or startup text in the selection.
                _ = FileManager.default.createFile(atPath: trigger, contents: Data())
                t.expect(
                    t.wait(until: { surface.gridTextForTesting().contains("TAIL-WRITE-COMPLETE") }, timeout: 5),
                    desc: "the complete tail line reaches the grid before the selection is read"
                )
                let selectedAfterOutput = surface.selectedText ?? ""

                t.expect(
                    selectedAfterOutput.contains("anchor"),
                    desc: "the press stays attached to its buffer character as it ages into scrollback"
                        + " (got \(selectedAfterOutput.debugDescription))"
                )
                t.expect(
                    selectedAfterOutput.contains("tail-line"),
                    desc: "the held gesture's head grows to the new tail with no further mouse movement"
                        + " (got \(selectedAfterOutput.debugDescription))"
                )

                if let up = mouseEvent(.leftMouseUp, in: window, at: pointerPoint) {
                    surface.mouseUp(with: up)
                }
                t.pump(0.1)
                t.expect(surface.hasSelection, desc: "the released selection stands")
            }
        }
    }
}
