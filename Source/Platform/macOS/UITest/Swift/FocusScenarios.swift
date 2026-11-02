// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// FocusScenarios.swift — a Kit-hosted pane's focus follows the window's key
// status, not the responder chain alone, and an activation latches the caret.
//
// The harness runs as an accessory application, so no window here is ever key:
// every pane in it is unfocused by Core's rule however it was made first
// responder. That is what these scenarios read, against a control that first
// drives the state the other way so the assertion is a decision and not a
// constant. The witnesses are applied state: what the surface last published,
// and Core's own flag read back off the model.

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

/// Core's applied focus for a surface, the model's own flag rather than the
/// shell's copy.
///
/// Asserting the shell's `isSurfaceFocused` alone would pass against a fact
/// that never reached the session, and the session is what drives the blink
/// freeze, the unfocused-bell gate and DECSET 1004.
///
/// - Parameter surface: The surface to read.
/// - Returns: Whether Core has this session focused.
@MainActor
private func coreWindowFocused(_ surface: TerminalSurface) -> Bool {
    surface.drive.lockForRead()
    defer { surface.drive.unlockForRead() }
    return surface.drive.borrowTerminal()?.windowFocused ?? false
}

/// Whether a surface's buffer holds some text, read through the find route.
///
/// - Parameters:
///   - text: The text to look for, verbatim.
///   - surface: The surface whose buffer is read.
/// - Returns: Whether the buffer holds the text.
@MainActor
private func bufferHolds(_ text: String, in surface: TerminalSurface) -> Bool {
    let holds = surface.searchScrollbackAndWait(text, isCaseSensitive: true).totalMatches > 0
    surface.drive.clearScrollbackSearch()
    return holds
}

/// Registers the focus scenarios with the UI-test runner.
enum FocusScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_focus_follows_the_key_window") { context in
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
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(surface)
                t.pump(0.4)
                t.expect(window.firstResponder === surface, desc: "the surface is its window's first responder")
                t.expect(!window.isKeyWindow, desc: "and the harness's window is not key, the app being an accessory")

                // The control: driven focused without the window's say, the
                // published state and Core's flag both read focused, so the
                // reads below are reading a decision rather than a constant.
                surface.setSurfaceFocused(true)
                t.pump(0.1)
                t.expect(surface.isSurfaceFocused, desc: "driven focused, the surface publishes focused")
                t.expect(t.wait(until: { coreWindowFocused(surface) }, timeout: 2.0), desc: "and Core's flag follows")

                // A window edge re-derives from the window's facts. Posted,
                // since the harness's windows never take or lose key on their
                // own; the observer it reaches is the one a real switch
                // reaches.
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                t.pump(0.2)
                t.expect(!surface.isSurfaceFocused, desc: "a resign-key edge re-derives the pane unfocused")
                t.expect(t.wait(until: { !coreWindowFocused(surface) }, timeout: 2.0), desc: "and Core's flag follows")

                // A responder edge re-derives too: the responder half holds and
                // the key half does not, so Core's rule unfocuses the pane a
                // responder-only rule would keep.
                surface.setSurfaceFocused(true)
                t.pump(0.1)
                t.expect(surface.isSurfaceFocused, desc: "driven focused again ahead of the responder edge")
                window.makeFirstResponder(nil)
                window.makeFirstResponder(surface)
                t.pump(0.4)
                t.expect(window.firstResponder === surface, desc: "the surface is first responder again")
                t.expect(!surface.isSurfaceFocused, desc: "and publishes unfocused, since its window is not key")
                t.expect(t.wait(until: { !coreWindowFocused(surface) }, timeout: 2.0), desc: "and Core's flag follows that too")

                // A second window taking front moves no responder in the first;
                // the first's answer stands on the window facts alone.
                guard let other = TerminalWindowController.spawn(), let otherWindow = other.window else {
                    t.expect(false, desc: "a second Swift-shell window opens")
                    return
                }
                defer { otherWindow.close() }
                otherWindow.makeKeyAndOrderFront(nil)
                t.pump(0.5)
                t.expect(window.firstResponder === surface, desc: "the first window's responder did not move")
                t.expect(!surface.isSurfaceFocused, desc: "and its pane stays unfocused")
            }
        }

        UBUITestRegister("swift_shell_focus_reports_follow_the_key_window") { context in
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
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(surface)
                t.pump(0.4)
                guard !window.isKeyWindow else {
                    t.expect(false, desc: "the harness's window is not key, the app being an accessory")
                    return
                }

                // A reader on the far end prints what the terminal sends the
                // child, which is the only way this harness can see a focus
                // report; the terminal's replies do not pass the input hook.
                surface.send("cat -v\n")
                t.pump(0.8)
                surface.feed(Data("\u{1b}[?1004h".utf8))
                t.pump(0.2)

                // A responder handoff inside the window that is not key.
                window.makeFirstResponder(nil)
                t.pump(0.2)
                window.makeFirstResponder(surface)
                t.pump(0.5)

                // The planted positive: the reader renders an escape the way it
                // would render a focus report, so the absence below is read by
                // a reader proven to show one.
                surface.send("marker-\u{1b}[Z-end\n")
                t.expect(
                    t.wait(until: { bufferHolds("marker-^[[Z-end", in: surface) }, timeout: 8.0),
                    desc: "the reader renders a planted escape"
                )
                t.expect(!bufferHolds("^[[I", in: surface), desc: "and no focus-in was reported for a handoff in a window that is not key")
                surface.send("\u{03}")
            }
        }

        UBUITestRegister("swift_shell_activation_latches_the_caret_filled") { context in
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
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)

                // What a tab close leaves behind: a window with no responder.
                window.makeFirstResponder(nil)
                t.pump(0.1)
                let notesBefore = surface.userActivityNotesForTesting
                // The delegate entry AppKit would call, called directly: the
                // harness cannot make an accessory application's window key.
                shell.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
                t.expect(window.firstResponder === surface, desc: "the activation hands the vacant responder to the focused pane")
                t.expect(surface.userActivityNotesForTesting > notesBefore, desc: "and notes the activity that holds the caret solid")

                // The control: a find field holding the responder keeps it.
                shell.performFindAction(nil)
                t.pump(0.3)
                guard window.firstResponder !== surface, window.firstResponder !== window else {
                    t.expect(false, desc: "opening Find moved the responder off the pane, which the control needs")
                    shell.findBarClose()
                    return
                }
                let holder = window.firstResponder
                shell.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
                t.expect(window.firstResponder === holder, desc: "an activation does not take the responder from the find field")
                shell.findBarClose()
                t.pump(0.2)
            }
        }
    }
}
