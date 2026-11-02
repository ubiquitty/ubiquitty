// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CxxStdlib
import Foundation
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittySSH

/// Asks a host's daemon for the port, token and certificate pin a QUIC carrier
/// needs, over SSH.
///
/// The desktop clients get this by running `ssh <host> '<command>'` as a local
/// subprocess. A phone cannot: it is sandboxed, there is no fork and no ssh
/// binary, and Core's own `readQUICBootstrap` — which spawns a piped command —
/// is unreachable here for exactly that reason.
///
/// What the phone does have is an authenticated SSH stack of its own, so it runs
/// the identical remote command over an exec session. The command comes from Core
/// (`quicBootstrapRemoteCommand()`) rather than being spelled here, so the two
/// paths cannot drift into asking different things.
///
/// The answer is parsed by Core's grammar too, through `QUICBootstrapReader`:
/// the daemon writes that line, and a second parser on this side is a second
/// thing to keep in step with it.
///
/// This is a SEPARATE, short-lived connection from the session's own carrier.
/// The session carrier holds a pseudo-terminal running a login shell, and asking
/// it to also carry a command's stdout would mean picking the reply back out of
/// the terminal's own output — which is why the bootstrap gets its own exec
/// channel and closes it as soon as the line arrives.
final class QUICBootstrapProbe: QUICBootstrapAsking, SSHCarrierDelegate, @unchecked Sendable {
    /// What the probe concluded.
    enum Outcome {
        /// The daemon answered with a complete, well-formed line, over a
        /// connection whose socket says which address it reached. The QUIC
        /// carrier dials that address: the token and the pin are that
        /// machine's, and the host's name resolved again may be another's.
        case ready(port: UInt16, token: [UInt8], certificateSHA256: [UInt8], reachedAddress: String)
        /// The host was reached and gave no usable answer: no daemon, or a
        /// line that did not parse. Never dialled: an unpinned token is
        /// stealable in the middle, so a partial line is a refusal, not a
        /// smaller success.
        case declined(reason: String)
        /// The host was never reached, or would not let this login in. Told
        /// apart from a decline because the two send a person to different
        /// places: the network or the credential, against the host's setup.
        ///
        /// - Parameters:
        ///   - reason: The carrier's own description, for the log.
        ///   - reachFailure: Why the connect failed, when it was typed.
        case unreachable(reason: String, reachFailure: SSHReachFailure?, classification: SSHCloseClassification? = nil)
        /// The bootstrap was pinned to a daemon that is gone. Neither asking
        /// again nor the same pin's stream reaches it; Core drops the pin.
        ///
        /// - Parameter socketName: The gone daemon's socket.
        case instanceGone(socketName: String)
    }

    private let host: String
    private let port: Int
    private let username: String
    private let credentials: SSHAuthentication
    private let pinnedFingerprint: String
    private let bootstrapCommand: String
    private let answer: (Outcome) -> Void

    /// The SSH key usable after an authenticated exec answer, ready or declined.
    private(set) var presentedFingerprint: String {
        get { lock.withLock { fingerprint } }
        set { lock.withLock { fingerprint = newValue } }
    }
    private var fingerprint = ""
    private let lock = NSLock()
    private var carrier: SSHCarrier?
    /// Core's own accumulator, not a second parser. The daemon writes that line
    /// and this reads it with the grammar that wrote it; a Swift reimplementation
    /// would be one more thing to keep in step.
    private var reader = Ubiquitty.SyncBridge.QUICBootstrapReader()
    /// Whether `answer` has run. The delegate reports a close after the line
    /// too, and a probe that answered twice would attach twice.
    private var hasAnswered = false
    /// Whether the exec channel opened, which is what separates a host that
    /// declined from one that was never reached.
    private var hasReachedTheHost = false
    /// Whether the TCP connection opened, which separates a host that never
    /// answered from a login that never finished.
    private var hasOpenedTransport = false

    init(
        host: String,
        port: Int,
        username: String,
        credentials: SSHAuthentication,
        pinnedFingerprint: String,
        bootstrapCommand: String = String(Ubiquitty.Session.quicBootstrapRemoteCommand()),
        answer: @escaping (Outcome) -> Void
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.pinnedFingerprint = pinnedFingerprint
        self.bootstrapCommand = bootstrapCommand
        self.answer = answer
    }

