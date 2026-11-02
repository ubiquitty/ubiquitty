// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The saved configuration and actual credential that authorize one cold read.
/// Display names, theme choices and shell commands confer no authority.
struct ColdResumeTarget: Codable, Equatable {
    let hostID: UUID
    let endpoint: String
    let port: Int
    let username: String
    let authentication: String
    let credentialDigest: Data
    let hostKeyFingerprint: String
    let workspace: String
    /// Absent is the same safe opt-out as a newly installed configuration.
    var shouldPersistHistory: Bool? = nil
}

/// Metadata is protected independently of the encrypted picture and its key.
/// A committed retirement remains a denial after a process replacement.
struct ColdResumeDescriptor: Codable, Equatable {
    enum State: String, Codable { case ready, retirementRequired }
    struct Peer: Codable, Equatable {
        let hostLow: UInt64
        let hostHigh: UInt64
        let principal: String
        let certificatePin: Data
        let address: String
        let port: UInt16
        /// The socket accepted by this peer's authenticated Welcome. Older
        /// records may attempt their pinned QUIC proof, but cannot invent an
        /// owner for a Sync-over-SSH fallback.
        var daemonSocketName: String? = nil

        var hasValidDaemonSocketName: Bool {
            guard let daemonSocketName else { return true }
            return !daemonSocketName.isEmpty && daemonSocketName.utf8.count <= Int(UInt16.max)
                && daemonSocketName.utf8.allSatisfy { byte in
                    (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                        || (byte >= 48 && byte <= 57) || byte == 46 || byte == 95 || byte == 45
                }
        }
    }

    let version: UInt8
    let target: ColdResumeTarget
    let clientID: UUID
    var state: State
    var peer: Peer?

    init(target: ColdResumeTarget) {
        version = 1
        self.target = target
        clientID = UUID()
        state = .ready
    }

    var isValid: Bool {
        guard version == 1, target.credentialDigest.count == 32,
            !target.username.isEmpty, !target.hostKeyFingerprint.isEmpty,
            !target.workspace.isEmpty, target.workspace.utf8.count <= 4096
        else { return false }
        guard let peer else { return true }
        return (peer.hostLow != 0 || peer.hostHigh != 0) && !peer.principal.isEmpty
            && peer.principal.utf8.count <= 4096 && peer.certificatePin.count == 32
            && peer.certificatePin.contains(where: { $0 != 0 }) && !peer.address.isEmpty && peer.port != 0
            && peer.hasValidDaemonSocketName
    }

    var clientHalves: (low: UInt64, high: UInt64) {
        let bytes = withUnsafeBytes(of: clientID.uuid) { Array($0) }
        func half(_ start: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(bytes[start + $1]) << (8 * $1) }
        }
        return (half(0), half(8))
    }
}

/// Security operations are injectable; production never substitutes a file or
/// weaker accessibility when protected Keychain access is unavailable.
protocol ColdResumeSecurity {
    func read(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
}

struct SystemColdResumeSecurity: ColdResumeSecurity {
    func read(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        return (SecItemCopyMatching(query as CFDictionary, &result), result)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

struct ColdResumeDescriptors {
    enum Read {
        case missing
        case value(ColdResumeDescriptor)
        case refused
    }
    let security: any ColdResumeSecurity
    static let maxBytes = 16384

    init(security: any ColdResumeSecurity = SystemColdResumeSecurity()) { self.security = security }

    private func query(_ hostID: UUID) -> [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.ubiquitty.Ubiquitty.cold-resume-descriptor.v1",
            kSecAttrAccount as String: hostID.uuidString,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authentication,
        ]
    }

    func read(_ hostID: UUID) -> Read {
        var request = query(hostID)
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = security.read(request)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let attributes = item as? [String: Any],
            attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            attributes[kSecAttrSynchronizable as String] as? Bool == false,
            let bytes = attributes[kSecValueData as String] as? Data, bytes.count <= Self.maxBytes,
            let record = try? JSONDecoder().decode(ColdResumeDescriptor.self, from: bytes),
            record.isValid, record.target.hostID == hostID
        else { return .refused }
        return .value(record)
    }

    /// Replaces a validated protected item without deleting it first. A failed
    /// replacement leaves the prior committed policy authoritative.
    func write(_ record: ColdResumeDescriptor) -> Bool {
        guard record.isValid, let bytes = try? JSONEncoder().encode(record), bytes.count <= Self.maxBytes else { return false }
        let request = query(record.target.hostID)
        switch read(record.target.hostID) {
        case .refused: return false
        case .missing:
            var insert = request
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insert[kSecValueData as String] = bytes
            let result = security.add(insert)
            if result == errSecSuccess { return true }
            guard result == errSecDuplicateItem, case .value = read(record.target.hostID) else { return false }
        case .value: break
        }
        return security.update(request, attributes: [kSecValueData as String: bytes]) == errSecSuccess
    }

    /// Commits denial before the caller accepts a target or credential edit.
    /// Missing means there is no protected identity to retire. Unavailable
    /// storage is not missing and must prevent the edit.
    func requireRetirement(_ hostID: UUID) -> Bool {
        switch read(hostID) {
        case .missing: return true
        case .refused: return false
        case .value(var record):
            if record.state == .retirementRequired { return true }
            record.state = .retirementRequired
            return write(record)
        }
    }
}
