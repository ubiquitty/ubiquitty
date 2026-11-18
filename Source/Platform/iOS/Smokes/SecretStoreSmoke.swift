// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SecretStoreSmoke.swift — the keychain round trip, through the store the app
// uses.
//
// A credential that saves but does not read back fails at connect time, with
// the editor long dismissed and the connection log naming a keychain miss it
// cannot explain. Every call between the editor and that miss is silent — the
// save's Bool is the only answer the keychain gives — so the round trip needs
// a leg of its own: whatever this simulator's keychain refuses or loses, this
// is the place that says so, with the raw status codes the store's interface
// reduces to a Bool.

import Foundation
import Security

/// The `--smoke-secret-store` leg: save, read back, remove, through
/// `SecretStore` itself.
enum SecretStoreSmokeEntry {
    /// Runs the round trip and reports the first step that breaks it.
    ///
    /// - Returns: Whether a secret saved, read back byte-identical, and was
    ///   gone after removal.
    @MainActor
    static func run() -> Bool {
        let identifier = UUID()
        let secret = "smoke-secret-\(identifier.uuidString)"
        defer { SecretStore.remove(for: identifier) }

        guard SecretStore.save(secret, for: identifier) else {
            SmokeLaunch.report(
                "smoke-secret-store: the save was refused; raw add answers \(rawAddStatus(secret, identifier))"
            )
            return false
        }
        guard let read = SecretStore.secret(for: identifier) else {
            SmokeLaunch.report(
                "smoke-secret-store: the saved secret did not read back; raw copy answers \(rawCopyStatus(identifier))"
            )
            return false
        }
        guard read == secret else {
            SmokeLaunch.report(
                "smoke-secret-store: the read secret differs — sent \(secret.utf8.count) bytes, got \(read.utf8.count)"
            )
            return false
        }
        SecretStore.remove(for: identifier)
        guard SecretStore.secret(for: identifier) == nil else {
            SmokeLaunch.report("smoke-secret-store: a removed secret still reads back")
            return false
        }
        return true
    }

    /// The OSStatus of a raw `SecItemAdd` with the store's own attributes,
    /// for the failure report only — the verdict is the store's.
    ///
    /// - Parameters:
    ///   - secret: The value whose save was refused.
    ///   - identifier: The record the store filed it under.
    /// - Returns: The status, as its numeric value.
    private static func rawAddStatus(_ secret: String, _ identifier: UUID) -> OSStatus {
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.ubiquitty.Ubiquitty.host-credential",
            kSecAttrAccount as String: identifier.uuidString,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(insert as CFDictionary, nil)
    }

    /// The OSStatus of a raw `SecItemCopyMatching` with the store's own
    /// attributes, for the failure report only.
    ///
    /// - Parameter identifier: The record whose secret did not read back.
    /// - Returns: The status, as its numeric value.
    private static func rawCopyStatus(_ identifier: UUID) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.ubiquitty.Ubiquitty.host-credential",
            kSecAttrAccount as String: identifier.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }
}
