// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CxxStdlib
import Foundation
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittySSH

/// An existing daemon's Sync stream over a pinned native SSH exec channel.
///
/// The command and session identity come from Core; this adapter opens no PTY.
final class SyncSSHCarrier: SSHCarrierDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let username: String
    private let credentials: SSHAuthentication
    private let pinnedFingerprint: String
    private let command: String
    private let noteDiagnostic: @Sendable (String) -> Void
    private let capacity = Int(ubiquittyIOSSyncCarrierRequiredOutboundCapacity())
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var carrier: SSHCarrier?
    private var hasStopped = false
    private var hasAuthenticationFailed = false
    private var diagnostic = ""

    init(record: HostRecord, credentials: SSHAuthentication, command: String, noteDiagnostic: @escaping @Sendable (String) -> Void) {
        host = record.hostName
        port = record.port
        username = record.username
        pinnedFingerprint = record.pinnedHostKeyFingerprint
        self.credentials = credentials
        self.command = command
        self.noteDiagnostic = noteDiagnostic
    }

    /// Transfers this adapter to Core even when the request became stale.
    func complete(_ request: OpaquePointer) {
        var driver = UbiquittyIOSCarrierDriver()
        driver.context = Unmanaged.passRetained(self).toOpaque()
        driver.start = { SyncSSHCarrier.owner($0).start() }
        driver.send = { context, bytes, count in
            SyncSSHCarrier.owner(context).activeCarrier()?.send(UnsafeRawBufferPointer(start: bytes, count: count))
        }
        driver.stop = { SyncSSHCarrier.owner($0).stop() }
        driver.release = { context in
            guard let context else { return }
            Unmanaged<SyncSSHCarrier>.fromOpaque(context).release()
        }
        driver.suspendReading = { SyncSSHCarrier.owner($0).activeCarrier()?.suspendReading() }
        driver.resumeReading = { SyncSSHCarrier.owner($0).activeCarrier()?.resumeReading() }
        driver.pendingOutboundBytes = { Int64(SyncSSHCarrier.owner($0).activeCarrier()?.pendingOutboundBytes ?? 0) }
        driver.outboundCapacityBytes = { Int64(SyncSSHCarrier.owner($0).capacity) }
        driver.peerAuthenticationFailed = { SyncSSHCarrier.owner($0).peerAuthenticationFailed }
        driver.fail = { context, reason in
            guard let reason else { return }
            SyncSSHCarrier.owner(context).activeCarrier()?.fail(reason: String(cString: reason))
        }
        ubiquittyIOSQUICRequestCompleteSSH(request, driver) { context, handle in
            let adapter = SyncSSHCarrier.owner(context)
            adapter.lock.withLock { adapter.handle = handle }
        }
    }

    private static func owner(_ context: UnsafeMutableRawPointer?) -> SyncSSHCarrier {
        guard let context else { preconditionFailure("A native Sync carrier needs its owned context.") }
        return Unmanaged<SyncSSHCarrier>.fromOpaque(context).takeUnretainedValue()
    }

    private func activeCarrier() -> SSHCarrier? {
        lock.withLock { hasStopped ? nil : carrier }
    }

    private var peerAuthenticationFailed: Bool {
        let snapshot = lock.withLock { (hasAuthenticationFailed, carrier) }
        return snapshot.0 || snapshot.1?.peerAuthenticationFailed == true
    }

    private func start() -> Bool {
        // A fallback cannot introduce a trust-on-first-use decision. Its SSH
        // endpoint must be the one already authenticated for this saved host.
        guard !pinnedFingerprint.isEmpty else {
            lock.withLock { hasAuthenticationFailed = true }
            return false
        }
        let pinned = pinnedFingerprint
        let next = SSHCarrier(
            host: host,
            port: port,
            username: username,
            credentials: credentials,
            hostKeyValidator: { key in
                let fingerprint = key.withUnsafeBufferPointer { SSHCarrierClient.hostKeyFingerprint(of: $0) }
                let verdict = pinned.withCString { expected in
                    fingerprint.withCString { ubiquittyIOSVerifyHostKeyFingerprint(expected, $0) }
                }
                guard verdict == 1 else { throw SSHCarrierError.hostKeyMismatched }
            },
            sessionKind: .exec(command: command.withCString { String(Ubiquitty.Transport.remoteShellCommand(std.string_view($0))) }),
            outboundCapacityBytes: capacity,
            delegate: self
        )
        let shouldStart = lock.withLock {
            guard !hasStopped, carrier == nil else { return false }
            carrier = next
            return true
        }
        guard shouldStart else {
            next.stop()
            return false
        }
        return next.start()
    }

    private func stop() {
        let stopped = lock.withLock {
            hasStopped = true
            handle = nil
            let stopped = carrier
            carrier = nil
            return stopped
        }
        // Core's dispatcher owns teardown, never the native carrier's loop.
        // Joining here leaves no callback holding the borrowed C++ handle.
        stopped?.stop()
    }

    func sshCarrierDidConnect(_ carrier: SSHCarrier) {
        guard let handle = lock.withLock({ handle }) else { return }
        ubiquittyIOSSyncCarrierNotifyConnect(handle)
    }

    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {
        guard let handle = lock.withLock({ handle }) else { return }
        let buffer = bytes.bindMemory(to: UInt8.self)
        // Core copies into its bounded inbound queue before this call returns
        // and can pause the SSH receive window on this same I/O thread.
        ubiquittyIOSSyncCarrierDeliver(handle, buffer.baseAddress, buffer.count)
    }

    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {
        lock.withLock {
            let room = max(0, 1024 - diagnostic.utf8.count)
            guard room > 0 else { return }
            diagnostic += String(decoding: bytes.prefix(room), as: UTF8.self)
            while diagnostic.utf8.count > 1024 { diagnostic.removeLast() }
        }
    }

    func sshCarrier(_ carrier: SSHCarrier, shouldKeepWaitingAfter reachFailure: SSHReachFailure?) -> Bool {
        reachFailure?.isWorthWaitingOut ?? true
    }

    func sshCarrier(
        _ carrier: SSHCarrier,
        didCloseWithFailure isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure?
    ) {
        let refused = carrier.peerAuthenticationFailed
        let snapshot = lock.withLock {
            hasAuthenticationFailed = hasAuthenticationFailed || refused
            return (handle, diagnostic)
        }
        guard let handle = snapshot.0 else { return }
        var detail = snapshot.1.isEmpty ? reason : "\(reason): \(snapshot.1)"
        while detail.utf8.count > 1024 { detail.removeLast() }
        noteDiagnostic(detail)
        let readable = SSHFailurePresentation.sentence(
            reason: detail,
            reachFailure: reachFailure,
            classification: carrier.closeClassification,
            host: host,
            port: port
        )
        readable.withCString {
            ubiquittyIOSSyncCarrierNotifyClose(handle, isFailure ? UbiquittyIOSCarrierOutcomeFailed : UbiquittyIOSCarrierOutcomeClosed, $0)
        }
    }
}
