// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TerminalBehaviourScenarios.swift — terminal behaviour a reader relies on
// that no single feature owns: what a copy reads, what a click selects, which
// chord reaches a selection through an application tracking the mouse, how a
// split pane is sized for its display, that a held synchronized-output block
// cannot freeze the window, and the Help menu the application installs.
//
// Each drives the real surface through the entry points AppKit uses and
// reads the effect off the model or the pasteboard, never off a value the
// surface reports about itself.

/// Registers the terminal-behaviour scenarios with the UI-test runner.
enum TerminalBehaviourScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // A copy reads the screen the reader is looking at. With an
        // application on the alternate screen, the primary buffer behind it
        // is not on screen, and a copy that read it would hand the reader
        // text they never selected.
        UBUITestRegister("swift_shell_copy_reads_the_active_alternate_screen") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let (shell, surface) = openShell(t) else { return }
                defer { shell.window?.close() }
                surface.feed(Data("PRIMARYBEHIND42\r\n".utf8))
                surface.feed(Data("\u{1b}[?1049h\u{1b}[HALTSCREEN99".utf8))
                t.pump(0.2)
                surface.selectAll(nil)
                t.pump(0.1)
                let copied = copyThroughTheMenuAction(surface, t)
                t.expect(copied.contains("ALTSCREEN99"), desc: "a copy reads the active alternate screen (\(copied.debugDescription))")
                t.expect(!copied.contains("PRIMARYBEHIND42"), desc: "and not the primary buffer behind it")
                surface.feed(Data("\u{1b}[?1049l".utf8))
            }
        }

        // A triple click takes the logical line, and a line the terminal
        // wrapped is one line: a click on its second visual row selects from
        // the first row's start through the tail.
        UBUITestRegister("swift_shell_triple_click_selects_the_whole_wrapped_line") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let (shell, surface) = openShell(t), let window = shell.window else { return }
                defer { window.close() }
                let columns = Int(surface.drive.readSnapshot().columns)
                t.expect(columns >= 20, desc: "the grid is wide enough to wrap a line into two rows (\(columns))")
                let filler = String(repeating: "x", count: columns)
                surface.feed(Data("\u{1b}[H\u{1b}[2JHEAD\(filler)TAIL\r\n".utf8))
                t.pump(0.2)
                guard let point = surface.viewPoint(forRow: 1, column: 2) else {
                    t.expect(false, desc: "the second visual row has a place on screen")
                    return
                }
                let inWindow = surface.convert(point, to: nil)
                for clickCount in 1...3 {
                    if let press = mouseEvent(.leftMouseDown, in: window, at: inWindow, modifiers: [], clickCount: clickCount) {
                        surface.mouseDown(with: press)
                    }
                    if let release = mouseEvent(.leftMouseUp, in: window, at: inWindow, modifiers: [], clickCount: clickCount) {
                        surface.mouseUp(with: release)
                    }
                }
                let selected = surface.selectedText ?? ""
                t.expect(
                    selected.hasPrefix("HEADxxx"),
                    desc: "a triple click on the second row selects from the first row's start (\(selected.prefix(12)))"
                )
                t.expect(selected.contains("xxxTAIL"), desc: "and through the wrapped tail")
            }
        }

        // Under an application tracking the mouse, a plain drag is the
        // application's. Shift is xterm's bypass to a local selection, which no
        // configuration takes away; Command is the link gesture and reaches no
        // selection, so the application keeps the report.
        UBUITestRegister("swift_shell_selection_chords_reach_through_mouse_reporting") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let (shell, surface) = openShell(t), let window = shell.window else { return }
                defer { window.close() }
                surface.feed(Data("\u{1b}[H\u{1b}[2J".utf8))
                for row in 0..<10 {
                    surface.feed(Data("ROW\(row)-ABCDEFGHIJ\r\n".utf8))
                }
                t.pump(0.2)
                let control = drag(surface, in: window, modifiers: [])
                t.expect(!control.isEmpty, desc: "control: with no reporting a plain drag selects locally")

                surface.feed(Data("\u{1b}[?1002h\u{1b}[?1006h".utf8))
                t.pump(0.3)
                t.expect(drag(surface, in: window, modifiers: []).isEmpty, desc: "under reporting a plain drag is the application's")
                t.expect(!drag(surface, in: window, modifiers: [.shift]).isEmpty, desc: "Shift reaches a local selection through it")
                _ = drag(surface, in: window, modifiers: [])
                t.expect(
                    drag(surface, in: window, modifiers: [.command]).isEmpty,
                    desc: "Command is the link gesture and reaches no selection"
                )
                surface.feed(Data("\u{1b}[?1002l\u{1b}[?1006l".utf8))
            }
        }

        UBUITestRegister("swift_shell_shift_drag_selects_through_the_top_edge") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let (shell, surface) = openShell(t), let window = shell.window else { return }
                defer { window.close() }
                surface.feed(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2JTOP\r\nmiddle\r\nbottom\u{1b}[?1002h\u{1b}[?1006h".utf8))
                t.pump(0.2)
                surface.selectAll(nil)
                t.expect(surface.selectedText?.contains("TOP") == true, desc: "Select All includes the first visible row")
                surface.clearSelection()

                guard let start = surface.viewPoint(forRow: 2, column: 4),
                    let top = surface.viewPoint(forRow: 0, column: 0),
                    let next = surface.viewPoint(forRow: 1, column: 0),
                    let right = surface.viewPoint(forRow: 0, column: 30),
                    let frameView = window.contentView?.superview
                else {
                    t.expect(false, desc: "the first rows have measured positions in the window")
                    return
                }
                let topInParent = surface.convert(top, to: frameView.superview)
                t.expect(frameView.hitTest(topInParent) === surface, desc: "native hit testing delivers the top row to the terminal")
                let above = CGPoint(x: right.x, y: top.y - 0.75 * (next.y - top.y))
                let windowFrame = window.frame
                for endpoint in [top, above] {
                    surface.clearSelection()
                    let from = surface.convert(start, to: nil)
                    let to = surface.convert(endpoint, to: nil)
                    if let press = mouseEvent(.leftMouseDown, in: window, at: from, modifiers: [.shift]) {
                        surface.mouseDown(with: press)
                    }
                    if let moved = mouseEvent(.leftMouseDragged, in: window, at: to, modifiers: [.shift]) {
                        surface.mouseDragged(with: moved)
                    }
                    if let release = mouseEvent(.leftMouseUp, in: window, at: to, modifiers: [.shift]) {
                        surface.mouseUp(with: release)
                    }
                    t.expect(
                        surface.selectedText == "TOP\nmiddle\nbotto",
                        desc: "Shift-drag includes the top row both over its text and beyond the upper edge"
                    )
                    t.expect(window.frame == windowFrame, desc: "the selection gesture leaves the window in place")
                }
            }
        }

        // Every pane of a split window draws into a drawable cut for the
        // window's display: a pane laid out after the split that kept a
        // stale scale would draw its grid blurred or at the wrong size.
        UBUITestRegister("swift_shell_split_panes_draw_at_the_backing_scale") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let (shell, _) = openShell(t), let window = shell.window, let content = window.contentView else { return }
                defer { window.close() }
                shell.splitRight(nil)
                t.pump(0.4)
                let surfaces = terminalSurfaces(under: content)
                t.expect(surfaces.count == 2, desc: "the split makes two panes (\(surfaces.count))")
                let scale = window.backingScaleFactor
                t.expect(scale > 0, desc: "the window has a backing scale")
                for (index, surface) in surfaces.enumerated() {
                    let layer = surface.metalLayer
                    t.expect(
                        layer.contentsScale == scale,
                        desc: "pane \(index) draws at the window's scale (\(layer.contentsScale) vs \(scale))"
                    )
                    let expected = CGSize(
                        width: (surface.bounds.width * scale).rounded(),
                        height: (surface.bounds.height * scale).rounded()
                    )
                    t.expect(
                        layer.drawableSize == expected,
                        desc: "pane \(index)'s drawable is its bounds at that scale (\(layer.drawableSize) vs \(expected))"
                    )
                }
            }
        }

        // A synchronized-output block an application opens and never closes
        // cannot hold the window forever: the surface expires it on its own
        // once its budget is spent, with no further output to prompt a draw.
        UBUITestRegister("swift_shell_a_stale_synchronized_output_hold_expires_on_its_own") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let (shell, surface) = openShell(t) else { return }
                defer { shell.window?.close() }
                surface.feed(Data("UBSYNCHOLD_MARK1\r\n".utf8))
                t.pump(0.2)
                surface.feed(Data("\u{1b}[?2026hUBSYNCHOLD_MARK2\r\n".utf8))
                surface.needsDisplay = true
                t.pump(0.1)
                let heldAtFirst = surface.drive.withTerminal { $0.modes.syncOutput } ?? false
                t.expect(heldAtFirst, desc: "DECSET 2026 opens a hold that is still up moments later")
                t.expect(
                    t.wait(until: { surface.drive.withTerminal { !$0.modes.syncOutput } ?? false }, timeout: 4),
                    desc: "the hold expires on its own past its budget, with nothing sent to close it"
                )
                let text = t.gridText(of: shell)
                t.expect(
                    text.contains("UBSYNCHOLD_MARK1") && text.contains("UBSYNCHOLD_MARK2"),
                    desc: "and nothing written under it is lost"
                )
            }
        }

        // The Help menu carries the documentation, the shortcut list and the
        // issue report, found by action rather than by title or position so
        // AppKit's own Help search field cannot move them.
        UBUITestRegister("app_help_menu_carries_its_charter_items") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let help = NSApp.helpMenu else {
                    t.expect(false, desc: "the application registers a Help menu")
                    return
                }
                let actions = Set(help.items.compactMap { $0.action.map(NSStringFromSelector) })
                for action in ["openHelpDocumentation:", "showKeyboardShortcuts:", "reportAnIssue:"] {
                    t.expect(actions.contains(action), desc: "the Help menu has \(action)")
                    t.expect(
                        (NSApp.delegate as? NSObject)?.responds(to: NSSelectorFromString(action)) == true,
                        desc: "and the application answers \(action)"
                    )
                }
            }
        }
    }
}

