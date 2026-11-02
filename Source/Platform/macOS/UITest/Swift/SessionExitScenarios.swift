// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Darwin
import UbiquittyCore
import UbiquittyKit

// SessionExitScenarios.swift — what a shell's exit does to a Kit-hosted window.
//
// Two windows drive the same shell with the same keystrokes and end
// differently, which is why they are one file: a session launched to run one
// program ends with it, and every other session outlives its child with its
// scrollback in place. Which is which is Core's, recorded on the session from
// its launch, and read here through the window it decides for.

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

/// Whether a surface's buffer, history and grid together, holds some text.
///
/// Read through the find route rather than the harness's grid reader, which
/// sees only the focused pane's visible screen and not its history. The
/// search is cleared afterwards so the pane keeps no highlight from the
/// question.
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

/// Registers the session-exit scenarios with the UI-test runner.
enum SessionExitScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("undo_close_recovers_the_original_local_process") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                defer { t.closeAllWindows() }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "the recoverable local shell opens")
                    return
                }
                let marker = UUID().uuidString
                let processFile = "/tmp/ubq-recovery-" + marker
                defer { try? FileManager.default.removeItem(atPath: processFile) }
                surface.send("UBQ_RECOVERY_MARK=\(marker); echo $$ > \(processFile); echo ready-$UBQ_RECOVERY_MARK\n")
                t.expect(
                    t.wait(until: { bufferHolds("ready-\(marker)", in: surface) }, timeout: 10),
                    desc: "the original process holds a private variable"
                )
                guard let processText = try? String(contentsOfFile: processFile, encoding: .utf8),
                    let processID = Int32(processText.trimmingCharacters(in: .whitespacesAndNewlines)), processID > 0
                else {
                    t.expect(false, desc: "the owned shell reports its process identity")
                    return
                }
                t.pump(0.5)
                window.performClose(nil)
                t.expect(t.wait(until: { !window.isVisible }, timeout: 5), desc: "closing hides the retained window")
                t.expect(
                    !TerminalWindowController.spawnedControllers.contains(where: { $0 === shell }),
                    desc: "the closed window is absent from the active roster"
                )
                guard
                    let item = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.items
                        .first(where: { $0.identifier?.rawValue == "reopenClosedWindow" }),
                    let action = item.action
                else {
                    t.expect(false, desc: "the File menu offers recovery")
                    return
                }
                NSApp.sendAction(action, to: item.target, from: item)
                t.expect(t.wait(until: { window.isVisible }, timeout: 5), desc: "recovery reopens the same window")
                t.expect(shell.focusedSurfaceForTesting === surface, desc: "recovery keeps the same terminal model")
                surface.send("echo retained-$UBQ_RECOVERY_MARK\n")
                t.expect(
                    t.wait(until: { bufferHolds("retained-\(marker)", in: surface) }, timeout: 10),
                    desc: "the original shell variable survives closing"
                )
                t.pump(1)
                window.performClose(nil)
                t.expect(
                    t.wait(until: { shell.isClosedForTesting }, timeout: 35),
                    desc: "the grace period tears down the retained window"
                )
                t.expect(
                    t.wait(until: { kill(processID, 0) == -1 && errno == ESRCH }, timeout: 5),
                    desc: "expiration terminates the owned shell"
                )
                t.expect(!window.isVisible, desc: "expiration does not open a fresh shell")
            }
        }
        UBUITestRegister("profile_exit_choices_close_only_the_requested_local_shells") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    t.closeAllWindows()
                }
                // The test profile is the only one: the reader's own profiles
                // are left out of each document.
                let withoutProfiles = documentDroppingTables(saved) { $0 == "[[profiles]]" }
                for (token, status, closes) in [
                    ("keep_output", 0, false), ("close_on_success", 0, true), ("close_on_success", 7, false), ("close_always", 7, true),
                ] {
                    t.closeAllWindows()
                    t.restoreConfiguration(
                        withoutProfiles + "\n[[profiles]]\nname = \"Exit test\"\nprocess_exit = \(tomlQuoted(token))\n"
                    )
                    guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                        let surface = shell.focusedSurfaceForTesting
                    else {
                        t.expect(false, desc: "the profile test shell opens")
                        return
                    }
                    shell.applyProfile(named: "Exit test")
                    surface.send("exit \(status)\n")
                    t.expect(t.wait(until: { surface.drive.sessionEnd.didEnd }, timeout: 10), desc: "the shell exits")
                    if closes {
                        t.expect(t.wait(until: { !window.isVisible }, timeout: 10), desc: "\(token) closes exit \(status)")
                    } else {
                        t.pump(1)
                        t.expect(window.isVisible, desc: "\(token) preserves exit \(status)")
                    }
                }
            }
        }
        UBUITestRegister("profile_restart_keeps_the_pane_and_stops_a_crash_loop") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = t.configureAppending("[[profiles]]\nname = \"Restart test\"\nprocess_exit = \"restart\"\n")
                defer {
                    t.restoreConfiguration(saved)
                    t.closeAllWindows()
                }
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh", "-c", "sleep 1; echo restart-witness; exit 7"],
                        localePolicy: .auto,
                        sessionLifetime: .outlivesChild
                    ),
                    let window = shell.window, let initial = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "the restart test opens")
                    return
                }
                shell.applyProfile(named: "Restart test")
                t.expect(
                    t.wait(until: { shell.focusedSurfaceForTesting !== initial }, timeout: 10),
                    desc: "a fresh process replaces the ended one"
                )
                t.expect(t.wait(until: { window.attachedSheet != nil }, timeout: 15), desc: "the crash loop stops with an explanation")
                let final = shell.focusedSurfaceForTesting
                t.pump(2)
                t.expect(
                    window.isVisible && shell.focusedSurfaceForTesting === final,
                    desc: "the final output remains without another restart"
                )
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
        }
        UBUITestRegister("swift_shell_ordinary_shell_exit_keeps_the_window_and_its_scrollback") { context in
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
                t.pump(0.3)
                t.expect(!surface.drive.doesSessionEndWithChild, desc: "a login shell's session outlives its child")

                // More lines than any grid the harness opens has rows, so the
                // count that must survive is well above the grid's height
                // whatever window frame the shell restored.
                surface.send("for i in $(seq 1 400); do echo keepalive-line-$i; done\n")
                t.expect(
                    t.wait(until: { surface.drive.readSnapshot().scrollbackCount > 200 }, timeout: 10),
                    desc: "the shell wrote history to keep (\(surface.drive.readSnapshot().scrollbackCount) rows)"
                )
                let historyBefore = surface.drive.readSnapshot().scrollbackCount

                surface.send("exit\n")
                t.pump(2.0)
                t.expect(window.isVisible, desc: "the window stays after an ordinary exit")
                t.expect(
                    TerminalWindowController.spawnedControllers.contains { $0 === shell },
                    desc: "and stays in the spawn roster"
                )
                // The exit itself scrolls the shell's last lines into history,
                // so the count can only grow; what is asserted is that nothing
                // was discarded.
                t.expect(
                    surface.drive.readSnapshot().scrollbackCount >= historyBefore,
                    desc: "with its history kept (\(historyBefore) → \(surface.drive.readSnapshot().scrollbackCount))"
                )
                t.expect(
                    t.wait(until: { bufferHolds("keepalive-line-400", in: surface) }, timeout: 1.0),
                    desc: "and the shell's last output still readable"
                )

                // The positive witness that the child is gone, and the answer to
                // whether input still means anything: the keys are accepted and
                // reach no reader.
                surface.send("echo after-exit-must-not-appear\n")
                t.expect(
                    !t.wait(until: { bufferHolds("after-exit-must-not-appear", in: surface) }, timeout: 2.0),
                    desc: "nothing typed after the exit reaches the buffer"
                )
            }
        }

        UBUITestRegister("swift_shell_launch_command_exit_closes_its_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let shell = TerminalWindowController.spawn(
                        arguments: ["/bin/sh"],
                        localePolicy: .auto,
                        sessionLifetime: .endsWithChild
                    ),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens for a launch command")
                    return
                }
                t.pump(0.3)
                t.expect(surface.drive.doesSessionEndWithChild, desc: "a launch command's session ends with its child")
                surface.send("echo live-$((6*7))\n")
                t.expect(t.wait(until: { bufferHolds("live-42", in: surface) }, timeout: 8), desc: "the launched shell is live")

                surface.send("exit\n")
                t.expect(
                    t.wait(until: { !window.isVisible }, timeout: 5.0),
                    desc: "the window closed with its program"
                )
                t.expect(
                    !TerminalWindowController.spawnedControllers.contains { $0 === shell },
                    desc: "and left the spawn roster"
                )
            }
        }
    }
}
