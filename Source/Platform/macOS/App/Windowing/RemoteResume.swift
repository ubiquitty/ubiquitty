// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RemoteResume.swift — a remote window's attachment across an app restart.
//
// Core owns the resume record, its proof and its rules (Docs/sync.md §6.9).
// This file owns what is the shell's: which window a record belongs to, the
// protected descriptor that names the client instance and the authenticated
// peer, and where the sealed file lives. The record is sealed with a key in
// the data protection keychain, as the phone's is; a build signed without the
// keychain access group cannot reach it, and keeps nothing across a restart.

import CryptoKit
import Foundation
import OSLog
import Security
internal import UbiquittyRemoteResume
internal import UbiquittyRenderKit

/// One remote window identity's protected resume.
///
/// Prepared before the window attaches: it restores the sealed record, if
/// any, into an owner the window's session adopts, so the stored picture is
/// drawn before the first packet and the first greeting resumes the stored
/// attachment. Every callback runs on the main thread.
@MainActor
package final class RemoteResume {
    /// The protected, per-window-identity metadata: the client instance the
    /// window greets as across launches, and the peer its record was bound
    /// to by an authenticated Welcome.
    struct Descriptor: Codable, Equatable {
        struct Peer: Codable, Equatable {
            let hostLow: UInt64
            let hostHigh: UInt64
            let principal: String
            let certificatePin: Data
            /// Where the QUIC carrier reached the daemon, once a session
            /// connected: what lets the next launch resume with no login.
            var address: String?
            var port: UInt16?
        }

        let version: UInt8
        let clientID: UUID
        var peer: Peer?

        init() {
            version = 1
            clientID = UUID()
        }

        var isValid: Bool {
            guard version == 1 else { return false }
            guard let peer else { return true }
            return (peer.hostLow != 0 || peer.hostHigh != 0) && !peer.principal.isEmpty && peer.principal.utf8.count <= 4096
                && peer.certificatePin.count == 32 && peer.certificatePin.contains(where: { $0 != 0 })
        }

        /// The client instance as Core's two halves, little-endian.
        var clientHalves: (low: UInt64, high: UInt64) {
            let bytes = withUnsafeBytes(of: clientID.uuid) { Array($0) }
            func half(_ start: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[start + $1]) << (8 * $1) } }
            return (half(0), half(8))
        }
    }

    /// Why a window keeps nothing across a restart, said once per process.
    package static let unavailableSentence =
        "Ubiquitty can’t keep remote windows across a restart: this build isn’t signed with a team that can use the protected keychain."

    private static let log = Logger(subsystem: "org.ubiquitty.Ubiquitty", category: "RemoteResume")
    private static var didReportUnavailable = false

    package let identity: String
    private(set) var descriptor: Descriptor
    private var owner: OpaquePointer?

    private init(identity: String, descriptor: Descriptor) {
        self.identity = identity
        self.descriptor = descriptor
    }

    /// The identity of the window an attach names: its transport, the host a
    /// QUIC carrier dials, and its workspace, or the session when it names
    /// no workspace. The same attach after a restart is the same window.
    package static func identity(shellCommand: String, quicHost: String, workspaceName: String, sessionID: UInt32) -> String {
        var material = Data("ubiquitty-remote-window-v1\0".utf8)
        for field in [shellCommand, quicHost, workspaceName, workspaceName.isEmpty ? String(sessionID) : ""] {
            material.append(contentsOf: field.utf8)
            material.append(0)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    /// The client instance the window greets its host as, kept across launches.
    package var clientID: UUID { descriptor.clientID }

    /// Whether the descriptor holds a peer an authenticated Welcome bound.
    package var hasBoundPeer: Bool { descriptor.peer != nil }

    /// Whether the descriptor holds the QUIC reach a resume dials.
    package var hasResumeReach: Bool { descriptor.peer?.port != nil }

    /// The team the running app is signed with, or nil for an ad-hoc or
    /// unsigned build, which cannot reach the protected keychain.
    package static var signingTeamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let values = information as? [String: Any]
        else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Adds and removes one item in the data protection keychain, as the
    /// sealed store does with its key: the probe a signed build is checked by.
    ///
    /// - Returns: The add's status; `errSecSuccess` means the store can keep
    ///   its key, and `errSecMissingEntitlement` that this signature cannot.
    package static func probeProtectedKeychain() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.ubiquitty.macos.remote-resume.probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = Data([1])
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { _ = SecItemDelete(query as CFDictionary) }
        return status
    }

    /// Reads or creates the window's descriptor and restores its record.
    ///
    /// - Parameter identity: The window identity (``identity(shellCommand:quicHost:workspaceName:sessionID:)``).
    /// - Returns: The prepared resume, or nil when protected storage is
    ///   unavailable, which is said once in the log.
    package static func prepare(identity: String) -> RemoteResume? {
        let descriptor: Descriptor
        switch DescriptorStore.read(identity) {
        case .unavailable:
            reportUnavailable()
            return nil
        case .missing:
            descriptor = Descriptor()
            guard DescriptorStore.write(descriptor, for: identity) else {
                reportUnavailable()
                return nil
            }
        case .value(let stored):
            descriptor = stored
        }
        let resume = RemoteResume(identity: identity, descriptor: descriptor)
        resume.prepareOwner()
        return resume
    }

    /// Hands the restored owner, the client instance and the kept reach to
    /// the window's session, before it attaches: the stored picture is drawn
    /// now, and the attach resumes the stored attachment.
    ///
    /// - Parameter drive: The window's session, not yet attached.
    func install(on drive: RuntimeDrive) {
        let halves = descriptor.clientHalves
        drive.setRemoteClientInstance(low: halves.low, high: halves.high)
        if let peer = descriptor.peer, let address = peer.address, let port = peer.port {
            _ = drive.seedRemoteResumeReach(address: address, port: port, pin: peer.certificatePin)
        }
        guard let owner else { return }
        if drive.prepareRemoteResume(
            ownerAddress: ubiquittyMacResumeCoreAddress(owner),
            paneLow: ubiquittyMacResumePreviewLow(owner),
            paneHigh: ubiquittyMacResumePreviewHigh(owner)
        ) {
            self.owner = nil
            ubiquittyMacResumeDestroy(owner)
        }
    }

    /// Keeps the QUIC reach a connected session would resume by, when it is
    /// the peer the record was bound to: the next launch dials it with no
    /// login.
    ///
    /// - Parameter drive: The window's connected session.
    func noteConnected(_ drive: RuntimeDrive) {
        guard var peer = descriptor.peer, let reach = drive.remoteResumeReach, reach.pin == peer.certificatePin,
            peer.address != reach.address || peer.port != reach.port
        else { return }
        peer.address = reach.address
        peer.port = reach.port
        var replacement = descriptor
        replacement.peer = peer
        if DescriptorStore.write(replacement, for: identity) { descriptor = replacement }
    }

    /// Retires the record of a window the person closed, which detached its
    /// attachment and left nothing to resume. The client instance stays, so
    /// the window reopened later is the same client to the host.
    func retire() {
        if let owner {
            self.owner = nil
            ubiquittyMacResumeDestroy(owner)
        }
        guard let path = Self.recordPath(for: descriptor.clientID) else { return }
        let retired = withScope(descriptor) { scope in path.withCString { ubiquittyMacResumeRetire($0, scope) } }
        guard retired else { return }
        var replacement = descriptor
        replacement.peer = nil
        if DescriptorStore.write(replacement, for: identity) { descriptor = replacement }
    }

    /// Restores the record into an owner the session can adopt.
    private func prepareOwner() {
        guard let path = Self.recordPath(for: descriptor.clientID) else { return }
        let retained = Unmanaged.passRetained(Box(self)).toOpaque()
        let hooks = UbiquittyMacResumeHooks(
            context: retained,
            bind: { pointer, low, high, principal, length, pin, pinLength in
                guard let pointer, let principal, let pin, length <= 4096, pinLength == 32,
                    let name = String(data: Data(bytes: principal, count: Int(length)), encoding: .utf8)
                else { return false }
                return MainActor.assumeIsolated {
                    Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue().value?
                        .bind(hostLow: low, hostHigh: high, principal: name, pin: Data(bytes: pin, count: 32)) ?? false
                }
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Box>.fromOpaque(pointer).release()
            }
        )
        owner = withScope(descriptor) { scope in path.withCString { ubiquittyMacResumeCreate($0, scope, hooks) } }
        if owner == nil { Unmanaged<Box>.fromOpaque(retained).release() }
    }

    /// Records the authenticated peer a Welcome bound, before the store
    /// commits a record for it.
    private func bind(hostLow: UInt64, hostHigh: UInt64, principal: String, pin: Data) -> Bool {
        guard !principal.isEmpty, hostLow != 0 || hostHigh != 0 else { return false }
        if let peer = descriptor.peer, peer.hostLow == hostLow, peer.hostHigh == hostHigh, peer.principal == principal,
            peer.certificatePin == pin
        {
            return true
        }
        var replacement = descriptor
        replacement.peer = .init(hostLow: hostLow, hostHigh: hostHigh, principal: principal, certificatePin: pin)
        guard replacement.isValid, DescriptorStore.write(replacement, for: identity) else { return false }
        descriptor = replacement
        return true
    }

    /// A weak handle for the C callbacks, so a closed window does not live on
    /// in the store Core holds.
    private final class Box {
        weak var value: RemoteResume?
        init(_ value: RemoteResume) { self.value = value }
    }

    private static func reportUnavailable() {
        guard !didReportUnavailable else { return }
        didReportUnavailable = true
        log.notice("\(unavailableSentence, privacy: .public)")
    }

    /// Hands the descriptor's sealing scope to `use`.
    private func withScope<Result>(_ descriptor: Descriptor, _ use: (UbiquittyMacResumeIdentity) -> Result) -> Result {
        let principal = descriptor.peer.map { Data(SHA256.hash(data: Data($0.principal.utf8))) } ?? Data(repeating: 0, count: 32)
        let pin = descriptor.peer?.certificatePin ?? Data(repeating: 0, count: 32)
        let halves = descriptor.clientHalves
        return principal.withUnsafeBytes { digest in
            pin.withUnsafeBytes { certificate in
                use(
                    UbiquittyMacResumeIdentity(
                        clientLow: halves.low,
                        clientHigh: halves.high,
                        hostLow: descriptor.peer?.hostLow ?? 0,
                        hostHigh: descriptor.peer?.hostHigh ?? 0,
                        principalDigest: digest.bindMemory(to: UInt8.self).baseAddress,
                        certificatePin: certificate.bindMemory(to: UInt8.self).baseAddress,
                        digestLength: digest.count,
                        pinLength: certificate.count
                    )
                )
            }
        }
    }

    /// The sealed record's file: in a private directory under Application
    /// Support, or under the UI-test keychain directory when a test names one.
    private static func recordPath(for clientID: UUID) -> String? {
        guard let directory = privateDirectory() else { return nil }
        return directory.appendingPathComponent(clientID.uuidString).appendingPathExtension("sealed").path
    }

    private static func privateDirectory() -> URL? {
        let parent: URL
        if let test = DescriptorStore.testDirectory {
            parent = test
        } else {
            guard
                let support = try? FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            else { return nil }
            parent = support.appendingPathComponent("Ubiquitty", isDirectory: true)
        }
        let directory = parent.appendingPathComponent("RemoteResume", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let kind = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard kind.isSymbolicLink == false, kind.isDirectory == true else { return nil }
        } catch {
            return nil
        }
        return directory
    }
}

