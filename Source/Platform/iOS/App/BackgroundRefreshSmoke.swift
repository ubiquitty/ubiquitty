// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security
import UbiquittyCore

/// Checks background authorization, protected persistence, and expiration without opening a host.
enum BackgroundRefreshSmoke {
    @MainActor
    static func run() async -> Bool {
        guard credentialsRemainSeparate() else {
            SmokeLaunch.report("background-refresh: credential isolation failed")
            return false
        }
        guard opaqueCacheRemainsBounded() else {
            SmokeLaunch.report("background-refresh: cache persistence failed")
            return false
        }
        guard await lifetimeCompletesOnce() else {
            SmokeLaunch.report("background-refresh: run lifetime failed")
            return false
        }
        return true
    }

    @MainActor
    private static func credentialsRemainSeparate() -> Bool {
        var host = HostRecord(
            hostName: "refresh.invalid",
            username: "test",
            pinnedHostKeyFingerprint: "SHA256:fixture"
        )
        let secret = "refresh-smoke-\(UUID().uuidString)"
        defer {
            SecretStore.remove(for: host.id)
            BackgroundRefreshSecretStore.remove(for: host.id)
        }
        guard !BackgroundRefreshSecretStore.save(secret, for: host), SecretStore.save(secret, for: host.id) else { return false }
        host.isBackgroundRefreshEnabled = true
        host.backgroundRefreshPermissionID = UUID()
        guard BackgroundRefreshSecretStore.save(secret, for: host), BackgroundRefreshSecretStore.secret(for: host) == secret,
            accessibility("org.ubiquitty.Ubiquitty.host-credential", host.id) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            accessibility("org.ubiquitty.Ubiquitty.background-refresh-credential", host.id)
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                as String
        else {
            SmokeLaunch.report("background-refresh: separate keychain protection failed")
            return false
        }
        var alternatives: [HostRecord] = []
        var changed = host
        changed.hostName = "another.invalid"
        alternatives.append(changed)
        changed = host
        changed.backgroundRefreshPermissionID = UUID()
        alternatives.append(changed)
        changed = host
        changed.port = 2222
        alternatives.append(changed)
        changed = host
        changed.username = "another"
        alternatives.append(changed)
        changed = host
        changed.pinnedHostKeyFingerprint = "SHA256:changed"
        alternatives.append(changed)
        changed = host
        changed.authenticationKind = .privateKey
        alternatives.append(changed)
        changed = host
        changed.isBackgroundRefreshEnabled = false
        alternatives.append(changed)
        changed = host
        changed.pinnedHostKeyFingerprint = ""
        alternatives.append(changed)
        changed = host
        changed.authenticationKind = .passwordPrompt
        alternatives.append(changed)
        guard alternatives.allSatisfy({ BackgroundRefreshSecretStore.secret(for: $0) == nil }),
            !BackgroundRefreshSecretStore.save(secret, for: changed)
        else {
            SmokeLaunch.report("background-refresh: a credential escaped its endpoint, pin, or opt-in")
            return false
        }
        BackgroundRefreshSecretStore.remove(for: host.id)
        guard BackgroundRefreshSecretStore.secret(for: host) == nil, SecretStore.secret(for: host.id) == secret else { return false }
        return true
    }

    private static func accessibility(_ service: String, _ identifier: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier.uuidString,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }

    private static func opaqueCacheRemainsBounded() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = BackgroundRefreshStore(directory: directory)
        let identifier = UUID()
        let authorization = BackgroundRefreshAuthorization(
            hostID: identifier,
            permissionID: UUID(),
            hostName: "refresh.invalid",
            port: 22,
            username: "test",
            fingerprint: "SHA256:fixture",
            authentication: "password"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let record = "opaque \u{0} — 日本語"
            try store.save(record, for: authorization)
            let file = store.directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("record")
            let protection = try file.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
            guard store.load(for: authorization) == record, store.modifiedAt(for: authorization) != nil,
                protection == .completeUntilFirstUserAuthentication,
                try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
            else {
                SmokeLaunch.report(
                    "background-refresh: cache round-trip=\(store.load(for: authorization) == record), "
                        + "modified=\(store.modifiedAt(for: authorization) != nil), "
                        + "protection=\(String(describing: protection)), "
                        + "excluded=\(String(describing: try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup))"
                )
                return false
            }
            try Data(repeating: 65, count: Int(Ubiquitty.Session.BackgroundRefreshState.recordByteLimit()) + 1).write(to: file)
            guard store.load(for: authorization) == nil else { return false }
            try Data([0xff]).write(to: file)
            guard store.load(for: authorization) == nil else { return false }
            store.remove(for: identifier)
            return !FileManager.default.fileExists(atPath: file.path)
        } catch {
            SmokeLaunch.report("background-refresh: protected cache round-trip failed")
            return false
        }
    }

    @MainActor
    private static func lifetimeCompletesOnce() async -> Bool {
        var completions: [Bool] = []
        var cancellations = 0
        var run: BackgroundRefreshRun?
        let success = await withCheckedContinuation { continuation in
            let active = BackgroundRefreshRun(isBackground: true, cancelOperation: { cancellations += 1 }) { result in
                completions.append(result)
                continuation.resume(returning: result)
            }
            run = active
            active.start { true }
        }
        run?.cancel()
        guard success, completions == [true], cancellations == 0 else { return false }

        completions = []
        var ordering: [String] = []
        var hasReturnedFromCancellation = false
        var didObserveCancellation = false
        var stopped: CheckedContinuation<Void, Never>?
        let expired = await withCheckedContinuation { continuation in
            let active = BackgroundRefreshRun(
                isBackground: true,
                cancelOperation: {
                    cancellations += 1
                    ordering.append("cancel")
                }
            ) { result in
                ordering.append("complete")
                completions.append(result)
                continuation.resume(returning: result)
            }
            run = active
            active.start(timeout: .zero) {
                do { try await Task.sleep(for: .seconds(60)) } catch { didObserveCancellation = error is CancellationError }
                hasReturnedFromCancellation = true
                stopped?.resume()
                return true
            }
        }
        if !hasReturnedFromCancellation { await withCheckedContinuation { stopped = $0 } }
        run?.cancel()
        guard !expired, completions == [false], cancellations == 1, ordering == ["cancel", "complete"], didObserveCancellation else {
            SmokeLaunch.report("background-refresh: expiration did not cancel before one completion")
            return false
        }
        var didStartCancelledWork = false
        var earlyResults: [Bool] = []
        let early = BackgroundRefreshRun(isBackground: false, cancelOperation: {}) { earlyResults.append($0) }
        early.cancel()
        early.start {
            didStartCancelledWork = true
            return true
        }
        early.cancel()
        await Task.yield()
        return earlyResults == [false] && !didStartCancelledWork
    }
}
