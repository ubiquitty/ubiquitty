// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyIOSBridge
import UbiquittySSH

/// A QUIC bootstrap that failed the way a waking path fails is asked again
/// before the person is shown anything, and a refusal is not.
///
/// The answers are scripted rather than dialled: a path that comes up a few
/// seconds late is the one condition a simulator cannot stage on demand. Each
/// fact is read from the model the screen draws.
///
/// - A timed-out ask is asked again on Core's schedule, reads as waiting for
///   the network meanwhile, and is reported only once the attempts are spent.
/// - A refused ask is reported at once, after one attempt.
enum BootstrapRetrySmokeEntry {
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
        record.prefersQUIC = true

        let timedOut = ScriptedAsks(.unreachable(reason: "timed out", reachFailure: .timedOut))
        let waking = TerminalSessionModel()
        waking.makeBootstrapAsk = timedOut.make
        waking.connect(to: record, secret: "unused", attach: .newSession)
        check(
            settle(seconds: 3) { waking.statusDetail == "Waiting for the network…" },
            "a timed-out ask did not wait for the network (status: \(waking.statusDetail))"
        )
        check(!waking.hasFailed, "a timed-out ask was reported before it was asked again")
        check(settle(seconds: 8) { waking.hasFailed }, "the spent attempts were never reported (asks: \(timedOut.count))")
        check(timedOut.count == 3, "a timed-out ask was asked \(timedOut.count) times, not 3")
        check(
            waking.statusDetail == "127.0.0.1 did not answer on port 1.",
            "the spent attempts did not say why: \(waking.statusDetail)"
        )
        waking.disconnect()

        let refusedError = POSIXErrorCode.ECONNREFUSED.rawValue
        let refused = ScriptedAsks(.unreachable(reason: "refused", reachFailure: .system(errorCode: refusedError)))
        let answered = TerminalSessionModel()
        answered.makeBootstrapAsk = refused.make
        answered.connect(to: record, secret: "unused", attach: .newSession)
        check(settle(seconds: 1) { answered.hasFailed }, "a refusal was not reported at once")
        check(refused.count == 1, "a refusal was asked \(refused.count) times, not once")
        answered.disconnect()

        let selected = HostAttachIntent.session(7, daemonSocketName: "listed.sock", daemonInstanceID: 17)
        let ownerAsks = ScriptedAsks(.unreachable(reason: "refused", reachFailure: .system(errorCode: refusedError)))
        let picked = TerminalSessionModel()
        picked.makeBootstrapAsk = ownerAsks.make
        picked.connect(to: record, secret: "unused", attach: selected)
        check(settle(seconds: 1) { picked.unreachedPick != nil }, "a selected owner refusal did not retain the pick")
        check(ownerAsks.commands.count == 1, "a selected owner did not issue exactly one bootstrap ask")
        check(ownerAsks.commands.first?.contains("SOCK=\"listed.sock\";") == true, "the initial bootstrap did not name the selected daemon")
        check(picked.currentAttachIntent == selected, "the selected owner was lost after bootstrap refusal")
        check(!picked.hasLoginShellCarrier, "an owner refusal opened a login shell")
        picked.disconnect()

        let unnamedOwner = HostAttachIntent.session(7, daemonSocketName: "", daemonInstanceID: 0)
        check(unnamedOwner.bootstrapCommand == nil, "a selected session without its directory owner built a bootstrap")
        let malformedOwner = HostAttachIntent.session(7, daemonSocketName: "../other.sock", daemonInstanceID: 17)
        check(malformedOwner.bootstrapCommand == nil, "an unsafe daemon name built a bootstrap")
        let oversizedOwner = HostAttachIntent.session(7, daemonSocketName: String(repeating: "a", count: 65_536), daemonInstanceID: 17)
        check(oversizedOwner.bootstrapCommand == nil, "an oversized daemon name built a bootstrap")
        check(
            HostAttachIntent.workspace("review", daemonSocketName: "listed.sock", daemonInstanceID: 17).bootstrapCommand?
                .contains("SOCK=\"listed.sock\";") == true,
            "a named workspace lost its directory owner"
        )

        var plainRecord = record
        plainRecord.prefersQUIC = false
        let kept = TerminalSessionModel()
        kept.connect(to: plainRecord, secret: "unused", attach: selected)
        check(kept.unreachedPick != nil, "a selected session without QUIC did not retain the pick")
        check(!kept.hasLoginShellCarrier, "a selected session without QUIC opened a login shell")
        kept.disconnect()