/// Where a window's descriptor is kept: the data protection keychain, with
/// no weaker fallback.
@MainActor
enum DescriptorStore {
    enum Read {
        case missing
        case value(RemoteResume.Descriptor)
        case unavailable
    }

    private static let service = "org.ubiquitty.macos.remote-resume.v1"

    /// The UI-test keychain directory, when a test run names one; see
    /// `ResumeTestKeychain` in the sealing layer, which reads the same name.
    static var testDirectory: URL? {
        #if UBIQUITTY_UI_TESTS
        if let path = ProcessInfo.processInfo.environment["UBIQUITTY_RESUME_TEST_KEYCHAIN"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return nil
    }

    static func read(_ identity: String) -> Read {
        let bytes: Data
        if let directory = testDirectory {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(service)-\(identity)")) else { return .missing }
            bytes = data
        } else {
            var request = query(identity)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &item)
            if status == errSecItemNotFound { return .missing }
            guard status == errSecSuccess, let data = item as? Data else { return .unavailable }
            bytes = data
        }
        // A descriptor that does not read back is replaced, as a missing one is.
        guard bytes.count <= maxBytes, let descriptor = try? JSONDecoder().decode(RemoteResume.Descriptor.self, from: bytes),
            descriptor.isValid
        else { return .missing }
        return .value(descriptor)
    }

    static func write(_ descriptor: RemoteResume.Descriptor, for identity: String) -> Bool {
        guard descriptor.isValid, let bytes = try? JSONEncoder().encode(descriptor), bytes.count <= maxBytes else { return false }
        if let directory = testDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let file = directory.appendingPathComponent("\(service)-\(identity)")
                try bytes.write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return true
            } catch {
                return false
            }
        }
        let request = query(identity)
        let updated = SecItemUpdate(request as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var insert = request
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecValueData as String] = bytes
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private static let maxBytes = 16384

    private static func query(_ identity: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
