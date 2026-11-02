// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// WindowPlacementScenarios.swift — a Kit-hosted window opens where the last one
// was, and a second one steps off the first.
//
// The arithmetic is pinned in Tests/Core/test_windowplacement.cpp against the
// one policy both shells read. What a Core test cannot reach is whether this
// shell asks: it did not, and called window.center() instead, so every window
// opened in the middle of the main display however the user had arranged the
// last one.
//
// The runner restores the persisted frame after each scenario, after all of
// its windows have closed.

/// The defaults key both shells persist through — see WindowFrameMemory.
private let windowFrameDefaultsKey = "UbiquittyWindowFrame"

/// Registers the window-placement scenarios with the UI-test runner.
enum WindowPlacementScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_window_opens_where_the_last_one_was") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let defaults = UserDefaults.standard

                // A frame the user could plausibly have left, inside whatever
                // display this machine has.
                guard let screen = NSScreen.main else {
                    t.expect(false, desc: "the machine has a screen")
                    return
                }
                let visible = screen.visibleFrame
                let remembered = NSRect(
                    x: visible.origin.x + 120,
                    y: visible.origin.y + 90,
                    width: 700,
                    height: 420
                )
                defaults.set(NSStringFromRect(remembered), forKey: windowFrameDefaultsKey)

                guard let first = TerminalWindowController.spawn(), let firstWindow = first.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { firstWindow.close() }
                t.pump(0.3)

                // Size is what was remembered. Origin is compared loosely
                // because the window may have been re-homed onto the screen
                // under the pointer, which is a different assertion and has its
                // own scenario below.
                t.expect(
                    abs(firstWindow.frame.width - remembered.width) < 2
                        && abs(firstWindow.frame.height - remembered.height) < 2,
                    desc: "the window restored the remembered size (got \(firstWindow.frame.size), wanted \(remembered.size))"
                )
                t.expect(
                    firstWindow.frame.origin != NSPoint(x: visible.midX - 400, y: visible.midY - 250),
                    desc: "and did not simply centre itself"
                )

                // A second window steps off the first rather than landing on it.
                guard let second = TerminalWindowController.spawn(), let secondWindow = second.window else {
                    t.expect(false, desc: "a second Swift-shell window opens")
                    return
                }
                defer { secondWindow.close() }
                t.pump(0.3)
                t.expect(
                    secondWindow.frame.origin != firstWindow.frame.origin,
                    desc:
                        "the second window cascaded off the first (first \(firstWindow.frame.origin), second \(secondWindow.frame.origin))"
                )
            }
        }

        // A drag is a place the user chose, and it is remembered when they let
        // go rather than only when the window closes: saved on close alone, a
        // window moved and left open tells the next window nothing.
        UBUITestRegister("swift_shell_window_remembers_a_move_and_a_resize") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: windowFrameDefaultsKey)

                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let screen = window.screen ?? NSScreen.main
                else {
                    t.expect(false, desc: "a Swift-shell window opens on a screen")
                    return
                }
                defer { window.close() }
                t.pump(0.3)

                let visible = screen.visibleFrame
                let moved = NSRect(x: visible.origin.x + 140, y: visible.origin.y + 160, width: 640, height: 380)
                window.setFrame(moved, display: true)
                // The delegate callback AppKit sends after a drag; the harness
                // moves windows programmatically, which sends it too.
                shell.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
                t.pump(0.2)

                guard let savedAfterMove = defaults.string(forKey: windowFrameDefaultsKey) else {
                    t.expect(false, desc: "the move was remembered")
                    return
                }
                let rememberedMove = NSRectFromString(savedAfterMove)
                t.expect(
                    abs(rememberedMove.origin.x - window.frame.origin.x) < 2
                        && abs(rememberedMove.origin.y - window.frame.origin.y) < 2,
                    desc: "the remembered origin is where the window was left (\(rememberedMove.origin) vs \(window.frame.origin))"
                )

                // And the size the user let go of, on the settle rather than
                // per step of the drag.
                var resized = window.frame
                resized.size.height -= 60
                window.setFrame(resized, display: true)
                shell.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                t.pump(0.2)
                guard let savedAfterResize = defaults.string(forKey: windowFrameDefaultsKey) else {
                    t.expect(false, desc: "the resize was remembered")
                    return
                }
                t.expect(
                    abs(NSRectFromString(savedAfterResize).height - window.frame.height) < 2,
                    desc: "the remembered height is the one the resize settled at"
                )
            }
        }

        // A window running one program belongs to that program. Remembering
        // where it sat makes a run of them hysteretic, each inheriting the frame
        // the last finished at.
        UBUITestRegister("swift_shell_a_launch_command_window_is_not_remembered") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: windowFrameDefaultsKey)

                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ), let window = shell.window
                else {
                    t.expect(false, desc: "a window opens for a launch command")
                    return
                }
                defer { window.close() }
                t.pump(0.4)

                shell.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
                t.pump(0.2)
                t.expect(
                    defaults.string(forKey: windowFrameDefaultsKey) == nil,
                    desc: "moving a launch-command window remembers nothing"
                )

                // The control: an ordinary window beside it is still remembered,
                // so the refusal is the session's lifetime and not a dead path.
                guard let ordinary = TerminalWindowController.spawn(), let ordinaryWindow = ordinary.window else {
                    t.expect(false, desc: "an ordinary window opens beside it")
                    return
                }
                defer { ordinaryWindow.close() }
                t.pump(0.3)
                ordinary.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: ordinaryWindow))
                t.pump(0.2)
                t.expect(
                    defaults.string(forKey: windowFrameDefaultsKey) != nil,
                    desc: "while an ordinary window beside it is remembered"
                )
            }
        }

        UBUITestRegister("swift_shell_window_does_not_persist_a_fullscreen_frame") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let defaults = UserDefaults.standard

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                t.pump(0.3)

                // A frame worth remembering is remembered on close.
                let known = NSStringFromRect(NSRect(x: 11, y: 22, width: 33, height: 44))
                defaults.set(known, forKey: windowFrameDefaultsKey)
                window.setFrame(NSRect(x: 60, y: 70, width: 640, height: 400), display: false)
                t.pump(0.1)
                window.close()
                t.pump(0.2)
                t.expect(
                    defaults.string(forKey: windowFrameDefaultsKey) != known,
                    desc: "closing a normal window remembers its frame"
                )

                // A zero-size frame is not. The Metal arm's comment claimed
                // this check for a long time without doing it, and a window
                // torn down mid-close can report exactly that.
                let sentinel = NSStringFromRect(NSRect(x: 99, y: 98, width: 97, height: 96))
                defaults.set(sentinel, forKey: windowFrameDefaultsKey)
                guard let second = TerminalWindowController.spawn(), let emptied = second.window else {
                    t.expect(false, desc: "a second Swift-shell window opens")
                    return
                }
                t.pump(0.2)
                emptied.setFrame(NSRect(x: 0, y: 0, width: 0, height: 0), display: false)
                t.pump(0.1)
                emptied.close()
                t.pump(0.2)
                t.expect(
                    defaults.string(forKey: windowFrameDefaultsKey) == sentinel,
                    desc:
                        "an empty frame is not remembered (key now \(defaults.string(forKey: windowFrameDefaultsKey) ?? "nil"))"
                )
            }
        }
    }
}
