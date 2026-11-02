// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The saved host list.
///
/// JSON in Application Support rather than UserDefaults: the list is documents,
/// not preferences, and a person who fills one in expects it to survive rather
/// than to be a cache. Secrets are not in it — see ``SecretStore``.
@Observable
@MainActor
final class HostStore {
    /// The app's one store.
    ///
    /// Every mutator writes the whole list, so a second instance holding an
    /// older read overwrites what the first wrote: the pairing Core stores
    /// through ``rememberedSessionRecord(forKey:)`` would be erased by the next
    /// theme change made through the list's own copy.
    static let shared = HostStore()

    private(set) var hosts: [HostRecord] = []

    private let fileURL: URL

    init() {
        let directory =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ))
            ?? URL.temporaryDirectory
        fileURL = directory.appendingPathComponent("hosts.json")
        load()
    }

    /// Adds a record, or replaces the one with its identifier.
    @discardableResult
    func save(_ record: HostRecord) -> Bool {
        guard ColdResumeSession.retireForConfigurationChange(record) else { return false }
        var record = record
        var didRetire = true
        if let index = hosts.firstIndex(where: { $0.id == record.id }) {
            let previous = hosts[index].backgroundRefreshAuthorization
            if let previous, let proposed = record.backgroundRefreshAuthorization,
                previous.permissionID == proposed.permissionID, !previous.hasSameEndpoint(as: proposed)
            {
                record.isBackgroundRefreshEnabled = false
                record.backgroundRefreshPermissionID = nil
                BackgroundRefreshSecretStore.remove(for: record.id)
            }
            if let previous, previous != record.backgroundRefreshAuthorization {
                didRetire = BackgroundRefreshCoordinator.shared.retire(previous)
            }
            hosts[index] = record
        } else {
            hosts.append(record)
        }
        let didPersist = persist()
        return didRetire && didPersist
    }

    /// Removes records and the secrets that belong to them.
    ///
    /// The keychain entry goes with the record: a credential outliving the host
    /// it was for is a secret nobody can see in order to delete it.
    @discardableResult
    func remove(atOffsets offsets: IndexSet) -> Bool {
        guard offsets.allSatisfy({ hosts.indices.contains($0) && ColdResumeSession.retireBeforeEdit(hosts[$0].id) }) else { return false }
        for index in offsets {
            SecretStore.remove(for: hosts[index].id)
            BackgroundRefreshSecretStore.remove(for: hosts[index].id)
            BackgroundRefreshStore().remove(for: hosts[index].id)
        }
        hosts.remove(atOffsets: offsets)
        return persist()
    }

    /// Records the host key an endpoint offered, once a connection succeeded.
    func pinFingerprint(_ fingerprint: String, for identifier: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == identifier }),
            hosts[index].pinnedHostKeyFingerprint != fingerprint
        else {
            return
        }
        var changed = hosts[index]
        changed.pinnedHostKeyFingerprint = fingerprint
        save(changed)
    }

    /// Remembers that a terminal on this host has just connected.
    ///
    /// Written without ``save(_:)``: the date is not configuration, and a
    /// configuration change retires the host's resumable session.
    ///
    /// - Parameter identifier: The host that connected.
    func noteConnection(for identifier: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == identifier }) else { return }
        hosts[index].lastConnectedAt = .now
        persist()
    }

    /// Remembers the theme a person chose while connected to this host.
    ///
    /// Written on change rather than on leaving the screen: a session that ends
    /// by losing the network never gets a chance to save on the way out, and
    /// the choice would be lost exactly when it was least expected to be.
    ///
    /// - Parameters:
    ///   - name: The theme's name, or empty for Core's default.
    ///   - identifier: The host to remember it against.
    func setThemeName(_ name: String, for identifier: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == identifier }),
            hosts[index].themeName != name
        else {
            return
        }
        hosts[index].themeName = name
        persist()
    }

    /// Remembers the workspace a host connects to.
    ///
    /// The editor writes it through ``save(_:)`` when a person types it. This
    /// is the same field written from elsewhere — the sessions screen, which
    /// learns the name a person attached under from the host's own answer
    /// rather than from the form.
    ///
    /// - Parameters:
    ///   - name: The workspace name, or empty for none.
    ///   - identifier: The host to remember it against.
    func setWorkspace(_ name: String, for identifier: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == identifier }), hosts[index].workspaceName != name else {
            return
        }
        var changed = hosts[index]
        changed.workspaceName = name
        save(changed)
    }

    /// The bytes Core last asked to keep for a host, or nil when there are none.
    ///
    /// The Load half of ``Ubiquitty::Session::RememberedSessions``'s persistence
    /// seam. The bytes are not read here: what they mean is Core's, and a store
    /// that parsed them would be a second reader to keep in step with the one
    /// that wrote them.
    ///
    /// - Parameter hostKey: The host, as ``HostRecord/pairingKey`` spells it.
    /// - Returns: The record's bytes, or nil for a host with no pairing.
    func rememberedSessionRecord(forKey hostKey: String) -> Data? {
        guard let record = hosts.first(where: { $0.pairingKey == hostKey }),
            !record.rememberedSessionRecord.isEmpty
        else {
            return nil
        }
        return Data(base64Encoded: record.rememberedSessionRecord)
    }

    /// Keeps the bytes Core asked to keep for a host.
    ///
    /// The Store half of the same seam. Empty bytes are a host to forget, which
    /// is how Core spells "this pairing is gone" — so they are written as an
    /// empty string rather than skipped, or a forgotten host would keep
    /// reattaching to a session that ended.
    ///
    /// - Parameters:
    ///   - bytes: The record, or empty to forget the host.
    ///   - hostKey: The host, as ``HostRecord/pairingKey`` spells it.
    func setRememberedSessionRecord(_ bytes: Data, forKey hostKey: String) {
        guard let index = hosts.firstIndex(where: { $0.pairingKey == hostKey }) else { return }
        let encoded = bytes.isEmpty ? "" : bytes.base64EncodedString()
        guard hosts[index].rememberedSessionRecord != encoded else { return }
        hosts[index].rememberedSessionRecord = encoded
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([HostRecord].self, from: data)
        else {
            return
        }
        hosts = decoded
    }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(hosts) else { return false }
        // Written without the complete-file-protection option the credentials
        // get: this file holds no secret, and a list a person cannot read back
        // while the phone is locked is a list that fails to open at a glance.
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}
