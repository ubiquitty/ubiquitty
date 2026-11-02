// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A failed connect can be dialled again, says why it failed, and never puts
/// a login shell where a picked session should be.
///
/// Driven against port 1 on the loopback, which refuses at once: no host and
/// no daemon are needed for any of the three facts, and each is read from the
/// model the screen draws rather than from the screen.
///
/// - A second connect on a failed model dials again. Keeping the dead
///   connection and answering every later connect with it would leave a host
///   that failed once unreachable until the app was killed.
/// - The failure is Core's sentence naming the host and the port, built from
///   the connect's typed error rather than the carrier's own spelling of it.
/// - A picked session whose QUIC probe could not reach the host opens no SSH
///   carrier. A login shell there would read as the session picked.
enum RedialSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }

        var record = HostRecord(
            id: UUID(),
            name: "smoke",
            hostName: "127.0.0.1",
            port: 1,
            username: "nobody"
        )
        let refused = "127.0.0.1 refused the connection on port 1."

        let shell = TerminalSessionModel()
        shell.connect(to: record, secret: "unused", attach: .newSession)
        check(settle { shell.hasFailed }, "the first connect never failed (status: \(shell.statusDetail))")
        check(shell.statusDetail == refused, "the failure did not name the refusal: \(shell.statusDetail)")

        shell.connect(to: record, secret: "unused", attach: .newSession)
        check(shell.isLive, "a second connect on a failed model did not dial again")
        check(settle { shell.hasFailed }, "the second connect never settled (status: \(shell.statusDetail))")
        check(shell.statusDetail == refused, "the second failure did not name the refusal: \(shell.statusDetail)")
        shell.disconnect()

        record.prefersQUIC = true
        let pick = TerminalSessionModel()
        pick.connect(to: record, secret: "unused", attach: .session(7, daemonSocketName: "listed.sock", daemonInstanceID: 17))
        check(settle { pick.unreachedPick != nil }, "an unreachable pick was never reported (status: \(pick.statusDetail))")
        check(!pick.hasLoginShellCarrier, "a login shell was opened in place of the picked session")
        check(
            pick.unreachedPick?.reason == refused,
            "the unreached pick did not say why: \(pick.unreachedPick?.reason ?? "nothing")"
        )
        pick.disconnect()

        for failure in failures {
            SmokeLaunch.report("redial: \(failure)")
        }
        return failures.isEmpty
    }

    /// Runs the main loop until a condition holds or five seconds pass.
    @MainActor
    private static func settle(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
