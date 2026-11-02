// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// SessionLogScenarios.swift — File ▸ Log Session to File… against a Swift-shell
// window.
//
// Core does the writing: every byte a session ingests is appended to the open
// log from inside the locked parse on the ingest thread. What a shell owns is
// the menu item, which pane the log follows, and opening and closing the file
// under that same lock — an fclose taken beside a write in flight is a write
// into a closed stream, and the log the reader keeps is the evidence they were
// collecting.
//
// Read back off disk rather than from the controller: a path remembered and a
// file written are different claims, and only the second is the feature.

/// Registers the session-log scenarios with the UI-test runner.
enum SessionLogScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_logs_the_session_to_the_file_it_was_given") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                guard let surface = shell.focusedSurfaceForTesting else {
                    t.expect(false, desc: "the window has a pane")
                    return
                }

                let path =
                    NSTemporaryDirectory()
                    + "ubiquitty-session-log-\(ProcessInfo.processInfo.processIdentifier)-\(window.windowNumber).log"
                try? FileManager.default.removeItem(atPath: path)
                defer { try? FileManager.default.removeItem(atPath: path) }

                let item = NSMenuItem(
                    title: "",
                    action: #selector(TerminalWindowController.toggleSessionLog(_:)),
                    keyEquivalent: ""
                )
                t.expect(shell.validateMenuItem(item), desc: "the item is offered on a window with a session")
                t.expect(
                    item.title == "Log Session to File…" && item.state == .off,
                    desc: "a window keeping no log offers to start one (\(item.title))"
                )

                t.expect(shell.startSessionLog(atPath: path), desc: "the log opens on the file it was given")
                _ = shell.validateMenuItem(item)
                t.expect(
                    item.title == "Stop Logging Session" && item.state == .on,
                    desc: "and the item then offers to stop it (\(item.title))"
                )

                // Both ingest routes: bytes fed into the model, and bytes a
                // process produced on the pseudo-terminal.
                surface.feed(Data("fed-marker-1\r\n".utf8))
                surface.transmitAsUserInputForTesting("k=42; echo \"logged-${k}\"\r")
                t.expect(
                    t.wait(until: { surface.searchScrollbackAndWait("logged-42").totalMatches > 0 }, timeout: 8),
                    desc: "the shell answered on the pseudo-terminal"
                )

                shell.toggleSessionLog(nil)
                t.expect(shell.sessionLogPath == nil, desc: "choosing the item again stops the log")
                _ = shell.validateMenuItem(item)
                t.expect(item.title == "Log Session to File…", desc: "and the item offers to start one again")

                // The close is also the flush: the file holds everything the
                // session took while the log was open.
                let logged = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                t.expect(logged.contains("fed-marker-1"), desc: "the log holds the bytes fed into the model")
                t.expect(logged.contains("logged-42"), desc: "and the bytes the process wrote")

                surface.feed(Data("after-the-close\r\n".utf8))
                t.pump(0.3)
                let afterwards = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                t.expect(
                    !afterwards.contains("after-the-close"),
                    desc: "a stopped log records nothing further"
                )
            }
        }
    }
}