        // An authenticated exec can offer no QUIC listener while the existing
        // daemon still answers control over SSH. The provider receives the
        // actual verified fingerprint, not an unpinned fallback. Its stream
        // seam is replaced before the directory asks, so no carrier is dialled.
        let fingerprint = "SHA256:verified-bootstrap-smoke"
        let noListener = ScriptedAsks(.declined(reason: "no QUIC listener"), fingerprint: fingerprint)
        let directory = TerminalSessionModel()
        directory.makeBootstrapAsk = noListener.make
        var controlRequests = 0
        directory.configureCarrierProvider = { provider in
            provider.provideSSHCarrier = { request, pinnedRecord, _, _ in
                controlRequests += 1
                check(pinnedRecord.pinnedHostKeyFingerprint == fingerprint, "the authenticated exec fingerprint did not reach native SSH")
                check(ubiquittyIOSQUICRequestIsControlOnly(request), "a first directory request was not control-only")
                check(!ubiquittyIOSQUICRequestHasPinnedOwner(request), "a first directory request invented a daemon owner")
                let reason = "scripted control completion"
                reason.withCString { ubiquittyIOSQUICRequestFail(request, UbiquittyIOSQUICFailureStop, $0, reason.utf8.count) }
            }
        }
        directory.askHostForSessions(on: record, secret: "unused")
        check(
            settle(seconds: 1) { directory.hostSessionAnswers > 0 },
            "a host without a QUIC listener did not finish its SSH directory errand"
        )
        check(controlRequests == 1, "an authenticated no-listener answer did not request exactly one passive SSH control carrier")
        check(!directory.hasLoginShellCarrier, "a directory request opened a login shell")
        directory.disconnect()

        let unverified = TerminalSessionModel()
        let noIdentity = ScriptedAsks(.declined(reason: "no verified SSH identity"))
        unverified.makeBootstrapAsk = noIdentity.make
        var unverifiedStreams = 0
        unverified.configureCarrierProvider = { provider in
            provider.provideSSHCarrier = { request, _, _, _ in
                unverifiedStreams += 1
                ubiquittyIOSQUICRequestComplete(request, 0, nil, 0, nil, 0, nil)
            }
        }
        unverified.askHostForSessions(on: record, secret: "unused")
        check(settle(seconds: 1) { unverified.hostSessionAnswers > 0 }, "an unverified directory ask did not end")
        check(unverifiedStreams == 0, "an unverified initial answer opened an SSH fallback")
        unverified.disconnect()

        // A deadline names the stage the ask stopped at. Only an ask that
        // never connected is a host that did not answer on the port; one
        // that connected and then stalled sends a person to the login or the
        // daemon, never the network.
        func deadlineSentence(at stage: QUICBootstrapProbe.Stage) -> String {
            let outcome = QUICBootstrapProbe.deadlineOutcome(at: stage, host: "build.example", port: 22)
            guard case .unreachable(let reason, let reachFailure, _) = outcome else { return "not unreachable" }
            return TerminalSessionModel.sentence(for: reason, reachFailure: reachFailure, host: "build.example", port: 22)
        }
        check(
            deadlineSentence(at: .dialling) == "build.example did not answer on port 22.",
            "a deadline before the connect read \(deadlineSentence(at: .dialling))"
        )
        check(
            deadlineSentence(at: .loggingIn) == "build.example answered on port 22, but the SSH sign-in didn’t finish.",
            "a deadline during the login read \(deadlineSentence(at: .loggingIn))"
        )
        check(
            deadlineSentence(at: .awaitingAnswer)
                == "build.example accepted the sign-in, but ubiquitty-host on it didn’t respond in time. Check that Ubiquitty is installed on the host.",
            "a deadline after the login read \(deadlineSentence(at: .awaitingAnswer))"
        )

        for failure in failures {
            SmokeLaunch.report("bootstrap-retry: FAIL: \(failure)")
        }
        return failures.isEmpty
    }

    /// Runs the main loop until a condition holds or the time runs out.
    @MainActor
    private static func settle(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

/// Answers every ask with the same outcome, counting the asks.
@MainActor
private final class ScriptedAsks {
    private let outcome: QUICBootstrapProbe.Outcome
    private let fingerprint: String
    private(set) var count = 0
    private(set) var commands: [String] = []

    init(_ outcome: QUICBootstrapProbe.Outcome, fingerprint: String = "") {
        self.outcome = outcome
        self.fingerprint = fingerprint
    }

    func make(
        _ record: HostRecord,
        _ credentials: SSHAuthentication,
        _ bootstrapCommand: String,
        _ answer: @escaping (QUICBootstrapProbe.Outcome) -> Void
    ) -> any QUICBootstrapAsking {
        count += 1
        commands.append(bootstrapCommand)
        return ScriptedAsk(outcome: outcome, fingerprint: fingerprint, answer: answer)
    }
}

/// One scripted ask, answering on the next turn of the main loop.
///
/// Unchecked because it is made, started, cancelled and answered on the main
/// thread only.
private final class ScriptedAsk: QUICBootstrapAsking, @unchecked Sendable {
    let presentedFingerprint: String
    let deadlineOutcome = QUICBootstrapProbe.Outcome.unreachable(reason: "timed out", reachFailure: .timedOut)
    private let outcome: QUICBootstrapProbe.Outcome
    private let answer: (QUICBootstrapProbe.Outcome) -> Void
    private var isCancelled = false

    init(outcome: QUICBootstrapProbe.Outcome, fingerprint: String, answer: @escaping (QUICBootstrapProbe.Outcome) -> Void) {
        self.outcome = outcome
        self.presentedFingerprint = fingerprint
        self.answer = answer
    }

    func start() {
        DispatchQueue.main.async { self.deliver() }
    }

    private func deliver() {
        guard !isCancelled else { return }
        answer(outcome)
    }

    func cancel() {
        isCancelled = true
    }
}
