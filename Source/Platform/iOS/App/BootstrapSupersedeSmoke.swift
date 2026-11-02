// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittySSH

import struct UbiquittyRenderKit.HostDaemonInstance

/// A newer request for a QUIC carrier ends the asks it replaces.
///
/// Core asks again on every redial — a resume, each network move, a backoff
/// timer — and only its newest ask can still be used. Every older one left
/// running is a full SSH login held open to the host for up to 30 seconds,
/// and a few at once trip sshd's MaxStartups, which resets connections at
/// random: one more way to fail on port 22.
///
/// Only a requester's own newer ask replaces its older one. The attach and
/// the directory errand are separate Cores asking through one provider, and
/// ending the other's ask answers a request it is still waiting on with no
/// carrier, so the two starve each other while the network is slow.
///
/// The requests are stand-ins no bridge made, so the answers are recorded
/// rather than delivered.
enum BootstrapSupersedeSmokeEntry {
    @MainActor
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ passed: Bool, _ what: String) {
            if !passed {
                failures.append(what)
            }
        }

        let record = HostRecord(id: UUID(), name: "smoke", hostName: "127.0.0.1", port: 1, username: "nobody")
        let provider = QUICCarrierProvider(
            record: record,
            credentials: [],
            initialBootstrap: .declined(reason: "consumed by the first request")
        ) { _ in }
        let asks = SilentAsks()
        provider.makeBootstrapAsk = asks.make
        provider.bootstrapRequest = { _ in .init(command: "unbound-bootstrap", hasPinnedOwner: false) }
        provider.requestIsCurrent = { _ in true }
        var answers: [Int: Int] = [:]
        provider.answerRequest = { request, _ in answers[Int(bitPattern: request), default: 0] += 1 }

        let attach = UUID()
        let requests = (1...4).map { OpaquePointer(bitPattern: $0)! }
        for request in requests {
            provider.requestChannel(request, from: attach)
        }
        check(asks.started == 3, "three requests after the first started \(asks.started) asks")
        check(asks.live == 1, "\(asks.live) asks were still running after the newest replaced them")
        check(answers[1] == 1, "the request the initial bootstrap answered was answered \(answers[1] ?? 0) times")
        for superseded in 2...3 {
            check(answers[superseded] == 1, "replaced request \(superseded) was answered \(answers[superseded] ?? 0) times")
        }
        check(answers[4] == nil, "the newest request was answered before its ask was")

        let directory = UUID()
        provider.requestChannel(OpaquePointer(bitPattern: 5)!, from: directory)
        check(answers[4] == nil, "another requester's ask ended the attach's newest one")
        check(asks.live == 2, "\(asks.live) asks were running with one from each requester")
        provider.requestChannel(OpaquePointer(bitPattern: 6)!, from: directory)
        check(answers[5] == 1, "the directory's own newer ask left its older one answered \(answers[5] ?? 0) times")
        check(answers[4] == nil, "the directory's newer ask ended the attach's")
        check(asks.live == 2, "\(asks.live) asks were running after the directory replaced its own")

        provider.cancel(from: attach)
        check(answers[4] == 1, "the newest request was answered \(answers[4] ?? 0) times on cancel")
        check(answers[6] == nil, "cancelling the attach's asks answered the directory's")
        provider.cancel(from: directory)
        check(asks.live == 0, "\(asks.live) asks outlived both requesters' cancels")
        check(answers[6] == 1, "the directory's newest request was answered \(answers[6] ?? 0) times on cancel")

        let ownerProvider = QUICCarrierProvider(
            record: record,
            credentials: [],
            initialBootstrap: .declined(reason: "unbound initial bootstrap")
        ) { _ in }
        let ownerAsks = SilentAsks()
        ownerProvider.makeBootstrapAsk = ownerAsks.make
        ownerProvider.bootstrapRequest = { request in
            .init(command: "owner-bootstrap", hasPinnedOwner: Int(bitPattern: request) == 7)
        }
        var isOwnerCurrent = true
        ownerProvider.requestIsCurrent = { _ in isOwnerCurrent }
        var ownerAnswers: [Int: Int] = [:]
        var verifiedBootstraps = 0
        var didAcceptStaleAnswer = false
        ownerProvider.noteVerifiedBootstrap = { _, _ in verifiedBootstraps += 1 }
        ownerProvider.answerRequest = { request, outcome in
            ownerAnswers[Int(bitPattern: request), default: 0] += 1
            if Int(bitPattern: request) == 7, outcome != nil { didAcceptStaleAnswer = true }
        }
        let ownerRequester = UUID()
        ownerProvider.requestChannel(OpaquePointer(bitPattern: 7)!, from: ownerRequester)
        check(ownerAnswers[7] == nil, "a pinned owner consumed an unbound initial bootstrap")
        check(ownerAsks.commands == ["owner-bootstrap"], "the owner's command did not reach its bootstrap ask")
        isOwnerCurrent = false
        ownerAsks.answerLatest(.declined(reason: "obsolete owner"))
        let settleDeadline = Date().addingTimeInterval(1)
        while ownerAnswers[7] == nil, Date() < settleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(ownerAnswers[7] == 1, "an obsolete owner request was not completed exactly once")
        check(!didAcceptStaleAnswer, "an obsolete owner request received a carrier answer")
        check(verifiedBootstraps == 0, "an obsolete owner answer refreshed protected reach metadata")
        isOwnerCurrent = true
        ownerProvider.requestChannel(OpaquePointer(bitPattern: 8)!, from: ownerRequester)
        check(ownerAnswers[8] == 1, "a pinned request consumed the initial bootstrap reserved for an unbound request")
        ownerProvider.cancel(from: ownerRequester)
        check(ownerAsks.live == 0, "an owner bootstrap ask outlived its completion")

        let matchedProvider = QUICCarrierProvider(
            record: record,
            credentials: [],
            initialBootstrap: .declined(reason: "same owner"),
            initialBootstrapCommand: "matching-owner-bootstrap"
        ) { _ in }
        matchedProvider.bootstrapRequest = { _ in .init(command: "matching-owner-bootstrap", hasPinnedOwner: true) }
        matchedProvider.requestIsCurrent = { _ in true }
        let matchedAsks = SilentAsks()
        matchedProvider.makeBootstrapAsk = matchedAsks.make
        var matchedAnswers = 0
        matchedProvider.answerRequest = { _, _ in matchedAnswers += 1 }
        matchedProvider.requestChannel(OpaquePointer(bitPattern: 9)!, from: UUID())
        check(matchedAnswers == 1, "a matching owner-bound initial bootstrap was not used")
        check(matchedAsks.started == 0, "a matching initial bootstrap opened a redundant SSH ask")

        let instanceData = Data(
            #"{"socketName":"host-0123456789abcdef.sock","executable":"/Applications/Other Host/ubiquitty-host","startedUnixSeconds":7}"#
                .utf8
        )
        if let instance = try? JSONDecoder().decode(HostDaemonInstance.self, from: instanceData) {
            let selectedProvider = QUICCarrierProvider(record: record, credentials: [], initialBootstrap: nil, hostInstance: instance) {
                _ in
            }
            let selectedAsks = SilentAsks()
            selectedProvider.makeBootstrapAsk = selectedAsks.make
            selectedProvider.requestIsCurrent = { _ in true }
            selectedProvider.answerRequest = { _, _ in }
            selectedProvider.bootstrapRequest = { request in
                let command = String(Ubiquitty.Session.quicBootstrapRemoteCommand())
                let pinned = Int(bitPattern: request) == 11
                let redirected = pinned ? instance.bootstrap(command, pinInitialOwner: true) : command
                return .init(command: redirected, hasPinnedOwner: pinned)
            }
            let requester = UUID()
            for number in 10...12 { selectedProvider.requestChannel(OpaquePointer(bitPattern: number)!, from: requester) }
            let directoryRequester = UUID()
            selectedProvider.requestChannel(OpaquePointer(bitPattern: 13)!, from: directoryRequester)
            check(selectedAsks.commands.count == 4, "a selected installation did not answer each bootstrap request")
            if selectedAsks.commands.count == 4 {
                check(
                    selectedAsks.commands.allSatisfy { $0.contains("'/Applications/Other Host/ubiquitty-host'") },
                    "an installation reconnect used another installation's executable"
                )
                check(selectedAsks.commands[0].contains(instance.socketName), "the first request lost its selected owner")
                check(selectedAsks.commands[1].contains(instance.socketName), "a pinned resume lost its selected owner")
                check(!selectedAsks.commands[2].contains(instance.socketName), "successor discovery was pinned back to a retired socket")
                check(
                    selectedAsks.commands[3].contains(instance.socketName),
                    "the directory's initial owner was lost after the terminal redialled"
                )
            }
            let intent = HostAttachIntent.workspace("review").targeting(instance, socket: instance.socketName, daemon: 17)
            check(intent.hostInstance == instance && intent.daemonInstanceID == 17, "a workspace selection lost its installation")
            check(intent.bootstrapCommand?.contains(instance.executable) == true, "an initial attach used the default installation")
            selectedProvider.cancel(from: requester)
            selectedProvider.cancel(from: directoryRequester)
        } else {
            check(false, "the discovered installation could not be decoded")
        }

        for failure in failures {
            SmokeLaunch.report("bootstrap-supersede: FAIL: \(failure)")
        }
        return failures.isEmpty
    }
}

