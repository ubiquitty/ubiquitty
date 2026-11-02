// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LocalAuthentication
import Security
import UbiquittyCore

/// Stores an explicitly authorized background credential separately from interactive login.
enum BackgroundRefreshSecretStore {
    private static let service = "org.ubiquitty.Ubiquitty.background-refresh-credential"

    private struct Credential: Codable {
        let authorization: BackgroundRefreshAuthorization
        let secret: String
    }

    /// Copies a saved credential only for an enabled, pinned, noninteractive host.
    static func save(_ secret: String, for host: HostRecord) -> Bool {
        guard let authorization = host.backgroundRefreshAuthorization, !secret.isEmpty,
            let data = try? JSONEncoder()
                .encode(
                    Credential(
                        authorization: authorization,
                        secret: secret
                    )
                )
        else { return false }
        let lookup = query(for: host.id)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(lookup.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    /// Reads only a credential still bound to the saved endpoint and trust pin.
    static func secret(for host: HostRecord) -> String? {
        guard let authorization = host.backgroundRefreshAuthorization else { return nil }
        var lookup = query(for: host.id)
        lookup[kSecReturnData as String] = true
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        // A credential that would need an interactive prompt fails instead.
        let context = LAContext()
        context.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
            let attributes = result as? [String: Any],
            attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            attributes[kSecAttrSynchronizable as String] as? Bool == false,
            let data = attributes[kSecValueData as String] as? Data,
            let credential = try? JSONDecoder().decode(Credential.self, from: data), credential.authorization == authorization
        else { return nil }
        return credential.secret
    }

    /// Revokes background access without changing the interactive credential.
    @discardableResult
    static func remove(for identifier: UUID) -> Bool {
        let status = SecItemDelete(query(for: identifier) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func query(for identifier: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// Persists Core's opaque catch-up record atomically across suspension and termination.
struct BackgroundRefreshStore {
    let directory: URL

    init(directory: URL? = nil) {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = support.appendingPathComponent("BackgroundRefresh", isDirectory: true)
    }

    /// Loads a bounded record without interpreting Core's serialized contents.
    func load(for authorization: BackgroundRefreshAuthorization) -> String? {
        let file = url(for: authorization.hostID)
        let limit = Int(Ubiquitty.Session.BackgroundRefreshState.recordByteLimit())
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + BackgroundRefreshAuthorization.headerLimit + 2) else { return nil }
        return authorization.unframe(data, limit: limit)
    }

    /// Commits accepted state before any corresponding notification is submitted.
    func save(_ record: String, for authorization: BackgroundRefreshAuthorization) throws {
        guard let data = authorization.frame(record, limit: Int(Ubiquitty.Session.BackgroundRefreshState.recordByteLimit())) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var location = directory
        try location.setResourceValues(excluded)
        try data.write(to: url(for: authorization.hostID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Removes cached attention and screen data when a host is revoked or deleted.
    @discardableResult
    func remove(for identifier: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: url(for: identifier))
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    func modifiedAt(for authorization: BackgroundRefreshAuthorization) -> Date? {
        guard load(for: authorization) != nil else { return nil }
        return try? url(for: authorization.hostID).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func url(for identifier: UUID) -> URL {
        directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("record")
    }
}
