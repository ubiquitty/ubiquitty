// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The carrier surface the C++ side drives. Every method here answers one entry
// point of Transport::DelegatedChannel::Driver, and every delegate callback
// answers one of notifyConnect / deliver / notifyClose, so the bridge between
// the two is a mechanical forward with no policy in it.
//
// Two session kinds ride the same connection: `shell` allocates a PTY and runs
// the login shell, which the Core emulates locally; `exec` runs one command and
// carries its bytes opaquely, which is how a ubiquitty-host bootstrap and its
// Sync stream reach us. The difference is a channel request, not a transport.

import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import Network

/// Judges the host key the server presented.
///
/// Handed the key in SSH wire encoding — the same bytes a `known_hosts` line
/// base64s. The decision belongs to Core (`Transport::hostKeyFingerprint` and
/// `Transport::verifyHostKeyFingerprint`) and the store belongs to the app; this
/// package neither fingerprints nor compares, so there is one pinning policy
/// across every frontend that stops shelling out to `ssh`.
///
/// Throwing refuses the connection, and the thrown error reaches the delegate's
/// close reason.
public typealias SSHHostKeyValidator = @Sendable (_ keyBytes: [UInt8]) throws -> Void

/// What a carrier asks the remote to run.
public enum SSHSessionKind: Sendable {
    /// Allocate a pseudo-terminal and start the login shell. `term` is the
    /// TERM value the remote sees.
    case shell(term: String)

    /// Run one command with no pseudo-terminal. The command string is built by
    /// Core (`Session::remoteBootstrapCommand`) and passed through verbatim —
    /// this package never composes one.
    case exec(command: String)
}

/// Where a carrier's bytes go, and how it reports its own life cycle.
///
/// Every callback arrives on the carrier's event loop, never re-entering the
/// carrier. The bridge marshals onward; nothing here assumes a UI thread.
public protocol SSHCarrierDelegate: AnyObject, Sendable {
    /// The TCP connection is open, before the SSH handshake and login.
    func sshCarrierDidOpenTransport(_ carrier: SSHCarrier)

    /// The session is open and ready for the first outbound bytes.
    func sshCarrierDidConnect(_ carrier: SSHCarrier)

    /// Delivers inbound bytes from the remote's stdout.
    ///
    /// - Parameter bytes: Valid only for the duration of the call.
    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer)

    /// Delivers the remote's stderr, which a PTY session never produces and an
    /// exec session uses for a bootstrap's diagnostics.
    ///
    /// - Parameter bytes: Valid only for the duration of the call.
    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer)

    /// The carrier finished.
    ///
    /// - Parameters:
    ///   - isFailure: True when a setup or I/O error tore the carrier down,
    ///     false for a clean close or peer EOF. The C++ side maps this onto
    ///     `Health::Failed` versus `Health::Closed`, which it cannot infer.
    ///   - reason: The error as the stack spelled it, for a log.
    ///   - reachFailure: Why the host was never reached, when the failure was
    ///     the TCP connect and its error was typed; nil otherwise.
    func sshCarrier(
        _ carrier: SSHCarrier,
        didCloseWithFailure isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure?
    )

    /// The connect is waiting for a usable path, and asks whether to keep
    /// waiting.
    ///
    /// Network.framework holds a connect it cannot complete yet rather than
    /// failing it, which is what lets a VPN or a radio finish coming up. Some
    /// of what it reports while it waits is already an answer, such as a host
    /// that refused the connection, and which failures are worth waiting out
    /// is Core's to say rather than this package's.
    ///
    /// - Parameter reachFailure: What the last attempt failed with, when typed.
    /// - Returns: False to end the connect now with this failure.
    func sshCarrier(_ carrier: SSHCarrier, shouldKeepWaitingAfter reachFailure: SSHReachFailure?) -> Bool
}

extension SSHCarrierDelegate {
    /// Ignores the transport opening; most delegates wait for the session.
    public func sshCarrierDidOpenTransport(_ carrier: SSHCarrier) {}

