// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyIOSBridge
import UbiquittyRenderKit
import UbiquittySSH

/// Obtains one authenticated bootstrap for each physical QUIC connection.
///
/// Each factory it makes is one requester: the session's attach and its
/// directory errand each hold their own, and only a requester's own newer ask
/// replaces its older one.
@MainActor
final class QUICCarrierProvider {
    struct BootstrapRequest {
        enum CarrierKind { case quic, syncSSH }
        let command: String
        let hasPinnedOwner: Bool
        var carrierKind: CarrierKind = .quic
    }

    private struct Pending {
        let request: OpaquePointer
        let requester: UUID
        let probe: any QUICBootstrapAsking
        let deadline: Task<Void, Never>
    }

    /// The callback context one factory holds: the provider, and which
    /// requester that factory's asks come from.
    private final class Requester {
        let provider: QUICCarrierProvider
        let identifier = UUID()

        init(provider: QUICCarrierProvider) {
            self.provider = provider
        }
    }

    /// Makes one bootstrap ask. The probe over SSH; a smoke scripts it.
    var makeBootstrapAsk:
        (HostRecord, SSHAuthentication, String, @escaping (QUICBootstrapProbe.Outcome) -> Void) -> any QUICBootstrapAsking =
            QUICCarrierProvider.probeOverSSH
    /// Reads the owner-bound command while Core's request is alive.
    var bootstrapRequest: (OpaquePointer) -> BootstrapRequest? = QUICCarrierProvider.bootstrapRequestThroughTheBridge
    /// Rejects answers whose physical owner changed while the SSH ask ran.
    var requestIsCurrent: (OpaquePointer) -> Bool = { ubiquittyIOSQUICRequestIsCurrent($0) }
    /// Hands Core's request its answer, nil for none. Through the bridge; a
    /// smoke records it instead, holding requests no bridge made.
    var answerRequest: (OpaquePointer, QUICBootstrapProbe.Outcome?) -> Void = QUICCarrierProvider.answerThroughTheBridge
    /// Observes authenticated bootstrap metadata before Core accepts its carrier.
    var noteVerifiedBootstrap: ((QUICBootstrapProbe.Outcome, String) -> Void)?
    /// Supplies the native stream; smokes replace it without opening SSH.
    lazy var provideSSHCarrier: (OpaquePointer, HostRecord, SSHAuthentication, String) -> Void = {
        [weak self] request, record, credentials, command in
        SyncSSHCarrier(
            record: record,
            credentials: credentials,
            command: command,
            noteDiagnostic: { [weak self] detail in
                Task { @MainActor in self?.note("The SSH connection closed: \(detail)") }
            }
        )
        .complete(request)
    }

    private let record: HostRecord
    private let credentials: SSHAuthentication
    private let note: (String) -> Void
    private var initialBootstrap: QUICBootstrapProbe.Outcome?
    private let initialBootstrapCommand: String?
    private let hostInstance: HostDaemonInstance?
    private var pinnedHostRequesters: Set<UUID> = []
    private var pending: [UUID: Pending] = [:]

    init(
        record: HostRecord,
        credentials: SSHAuthentication,
        initialBootstrap: QUICBootstrapProbe.Outcome?,
        initialBootstrapCommand: String? = nil,
        hostInstance: HostDaemonInstance? = nil,
        note: @escaping (String) -> Void
    ) {
        self.record = record
        self.credentials = credentials
        self.initialBootstrap = initialBootstrap
        self.initialBootstrapCommand = initialBootstrapCommand
        self.hostInstance = hostInstance
        self.note = note
    }