/// Asks that never answer, counting how many were started and how many are
/// still running.
@MainActor
private final class SilentAsks {
    private(set) var started = 0
    private(set) var commands: [String] = []
    private var asks: [SilentAsk] = []
    var live: Int { asks.filter { !$0.isCancelled }.count }

    func make(
        _ record: HostRecord,
        _ credentials: SSHAuthentication,
        _ bootstrapCommand: String,
        _ answer: @escaping (QUICBootstrapProbe.Outcome) -> Void
    ) -> any QUICBootstrapAsking {
        started += 1
        commands.append(bootstrapCommand)
        let ask = SilentAsk(answer: answer)
        asks.append(ask)
        return ask
    }

    func answerLatest(_ outcome: QUICBootstrapProbe.Outcome) {
        asks.last?.answer(outcome)
    }
}

/// One ask that never answers.
private final class SilentAsk: QUICBootstrapAsking {
    let presentedFingerprint = ""
    let deadlineOutcome = QUICBootstrapProbe.Outcome.unreachable(reason: "timed out", reachFailure: .timedOut)
    private(set) var isCancelled = false
    let answer: (QUICBootstrapProbe.Outcome) -> Void

    init(answer: @escaping (QUICBootstrapProbe.Outcome) -> Void) {
        self.answer = answer
    }

    func start() {}

    func cancel() {
        isCancelled = true
    }
}
