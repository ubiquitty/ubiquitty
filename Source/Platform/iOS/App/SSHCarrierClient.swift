// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyIOSBridge
import UbiquittySSH

/// The SSH connection behind one terminal, as a byte pipe.
///
/// Nothing here knows what a terminal is. Bytes arrive and are handed on; bytes
/// are handed in and go out. What parses them is Core, reached through the
/// surface — so this file has no model, no grid and no policy in it beyond the
/// host-key verdict, which it asks Core for rather than deciding.
final class SSHCarrierClient: SSHCarrierDelegate, @unchecked Sendable {
    /// Called on the carrier's own thread with bytes from the remote.
    var onBytes: ((UnsafeRawBufferPointer) -> Void)?
    /// Called on the carrier's own thread when the host is reached, before
    /// the handshake and sign-in.
    var onTransportOpen: (() -> Void)?
    /// Called on the carrier's own thread when the link opens.
    var onConnect: (() -> Void)?
    /// Called on the carrier's own thread when the link finishes, with why
    /// the host was never reached when that is what failed.
    var onClose:
        ((_ isFailure: Bool, _ reason: String, _ reachFailure: SSHReachFailure?, _ classification: SSHCloseClassification?) -> Void)?

    /// The fingerprint the server offered, recorded during validation so a
    /// caller can pin it only once a connection actually succeeded.
    private(set) var presentedFingerprint: String {
        get { lock.withLock { fingerprint } }
        set { lock.withLock { fingerprint = newValue } }
    }
    private var fingerprint = ""

    private let host: String
    private let port: Int
    private let username: String
    private let credentials: SSHAuthentication
    private let pinnedFingerprint: String
    private let terminalType: String

    private let lock = NSLock()
    private var carrier: SSHCarrier?

    init(
        host: String,
        port: Int,
        username: String,
        credentials: SSHAuthentication,
        pinnedFingerprint: String,
        terminalType: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.pinnedFingerprint = pinnedFingerprint
        self.terminalType = terminalType
    }

    /// Opens the connection. Answers through the callbacks, never inline.
    @discardableResult
    func start() -> Bool {
        let pinned = pinnedFingerprint
        let validator: SSHHostKeyValidator = { [weak self] keyBytes in
            let fingerprint = keyBytes.withUnsafeBufferPointer { Self.hostKeyFingerprint(of: $0) }
            self?.presentedFingerprint = fingerprint
            // Core's verdict, so this frontend pins by the same rule as the
            // ones that still spawn `ssh`. Unknown is trust-on-first-use, which
            // is the app's policy to allow; mismatched is never re-pinned from.
            let verdict = fingerprint.withCString { presented in
                pinned.withCString { ubiquittyIOSVerifyHostKeyFingerprint($0, presented) }
            }
            if verdict == 2 {
                throw SSHCarrierError.hostKeyMismatched
            }
        }
        let carrier = SSHCarrier(
            host: host,
            port: port,
            username: username,
            credentials: credentials,
            hostKeyValidator: validator,
            sessionKind: .shell(term: terminalType),
            delegate: self
        )
        lock.lock()
        self.carrier = carrier
        lock.unlock()
        return carrier.start()
    }

    /// Queues bytes toward the remote's stdin.
    func send(_ bytes: UnsafeRawBufferPointer) {
        lock.lock()
        let carrier = self.carrier
        lock.unlock()
        carrier?.send(bytes)
    }

    /// Carries a client resize as an SSH window-change request.
    func setWindowSize(columns: Int, rows: Int) {
        lock.lock()
        let carrier = self.carrier
        lock.unlock()
        carrier?.setWindowSize(columns: columns, rows: rows)
    }

    /// Closes the connection and quiesces it.
    func stop() {
        lock.lock()
        let carrier = self.carrier
        self.carrier = nil
        lock.unlock()
        carrier?.stop()
    }

    /// The SHA-256 fingerprint of a presented host key, in Core's spelling.
    ///
    /// Shared with the QUIC bootstrap probe, which opens its own connection to
    /// the same host and must judge the key by the same rule — a probe that
    /// trusted more freely would be a second, laxer front door.
    static func hostKeyFingerprint(of keyBytes: UnsafeBufferPointer<UInt8>) -> String {
        guard let base = keyBytes.baseAddress, !keyBytes.isEmpty else { return "" }
        let needed = ubiquittyIOSHostKeyFingerprint(base, keyBytes.count, nil, 0)
        guard needed > 0 else { return "" }
        var storage = [CChar](repeating: 0, count: needed + 1)
        _ = storage.withUnsafeMutableBufferPointer {
            ubiquittyIOSHostKeyFingerprint(base, keyBytes.count, $0.baseAddress, needed)
        }
        // The bridge writes exactly `needed` bytes ahead of the terminator, so
        // the decode takes that prefix rather than scanning for the NUL.
        return String(decoding: storage.prefix(needed).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    // MARK: - SSHCarrierDelegate

    func sshCarrierDidOpenTransport(_ carrier: SSHCarrier) {
        onTransportOpen?()
    }

    func sshCarrierDidConnect(_ carrier: SSHCarrier) {
        onConnect?()
    }

    func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {
        onBytes?(bytes)
    }

    func sshCarrier(_ carrier: SSHCarrier, shouldKeepWaitingAfter reachFailure: SSHReachFailure?) -> Bool {
        reachFailure?.isWorthWaitingOut ?? true
    }

    func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {
        // A shell session allocates a pseudo-terminal, so the remote merges its
        // own stderr into the stream above. Anything arriving here belongs to
        // the transport, and feeding it to the parser would render a diagnostic
        // as though the shell had printed it.
    }

    func sshCarrier(
        _ carrier: SSHCarrier,
        didCloseWithFailure isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure?
    ) {
        onClose?(isFailure, reason, reachFailure, carrier.closeClassification)
    }
}