    /// Waits out every failure until the connect budget runs out.
    public func sshCarrier(_ carrier: SSHCarrier, shouldKeepWaitingAfter reachFailure: SSHReachFailure?) -> Bool {
        true
    }
}

/// Why a carrier never reached its host, read from the connect's typed error.
///
/// Facts, not sentences: what the failure means to a person is Core's
/// `Transport::describeConnectFailure`, so every frontend says the same thing
/// about the same refusal.
public enum SSHReachFailure: Sendable, Equatable {
    /// The connect failed with this system error code.
    case system(errorCode: Int32)
    /// No address could be found for the host's name.
    case nameNotResolved
    /// Nothing answered before the connect gave up.
    case timedOut
}

/// Counts queued and in-flight bytes before their buffers or event-loop tasks
/// are allocated.
///
/// A separate entry limit bounds per-write bookkeeping even
/// when a peer receives one byte per write and acknowledges none.
struct SSHOutboundBudget {
    let capacity: Int
    private(set) var byteCount = 0
    private(set) var writeCount = 0
    static let maximumWrites = 4096

    mutating func admit(_ count: Int) -> Bool {
        guard count > 0, count <= capacity - byteCount, writeCount < Self.maximumWrites else { return false }
        byteCount += count
        writeCount += 1
        return true
    }

    mutating func complete(_ count: Int) {
        precondition(count > 0 && count <= byteCount && writeCount > 0)
        byteCount -= count
        writeCount -= 1
    }

    mutating func discard() {
        byteCount = 0
        writeCount = 0
    }
}

/// An SSH session presented as a byte carrier.
///
/// Owns its own event loop group, so the embedder integrates no socket into its
/// runloop — the same self-driving contract every `Transport::Channel` has.
public final class SSHCarrier: @unchecked Sendable {
    /// Creates a carrier. No I/O happens until `start`.
    ///
    /// - Parameters:
    ///   - host: The remote host name or address. Already validated by Core's
    ///     `Transport::validateSSHHost` at the call site; this package does not
    ///     re-derive a characterSet of its own.
    ///   - port: The TCP port, conventionally 22.
    ///   - username: The user to authenticate as.
    ///   - credentials: The offers to make, each only for a method the server
    ///     lists after refusing `none`, and who to ask when one needs the
    ///     person.
    ///   - hostKeyValidator: Judges the presented host key; throwing refuses
    ///     the connection.
    ///   - sessionKind: Whether to run a login shell or one command.
    ///   - outboundCapacityBytes: The hard bound on queued and in-flight writes.
    ///   - delegate: Receives the bytes and the life cycle.
    public init(
        host: String,
        port: Int,
        username: String,
        credentials: SSHAuthentication,
        hostKeyValidator: @escaping SSHHostKeyValidator,
        sessionKind: SSHSessionKind,
        outboundCapacityBytes: Int = 4 * 1024 * 1024,
        delegate: SSHCarrierDelegate
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.hostKeyValidator = hostKeyValidator
        self.sessionKind = sessionKind
        self.outboundBudget = SSHOutboundBudget(capacity: max(0, outboundCapacityBytes))
        self.delegate = delegate
    }

    deinit {
        // The group is shut down by stop(); this is the floor under a carrier
        // dropped without one.
        try? eventLoopGroup.syncShutdownGracefully()
    }

    /// The numeric address the carrier's TCP connection reached, once it is
    /// open: the remote end of its socket, with no name in it. Nil before
    /// the transport opens and for an endpoint that is not an IP address.
    public var reachedAddress: String? {
        stateLock.lock()
        let channel = transportChannel
        stateLock.unlock()
        return channel?.remoteAddress?.ipAddress
    }

