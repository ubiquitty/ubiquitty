// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UbiquittyIOSBridge

/// How a host signs in.
///
/// The secret itself never lives in this value — it is held in the keychain
/// under the record's identifier — so a host list can be logged, encoded and
/// passed around without carrying a password with it.
///
/// Every kind negotiates: the connection first asks the server to accept it
/// with no credential, and offers a credential only for a method the server
/// then lists. The kind says what may be offered; it never makes the app ask
/// for something the server did not ask for.
enum HostAuthenticationKind: String, Codable, CaseIterable, Identifiable {
    /// The password saved in the keychain, offered when the server lists
    /// `password`; asked for instead when the keychain holds none.
    case password
    /// A password asked for when the server wants one. It is saved only if
    /// the person explicitly chooses Connect and Save Password.
    case passwordPrompt
    /// The private key saved in the keychain, offered when the server lists
    /// `publickey`; a password is asked for after it only when the server
    /// refuses the key and lists `password`, as OpenSSH's client does.
    case privateKey

    var id: String { rawValue }

    /// The choice as the editor's menu names it.
    var title: String {
        switch self {
        case .password: return "Saved Password"
        case .passwordPrompt: return "Ask for Password"
        case .privateKey: return "SSH Key"
        }
    }

    /// What the keychain holds for a host signing in this way.
    var savedCredential: HostSavedCredential {
        switch self {
        case .password: return .password
        case .passwordPrompt: return .none
        case .privateKey: return .privateKey
        }
    }
}

/// What the keychain holds for a host, which decides how the secret is read
/// and which method it is offered for.
enum HostSavedCredential: String, Codable {
    /// Nothing is saved.
    case none
    /// A password.
    case password
    /// The text of a private key, in any container ``SSHPrivateKeyText`` reads.
    case privateKey
}

