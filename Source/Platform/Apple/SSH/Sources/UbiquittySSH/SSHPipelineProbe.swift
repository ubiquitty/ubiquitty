// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import NIOCore
import NIOEmbedded
import NIOSSH

/// A delegate that records only how the carrier closed.
///
/// The probes build a pipeline and drive it by hand; none opens a session, so
/// the close is the one callback that can run. It exists because the carrier's
/// delegate is not optional, which is the right shape for the real thing.
private final class SilentDelegate: SSHCarrierDelegate, @unchecked Sendable {
    var closedAsFailure: Bool?
    func sshCarrierDidConnect(_ carrier: SSHCarrier) {}
    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {}
    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {}
    func sshCarrier(
        _ carrier: SSHCarrier,
        didCloseWithFailure isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure?
    ) {
        closedAsFailure = isFailure
    }
}

/// What `installHandlers` actually puts on a channel, and in what order.
///
/// The pipeline is built for its side effect, which is the hardest kind of code
/// to hold still: every arrangement of these two handlers compiles, and every
/// arrangement connects. A carrier with the error handler in front sees raw
/// transport bytes instead of the events the SSH layer could not handle, and
/// then misses failures — which presents as an unreliable network rather than
/// as a wiring mistake, and gets blamed accordingly.
///
/// So the order is read back from a real pipeline rather than asserted about
/// the source. An EmbeddedChannel runs the same code the connection path runs,
/// on a loop that needs no network.
public enum SSHPipelineProbe {
    /// The handlers `installHandlers` adds, named in pipeline order.
    ///
    /// - Returns: The type names, front of the pipeline first, or nil when the
    ///   pipeline refused them.
    public static func handlerNamesForTesting() -> [String]? {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        // Held in a named binding: the carrier's delegate reference is weak,
        // so an inline instance is gone before the next statement runs.
        let silentDelegate = SilentDelegate()
        let carrier = SSHCarrier(
            host: "probe.invalid",
            port: 22,
            username: "probe",
            credentials: [],
            hostKeyValidator: { _ in },
            sessionKind: .shell(term: "xterm-256color"),
            delegate: silentDelegate
        )
        let configuration = SSHClientConfiguration(
            userAuthDelegate: SSHUserAuthenticationDelegate(username: "probe", credentials: []),
            serverAuthDelegate: SSHHostKeyValidationDelegate(validator: { _ in })
        )
        // The list the carrier hands to addHandlers, in its own order. NIO adds
        // an array front-to-back, so this list is the pipeline order itself.
        //
        // Asking the pipeline instead looks stronger and is weaker: its public
        // lookup answers "is a handler of this type present", with no position,
        // so a probe built on it reports whatever order the probe's own lines
        // are written in, and passes with the handlers reversed.
        let ordered = carrier.orderedHandlers(for: channel, configuration: configuration)
        // Installed as well as listed, so a list that no longer reaches the
        // pipeline fails here rather than reading correct.
        do {
            try withExtendedLifetime(silentDelegate) {
                try carrier.installHandlers(on: channel, configuration: configuration).wait()
            }
        } catch {
            return nil
        }
        return ordered.map { String(describing: type(of: $0)) }
    }

    /// Whether a pipeline that cannot accept handlers reports a failure.
    ///
    /// `makeCompletedFuture` turns a synchronous throw into a failed future,
    /// and a caller that ignored the difference would hang rather than fail:
    /// `connect` would never complete and the session would sit "Connecting…"
    /// forever.
    ///
    /// A FINISHED channel is what refuses, not a closed one. Closing an
    /// EmbeddedChannel leaves its pipeline willing to take handlers, so a probe
    /// built on close() passes whatever the code does — measured, after writing
    /// that probe first and watching it report success against a pipeline that
    /// had accepted everything.
    ///
    /// - Returns: Whether the future failed rather than succeeding or hanging.
    public static func setupFailureIsReportedForTesting() -> Bool {
        let channel = EmbeddedChannel()
        _ = try? channel.finish()
        // Held in a named binding: the carrier's delegate reference is weak,
        // so an inline instance is gone before the next statement runs.
        let silentDelegate = SilentDelegate()
        let carrier = SSHCarrier(
            host: "probe.invalid",
            port: 22,
            username: "probe",
            credentials: [],
            hostKeyValidator: { _ in },
            sessionKind: .shell(term: "xterm-256color"),
            delegate: silentDelegate
        )
        let configuration = SSHClientConfiguration(
            userAuthDelegate: SSHUserAuthenticationDelegate(username: "probe", credentials: []),
            serverAuthDelegate: SSHHostKeyValidationDelegate(validator: { _ in })
        )
        return withExtendedLifetime(silentDelegate) {
            do {
                try carrier.installHandlers(on: channel, configuration: configuration).wait()
                return false
            } catch {
                return true
            }
        }
    }
}