    /// Whether a credential or pinned host-key gate refused this peer.
    ///
    /// Read before disposing the carrier; ordinary path and I/O errors do not
    /// set it. Callers must not downgrade authentication after a refusal.
    public var peerAuthenticationFailed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return hasPeerAuthenticationFailed
    }

    /// The first reported close, or local cancellation, without raw diagnostic text.
    public var closeClassification: SSHCloseClassification? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return reportedCloseClassification
    }

    private func authenticationRefused() {
        stateLock.lock()
        hasPeerAuthenticationFailed = true
        stateLock.unlock()
    }

    /// Moves the connection to a later milestone and never back, so an event
    /// reported late cannot rewind a connection that has moved on.
    func advancePhase(to next: SSHConnectionPhase) {
        stateLock.withLock {
            if connectionPhase.order < next.order { connectionPhase = next }
        }
    }

    /// Releases whatever this connection's sign-in holds on the person.
    private func endSignIn() {
        let authentication = stateLock.withLock { authenticationDelegate }
        authentication?.endSignIn()
    }

    /// Queued bytes remain counted until the SSH child accepts their writes.
    public var pendingOutboundBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return outboundBudget.byteCount
    }

    /// The maximum admitted bytes, including writes awaiting completion.
    public var outboundCapacityBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return outboundBudget.capacity
    }

    /// Begins connecting. Answers through the delegate, never inline.
    ///
    /// - Returns: False only for a local setup error, in which case no delegate
    ///   callback ever fires.
    @discardableResult
    public func start() -> Bool {
        stateLock.lock()
        if hasStarted || hasStopped {
            stateLock.unlock()
            return hasStarted && !hasStopped
        }
        hasStarted = true
        stateLock.unlock()

        // Waiting for activity is what keeps a connect alive across a path
        // that is not usable yet. Without it Network.framework's first
        // waiting state ends the connect, which is the BSD-socket behaviour
        // this transport replaces.
        let bootstrap = NIOTSConnectionBootstrap(group: eventLoopGroup)
            .connectTimeout(Self.connectTimeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: true)
            .tcpOptions(Self.tcpOptions())
            .channelInitializer { [self] channel in
                let authentication = SSHUserAuthenticationDelegate(
                    username: self.username,
                    host: self.host,
                    credentials: self.credentials,
                    signInBegan: { [weak self] in self?.advancePhase(to: .signingIn) },
                    authenticationRefused: { [weak self] in self?.authenticationRefused() }
                )
                self.stateLock.withLock { self.authenticationDelegate = authentication }
                let configuration = SSHClientConfiguration(
                    userAuthDelegate: authentication,
                    serverAuthDelegate: SSHHostKeyValidationDelegate(
                        validator: self.hostKeyValidator,
                        authenticationRefused: { [weak self] in self?.authenticationRefused() }
                    )
                )
                return self.installHandlers(on: channel, configuration: configuration, authentication: authentication)
            }

        bootstrap.connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    self.stateLock.lock()
                    self.transportChannel = channel
                    self.stateLock.unlock()
                    self.advancePhase(to: .transportOpen)
                    self.withDelegate { $0.sshCarrierDidOpenTransport(self) }
                    self.openSession(on: channel)
                case .failure(let error):
                    self.finish(
                        isFailure: true,
                        reason: Self.describe(error),
                        reachFailure: self.reachFailureOfFailedConnect(error)
                    )
                }
            }
        return true
    }

    /// Reads why the connect failed, preferring what it waited on.
    ///
    /// A connect that waited until its budget ran out fails with a timeout,
    /// which says nothing the waiting state did not say better: a host with no
    /// route, or a name that does not resolve, is where the person should look.
    private func reachFailureOfFailedConnect(_ error: Error) -> SSHReachFailure? {
        let reached = Self.reachFailure(of: error)
        guard reached == .timedOut else { return reached }
        stateLock.lock()
        let waitedOn = lastWaitingFailure
        stateLock.unlock()
        return waitedOn ?? reached
    }

    /// Reports that the connect is waiting for a usable path.
    ///
    /// - Parameter error: What the last attempt failed with.
    /// - Returns: Whether to keep waiting. False means the carrier has already
    ///   reported its close, and the caller closes the channel.
    func connectIsWaiting(after error: NWError) -> Bool {
        let failure = Self.reachFailure(of: error)
        stateLock.lock()
        lastWaitingFailure = failure
        let delegate = self.delegate
        stateLock.unlock()
        guard let delegate, !delegate.sshCarrier(self, shouldKeepWaitingAfter: failure) else { return true }
        finish(isFailure: true, reason: Self.describe(error), reachFailure: failure)
        return false
    }

    /// The TCP options every carrier connects with.
    ///
    /// Keepalive probes an idle link, which is what tells a session that its
    /// path died while the app was away: without it nothing is sent until a
    /// keystroke, and that write takes minutes to time out. Fifteen idle
    /// seconds, then three probes five seconds apart, report a dead link in
    /// about half a minute.
    static func tcpOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.enableKeepalive = true
        options.keepaliveIdle = 15
        options.keepaliveInterval = 5
        options.keepaliveCount = 3
        return options
    }

    /// How long a connect may wait for a usable path and an answer.
    ///
    /// Long enough for an on-demand VPN or a waking radio to come up, and
    /// shorter than the 30-second deadline a QUIC bootstrap runs under, so the
    /// carrier's typed failure is what reaches the person rather than the
    /// deadline's.
    static let connectTimeout = TimeAmount.seconds(25)

    /// Reads why a connect never reached its host, from the error it failed
    /// with.
    ///
    /// Network.framework reports a failed attempt as an `NWError`: a POSIX
    /// code for the connect itself, or a DNS service error for the lookup.
    ///
    /// - Parameter error: The error the connect failed with.
    /// - Returns: The failure, or nil when the error says nothing about
    ///   reaching the host.
    public static func reachFailure(of error: Error) -> SSHReachFailure? {
        if let failure = error as? NWError {
            switch failure {
            case .posix(let code):
                return .system(errorCode: code.rawValue)
            case .dns:
                return .nameNotResolved
            default:
                return nil
            }
        }
        if let failure = error as? IOError {
            return .system(errorCode: failure.errnoCode)
        }
        if let failure = error as? ChannelError, case .connectTimeout = failure {
            return .timedOut
        }
        return nil
    }

    /// Puts this carrier's handlers on a channel, in the order they must run.
    ///
    /// Built through `syncOperations` inside `makeCompletedFuture` rather than
    /// `pipeline.addHandlers`: NIOSSHHandler declares its Sendable conformance
    /// unavailable, so handing one to addHandlers sends a non-Sendable value
    /// across an isolation boundary. syncOperations runs on the event loop the
    /// channel already belongs to, so nothing crosses and nothing needs to be
    /// Sendable.
    ///
    /// The order is the contract, and the compiler cannot check it. NIOSSHHandler
    /// comes first because it turns bytes into SSH events; the error handler
    /// sits behind it so it sees what the SSH layer could not handle rather
    /// than raw transport bytes. Both orders compile and both connect — the
    /// wrong one surfaces as a carrier that misses errors, which reads as a
    /// flaky network rather than a wiring bug. `handlerNamesForTesting` is what
    /// holds that order down.
    ///
    /// - Parameters:
    ///   - channel: The channel being initialised.
    ///   - configuration: The client configuration for this connection.
    /// - Returns: A future that fails if the pipeline refuses a handler.
    func installHandlers(
        on channel: Channel,
        configuration: SSHClientConfiguration,
        authentication: SSHUserAuthenticationDelegate? = nil
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers(
                self.orderedHandlers(for: channel, configuration: configuration, authentication: authentication)
            )
        }
    }

    /// The handlers this carrier installs, front of the pipeline first.
    ///
    /// Separate from installing them so the order is a value a test can read.
    /// NIO adds an array front-to-back, so this list is the pipeline order, and
    /// it is the half that can regress: a rewrite reorders the literal, not
    /// NIO's contract.
    ///
    /// - Parameters:
    ///   - channel: The channel whose allocator the SSH handler takes.
    ///   - configuration: The client configuration for this connection.
    ///   - authentication: The sign-in delegate inside `configuration`, which
    ///     reads the banners and the success NIOSSH raises as events.
    /// - Returns: The handlers, in the order they must run.
    func orderedHandlers(
        for channel: Channel,
        configuration: SSHClientConfiguration,
        authentication: SSHUserAuthenticationDelegate? = nil
    ) -> [ChannelHandler] {
        [
            NIOSSHHandler(
                role: .client(configuration),
                allocator: channel.allocator,
                inboundChildChannelInitializer: nil
            ),
            SSHConnectionErrorHandler(carrier: self, authentication: authentication),
        ]
    }

    /// Queues bytes toward the remote's stdin. Never blocks the caller.
    ///
    /// - Parameter bytes: Copied before the call returns.
    public func send(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        stateLock.lock()
        guard !hasStopped, !hasReportedClose, !hasOutboundOverflowed, !hasLocalFailureScheduled else {
            stateLock.unlock()
            return
        }
        guard outboundBudget.admit(bytes.count) else {
            hasOutboundOverflowed = true
            stateLock.unlock()
            eventLoopGroup.next()
                .execute { [self] in
                    finish(isFailure: true, reason: "The SSH outbound queue exceeded its bounded capacity.")
                    closeTransport()
                }
            return
        }

        var buffer = byteAllocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        pendingOutbound.append(OutboundWrite(data: data, byteCount: bytes.count))
        let channel = isSessionReady && !isOutboundDrainScheduled ? sessionChannel : nil
        if channel != nil { isOutboundDrainScheduled = true }
        stateLock.unlock()
        if let channel { channel.eventLoop.execute { [self] in flushPendingOutbound(on: channel) } }
    }

    /// Refuses further writes and reports a local error on the carrier's loop.
    ///
    /// - Parameter reason: A bounded diagnostic copied before return.
    public func fail(reason: String) {
        stateLock.lock()
        guard !hasStopped, !hasReportedClose, !hasLocalFailureScheduled else {
            stateLock.unlock()
            return
        }
        hasLocalFailureScheduled = true
        var detail = String(reason.prefix(1024))
        while detail.utf8.count > 1024 { detail.removeLast() }
        eventLoopGroup.next()
            .execute { [self, detail] in
                finish(isFailure: true, reason: detail)
                closeTransport()
            }
        stateLock.unlock()
    }

    /// Stops requesting reads on the SSH child, which also withholds further
    /// SSH receive-window credit.
    ///
    /// Remembered while the child is still opening.
    public func suspendReading() { setReadingSuspended(true) }

    /// Resumes the child and drains bytes held under its receive-window bound.
    public func resumeReading() { setReadingSuspended(false) }

    private func setReadingSuspended(_ suspended: Bool) {
        stateLock.lock()
        isReadingSuspended = suspended
        let channel = hasStopped || hasReportedClose ? nil : sessionChannel
        stateLock.unlock()
        if let channel {
            if channel.eventLoop.inEventLoop {
                applyReadingState(on: channel)
            } else {
                channel.eventLoop.execute { [self] in applyReadingState(on: channel) }
            }
        }
    }

    private func applyReadingState(on channel: Channel) {
        stateLock.lock()
        let isRunning = !hasStopped && !hasReportedClose
        let suspended = isReadingSuspended
        stateLock.unlock()
        guard isRunning else { return }
        channel.setOption(ChannelOptions.autoRead, value: !suspended)
            .whenComplete { [self] result in
                switch result {
                case .success:
                    // SSHChildChannel's autoRead setter changes only its flag;
                    // a resumed child needs an explicit read to consume its queue.
                    if !suspended { channel.read() }
                case .failure(let error):
                    finish(error: error)
                    closeTransport()
                }
            }
    }

    private func closeTransport() {
        stateLock.lock()
        let channel = transportChannel
        stateLock.unlock()
        channel?.close(promise: nil)
    }

    /// Propagates a client resize as an SSH `window-change` request.
    ///
    /// A no-op for an exec session, which allocated no pseudo-terminal.
    ///
    /// - Parameters:
    ///   - columns: The new width in cells.
    ///   - rows: The new height in cells.
    public func setWindowSize(columns: Int, rows: Int) {
        stateLock.lock()
        latestColumns = columns
        latestRows = rows
        let sessionChannel = self.sessionChannel
        let isRunning = !hasStopped
        stateLock.unlock()
        guard isRunning, case .shell = sessionKind, let sessionChannel else { return }

        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        sessionChannel.eventLoop.execute {
            sessionChannel.triggerUserOutboundEvent(request, promise: nil)
        }
    }

    /// Closes the carrier and quiesces it.
    ///
    /// Blocks until the event loop group has shut down, so no delegate callback
    /// can be in flight or begin once this returns — the guarantee the C++
    /// Driver contract rests on. Never call it from the carrier's own loop.
    public func stop() {
        stateLock.lock()
        if hasStopped {
            stateLock.unlock()
            return
        }
        hasStopped = true
        if !hasReportedClose { reportedCloseClassification = .cancelled }
        pendingOutbound.removeAll()
        outboundBudget.discard()
        // Dropped before the loop winds down so a callback racing this sees no
        // delegate rather than a delegate the caller may be about to release.
        delegate = nil
        let transportChannel = self.transportChannel
        stateLock.unlock()

        endSignIn()
        transportChannel?.close(promise: nil)
        try? eventLoopGroup.syncShutdownGracefully()
        hasShutDownGroup = true
    }

    // MARK: - Session establishment

    private func openSession(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    self.finish(error: error)
                case .success(let sshHandler):
                    let promise = channel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
                        // Same syncOperations rationale as installHandlers above:
                        // the initializer already runs on childChannel's own
                        // event loop, so construction and installation cross no
                        // isolation boundary and SSHSessionHandler needs no
                        // Sendable conformance.
                        childChannel.eventLoop.makeCompletedFuture {
                            try childChannel.pipeline.syncOperations.addHandler(SSHSessionHandler(carrier: self))
                        }
                    }
                    promise.futureResult.whenComplete { result in
                        switch result {
                        case .failure(let error):
                            self.finish(error: error)
                        case .success(let sessionChannel):
                            self.requestSession(on: sessionChannel)
                        }
                    }
                }
            }
    }

    private func requestSession(on sessionChannel: Channel) {
        stateLock.lock()
        self.sessionChannel = sessionChannel
        let columns = latestColumns
        let rows = latestRows
        stateLock.unlock()

        let started: EventLoopFuture<Void>
        switch sessionKind {
        case .shell(let term):
            let terminalRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: term,
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            started = sessionChannel.triggerUserOutboundEvent(terminalRequest)
                .flatMap {
                    sessionChannel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
                }
        case .exec(let command):
            started = sessionChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        }

        started.whenComplete { result in
            switch result {
            case .failure(let error):
                self.finish(error: error)
            case .success:
                self.stateLock.lock()
                self.isSessionReady = true
                self.connectionPhase = .sessionOpen
                self.stateLock.unlock()
                self.applyReadingState(on: sessionChannel)
                self.flushPendingOutbound(on: sessionChannel)
                self.withDelegate { $0.sshCarrierDidConnect(self) }
            }
        }
    }

    private func flushPendingOutbound(on sessionChannel: Channel) {
        stateLock.lock()
        let queued = pendingOutbound
        pendingOutbound.removeAll()
        isOutboundDrainScheduled = false
        let isRunning = !hasStopped && !hasReportedClose && !hasLocalFailureScheduled
        stateLock.unlock()
        guard isRunning else { return }
        for write in queued {
            let promise = sessionChannel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [self] result in
                stateLock.lock()
                if !hasStopped && !hasReportedClose { outboundBudget.complete(write.byteCount) }
                stateLock.unlock()
                if case .failure(let error) = result {
                    finish(error: error)
                    closeTransport()
                }
            }
            sessionChannel.write(write.data, promise: promise)
        }
        if !queued.isEmpty {
            sessionChannel.flush()
        }
    }

    // MARK: - Delivery

    func deliver(_ buffer: ByteBuffer, isStandardError: Bool) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            withDelegate { delegate in
                if isStandardError {
                    delegate.sshCarrier(self, didReceiveStandardError: raw)
                } else {
                    delegate.sshCarrier(self, didReceive: raw)
                }
            }
        }
    }

    /// Reports a typed transport or SSH failure while retaining its raw diagnostic.
    func finish(error: Error) {
        stateLock.lock()
        let phase = connectionPhase
        stateLock.unlock()
        let classification = classifySSHClose(.failure, error: error, phase: phase)
        let reachFailure: SSHReachFailure?
        if case .reachFailure(let failure) = classification { reachFailure = failure } else { reachFailure = nil }
        finish(isFailure: true, reason: Self.describe(error), reachFailure: reachFailure, classification: classification)
    }

    /// Reports a channel that ended without the remote session's exit status.
    func finishUnexpectedClose() {
        stateLock.lock()
        let phase = connectionPhase
        stateLock.unlock()
        finish(
            isFailure: true,
            reason: Self.lostConnectionSentence,
            classification: classifySSHClose(.unexpectedClose, phase: phase)
        )
    }

    func finish(isFailure: Bool, reason: String, reachFailure: SSHReachFailure? = nil, classification: SSHCloseClassification? = nil) {
        stateLock.lock()
        if hasReportedClose || hasStopped {
            stateLock.unlock()
            return
        }
        hasReportedClose = true
        reportedCloseClassification = classification ?? (isFailure ? reachFailure.map { .reachFailure($0) } ?? .otherFailure : .normal)
        pendingOutbound.removeAll()
        outboundBudget.discard()
        let delegate = self.delegate
        stateLock.unlock()
        endSignIn()
        delegate?.sshCarrier(self, didCloseWithFailure: isFailure, reason: reason, reachFailure: reachFailure)
    }

    // Runs `body` against the delegate if the carrier still has one. The lock is
    // released first: a delegate that answers by calling back into send() would
    // otherwise deadlock on a non-recursive lock.
    private func withDelegate(_ body: (SSHCarrierDelegate) -> Void) {
        stateLock.lock()
        let delegate = self.delegate
        stateLock.unlock()
        guard let delegate else { return }
        body(delegate)
    }

    /// What a person reads when the link to the host died under a session.
    static let lostConnectionSentence = "The connection to the host was lost."

    /// Renders an error as a line for the diagnostic log.
    ///
    /// `localizedDescription` is reached only for a type that actually supplies
    /// one. For every other Swift error it produces "The operation couldn't be
    /// completed. (Module.Type error 0.)" — a sentence naming the ORDINAL of a
    /// case, which is what a failed connection showed instead of why it failed.
    /// Every error crossing this seam is a NIO or transport type, so
    /// `String(describing:)` is the form that carries the case and its payload.
    ///
    /// - Parameter error: The error to render.
    /// - Returns: The original stack description, not a user-facing summary.
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    // MARK: - State

    private let host: String
    private let port: Int
    private let username: String
    private let credentials: SSHAuthentication
    private let hostKeyValidator: SSHHostKeyValidator
    private let sessionKind: SSHSessionKind

    private let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
    private let byteAllocator = ByteBufferAllocator()

    // Guards everything below. Held only for field access, never across a
    // delegate callback or a channel write.
    private let stateLock = NSLock()
    private weak var delegate: SSHCarrierDelegate?
    private var transportChannel: Channel?
    private var sessionChannel: Channel?
    private struct OutboundWrite {
        let data: SSHChannelData
        let byteCount: Int
    }

    private var pendingOutbound: [OutboundWrite] = []
    private var outboundBudget: SSHOutboundBudget
    private var isOutboundDrainScheduled = false
    private var hasOutboundOverflowed = false
    private var hasLocalFailureScheduled = false
    private var isSessionReady = false
    private var isReadingSuspended = false
    private var latestColumns = 80
    private var latestRows = 24
    private var hasStarted = false
    private var hasStopped = false
    private var hasShutDownGroup = false
    private var hasReportedClose = false
    private var reportedCloseClassification: SSHCloseClassification?
    private var connectionPhase = SSHConnectionPhase.connecting
    private var lastWaitingFailure: SSHReachFailure?
    private var hasPeerAuthenticationFailed = false
    private var authenticationDelegate: SSHUserAuthenticationDelegate?
}