    /// Runs the probe. Answers through the closure, never inline.
    func start() {
        let pinned = pinnedFingerprint
        let validator: SSHHostKeyValidator = { [weak self] keyBytes in
            let fingerprint = keyBytes.withUnsafeBufferPointer { SSHCarrierClient.hostKeyFingerprint(of: $0) }
            // The same verdict the session carrier asks for, from the same Core
            // policy. A probe that trusted more freely than the session would be
            // a second, laxer front door to the same host.
            let verdict = fingerprint.withCString { presented in
                pinned.withCString { ubiquittyIOSVerifyHostKeyFingerprint($0, presented) }
            }
            if verdict == 2 {
                throw SSHCarrierError.hostKeyMismatched
            }
            self?.presentedFingerprint = fingerprint
        }
        let carrier = SSHCarrier(
            host: host,
            port: port,
            username: username,
            credentials: credentials,
            hostKeyValidator: validator,
            // exec, not shell: no pseudo-terminal, so the daemon's one line
            // arrives as itself rather than mixed into a shell's output.
            sessionKind: .exec(
                command: bootstrapCommand.withCString { String(Ubiquitty.Transport.remoteShellCommand(std.string_view($0))) }
            ),
            delegate: self
        )
        lock.lock()
        self.carrier = carrier
        lock.unlock()
        if !carrier.start() {
            finish(.unreachable(reason: "The SSH connection to the host couldn’t be started.", reachFailure: nil))
        }
    }

    /// Sleeps out an ask's deadline, held for as long as its sign-in waits on
    /// the person and for a grace after.
    ///
    /// The deadline guards against a host that went silent. A sign-in waiting
    /// on the person — a password being typed, a Tailscale check being
    /// approved in a browser — is not a silent host, and ending it would fail
    /// the connection for the person being slower than the server. The grace
    /// lets the answer the person just gave reach the server and come back.
    ///
    /// - Parameters:
    ///   - duration: The deadline when nobody is asked.
    ///   - interaction: The sign-in's interaction, nil when it can ask nobody.
    static func waitOutDeadline(_ duration: Duration, signIn interaction: SSHAuthenticationInteraction?) async throws {
        try await Task.sleep(for: duration)
        while interaction?.isWaitingOnPerson == true {
            repeat {
                try await Task.sleep(for: .seconds(1))
            } while interaction?.isWaitingOnPerson == true
            try await Task.sleep(for: .seconds(15))
        }
    }

    /// What a deadline that ran out before any answer means, from how far
    /// this ask got.
    var deadlineOutcome: Outcome {
        lock.lock()
        let stage: Stage = hasReachedTheHost ? .awaitingAnswer : hasOpenedTransport ? .loggingIn : .dialling
        lock.unlock()
        return Self.deadlineOutcome(at: stage, host: host, port: port)
    }

    /// How far an ask got before its deadline.
    enum Stage {
        /// No TCP connection yet.
        case dialling
        /// Connected, with the SSH handshake or login unfinished.
        case loggingIn
        /// Logged in, waiting on the daemon's bootstrap line.
        case awaitingAnswer
    }

    /// What a deadline that ran out at a stage means.
    ///
    /// - Parameters:
    ///   - stage: How far the ask got.
    ///   - host: The host as the person typed it.
    ///   - port: The SSH port dialled.
    /// - Returns: The outcome a person is told about.
    static func deadlineOutcome(at stage: Stage, host: String, port: Int) -> Outcome {
        // Only the first stage is a host that did not answer on the port, and
        // only it is typed as a timeout, which is what Core retries. The other
        // two reached the host, and a sentence about the network would send a
        // person to check a firewall that let them through.
        switch stage {
        case .dialling:
            return .unreachable(reason: "QUIC bootstrap timed out", reachFailure: .timedOut)
        case .loggingIn:
            return .unreachable(
                reason: "\(host) answered on port \(port), but the SSH sign-in didn’t finish.",
                reachFailure: nil
            )
        case .awaitingAnswer:
            return .unreachable(
                reason:
                    "\(host) accepted the sign-in, but ubiquitty-host on it didn’t respond in time. Check that Ubiquitty is installed on the host.",
                reachFailure: nil
            )
        }
    }

    /// Stops the probe without answering. For a caller that gave up first.
    func cancel() {
        lock.lock()
        let carrier = self.carrier
        self.carrier = nil
        hasAnswered = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { carrier?.stop() }
    }

    /// Answers once and tears the connection down.
    private func finish(_ outcome: Outcome) {
        lock.lock()
        if hasAnswered {
            lock.unlock()
            return
        }
        hasAnswered = true
        let carrier = self.carrier
        self.carrier = nil
        lock.unlock()
        // finish runs from a delegate callback on the carrier's own event
        // loop, and stop() blocks on that loop's shutdown — a synchronous
        // shutdown from inside the loop it is shutting down traps. The
        // teardown is handed to a background queue so the loop thread returns
        // to drain; the captured carrier keeps itself alive until the shutdown
        // completes, and the answer does not wait on it.
        DispatchQueue.global(qos: .userInitiated).async { carrier?.stop() }
        answer(outcome)
    }

    // MARK: - SSHCarrierDelegate

    func sshCarrierDidOpenTransport(_ carrier: SSHCarrier) {
        lock.lock()
        hasOpenedTransport = true
        lock.unlock()
    }

    func sshCarrierDidConnect(_ carrier: SSHCarrier) {
        lock.lock()
        hasReachedTheHost = true
        lock.unlock()
    }

    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {
        lock.lock()
        let state = feedLocked(bytes)
        let outcome = outcomeLocked(for: state, over: carrier)
        lock.unlock()
        guard let outcome else { return }
        finish(outcome)
    }