/// The connect facts a carrier reports, read without a network.
public enum SSHConnectProbe {
    /// Exercises only the accounting value; no carrier, thread, or socket is created.
    public static func outboundBudgetIsBoundedForTesting() -> Bool {
        var budget = SSHOutboundBudget(capacity: 4 * 1024 * 1024)
        guard budget.admit(budget.capacity), !budget.admit(1), !budget.admit(0), !budget.admit(-1) else { return false }
        budget.complete(budget.capacity)
        guard budget.byteCount == 0, budget.writeCount == 0 else { return false }
        for _ in 0..<SSHOutboundBudget.maximumWrites {
            guard budget.admit(1) else { return false }
        }
        guard !budget.admit(1), budget.byteCount == SSHOutboundBudget.maximumWrites else { return false }
        budget.complete(1)
        guard budget.admit(1) else { return false }
        budget.discard()
        return budget.byteCount == 0 && budget.writeCount == 0 && budget.admit(budget.capacity)
    }

    /// The connect budget the carrier dials with, in whole seconds.
    public static var connectTimeoutSecondsForTesting: Int64 {
        SSHCarrier.connectTimeout.nanoseconds / 1_000_000_000
    }

    /// Whether the carrier's TCP connection probes an idle link, and after
    /// how many idle seconds.
    public static var keepaliveForTesting: (isEnabled: Bool, idleSeconds: Int) {
        let options = SSHCarrier.tcpOptions()
        return (options.enableKeepalive, options.keepaliveIdle)
    }

    /// What a connect that ran out of time reports as its reach failure.
    public static func reachFailureOfAnElapsedConnectForTesting() -> SSHReachFailure? {
        SSHCarrier.reachFailure(of: ChannelError.connectTimeout(SSHCarrier.connectTimeout))
    }
}

extension SSHConnectProbe {
    /// Whether a session channel that went away is reported as a failure.
    ///
    /// Drives the carrier's own session handler on an EmbeddedChannel: the
    /// remote's exit status arrives or not, then the channel goes inactive,
    /// which is what both a shell that exited and a link that died look like
    /// from inside the session.
    ///
    /// - Parameter afterExitStatus: Whether the remote reported an exit status
    ///   before the channel went away.
    /// - Returns: Whether the close was reported as a failure, or nil when no
    ///   close was reported.
    public static func closeIsFailureForTesting(afterExitStatus: Bool) -> Bool? {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let delegate = SilentDelegate()
        let carrier = SSHCarrier(
            host: "probe.invalid",
            port: 22,
            username: "probe",
            credentials: [],
            hostKeyValidator: { _ in },
            sessionKind: .shell(term: "xterm-256color"),
            delegate: delegate
        )
        return withExtendedLifetime(delegate) {
            do {
                try channel.pipeline.syncOperations.addHandler(SSHSessionHandler(carrier: carrier))
            } catch {
                return nil
            }
            if afterExitStatus {
                channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
            }
            channel.pipeline.fireChannelInactive()
            return delegate.closedAsFailure
        }
    }
}

/// A delegate that records the order of what the carrier reports.
private final class OrderRecordingDelegate: SSHCarrierDelegate, @unchecked Sendable {
    var events: [String] = []
    func sshCarrierDidConnect(_ carrier: SSHCarrier) {}
    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {
        events.append("output:" + String(decoding: bytes, as: UTF8.self))
    }
    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {}
    func sshCarrier(
        _ carrier: SSHCarrier,
        didCloseWithFailure isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure?
    ) {
        events.append(isFailure ? "close:failure" : "close:clean")
    }
}

extension SSHConnectProbe {
    /// What an exec session reports when its exit status overtakes its output.
    ///
    /// NIOSSH's child channel fires a channel request as soon as it is parsed
    /// and holds channel data until the next read, so an exec whose output,
    /// exit status and close share one segment hands the session handler the
    /// exit status first, then the output, then the inactive channel. This
    /// drives the carrier's session handler through that order.
    ///
    /// - Returns: The carrier's reports in order, `output:<text>` and
    ///   `close:clean` or `close:failure`, or nil when the handler was refused.
    public static func reportsWhenExitStatusOvertakesOutputForTesting() -> [String]? {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let delegate = OrderRecordingDelegate()
        let carrier = SSHCarrier(
            host: "probe.invalid",
            port: 22,
            username: "probe",
            credentials: [],
            hostKeyValidator: { _ in },
            sessionKind: .exec(command: "probe"),
            delegate: delegate
        )
        return withExtendedLifetime(delegate) {
            do {
                try channel.pipeline.syncOperations.addHandler(SSHSessionHandler(carrier: carrier))
            } catch {
                return nil
            }
            channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
            let line = channel.allocator.buffer(string: "quic_port=1\n")
            channel.pipeline.syncOperations.fireChannelRead(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(line))))
            channel.pipeline.fireChannelInactive()
            return delegate.events
        }
    }
}