// Extracts the host key's wire encoding and hands the decision to the validator.
// The only host-key logic in this package: serialising the key. What the bytes
// mean is Core's.
final class SSHHostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate {
    init(
        validator: @escaping SSHHostKeyValidator,
        authenticationRefused: @escaping @Sendable () -> Void = {}
    ) {
        self.validator = validator
        self.authenticationRefused = authenticationRefused
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // NIOSSH keeps its wire serialiser internal and exposes it only through
        // the OpenSSH string form, "algorithm base64-wire-key". The base64 half
        // is the encoding `known_hosts` stores and `ssh-keygen -lf` digests, so
        // decoding it yields exactly the bytes Core must fingerprint.
        let openSSHForm = String(openSSHPublicKey: hostKey)
        guard let encodedKey = openSSHForm.split(separator: " ").dropFirst().first,
            let keyData = Data(base64Encoded: String(encodedKey))
        else {
            authenticationRefused()
            validationCompletePromise.fail(SSHCarrierError.hostKeyUnreadable)
            return
        }
        do {
            try validator([UInt8](keyData))
            validationCompletePromise.succeed(())
        } catch {
            authenticationRefused()
            validationCompletePromise.fail(error)
        }
    }

    private let validator: SSHHostKeyValidator
    private let authenticationRefused: @Sendable () -> Void
}

