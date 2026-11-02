// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// RemoteClearScenarios.swift — Cmd-K in a window attached to a ubiquitty-host
// session this scenario forks with a home of its own.
//
// The host owns the session's terminal, so the window's own grid is a replica
// the next frame overwrites. Cmd-K therefore has to reach the host as a
// request, and the window shows the clear only once the host's frame says so.
// The gesture is taken from the Edit menu item AppKit would run, and delivered
// to the responder AppKit would deliver it to: the harness has no key window,
// so a nil-target dispatch would reach nobody and prove nothing.

/// Registers the hosted-session clear scenario with the UI-test runner, and
/// holds the menu dispatch the tmux clear scenario shares.
enum RemoteClearScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("remote_session_cmd_k_clears_on_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t) }
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

    @MainActor
    private static func run(_ t: UBUITestContext) {
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

        // History the clear has to take, and a marker on screen it has to take
        // with it.
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
            return
        }

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
}
