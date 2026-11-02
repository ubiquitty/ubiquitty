// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// The keychain, holding one secret per host record.
///
/// Passwords and private keys are the only things this app stores that would
/// matter if the file store leaked, so they are the only things that go here —
/// the host list itself is ordinary data and lives as JSON beside it.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on purpose: a terminal
/// credential should not ride a backup to another device, and nothing here can
/// be used while the phone is locked anyway.
enum SecretStore {
    private static let service = "org.ubiquitty.Ubiquitty.host-credential"

    /// Stores or replaces the secret for a record.
    ///
    /// - Returns: Whether the keychain accepted it.
    @discardableResult
    @MainActor
    static func save(_ secret: String, for identifier: UUID) -> Bool {
        if self.secret(for: identifier) != secret, !ColdResumeSession.retireBeforeEdit(identifier) { return false }
        guard let encoded = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = encoded
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the secret for a record, or nil when there is none.
    static func secret(for identifier: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the secret for a record. Absent is success.
    @MainActor
    static func remove(for identifier: UUID) {
        guard ColdResumeSession.retireBeforeEdit(identifier) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