// Surfaces a transport-level failure (a dropped TCP connection, a failed key
// exchange) that no child channel would otherwise report.
final class SSHConnectionErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    init(carrier: SSHCarrier, authentication: SSHUserAuthenticationDelegate? = nil) {
        self.carrier = carrier
        self.authentication = authentication
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let banner = event as? NIOUserAuthBannerEvent {
            authentication?.receiveBanner(banner.message)
        } else if event is UserAuthSuccessEvent {
            authentication?.endSignIn()
            carrier?.advancePhase(to: .signedIn)
        }
        if let waiting = event as? NIOTSNetworkEvents.WaitingForConnectivity,
            let carrier, !carrier.connectIsWaiting(after: waiting.transientError)
        {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        carrier?.finish(error: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Reached only when the session never reported its end: a remote that
        // exits says so first, and that report is the clean close.
        carrier?.finishUnexpectedClose()
        context.fireChannelInactive()
    }

    private weak var carrier: SSHCarrier?
    private let authentication: SSHUserAuthenticationDelegate?
}

// Carries one session's bytes in both directions.
final class SSHSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    init(carrier: SSHCarrier) {
        self.carrier = carrier
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        // Tested against the stdout case rather than the error one: anything
        // that is not the session's own stream is diagnostic output, and the
        // terminal must never take it for terminal bytes.
        carrier?.deliver(buffer, isStandardError: channelData.type != .channel)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The remote exited: a clean end of session, whatever its status or
        // the signal that ended it. Remembered rather than reported, because
        // NIOSSH fires a channel request the moment it is parsed while the
        // data that preceded it on the wire waits in the child channel for the
        // next read. An exec whose output, exit status and close arrive in one
        // segment would otherwise close before its output: a QUIC bootstrap
        // read as "no quic_port line" from a daemon that printed one. The
        // child delivers every held read before it goes inactive, so the end
        // is reported there.
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitReason = "remote exited with status \(status.exitStatus)"
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            exitReason = "remote ended by signal \(signal.signalName)"
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        carrier?.finish(error: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A session going away without an exit status went away with the
        // link: the shell may still be running on the host.
        if let exitReason {
            carrier?.finish(isFailure: false, reason: exitReason)
        } else {
            carrier?.finishUnexpectedClose()
        }
        context.fireChannelInactive()
    }

    private weak var carrier: SSHCarrier?
    /// How the remote said it ended, held until the channel's last read.
    private var exitReason: String?
}