    /// Hands one slice to Core's reader. Caller holds the lock.
    private func feedLocked(_ bytes: UnsafeRawBufferPointer) -> Ubiquitty.SyncBridge.QUICBootstrapReader.State {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return reader.state() }
        return base.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { pointer in
            reader.feed(Ubiquitty.SyncBridge.QUICBootstrapBytes(UnsafeBufferPointer(start: pointer, count: bytes.count)))
        }
    }

    /// Copies a std::string's bytes out verbatim.
    ///
    /// Never through `.utf8`. These two fields are the decoded token and
    /// certificate pin — arbitrary bytes, not text — and a UTF-8 view of a
    /// buffer containing 0x80 or above does not round-trip. A mangled pin does
    /// not fail loudly; it fails the dial, or matches a certificate nobody
    /// meant, which is the one thing the pin exists to prevent.
    private static func bytes(of value: std.string) -> [UInt8] {
        let count = Int(value.size())
        guard count > 0, let data = value.__dataUnsafe() else { return [] }
        return data.withMemoryRebound(to: UInt8.self, capacity: count) { pointer in
            Array(UnsafeBufferPointer(start: pointer, count: count))
        }
    }

    /// Turns a reader state into an answer, or nil while it is undecided.
    /// Caller holds the lock.
    private func outcomeLocked(for state: Ubiquitty.SyncBridge.QUICBootstrapReader.State, over carrier: SSHCarrier) -> Outcome? {
        switch state {
        case .Ready:
            let info = Ubiquitty.SyncBridge.bootstrapInfo(reader)
            // No address, no carrier: the name is not resolved a second time.
            guard let reachedAddress = carrier.reachedAddress, !reachedAddress.isEmpty else {
                return .declined(reason: "QUIC wasn’t used because the SSH connection didn’t report the host’s address.")
            }
            return .ready(
                port: info.port,
                token: Self.bytes(of: info.token),
                certificateSHA256: Self.bytes(of: info.certificateSHA256),
                reachedAddress: reachedAddress
            )
        case .Refused:
            return .declined(reason: String(Ubiquitty.SyncBridge.bootstrapRefusal(reader)))
        case .InstanceGone:
            return .instanceGone(socketName: String(Ubiquitty.SyncBridge.bootstrapGoneSocketName(reader)))
        default:
            return nil
        }
    }

    func sshCarrier(_ carrier: SSHCarrier, shouldKeepWaitingAfter reachFailure: SSHReachFailure?) -> Bool {
        reachFailure?.isWorthWaitingOut ?? true
    }

    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {
        // An exec session keeps stderr separate, and the daemon's diagnostics go
        // there. Feeding them to the line parser would let a warning that
        // happens to contain `quic_port=` be read as an answer.
    }

    func sshCarrier(
        _ carrier: SSHCarrier,
        didCloseWithFailure isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure?
    ) {
        // A command that exits without a trailing newline still produced its
        // answer, so the close is offered to the reader before it is called a
        // failure. Core decides; this only reports.
        // A host never reached sent no line, and the reader's verdict on an
        // empty stream is a refusal: asked first, it would call an
        // unreachable host one that declined.
        lock.lock()
        let classification = carrier.closeClassification
        let readOutcome = hasReachedTheHost ? outcomeLocked(for: reader.finish(), over: carrier) : nil
        let offer: QUICBootstrapOffer
        if case .ready = readOutcome { offer = .ready } else { offer = .absent }
        let phase: SSHConnectionPhase = hasReachedTheHost ? .sessionOpen : hasOpenedTransport ? .transportOpen : .connecting
        let decision = quicBootstrapCloseDecision(offer: offer, phase: phase, classification: classification)
        let outcome: Outcome?
        switch decision {
        case .ready: outcome = readOutcome
        case .declined:
            outcome = readOutcome ?? .declined(reason: reason.isEmpty ? "QUIC wasn’t used because the host didn’t offer it." : reason)
        case .unreachable: outcome = .unreachable(reason: reason, reachFailure: reachFailure, classification: classification)
        case .cancelled: outcome = nil
        }
        lock.unlock()
        if let outcome { finish(outcome) }
    }
}

/// One ask for a QUIC bootstrap, answered once through the closure it was
/// made with.
///
/// The probe is the one implementation; a smoke stands a scripted one in its
/// place to drive the answers a real host gives only on a bad day.
protocol QUICBootstrapAsking: AnyObject {
    /// The SSH key that authenticated the ask, read after a ready answer.
    var presentedFingerprint: String { get }
    /// What the ask's deadline running out means, from how far it got.
    var deadlineOutcome: QUICBootstrapProbe.Outcome { get }
    /// Starts asking. Answers through the closure, never inline.
    func start()
    /// Stops asking without answering.
    func cancel()
}