/// One saved host.
///
/// `pinnedHostKeyFingerprint` is the trust-on-first-use record: empty until the
/// first successful connection pins what the server offered, and compared by
/// Core on every connection after that. It is stored beside the host rather
/// than in the keychain because it is not a secret — it is a public digest, and
/// the point of showing it is that a person can read it back.
struct HostRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var hostName: String = ""
    var port: Int = 22
    var username: String = ""
    var authenticationKind: HostAuthenticationKind = .password
    var pinnedHostKeyFingerprint: String = ""
    /// Whether to try Sync over QUIC before falling back to bytes over SSH:
    /// what the editor calls Use Workspaces, since workspaces live only on a
    /// host reached that way.
    ///
    /// On for a new host, as the desktop clients try QUIC whenever the host
    /// offers it; a host that cannot answer stays on SSH and says so. Per host
    /// rather than global, because whether a host can carry QUIC is a fact
    /// about that host. Saving the preference keeps each host's choice.
    var prefersQUIC: Bool = true

    /// Whether a separately authorized credential may refresh this host while the app is suspended.
    var isBackgroundRefreshEnabled: Bool = false

    /// Identifies one explicit opt-in; renewed credentials or trust create a new permission.
    var backgroundRefreshPermissionID: UUID?

    /// The exact owner of background credentials, cached data, and notifications.
    var backgroundRefreshAuthorization: BackgroundRefreshAuthorization? {
        guard isBackgroundRefreshEnabled, let backgroundRefreshPermissionID, isComplete,
            !pinnedHostKeyFingerprint.isEmpty, canOfferSavedCredential
        else { return nil }
        return BackgroundRefreshAuthorization(
            hostID: id,
            permissionID: backgroundRefreshPermissionID,
            hostName: hostName,
            port: port,
            username: username,
            fingerprint: pinnedHostKeyFingerprint,
            authentication: authenticationIdentity
        )
    }

    /// What the keychain holds for this host: the credential a connection
    /// with nobody to ask, such as a background refresh, can sign in with.
    var savedCredential: HostSavedCredential { authenticationKind.savedCredential }

    /// Whether a saved credential may be offered without asking anyone.
    var canOfferSavedCredential: Bool { savedCredential != .none }

    /// Whether this host permits saving a password typed at connect time.
    ///
    /// Never over a saved key. The caller also checks that the keychain holds no secret,
    /// so no credential sealing a kept workspace is replaced.
    var canSavePromptedPassword: Bool {
        authenticationKind != .privateKey
    }

    /// The sign-in configuration as one value, which an authorization that
    /// must be retired when it changes records.
    var authenticationIdentity: String { authenticationKind.rawValue }

    /// The theme this host opens with, by name, or empty for the default.
    ///
    /// By name rather than by index: an index means a different theme the
    /// moment the theme list gains or loses one, and the list is not fixed —
    /// Core's count is built-ins plus whatever has been registered.
    var themeName: String = ""

    /// The workspace this host connects to, or empty when it names none.
    ///
    /// A name outranks everything else a connect could decide: the host it is
    /// saved on attaches to the session bearing it and creates one under it
    /// when nothing does, so a host with a name never asks which session to
    /// open. Empty leaves the choice to the connect rule.
    var workspaceName: String = ""

    /// What this host was last attached on, as Core's own record, base64.
    ///
    /// Opaque here on purpose: the pairing's meaning and its layout belong to
    /// ``Ubiquitty::Session::RememberedSessions``, and this shell is the place
    /// the bytes are kept rather than a second reader of them. Base64 because
    /// the record is binary and this file is JSON.
    var rememberedSessionRecord: String = ""
    /// When a terminal on this host last connected, nil before the first time.
    ///
    /// What the host list says about a host with nothing open: the date a
    /// person reads to tell a machine in daily use from one not reached in
    /// months. Kept on this device only; it is not the host's own record.
    var lastConnectedAt: Date?

    /// Decoded field by field, each absence falling back to the default above.
    ///
    /// Synthesised decoding requires every key, so a record written by an
    /// older build — one field short — fails to decode. The store reads with
    /// `try?`, which turns that failure into an empty list: adding a field
    /// would silently delete every host a person had saved. This is what makes
    /// the format forward and backward tolerant, and it has to stay exhaustive
    /// as fields are added.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostName = try values.decodeIfPresent(String.self, forKey: .hostName) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        authenticationKind = try values.decodeIfPresent(HostAuthenticationKind.self, forKey: .authenticationKind) ?? .password
        pinnedHostKeyFingerprint =
            try values.decodeIfPresent(String.self, forKey: .pinnedHostKeyFingerprint) ?? ""
        themeName = try values.decodeIfPresent(String.self, forKey: .themeName) ?? ""
        prefersQUIC = try values.decodeIfPresent(Bool.self, forKey: .prefersQUIC) ?? false
        isBackgroundRefreshEnabled = try values.decodeIfPresent(Bool.self, forKey: .isBackgroundRefreshEnabled) ?? false
        backgroundRefreshPermissionID = try values.decodeIfPresent(UUID.self, forKey: .backgroundRefreshPermissionID)
        workspaceName = try values.decodeIfPresent(String.self, forKey: .workspaceName) ?? ""
        rememberedSessionRecord =
            try values.decodeIfPresent(String.self, forKey: .rememberedSessionRecord) ?? ""
        lastConnectedAt = try values.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    /// The memberwise initialiser the custom decoder above suppresses.
    init(
        id: UUID = UUID(),
        name: String = "",
        hostName: String = "",
        port: Int = 22,
        username: String = "",
        authenticationKind: HostAuthenticationKind = .password,
        pinnedHostKeyFingerprint: String = "",
        themeName: String = "",
        prefersQUIC: Bool = true,
        isBackgroundRefreshEnabled: Bool = false,
        backgroundRefreshPermissionID: UUID? = nil,
        workspaceName: String = "",
        rememberedSessionRecord: String = "",
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.port = port
        self.username = username
        self.authenticationKind = authenticationKind
        self.pinnedHostKeyFingerprint = pinnedHostKeyFingerprint
        self.themeName = themeName
        self.prefersQUIC = prefersQUIC
        self.isBackgroundRefreshEnabled = isBackgroundRefreshEnabled
        self.backgroundRefreshPermissionID = backgroundRefreshPermissionID
        self.workspaceName = workspaceName
        self.rememberedSessionRecord = rememberedSessionRecord
        self.lastConnectedAt = lastConnectedAt
    }

    /// Whether this host can be asked what sessions it is holding.
    ///
    /// Only the Sync carrier has a session directory to ask. A plain-SSH host
    /// runs a login shell down a channel and holds nothing to list, so the
    /// question has no answer there rather than an empty one.
    var canListSessions: Bool { prefersQUIC }

    /// The key the pairing is remembered against.
    ///
    /// The record's identifier rather than its endpoint: two saved hosts may
    /// name the same machine with different credentials, and each keeps its own
    /// session.
    var pairingKey: String { id.uuidString }

    /// What the list shows when the record has no name of its own.
    var displayName: String {
        if !name.isEmpty {
            return name
        }
        if username.isEmpty {
            return hostName
        }
        return "\(username)@\(hostName)"
    }

    /// Where the host is, as a person would type it to reach it: the user, the
    /// host, and the port when it is not ssh's own.
    ///
    /// A literal IPv6 address is bracketed so its colons do not read as the
    /// port's.
    var endpoint: String {
        port == 22 ? userAndHost : "\(userAndHost):\(port)"
    }

    /// The endpoint without its port: the part a narrow row may shorten,
    /// where the port must stay whole.
    var userAndHost: String {
        let host = hostName.contains(":") && !hostName.hasPrefix("[") ? "[\(hostName)]" : hostName
        return username.isEmpty ? host : "\(username)@\(host)"
    }

    /// Whether this record has enough to dial.
    ///
    /// The host itself is judged by Core rather than here: `validateSSHHost` is
    /// the floor every frontend in this product dials through, and a second
    /// characterSet written in Swift would be a different one the day either moves.
    var isComplete: Bool {
        !hostName.isEmpty && !username.isEmpty && (1...65535).contains(port)
            && ubiquittyIOSValidateSSHHost(hostName)
    }
}