/// Opens a Swift-shell window on a quiet program, so a fed byte is the only
/// thing that reaches the grid.
///
/// - Parameter t: The native test harness.
/// - Returns: The controller and its surface, or nil after reporting why not.
@MainActor
private func openShell(_ t: UBUITestContext) -> (TerminalWindowController, TerminalSurface)? {
    guard let shell = t.newWindowRunning(["/bin/cat"]), let surface = shell.focusedSurfaceForTesting else {
        t.expect(false, desc: "a Swift-shell window opens with a surface")
        return nil
    }
    t.pump(0.3)
    return (shell, surface)
}

/// Every terminal surface in a view hierarchy, in subview order.
@MainActor
private func terminalSurfaces(under view: NSView) -> [TerminalSurface] {
    if let surface = view as? TerminalSurface {
        return [surface]
    }
    return view.subviews.flatMap { terminalSurfaces(under: $0) }
}

/// Copies the selection the way the Edit menu does, and reads the plain text
/// the pasteboard received.
@MainActor
private func copyThroughTheMenuAction(_ surface: TerminalSurface, _ t: UBUITestContext) -> String {
    let saved = NSPasteboard.general.string(forType: .string)
    defer {
        NSPasteboard.general.clearContents()
        if let saved { NSPasteboard.general.setString(saved, forType: .string) }
    }
    NSPasteboard.general.clearContents()
    NSApp.sendAction(#selector(NSText.copy(_:)), to: surface, from: nil)
    t.pump(0.2)
    return NSPasteboard.general.string(forType: .string) ?? ""
}

/// One mouse event, as AppKit would deliver it.
@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType,
    in window: NSWindow,
    at point: CGPoint,
    modifiers: NSEvent.ModifierFlags,
    clickCount: Int = 1
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: type == .leftMouseUp ? 0 : 1
    )
}

/// Drags down a column across several rows and reports what was selected.
///
/// Vertical, so it crosses rows of text and opens a selection wherever the
/// press lands in the cell.
@MainActor
private func drag(_ surface: TerminalSurface, in window: NSWindow, modifiers: NSEvent.ModifierFlags) -> String {
    guard let start = surface.viewPoint(forRow: 2, column: 4), let end = surface.viewPoint(forRow: 6, column: 4) else {
        return ""
    }
    let from = surface.convert(start, to: nil)
    let to = surface.convert(end, to: nil)
    if let press = mouseEvent(.leftMouseDown, in: window, at: from, modifiers: modifiers) {
        surface.mouseDown(with: press)
    }
    if let moved = mouseEvent(.leftMouseDragged, in: window, at: to, modifiers: modifiers) {
        surface.mouseDragged(with: moved)
    }
    if let release = mouseEvent(.leftMouseUp, in: window, at: to, modifiers: modifiers) {
        surface.mouseUp(with: release)
    }
    return surface.selectedText ?? ""
}
