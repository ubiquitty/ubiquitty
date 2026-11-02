// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittySSH

/// Carries one passive Core control request over a separately authenticated SSH exec channel.
@MainActor
final class BackgroundRefreshConnection: SSHCarrierDelegate {
    enum Failure: Error { case unavailable, invalidReply, connectionClosed }

    private let host: HostRecord
    private let credentials: SSHAuthentication
    private var client: OpaquePointer?
    private var carrier: SSHCarrier?
    private var continuation: CheckedContinuation<String, any Error>?
    private var hasFinished = false
    private nonisolated let incoming = IncomingBudget()

    init?(host: HostRecord, secret: String) {
        guard !host.pinnedHostKeyFingerprint.isEmpty, host.isComplete else { return nil }
        self.host = host
        // Nobody is there to ask, so only what is saved is offered, and only
        // for a method the server lists.
        switch host.savedCredential {
        case .password:
            credentials = [.password(secret)]
        case .privateKey:
            guard case .key(let key) = SSHPrivateKeyText.read(secret) else { return nil }
            credentials = [.privateKey(key)]
        case .none:
            return nil
        }
    }

    /// Runs the Core request, propagating task cancellation into carrier teardown.
    func request(_ request: String) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !hasFinished, continuation == nil else { throw Failure.unavailable }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                installClient()
                guard let client, request.withCString({ ubiquittyIOSControlClientStart(client, $0) }) else {
                    finish(.failure(Failure.unavailable))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Ends an expired or superseded operation exactly once.
    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func installClient() {
        var driver = UbiquittyIOSCarrierDriver()
        driver.context = Unmanaged.passRetained(self).toOpaque()
        driver.start = { context in
            MainActor.assumeIsolated { BackgroundRefreshConnection.owner(context).startCarrier() }
        }
        driver.send = { context, bytes, count in
            MainActor.assumeIsolated {
                BackgroundRefreshConnection.owner(context).carrier?.send(UnsafeRawBufferPointer(start: bytes, count: count))
            }
        }
        driver.stop = { context in
            MainActor.assumeIsolated { BackgroundRefreshConnection.owner(context).stopCarrier() }
        }
        driver.release = { context in
            guard let context else { return }
            Unmanaged<BackgroundRefreshConnection>.fromOpaque(context).release()
        }
        var observer = UbiquittyIOSControlObserver()
        observer.context = Unmanaged.passRetained(self).toOpaque()
        observer.onAnswer = { context, bytes, count in
            MainActor.assumeIsolated {
                guard let bytes, let answer = String(bytes: UnsafeRawBufferPointer(start: bytes, count: count), encoding: .utf8) else {
                    BackgroundRefreshConnection.owner(context).finish(.failure(Failure.invalidReply))
                    return
                }
                BackgroundRefreshConnection.owner(context).finish(.success(answer))
            }
        }
        observer.onFailure = { context, _, _ in
            MainActor.assumeIsolated { BackgroundRefreshConnection.owner(context).finish(.failure(Failure.connectionClosed)) }
        }
        observer.release = driver.release
        client = ubiquittyIOSControlClientCreate(driver, observer)
    }

    private static func owner(_ context: UnsafeMutableRawPointer?) -> BackgroundRefreshConnection {
        Unmanaged<BackgroundRefreshConnection>.fromOpaque(context!).takeUnretainedValue()
    }

    private func startCarrier() -> Bool {
        let count = ubiquittyIOSControlRemoteCommand(nil, 0)
        guard count > 0 else { return false }
        var bytes = [CChar](repeating: 0, count: count)
        let copied = bytes.withUnsafeMutableBufferPointer { ubiquittyIOSControlRemoteCommand($0.baseAddress, $0.count) }
        guard copied == count else { return false }
        let command = String(decoding: bytes.map(UInt8.init(bitPattern:)), as: UTF8.self)
        let pinned = host.pinnedHostKeyFingerprint
        let carrier = SSHCarrier(
            host: host.hostName,
            port: host.port,
            username: host.username,
            credentials: credentials,
            hostKeyValidator: { key in
                let fingerprint = key.withUnsafeBufferPointer { SSHCarrierClient.hostKeyFingerprint(of: $0) }
                let verdict = pinned.withCString { expected in
                    fingerprint.withCString { ubiquittyIOSVerifyHostKeyFingerprint(expected, $0) }
                }
                guard verdict == 1 else { throw SSHCarrierError.hostKeyMismatched }
            },
            sessionKind: .exec(command: command),
            delegate: self
        )
        self.carrier = carrier
        return carrier.start()
    }

    private func stopCarrier() {
        let stopped = carrier
        carrier = nil
        DispatchQueue.global(qos: .utility).async { stopped?.stop() }
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        let stopped = client
        client = nil
        if let stopped { ubiquittyIOSControlClientDestroy(stopped) }
        stopCarrier()
        let completion = continuation
        continuation = nil
        completion?.resume(with: result)
    }

    nonisolated func sshCarrierDidConnect(_ carrier: SSHCarrier) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let client = self?.client else { return }
                ubiquittyIOSControlClientNotifyConnect(client)
            }
        }
    }

    nonisolated func sshCarrier(_ carrier: SSHCarrier, didReceive bytes: UnsafeRawBufferPointer) {
        switch incoming.admit(bytes.count) {
        case .alreadyRefused:
            return
        case .firstRefusal:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finish(.failure(Failure.invalidReply)) }
            }
            return
        case .admitted:
            break
        }
        let data = Data(bytes)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let client = self?.client else { return }
                data.withUnsafeBytes { bytes in
                    let buffer = bytes.bindMemory(to: UInt8.self)
                    ubiquittyIOSControlClientDeliver(client, buffer.baseAddress, buffer.count)
                }
            }
        }
    }

    nonisolated func sshCarrier(_ carrier: SSHCarrier, didReceiveStandardError bytes: UnsafeRawBufferPointer) {}

    nonisolated func sshCarrier(_ carrier: SSHCarrier, shouldKeepWaitingAfter reachFailure: SSHReachFailure?) -> Bool { false }

    nonisolated func sshCarrier(_ carrier: SSHCarrier, didCloseWithFailure isFailure: Bool, reason: String, reachFailure: SSHReachFailure?)
    {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let client = self?.client else { return }
                let outcome = isFailure ? UbiquittyIOSCarrierOutcomeFailed : UbiquittyIOSCarrierOutcomeClosed
                reason.withCString { ubiquittyIOSControlClientNotifyClose(client, outcome, $0) }
            }
        }
    }
}

/// Bounds bytes awaiting main-actor delivery even when a peer sends faster than the UI queue.
private final class IncomingBudget: @unchecked Sendable {
    enum Admission { case admitted, firstRefusal, alreadyRefused }
    private let lock = NSLock()
    private var remaining = Int(Ubiquitty.Session.BackgroundRefreshState.recordByteLimit())
    private var hasRefused = false

    func admit(_ count: Int) -> Admission {
        lock.withLock {
            guard !hasRefused else { return .alreadyRefused }
            guard count <= remaining else {
                hasRefused = true
                return .firstRefusal
            }
            remaining -= count
            return .admitted
        }
    }
}
