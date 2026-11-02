// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// ProfileLaunchScenarios.swift — what a window opened under a profile runs.
//
// A profile's `startup_host` opens the window on that host. The value is a
// profile's, and a profile is shareable, so it may name a host and nothing a
// launch would execute: the refusal is a trust property, and its case is a
// negative one — the hostile value must not run, and the local shell must
// open in its place.

/// Registers the profile-launch scenarios with the UI-test runner.
enum ProfileLaunchScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_profile_startup_host_opens_the_window_on_that_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A reserved name that resolves nowhere, so ssh's own answer
                // naming it is the witness that ssh ran against the profile's
                // host, without reaching any network.
                let host = "ubiquitty-startup-host.invalid"
                withProfile(named: "Startup host test", startupHost: host) {
                    guard let shell = TerminalWindowController.spawn(profileNamed: "Startup host test") else {
                        t.expect(false, desc: "the profile's window opens")
                        return
                    }
                    defer { shell.window?.close() }
                    t.expect(
                        t.wait(forText: host, in: shell, timeout: 20),
                        desc: "the window runs ssh against the profile's host (\(t.gridText(of: shell).prefix(160)))"
                    )
                }
            }
        }

        UBUITestRegister("swift_shell_profile_startup_host_refuses_a_program") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The documented "ssh host" form carrying an option that names
                // a program. A launch that forwarded the option would have ssh
                // run the program, which leaves a file behind as its witness.
                let base = NSTemporaryDirectory() + "ubq-startup-hostile-\(ProcessInfo.processInfo.processIdentifier)"
                let program = base + ".sh"
                let witness = base + ".ran"
                try? FileManager.default.removeItem(atPath: witness)
                FileManager.default.createFile(
                    atPath: program,
                    contents: Data("#!/bin/sh\ntouch '\(witness)'\n".utf8),
                    attributes: [.posixPermissions: 0o700]
                )
                defer {
                    try? FileManager.default.removeItem(atPath: program)
                    try? FileManager.default.removeItem(atPath: witness)
                }
                withProfile(named: "Hostile host test", startupHost: "ssh -oProxyCommand=\(program) prod.example") {
                    guard let shell = TerminalWindowController.spawn(profileNamed: "Hostile host test") else {
                        t.expect(false, desc: "the profile's window opens")
                        return
                    }
                    defer { shell.window?.close() }
                    t.pump(0.5)
                    t.sendText("k=CAL; echo \"LO${k}-$((6*7))\"\r", to: shell)
                    t.expect(
                        t.wait(forText: "LOCAL-42", in: shell, timeout: 10),
                        desc: "a refused startup_host opens the local shell instead"
                    )
                    t.pump(1)
                    t.expect(
                        !FileManager.default.fileExists(atPath: witness),
                        desc: "and the program the value named never ran"
                    )
                    t.expect(!t.gridText(of: shell).contains("ssh:"), desc: "and ssh was not launched with it")
                }
            }
        }
    }
}

/// Runs a body with one `[[profiles]]` table appended to the live document,
/// and configures the document it found again whatever the body does.
///
/// - Parameters:
///   - name: The profile's name.
///   - startupHost: Its `startup_host`.
///   - body: What runs while the profile exists.
@MainActor
private func withProfile(named name: String, startupHost: String, _ body: () -> Void) {
    let saved = configureAppendingToLiveDocument(
        "[[profiles]]\nname = \(tomlQuoted(name))\nstartup_host = \(tomlQuoted(startupHost))\n"
    )
    defer { restoreLiveDocument(saved) }
    body()
}
