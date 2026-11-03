// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// RemoteClearScenarios.swift — the clear commands in a window attached to a
// ubiquitty-host session each scenario forks with a home of its own.
//
// The host owns the session's terminal, so the window's own grid is a replica
// the next frame overwrites. A clear therefore has to reach the host as a
// request, and the window shows the clear only once the host's frame says so.
// Cmd-K is taken from the Edit menu item AppKit would run, and delivered to
// the responder AppKit would deliver it to: the harness has no key window, so
// a nil-target dispatch would reach nobody and prove nothing. The public
// `clear(_:)` an embedding host calls is driven the way such a host drives it,
// and the surface's context menu is opened over the hosted pane.

/// Registers the hosted-session clear scenarios with the UI-test runner, and
/// holds the menu dispatch the tmux clear scenario shares.
enum RemoteClearScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("remote_session_cmd_k_clears_on_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHostedSurface(t) { surface, window in
                    clearByMenu(t, surface, window)
                }
            }
        }
        UBUITestRegister("remote_session_public_clear_runs_on_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHostedSurface(t) { surface, _ in
                    clearByPublicCall(t, surface)
                }
            }
        }
        UBUITestRegister("remote_session_context_menu_leaves_the_terminal_to_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                withHostedSurface(t) { surface, _ in
                    contextMenuOnHostedPane(t, surface)
                }
            }
        }
    }

    /// The Edit menu item carrying a key equivalent.
    ///
    /// - Parameters:
    ///   - key: The key equivalent, lowercased as AppKit stores it.
    ///   - modifiers: The modifier mask the item must carry exactly.
    /// - Returns: The item, or nil when no Edit-menu item claims that gesture.
    @MainActor
    static func editMenuItem(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else {
            return nil
        }
        return edit.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    /// The responder AppKit would hand a menu item's action to, were the
    /// window key: the first one up the chain from `start` that answers it.
    ///
    /// - Parameters:
    ///   - action: The item's action.
    ///   - start: The window's first responder.
    /// - Returns: The answering responder, or nil when none on the chain does.
    @MainActor
    static func answerer(of action: Selector, from start: NSResponder?) -> NSResponder? {
        var walker = start
        while let responder = walker {
            if responder.responds(to: action) {
                return responder
            }
            walker = responder.nextResponder
        }
        return nil
    }

    /// Forks a host with a home of its own, attaches a window to a session on
    /// it, and runs `body` against that window's surface and window.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - body: The scenario, run while the window is connected.
    @MainActor
    private static func withHostedSurface(_ t: UBUITestContext, _ body: (TerminalSurface, NSWindow) -> Void) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        // Under /tmp: a Unix socket path is capped at 103 bytes, and the
        // daemon's socket lives in this home.
        let root = "/tmp/ubq-clear-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let attachCommand = "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach"
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            if let previousHome {
                setenv("UBIQUITTY_HOME", previousHome, 1)
            } else {
                unsetenv("UBIQUITTY_HOME")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home, "ZDOTDIR": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            // The windows first: a client still attached when its daemon goes
            // would redial.
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        guard
            t.wait(
                until: {
                    let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                    return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the daemon opened its socket")
            return
        }

        guard
            let controller = TerminalWindowController.spawnRemoteWindow(
                shellCommand: attachCommand,
                hostLabel: "clear host",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0
            ),
            let surface = controller.remoteSurface,
            let window = controller.window
        else {
            t.expect(false, desc: "a window attached to the host session opened")
            return
        }
        guard t.wait(until: { surface.drive.remoteState == .Connected }, timeout: 20) else {
            t.expect(false, desc: "the window connected to the host session")
            return
        }
        body(surface, window)
    }

    /// Runs output into the hosted session until it has history and a marker
    /// on screen.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - surface: The hosted window's surface.
    /// - Returns: Whether the history and the marker arrived.
    @MainActor
    private static func fillHistory(_ t: UBUITestContext, _ surface: TerminalSurface) -> Bool {
        surface.send("seq 1 300; echo CLEAR_\"\"MARKER\n")
        let isFilled = t.wait(
            until: {
                surface.gridTextForTesting().contains("CLEAR_MARKER") && surface.drive.readSnapshot().scrollbackCount > 200
            },
            timeout: 60
        )
        guard isFilled else {
            let screen = surface.gridTextForTesting()
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            t.expect(
                false,
                desc: "the host session produced scrollback (got \(surface.drive.readSnapshot().scrollbackCount); on screen: \(screen))"
            )
            return false
        }
        return true
    }

    /// Cmd-K, as the Edit menu would deliver it, empties the hosted session.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - surface: The hosted window's surface.
    ///   - window: The hosted window.
    @MainActor
    private static func clearByMenu(_ t: UBUITestContext, _ surface: TerminalSurface, _ window: NSWindow) {
        // History the clear has to take, and a marker on screen it has to take
        // with it.
        guard fillHistory(t, surface) else { return }

        // Cmd-K, as the menu would deliver it.
        guard let item = editMenuItem(key: "k", modifiers: [.command]), let action = item.action else {
            t.expect(false, desc: "the Edit menu holds a Cmd-K item")
            return
        }
        window.makeFirstResponder(surface)
        guard let target = answerer(of: action, from: window.firstResponder) else {
            t.expect(false, desc: "a responder in the hosted window answers \(NSStringFromSelector(action))")
            return
        }
        if let validating = target as? NSMenuItemValidation {
            t.expect(validating.validateMenuItem(item), desc: "Cmd-K is enabled in a hosted window")
        }
        let wasScrollback = surface.drive.readSnapshot().scrollbackCount
        NSApp.sendAction(action, to: target, from: item)

        t.expect(
            t.wait(until: { surface.drive.readSnapshot().scrollbackCount == 0 }, timeout: 10),
            desc:
                "Cmd-K empties the hosted session's history (was \(wasScrollback), now \(surface.drive.readSnapshot().scrollbackCount))"
        )
        t.expect(
            t.wait(until: { !surface.gridTextForTesting().contains("CLEAR_MARKER") }, timeout: 10),
            desc: "Cmd-K clears the hosted session's screen"
        )
        // The session is still the window's: the shell answers after the clear.
        surface.send("echo AFTER_\"\"CLEAR\n")
        t.expect(
            t.wait(until: { surface.gridTextForTesting().contains("AFTER_CLEAR") }, timeout: 10),
            desc: "the cleared host session still answers input"
        )
    }

    /// The three public clear commands run on the host, each a request whose
    /// selection goes when it is sent and whose result arrives in the host's
    /// frames.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - surface: The hosted window's surface.
    @MainActor
    private static func clearByPublicCall(_ t: UBUITestContext, _ surface: TerminalSurface) {
        guard fillHistory(t, surface) else { return }
        let history = { Int(surface.drive.readSnapshot().scrollbackCount) }

        // Clear Scrollback: the history goes and the marker on screen stands.
        surface.selectAll(nil)
        t.expect(surface.hasSelection, desc: "Select All selects in the hosted window")
        surface.clear(.scrollback)
        t.expect(!surface.hasSelection, desc: "Clear Scrollback drops the selection when it is sent")
        t.expect(
            t.wait(until: { history() == 0 }, timeout: 10),
            desc: "Clear Scrollback empties the hosted session's history (now \(history()))"
        )
        t.expect(surface.gridTextForTesting().contains("CLEAR_MARKER"), desc: "Clear Scrollback leaves the hosted session's screen")

        // Clear Screen: the prompt rises to the top row, and the rows above
        // it, the marker among them, move into the history.
        surface.clear(.screen)
        t.expect(
            t.wait(until: { history() > 0 && !surface.gridTextForTesting().contains("CLEAR_MARKER") }, timeout: 10),
            desc: "Clear Screen lifts the hosted session's screen into its history (history \(history()))"
        )

        // Clear Buffer: the screen and the history both go.
        surface.clear(.buffer)
        t.expect(
            t.wait(until: { history() == 0 }, timeout: 10),
            desc: "Clear Buffer empties the hosted session's history (now \(history()))"
        )
        surface.send("echo AFTER_\"\"CLEAR\n")
        t.expect(
            t.wait(until: { surface.gridTextForTesting().contains("AFTER_CLEAR") }, timeout: 10),
            desc: "the cleared host session still answers input"
        )
    }

    /// The surface's context menu over a hosted pane: Clear Scrollback runs on
    /// the host, and Reset Terminal, whose terminal is the host's, is disabled
    /// and leaves the pane's copy as the host set it.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - surface: The hosted window's surface.
    @MainActor
    private static func contextMenuOnHostedPane(_ t: UBUITestContext, _ surface: TerminalSurface) {
        guard fillHistory(t, surface) else { return }
        let history = { Int(surface.drive.readSnapshot().scrollbackCount) }
        guard let event = rightClick(on: surface, row: 0, column: 2),
            let menu = surface.menu(for: event),
            let clear = menu.items.first(where: { $0.title == "Clear Scrollback" }),
            let clearAction = clear.action,
            let reset = menu.items.first(where: { $0.title == "Reset Terminal" })
        else {
            t.expect(false, desc: "a right-click on the hosted pane offers Clear Scrollback and Reset Terminal")
            return
        }
        t.expect(surface.validateMenuItem(clear), desc: "Clear Scrollback is enabled on the hosted pane")
        t.expect(!surface.validateMenuItem(reset), desc: "Reset Terminal is disabled on the hosted pane")
        _ = NSApp.sendAction(clearAction, to: clear.target, from: clear)
        t.expect(
            t.wait(until: { history() == 0 }, timeout: 10),
            desc: "the context menu's Clear Scrollback empties the hosted session's history (now \(history()))"
        )

        // Mouse reporting, which the host's program turns on and a reset of
        // the pane's copy alone would turn off there.
        surface.send("printf '\\033[?1000h'\n")
        t.expect(
            t.wait(until: { surface.drive.readSnapshot().mouseReportsActive }, timeout: 10),
            desc: "the host's program turns mouse reporting on"
        )
        surface.softResetTerminal()
        t.pump(0.5)
        t.expect(
            surface.drive.readSnapshot().mouseReportsActive,
            desc: "a reset leaves the hosted pane's copy of the terminal as the host set it"
        )
    }
}
