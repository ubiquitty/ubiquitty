// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// HostServers.swift — the saved Ubiquitty hosts the Connect window lists:
// a named row per host, added and removed with + and − beneath the list.
// Selecting one fills the form.
//
// Persisted in UserDefaults beside ConnectRecents, which is where this app
// already keeps the non-secret half of a connection. Nothing here is a
// credential: a host string and the workspace the human named.
//

import Foundation
import UbiquittyKit

import struct UbiquittyRenderKit.HostDaemonInstance

/// What a saved host connects with.
enum HostKind: String, CaseIterable, Identifiable {
    /// A `ubiquitty-host` daemon: sessions that outlive their windows.
    case ubiquittyHost
    /// A native ssh shell.
    case ssh
    /// A roaming mosh shell.
    case mosh
    /// tmux control mode through ssh.
    case remoteTmux
    /// A serial device on this Mac.
    case serial

    var id: String { rawValue }

    /// What the inspector's Connect With menu calls the kind.
    var title: String {
        switch self {
        case .ubiquittyHost: "Ubiquitty Host"
        case .ssh: "SSH Shell"
        case .mosh: "mosh Shell"
        case .remoteTmux: "tmux over SSH"
        case .serial: "Serial"
        }
    }

    /// The kind's symbol in the sidebar.
    var symbol: String {
        switch self {
        case .ubiquittyHost: "bolt.horizontal.circle"
        case .ssh: "terminal"
        case .mosh: "antenna.radiowaves.left.and.right"
        case .remoteTmux: "square.split.2x2"
        case .serial: "cable.connector"
        }
    }
}

/// One saved host.
struct HostServer: Identifiable, Hashable {
    /// A discovered running owner, used for this visit rather than saved as a host.
    var daemonInstance: HostDaemonInstance?
    /// The row's stable identity, kept across renames so a selection survives
    /// an edit of the name it was made on.
    let id: UUID
    /// What the human calls this host.
    var name: String
    /// What a connect dials: `local` for this Mac's daemon, `[user@]host`
    /// otherwise; empty for a serial host.
    var host: String
    /// What it connects with.
    var kind: HostKind = .ubiquittyHost
    /// The workspace every connect to this host attaches under, empty when it
    /// names none. A name makes the connect attach-or-create and never shows
    /// the session list — Core's rule, not this file's.
    var workspaceName: String
    /// The tmux session a tmux-over-SSH host attaches to; blank is Core's
    /// default.
    var tmuxSession = ""
    /// The device a serial host opens.
    var device = ""
    /// The serial line rate.
    var baudRate: Int32 = 115200
    /// Whether an ssh shell forwards the agent.
    var shouldForwardAgent = false
    /// The locale policy a shell runs under, as `ConnectCharacterLocalePolicy`'s raw value.
    var localePolicy = 0

    init(
        id: UUID,
        name: String,
        host: String,
        kind: HostKind = .ubiquittyHost,
        workspaceName: String,
        tmuxSession: String = "",
        device: String = "",
        baudRate: Int32 = 115200,
        shouldForwardAgent: Bool = false,
        localePolicy: Int = 0
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.kind = kind
        self.workspaceName = workspaceName
        self.tmuxSession = tmuxSession
        self.device = device
        self.baudRate = baudRate
        self.shouldForwardAgent = shouldForwardAgent
        self.localePolicy = localePolicy
    }

    /// Whether this is this Mac's own daemon.
    var isLocal: Bool { host == "local" }

    /// Whether this row connects exactly as the This Mac row does: this Mac's
    /// daemon, naming no session of its own.
    ///
    /// Such a row is the same host listed twice, with the same sessions and the
    /// same count, so the sidebar folds it into This Mac. A local row that
    /// names a session is a different connect and stays.
    var isThisMacDuplicate: Bool { kind == .ubiquittyHost && isLocal && workspaceName.isEmpty }

    /// The key the remembered connect/session pairing is filed under.
    ///
    /// The host string rather than the row's name or its id: two saved rows for
    /// one host are one host to the daemon, and a pairing keyed by the row
    /// would offer the same session twice under two names.
    var pairingKey: String { host }

    /// What a row and a window title call this host.
    ///
    /// The name the human gave it, falling back to what a connect dials: a row
    /// that showed an empty name would be a row nothing distinguishes from the
    /// next blank one.
    var displayName: String { name.isEmpty ? (kind == .serial ? device : host) : name }

    /// This host with the fields its kind does not use cleared, so a pairing
    /// key or a device from another kind never survives a change of kind.
    ///
    /// - Parameter kind: The new kind.
    /// - Returns: The host.
    func changingKind(to kind: HostKind) -> HostServer {
        var changed = self
        changed.kind = kind
        if kind != .ubiquittyHost {
            changed.workspaceName = ""
        }
        if kind != .remoteTmux {
            changed.tmuxSession = ""
        }
        if kind == .serial {
            changed.host = ""
        } else {
            changed.device = ""
            if changed.isLocal, kind != .ubiquittyHost {
                changed.host = ""
            }
        }
        if kind != .ssh {
            changed.shouldForwardAgent = false
        }
        return changed
    }
}

/// The saved hosts, as the Connect window reads and writes them.
enum HostServers {
    private static let defaultsKey = "UBHostServers"

