// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// ClearCommandScenarios.swift — the Edit menu's clear items are bound to the
// right commands, and invoking them against a Kit-hosted window reaches the
// model.
//
// This file and Core's test split the same two commands along what each
// layer can pin. What each command destroys, what it sends the process, and
// whether it asks the viewport back to the tail are Core's, pinned
// in Tests/Core/test_clearcommands.cpp against the one dispatch both arms call.
// What cannot be pinned there is the other half: which gesture reaches which
// command, and whether a Kit-hosted window answers the selector at all. A
// window that answers none of them leaves every one of these items dead while
// the menu still shows them enabled.

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

/// The Edit menu item carrying a key equivalent, wherever it sits.
///
/// - Parameters:
///   - key: The key equivalent, lowercased as AppKit stores it.
///   - modifiers: The modifier mask the item must carry exactly.
/// - Returns: The item, or nil when no Edit-menu item claims that gesture.
@MainActor
private func editMenuItem(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
    guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else {
        return nil
    }
    return edit.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
}

/// What the session has on screen, for a refusal that ran out of patience.
///
/// A line count alone says a deadline passed. It cannot say whether the shell
/// started, whether it echoed the command and did nothing, or whether it wrote
/// an error instead of output — and those are three different faults with one
/// symptom. The grid is the only record the scenario holds of which it was, so
/// the refusal carries it rather than leaving the next reader to guess from a
/// zero. Blank rows are dropped and the rest joined, because a refusal is one
/// line in a log.
///
/// - Parameter surface: The surface the scenario is driving.
/// - Returns: The visible rows, or a phrase saying there are none.
@MainActor
private func screenReport(_ surface: TerminalSurface) -> String {
    let rows = surface.gridTextForTesting()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return rows.isEmpty ? "nothing on screen" : "on screen: " + rows.joined(separator: " / ")
}

/// Runs a shell until it has produced scrollback, or gives up.
///
/// - Parameters:
///   - surface: The surface to drive.
///   - t: The scenario's context, for pumping the run loop.
/// - Returns: The scrollback line count reached.
@MainActor
private func growScrollback(_ surface: TerminalSurface, _ t: UBUITestContext) -> Int {
    surface.send("for i in $(seq 1 200); do echo clear-line-$i; done\n")
    var scrollback = 0
    for _ in 0..<40 {
        t.pump(0.1)
        scrollback = Int(surface.drive.readSnapshot().scrollbackCount)
        if scrollback > 60 { break }
    }
    return scrollback
}

/// Registers the clear-command scenarios with the UI-test runner.
enum ClearCommandScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("edit_menu_binds_the_clear_gestures") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // Cmd-K takes everything. It was bound to Clear Screen, which
                // scrolls and destroys nothing, so the gesture stopped clearing
                // and stopped asking the shell to repaint.
                // Compared by name rather than #selector: the menu targets the
                // responder chain, so the selector belongs to no one class here
                // — both shells answer it, which is the point of the item.
                let takesEverything = editMenuItem(key: "k", modifiers: [.command])
                t.expect(
                    takesEverything?.action == NSSelectorFromString("clearBuffer:"),
                    desc: "Cmd-K clears the buffer (bound to \(takesEverything?.action.map(NSStringFromSelector) ?? "nothing"))"
                )

                // Opt-Cmd-K takes only what the screen is not showing.
                let takesHistory = editMenuItem(key: "k", modifiers: [.command, .option])
                t.expect(
                    takesHistory?.action == NSSelectorFromString("clearScrollback:"),
                    desc: "Opt-Cmd-K clears the scrollback (bound to \(takesHistory?.action.map(NSStringFromSelector) ?? "nothing"))"
                )

                // Clear Screen destroys nothing, so it is reached only by
                // choosing it from the menu, never by reflex: it must not
                // hold a shortcut of its own.
                guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else {
                    t.expect(false, desc: "the app has an Edit menu")
                    return
                }
                let screenItem = edit.items.first { $0.action == NSSelectorFromString("clearScreen:") }
                t.expect(screenItem != nil, desc: "Clear Screen is on the Edit menu")
                t.expect(
                    screenItem?.keyEquivalent.isEmpty ?? false,
                    desc: "Clear Screen carries no shortcut (has \"\(screenItem?.keyEquivalent ?? "")\")"
                )
            }
        }

        UBUITestRegister("swift_shell_clear_commands_reach_the_model") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let content = shell.window?.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                t.pump(0.3)

                // Clear Buffer takes the history with the screen.
                var scrollback = growScrollback(surface, t)
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback (got \(scrollback); \(screenReport(surface)))")
                    return
                }
                shell.clearBuffer(nil)
                t.pump(0.1)
                t.expect(
                    surface.drive.readSnapshot().scrollbackCount == 0,
                    desc:
                        "Clear Buffer empties the history (was \(scrollback), now \(surface.drive.readSnapshot().scrollbackCount))"
                )

                // Clear Scrollback takes the history alone.
                scrollback = growScrollback(surface, t)
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback again (got \(scrollback); \(screenReport(surface)))")
                    return
                }
                shell.clearScrollback(nil)
                t.pump(0.1)
                t.expect(
                    surface.drive.readSnapshot().scrollbackCount == 0,
                    desc:
                        "Clear Scrollback empties the history (was \(scrollback), now \(surface.drive.readSnapshot().scrollbackCount))"
                )

                // Clear Screen destroys nothing, so the history it lifts the
                // screen into can only grow. This is what separates it from the
                // two above through the published snapshot alone.
                scrollback = growScrollback(surface, t)
                guard scrollback > 60 else {
                    t.expect(false, desc: "the shell produced scrollback a third time (got \(scrollback); \(screenReport(surface)))")
                    return
                }
                shell.clearScreen(nil)
                t.pump(0.1)
                let afterScreenClear = Int(surface.drive.readSnapshot().scrollbackCount)
                t.expect(
                    afterScreenClear >= scrollback,
                    desc: "Clear Screen keeps the history (was \(scrollback), now \(afterScreenClear))"
                )

                // The fourth command answers too; with no executed prompt above
                // it Core clears the buffer, which is history gone either way.
                shell.clearToPreviousMark(nil)
                t.pump(0.1)
                t.expect(
                    surface.drive.readSnapshot().scrollbackCount <= afterScreenClear,
                    desc:
                        "Clear to Previous Mark reaches the model (was \(afterScreenClear), now \(surface.drive.readSnapshot().scrollbackCount))"
                )
            }
        }
    }
}