    /// Makes a factory for one more requester, which holds the provider
    /// through the C++ factory's callback context.
    func makeFactory() -> OpaquePointer? {
        let context = Unmanaged.passRetained(Requester(provider: self)).toOpaque()
        let hooks = UbiquittyIOSQUICProvider(
            context: context,
            request: { context, request in
                guard let context, let request else { return }
                MainActor.assumeIsolated {
                    let requester = Unmanaged<Requester>.fromOpaque(context).takeUnretainedValue()
                    requester.provider.requestChannel(request, from: requester.identifier)
                }
            },
            release: { context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let requester = Unmanaged<Requester>.fromOpaque(context).takeRetainedValue()
                    requester.provider.cancel(from: requester.identifier)
                }
            }
        )
        let factory = record.hostName.withCString { ubiquittyIOSQUICFactoryCreate($0, hooks) }
        if factory == nil { Unmanaged<Requester>.fromOpaque(context).release() }
        return factory
    }

    /// Starts answering one of Core's requests for a carrier.
    ///
    /// - Parameters:
    ///   - request: The request, answered exactly once.
    ///   - requester: The factory it came through.
    func requestChannel(_ request: OpaquePointer, from requester: UUID) {
        guard requestIsCurrent(request), var bootstrap = bootstrapRequest(request) else {
            answerRequest(request, nil)
            return
        }
        if let hostInstance {
            let command = hostInstance.bootstrap(
                bootstrap.command,
                pinInitialOwner: !bootstrap.hasPinnedOwner && !pinnedHostRequesters.contains(requester)
            )
            guard !command.isEmpty else {
                answerRequest(request, nil)
                return
            }
            if bootstrap.hasPinnedOwner { pinnedHostRequesters.insert(requester) }
            bootstrap = BootstrapRequest(command: command, hasPinnedOwner: bootstrap.hasPinnedOwner, carrierKind: bootstrap.carrierKind)
        }
        if bootstrap.carrierKind == .syncSSH {
            cancel(from: requester)
            note("Attaching to the host over SSH")
            provideSSHCarrier(request, record, credentials, bootstrap.command)
            return
        }
        let matchesInitialOwner = initialBootstrapCommand.map { $0 == bootstrap.command } ?? !bootstrap.hasPinnedOwner
        if matchesInitialOwner, let initialBootstrap {
            self.initialBootstrap = nil
            complete(request, with: initialBootstrap)
            return
        }
        // A Core uses only its newest request; it bumps the attempt it would
        // hand an older one's carrier to. Each older ask still running is an
        // SSH login held open on the host, and several at once trip sshd's
        // MaxStartups, which resets connections at random. Another Core's ask
        // is still that Core's newest, and ending it would answer a request it
        // is waiting on with no carrier.
        let replaced = pending.filter { $0.value.requester == requester }.count
        if replaced > 0 {
            note("Replacing \(replaced) unfinished QUIC connection request\(replaced == 1 ? "" : "s")")
            cancel(from: requester)
        }
        note("Getting new QUIC connection details over SSH")
        let id = UUID()
        let probe = makeBootstrapAsk(record, credentials, bootstrap.command) { [weak self] outcome in
            Task { @MainActor in self?.settle(id, with: outcome) }
        }
        let signIn = credentials.interaction
        let deadline = Task { [weak self, weak probe] in
            do { try await QUICBootstrapProbe.waitOutDeadline(.seconds(30), signIn: signIn) } catch { return }
            guard let probe else { return }
            self?.settle(id, with: probe.deadlineOutcome)
        }
        pending[id] = Pending(request: request, requester: requester, probe: probe, deadline: deadline)
        probe.start()
    }

    private func settle(_ id: UUID, with outcome: QUICBootstrapProbe.Outcome) {
        guard let attempt = pending.removeValue(forKey: id) else { return }
        attempt.deadline.cancel()
        attempt.probe.cancel()
        guard requestIsCurrent(attempt.request) else {
            answerRequest(attempt.request, nil)
            return
        }
        noteVerifiedBootstrap?(outcome, attempt.probe.presentedFingerprint)
        complete(attempt.request, with: outcome)
    }

    private func complete(_ request: OpaquePointer, with outcome: QUICBootstrapProbe.Outcome) {
        if case .declined(let reason) = outcome {
            note("QUIC bootstrap failed: \(reason)")
        } else if case .unreachable(let reason, _, _) = outcome {
            note("QUIC bootstrap failed: \(reason)")
        } else if case .instanceGone(let socketName) = outcome {
            note("QUIC bootstrap: the daemon on \(socketName) is gone")
        }
        if case .unreachable(let reason, let reachFailure, let classification) = outcome {
            let readable = SSHFailurePresentation.sentence(
                reason: reason,
                reachFailure: reachFailure,
                classification: classification,
                host: record.hostName,
                port: record.port
            )
            answerRequest(request, .unreachable(reason: readable, reachFailure: reachFailure, classification: classification))
        } else {
            answerRequest(request, outcome)
        }
    }

    /// Ends one requester's asks in flight, answering each with no carrier.
    ///
    /// - Parameter requester: The factory whose asks end.
    func cancel(from requester: UUID) {
        let ended = pending.filter { $0.value.requester == requester }
        for id in ended.keys {
            pending.removeValue(forKey: id)
        }
        for attempt in ended.values {
            attempt.deadline.cancel()
            attempt.probe.cancel()
            answerRequest(attempt.request, nil)
        }
    }

    /// Asks a host for its QUIC bootstrap over an SSH exec session.
    nonisolated private static func probeOverSSH(
        _ record: HostRecord,
        _ credentials: SSHAuthentication,
        _ bootstrapCommand: String,
        _ answer: @escaping (QUICBootstrapProbe.Outcome) -> Void
    ) -> any QUICBootstrapAsking {
        QUICBootstrapProbe(
            host: record.hostName,
            port: record.port,
            username: record.username,
            credentials: credentials,
            pinnedFingerprint: record.pinnedHostKeyFingerprint,
            bootstrapCommand: bootstrapCommand,
            answer: answer
        )
    }

    nonisolated private static func bootstrapRequestThroughTheBridge(_ request: OpaquePointer) -> BootstrapRequest? {
        let length = ubiquittyIOSQUICRequestBootstrapCommand(request, nil, 0)
        guard length > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: length)
        let copied = bytes.withUnsafeMutableBufferPointer {
            ubiquittyIOSQUICRequestBootstrapCommand(request, $0.baseAddress, $0.count)
        }
        guard copied == length else { return nil }
        return BootstrapRequest(
            command: String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            hasPinnedOwner: ubiquittyIOSQUICRequestHasPinnedOwner(request),
            carrierKind: ubiquittyIOSQUICRequestCarrierKind(request) == UbiquittyIOSCarrierSyncSSH ? .syncSSH : .quic
        )
    }

    /// Completes Core's request through the bridge: a carrier for a ready
    /// answer, a bounded typed failure for an unsuccessful ask, or a plain
    /// cancellation when its requester went away.
    nonisolated private static func answerThroughTheBridge(_ request: OpaquePointer, _ outcome: QUICBootstrapProbe.Outcome?) {
        switch outcome {
        case .declined(let reason):
            // The SSH exec channel authenticated and opened, but offered no
            // usable QUIC carrier. Core may try only its pinned Sync stream;
            // this is never a login-shell fallback or a trust-key decision.
            reason.withCString { ubiquittyIOSQUICRequestFail(request, UbiquittyIOSQUICFailureUseStream, $0, reason.utf8.count) }
            return
        case .unreachable(let reason, let reachFailure, _):
            let recovery = reachFailure?.isWorthWaitingOut == false ? UbiquittyIOSQUICFailureStop : UbiquittyIOSQUICFailureRetry
            reason.withCString { ubiquittyIOSQUICRequestFail(request, recovery, $0, reason.utf8.count) }
            return
        case .instanceGone:
            // Core drops the pin and asks the host's current daemon; no
            // stream is opened to the daemon that is gone.
            let reason = "the Ubiquitty host this connection used is no longer running"
            reason.withCString { ubiquittyIOSQUICRequestFail(request, UbiquittyIOSQUICFailureInstanceGone, $0, reason.utf8.count) }
            return
        default:
            break
        }
        guard case .ready(let port, let token, let certificate, let reachedAddress) = outcome else {
            ubiquittyIOSQUICRequestComplete(request, 0, nil, 0, nil, 0, nil)
            return
        }
        token.withUnsafeBufferPointer { tokenBytes in
            certificate.withUnsafeBufferPointer { pin in
                reachedAddress.withCString { address in
                    ubiquittyIOSQUICRequestComplete(
                        request,
                        port,
                        tokenBytes.baseAddress,
                        tokenBytes.count,
                        pin.baseAddress,
                        pin.count,
                        address
                    )
                }
            }
        }
    }
}