    /// Every saved host, in the order the human arranged them.
    static func all() -> [HostServer] {
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]] ?? []
        return stored.compactMap(server(from:))
    }

    /// Replaces the whole list.
    ///
    /// Whole rather than per-row: the list is short, the window edits it as a
    /// list, and a per-row write would need a merge rule for a row two windows
    /// changed at once — which this store has no way to arbitrate.
    ///
    /// - Parameter servers: The list to keep.
    static func save(_ servers: [HostServer]) {
        UserDefaults.standard.set(servers.map(dictionary(for:)), forKey: defaultsKey)
    }

    /// The saved row for a host string, or nil when none was saved for it.
    ///
    /// Matched on the host verbatim rather than on the row's name, because the
    /// host is the pairing key: a row found under a differently-spelled host
    /// would carry a workspace name into a connect Core remembers under another
    /// key, and the next connect would recall neither.
    ///
    /// - Parameter host: What a connect dials.
    /// - Returns: The first row naming that host.
    static func saved(forHost host: String) -> HostServer? {
        all().first { $0.host == host }
    }

    /// A row nothing has been typed into.
    ///
    /// The loopback daemon rather than ssh: it is the one host every Mac has,
    /// and a new row that opened on ssh would be a row that cannot connect
    /// until something is typed.
    ///
    /// - Returns: The row, with an identity of its own.
    static func blank() -> HostServer {
        HostServer(id: UUID(), name: "", host: "local", workspaceName: "")
    }

    /// A remote row, for the Add Host sheet to open with.
    ///
    /// - Parameter host: The address, empty for none typed yet.
    /// - Returns: The row, with an identity of its own.
    static func blankRemote(host: String = "") -> HostServer {
        HostServer(id: UUID(), name: "", host: host, workspaceName: "")
    }

    /// Hands Core this store as the place a host-to-session pairing, and the
    /// list of hosts trusted to receive a push, are kept.
    ///
    /// The Load and Store halves of ``UbiquittyKit/HostDirectory``'s persistence
    /// seam over the defaults this file already writes. The bytes are never read
    /// here: what a record means is Core's, and a store that parsed one would be
    /// a second reader to keep in step with the writer.
    ///
    /// Keyed by ``HostServer/pairingKey`` rather than by a saved row, so a host
    /// typed once and never saved is remembered too — and so two saved rows
    /// naming one machine share the one session the daemon has for it.
    ///
    /// Installed once per process rather than per caller: Core borrows the
    /// context the closures live in, so a second install replaces a box the
    /// first one is still pointing at, and every window that could open a
    /// remembered session calls this before it does.
    ///
    /// Main-actor, because the flag guarding the one install is: a connect is
    /// made from a window and a directory errand runs on the main thread, so a
    /// second actor asking would be a second install racing the first.
    @MainActor
    static func installPairingPersistence() {
        guard !isPairingPersistenceInstalled else {
            return
        }
        isPairingPersistenceInstalled = true
        HostDirectory.setPersistence(
            load: { hostKey in
                guard let encoded = pairingRecords()[hostKey], let bytes = Data(base64Encoded: encoded) else {
                    return nil
                }
                return [UInt8](bytes)
            },
            store: { hostKey, bytes in
                var records = pairingRecords()
                // Empty bytes are how Core spells a host to forget, so the row
                // goes rather than being written empty: a record that decoded to
                // nothing would still be a record, and the next connect would
                // read it as a pairing.
                if bytes.isEmpty {
                    records.removeValue(forKey: hostKey)
                } else {
                    records[hostKey] = Data(bytes).base64EncodedString()
                }
                UserDefaults.standard.set(records, forKey: pairingsKey)
            }
        )
        TerminalWindowController.installDeployTrustPersistence()
    }

    /// Whether ``installPairingPersistence()`` has run in this process.
    @MainActor
    private static var isPairingPersistenceInstalled = false

    /// The defaults key the pairing records live under, one dictionary of host
    /// key to base64 record.
    private static let pairingsKey = "UBHostSessionPairings"

    /// Every stored pairing record, by host key.
    private static func pairingRecords() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: pairingsKey) as? [String: String] ?? [:]
    }

    private static func server(from stored: [String: Any]) -> HostServer? {
        guard let rawIdentifier = stored["id"] as? String, let id = UUID(uuidString: rawIdentifier) else {
            return nil
        }
        return HostServer(
            id: id,
            name: stored["name"] as? String ?? "",
            host: stored["host"] as? String ?? "",
            kind: HostKind(rawValue: stored["kind"] as? String ?? "") ?? .ubiquittyHost,
            workspaceName: stored["workspaceName"] as? String ?? "",
            tmuxSession: stored["tmuxSession"] as? String ?? "",
            device: stored["device"] as? String ?? "",
            baudRate: Int32(stored["baud"] as? Int ?? 115200),
            shouldForwardAgent: stored["forwardAgent"] as? Bool ?? false,
            localePolicy: stored["locale"] as? Int ?? 0
        )
    }

    private static func dictionary(for server: HostServer) -> [String: Any] {
        [
            "id": server.id.uuidString,
            "name": server.name,
            "host": server.host,
            "kind": server.kind.rawValue,
            "workspaceName": server.workspaceName,
            "tmuxSession": server.tmuxSession,
            "device": server.device,
            "baud": Int(server.baudRate),
            "forwardAgent": server.shouldForwardAgent,
            "locale": server.localePolicy,
        ]
    }
}
