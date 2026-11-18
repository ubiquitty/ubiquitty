// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A second session pick re-homes the model instead of being swallowed.
///
/// A host holds one model, so picking another of its sessions arrives at
/// `connect` as a repeat visit. Returning at the `hasBegunConnecting` guard
/// with no report would leave the screen on the session picked first: a
/// person choosing row 9 would be handed row 7 and told nothing.
///
/// The summary is read rather than the connection: `connect` sets it before it
/// asks for credentials, so this says what the model decided without needing a
/// host to answer.
enum SecondPickSmokeEntry {
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
            port: 22,
            username: "nobody"
        )
        record.prefersQUIC = true

        let model = TerminalSessionModel()
        defer { model.disconnect() }
        record.authenticationKind = .privateKey
        let firstPick = HostAttachIntent.session(7, daemonSocketName: "listed.sock", daemonInstanceID: 17)
        model.connect(to: record, secret: "", attach: firstPick)
        check(model.hasFailed && model.hasExited, "a missing private key did not fail the first connection")
        check(
            model.sessionSummary.contains("7"),
            "the first pick did not reach the model (summary: \(model.sessionSummary))"
        )

        check(model.currentAttachIntent == firstPick, "return navigation lost the selected attachment")
        model.connect(to: record, secret: "", attach: model.currentAttachIntent)
        check(
            model.sessionSummary.contains("7"),
            "asking for the same session again moved the model (summary: \(model.sessionSummary))"
        )

        // A DIFFERENT ask is a person picking another row, and must be honoured.
        record.authenticationKind = .password
        model.connect(to: record, secret: "", attach: .session(9, daemonSocketName: "listed.sock", daemonInstanceID: 17))
        check(!model.hasFailed && !model.hasExited, "the second connection retained the first connection's failure")
        check(
            model.sessionSummary.contains("9"),
            "the second pick was swallowed: the model still reads \(model.sessionSummary)"
        )
        model.selectTheme(named: "Noir Clair")
        model.connect(to: record, secret: "", attach: model.currentAttachIntent)
        check(model.themeName == "Noir Clair", "return navigation restored the host record's stale theme")

        // A workspace pick differs from a session pick by more than its number.
        model.connect(to: record, secret: "", attach: .workspace("review"))
        check(
            model.sessionSummary.contains("review"),
            "a workspace pick after a session pick was swallowed (summary: \(model.sessionSummary))"
        )

        for failure in failures {
            SmokeLaunch.report("second-pick: \(failure)")
        }
        return failures.isEmpty
    }
}
