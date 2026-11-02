// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Refusal.swift — what a terminal window says when
// the host refuses its session, and the two things every remote window and
// the Connect window share to say it: a remedy's title, and the access token a
// host is reached with.
//
// The remedies are Core's (`connectRemedies`), in Core's order, the first the
// default. This file titles them and carries them out; it adds none.

import AppKit
import Security
internal import UbiquittyCore

/// The access tokens hosts are reached with, one per host key, kept in the
/// keychain and never in the defaults.
///
/// Under the UI-test build the store is memory, so a scenario never writes the
/// keychain of the machine it runs on.
@MainActor
package enum HostTokenStore {
    private static var cached: [String: String] = [:]
    private static var revisions: [String: UInt64] = [:]

    #if UBIQUITTY_UI_TESTS
    private static var memory: [String: String] = [:]
    package static var loadForTesting: ((String, @escaping @MainActor (String?) -> Void) -> Void)?
    #else
    private static let keychain = HostTokenKeychain()
    private static var pendingWork: Task<Void, Never>?
    #endif

    /// The last loaded token, without performing credential I/O.
    ///
    /// - Parameter hostKey: The pairing key.
    /// - Returns: The token.
    package static func token(forHost hostKey: String) -> String? {
        guard !hostKey.isEmpty else { return nil }
        #if UBIQUITTY_UI_TESTS
        return memory[hostKey]
        #else
        return cached[hostKey]
        #endif
    }

    /// Loads credentials off the UI actor; Keychain may wait for user approval.
    /// - Parameters:
    ///   - hostKey: The pairing key.
    ///   - completion: Called on the UI actor with the current credential.
    package static func load(forHost hostKey: String, completion: @escaping @MainActor (String?) -> Void) {
        guard !hostKey.isEmpty else {
            completion(nil)
            return
        }
        #if UBIQUITTY_UI_TESTS
        if let loadForTesting { loadForTesting(hostKey, completion) } else { completion(memory[hostKey]) }
        #else
        let revision = revisions[hostKey, default: 0]
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            let token = await keychain.token(forHost: hostKey)
            guard revisions[hostKey, default: 0] == revision else {
                load(forHost: hostKey, completion: completion)
                return
            }
            cached[hostKey] = token
            completion(token)
        }
        #endif
    }

    /// Stores or replaces a host's token.
    ///
    /// - Parameters:
    ///   - token: The token.
    ///   - hostKey: The pairing key.
    ///   - completion: Called when Keychain has accepted or refused the write.
    package static func save(_ token: String, forHost hostKey: String, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard !hostKey.isEmpty, !token.isEmpty else {
            completion(false)
            return
        }
        revisions[hostKey, default: 0] &+= 1
        let revision = revisions[hostKey, default: 0]
        #if UBIQUITTY_UI_TESTS
        memory[hostKey] = token
        completion(true)
        #else
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            let saved = await keychain.save(token, forHost: hostKey)
            if saved, revisions[hostKey, default: 0] == revision { cached[hostKey] = token }
            completion(saved)
        }
        #endif
    }

    /// Removes a host's token. Absent is success.
    ///
    /// - Parameter hostKey: The pairing key.
    package static func remove(forHost hostKey: String) {
        revisions[hostKey, default: 0] &+= 1
        cached.removeValue(forKey: hostKey)
        #if UBIQUITTY_UI_TESTS
        memory.removeValue(forKey: hostKey)
        #else
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            await keychain.remove(forHost: hostKey)
        }
        #endif
    }
}

#if !UBIQUITTY_UI_TESTS
/// Serializes credential I/O without borrowing an AppKit responder or window.
private actor HostTokenKeychain {
    private let service = "org.ubiquitty.host-token"

    private func query(for hostKey: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostKey,
        ]
    }

    func token(forHost hostKey: String) -> String? {
        var query = query(for: hostKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String, forHost hostKey: String) -> Bool {
        guard let encoded = token.data(using: .utf8) else { return false }
        let query = query(for: hostKey)
        let attributes = [kSecValueData as String: encoded]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var insert = query
        insert[kSecValueData as String] = encoded
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    func remove(forHost hostKey: String) {
        SecItemDelete(query(for: hostKey) as CFDictionary)
    }
}
#endif

/// What a remedy's button says, the same in the Connect window and on a
/// terminal window's refusal sheet.
package enum RemedyTitles {
    /// The title for one of Core's remedies.
    ///
    /// - Parameters:
    ///   - remedy: The remedy.
    ///   - host: The host's name.
    ///   - workspaceName: The refused session's name, empty for an unnamed one.
    ///   - isThisMachine: Whether the host is this Mac's own, whose name is
    ///     the machine's rather than the host's.
    /// - Returns: The title.
    package static func title(
        for remedy: Ubiquitty.Session.Remedy,
        host: String,
        workspaceName: String,
        isThisMachine: Bool = false
    ) -> String {
        switch remedy {
        case .installAndConnect: "Install and Connect"
        case .copyInstallCommands: "Copy Install Commands"
        case .openSettings: "Open Remote Sessions Settings…"
        case .updateHost: isThisMachine ? "Update Host" : "Update \(host)"
        case .enterToken: "Enter Access Token…"
        case .manageHost: "Manage “\(host)”…"
        case .startNewNamed: "Start New “\(workspaceName)”"
        case .startNewSession: "New Workspace"
        case .chooseAnother: "Choose Another…"
        case .askAgain: "Ask Again"
        case .tryAgain: "Try Again"
        case .openSSHShell: "Open SSH Shell"
        case .editAddress: "Edit Host…"
        case .closeWindow: "Close Window"
        @unknown default: "Continue"
        }
    }

    /// The identifier suffix a remedy's button carries.
    ///
    /// - Parameter remedy: The remedy.
    /// - Returns: The suffix.
    package static func identifier(for remedy: Ubiquitty.Session.Remedy) -> String {
        switch remedy {
        case .installAndConnect: "InstallAndConnect"
        case .copyInstallCommands: "CopyInstallCommands"
        case .openSettings: "OpenSettings"
        case .updateHost: "UpdateHost"
        case .enterToken: "EnterToken"
        case .manageHost: "ManageHost"
        case .startNewNamed: "StartNewNamed"
        case .startNewSession: "StartNewSession"
        case .chooseAnother: "ChooseAnother"
        case .askAgain: "AskAgain"
        case .tryAgain: "TryAgain"
        case .openSSHShell: "OpenSSHShell"
        case .editAddress: "EditAddress"
        case .closeWindow: "CloseWindow"
        @unknown default: "Unknown"
        }
    }

    /// Core's remedies for a fact, in Core's order.
    ///
    /// - Parameter fact: What happened.
    /// - Returns: The remedies, default first.
    package static func remedies(for fact: Ubiquitty.Session.ConnectFact) -> [Ubiquitty.Session.Remedy] {
        (0..<Ubiquitty.Session.connectRemedyCount(fact)).map { Ubiquitty.Session.connectRemedyAt(fact, $0) }
    }
}

/// What the refusal sheet shows.
package struct RefusalSheetContent: Equatable {
    package let title: String
    package let detail: String
    package let sentence: String
    package let remedies: [Ubiquitty.Session.Remedy]
    package let titles: [String]

    package init(title: String, detail: String, sentence: String, remedies: [Ubiquitty.Session.Remedy], titles: [String]) {
        self.title = title
        self.detail = detail
        self.sentence = sentence
        self.remedies = remedies
        self.titles = titles
    }

    /// Builds the native presentation without showing it or starting a connection.
    @MainActor
    package func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = sentence
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        for (index, remedy) in remedies.enumerated() {
            let button = alert.addButton(withTitle: titles[index])
            button.setAccessibilityIdentifier("refusal-action-\(RemedyTitles.identifier(for: remedy))")
            if index == 0 { button.keyEquivalent = "\r" } else if remedy == .closeWindow { button.keyEquivalent = "\u{1b}" }
        }
        if !detail.isEmpty, detail != sentence {
            alert.accessoryView = RefusalDetailsView(detail: detail, alert: alert)
        }
        alert.window.identifier = NSUserInterfaceItemIdentifier("refusal-sheet")
        return alert
    }
}

/// Keeps the complete host diagnostic selectable without making it the alert's main message.
@MainActor
private final class RefusalDetailsView: NSStackView {
    private weak var alert: NSAlert?
    private let disclosure = NSButton()
    private let scroll = NSScrollView()

    init(detail: String, alert: NSAlert) {
        self.alert = alert
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        detachesHiddenViews = true

        disclosure.title = ""
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        disclosure.target = self
        disclosure.action = #selector(toggleDetails(_:))
        disclosure.setAccessibilityLabel("Technical Details")
        let heading = NSTextField(labelWithString: "Technical Details")
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [disclosure, heading])
        row.spacing = 4
        row.alignment = .centerY
        addArrangedSubview(row)

        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.string = detail
        text.setAccessibilityLabel("Host Diagnostic")
        scroll.documentView = text
        addArrangedSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 360),
            scroll.widthAnchor.constraint(equalTo: widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 160),
        ])
        scroll.isHidden = true
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("RefusalDetailsView is built in code") }

    @objc
    private func toggleDetails(_ sender: NSButton) {
        scroll.isHidden = sender.state != .on
        layoutSubtreeIfNeeded()
        setFrameSize(fittingSize)
        alert?.layout()
    }
}

extension TerminalWindowController {
    /// Opens Connect on a host; installed by the app, which owns the Connect
    /// window this module cannot name.
    package static var showConnectForHost: ((String) -> Void)?

    /// Opens the host's administration window, separately from choosing a session.
    package static var showManagementForHost: ((String) -> Void)?

    /// What the refusal sheet for this window says, from Core's facts.
    ///
    /// - Parameters:
    ///   - reason: The refusal's reason.
    ///   - hostBuild: What the refusing host said about its build.
    ///   - detail: The host's own words.
    /// - Returns: The content.
    package func refusalSheetContent(
        reason: Ubiquitty.`Protocol`.Sync.ByeReason,
        hostBuild: Ubiquitty.`Protocol`.Sync.PeerBuild,
        detail: String
    ) -> RefusalSheetContent {
        var fact = Ubiquitty.Session.ConnectFact()
        fact.kind = .attachRefused
        fact.surface = .terminalWindow
        fact.deniedReason = reason
        fact.hasWorkspaceName = !remoteWorkspaceName.isEmpty
        fact.update.host = hostBuild
        fact.update.hostLabel = std.string(remoteHostLabel)
        // Kind only: everywhere else this app names this machine This Mac.
        fact.update.localDevice.kind = .mac
        let isThisMachine = remoteHostKey == Self.thisMacHostKey
        fact.update.isThisMachine = isThisMachine
        // This Mac's host is taken over by the host this app bundles; a
        // remote one is pushed a bundled build for its platform.
        fact.update.hasBundledBinary = isThisMachine ? LocalHostUpgrade.isAvailable : !remoteDeployBinaries.isEmpty
        fact.remotePlatform = std.string(remoteSurface?.drive.lastHostRefusal.map { String($0.hostPlatform) } ?? "")
        let remedies = RemedyTitles.remedies(for: fact)
        let host = remoteHostLabel.isEmpty ? "the host" : remoteHostLabel
        let title: String
        switch reason {
        case .SessionGone:
            title = remoteWorkspaceName.isEmpty ? "Workspace No Longer Available" : "“\(remoteWorkspaceName)” Is No Longer Available"
        case .VersionMismatch:
            title = String(Ubiquitty.Session.versionRefusalTitle(fact.update))
        case .OutsideScope:
            title = remoteWorkspaceName.isEmpty ? "Can’t Open Workspace on \(host)" : "Can’t Open “\(remoteWorkspaceName)” on \(host)"
        case .NoConsent:
            title = "Connection Not Approved"
        default:
            title = "Can’t Connect to \(host)"
        }
        return RefusalSheetContent(
            title: title,
            detail: detail,
            sentence: String(Ubiquitty.Session.connectRemedySentence(fact)),
            remedies: remedies,
            titles: remedies.map {
                RemedyTitles.title(for: $0, host: host, workspaceName: remoteWorkspaceName, isThisMachine: isThisMachine)
            }
        )
    }

    /// Puts the refusal sheet up on this window.
    ///
    /// - Parameters:
    ///   - sessionID: The session the host refused.
    ///   - content: What the sheet says.
    package func presentRefusalSheet(sessionID: UInt32, content: RefusalSheetContent) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = content.makeAlert()
        lastRefusalSheetContent = content
        alert.beginSheetModal(for: window) { [weak self] response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard content.remedies.indices.contains(index) else { return }
            self?.performRefusalRemedy(content.remedies[index], sessionID: sessionID)
        }
    }

    /// Saves a reviewed token without changing the refused attachment or creating a session.
    private func presentAccessTokenSheet() {
        guard let window, window.attachedSheet == nil, !remoteHostKey.isEmpty else { return }
        let hostKey = remoteHostKey
        let alert = NSAlert()
        alert.messageText = "Enter an Access Token"
        alert.informativeText =
            "Paste an access token for \(remoteHostLabel.isEmpty ? "this host" : remoteHostLabel). Ubiquitty saves it in your keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Access token"
        field.setAccessibilityLabel("Access Token")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Token")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, !self.isWindowClosed else { return }
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            HostTokenStore.save(token, forHost: hostKey) { [weak self] saved in
                guard let self, !self.isWindowClosed else { return }
                guard saved else {
                    let failure = NSAlert()
                    failure.messageText = "Couldn’t Save the Access Token"
                    failure.informativeText = "The token couldn’t be saved in your keychain. Try again."
                    failure.addButton(withTitle: "Close")
                    if let window = self.window { failure.beginSheetModal(for: window) }
                    return
                }
                Self.showConnectForHost?(hostKey)
            }
        }
    }

    /// Carries out one of Core's remedies from the refusal sheet.
    ///
    /// - Parameters:
    ///   - remedy: The remedy.
    ///   - sessionID: The refused session.
    package func performRefusalRemedy(_ remedy: Ubiquitty.Session.Remedy, sessionID: UInt32) {
        if let window, let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }
        switch remedy {
        case .startNewNamed, .startNewSession, .askAgain:
            guard let connection = remoteConnection else { return }
            // The full spawn, with the host key, the name and the install
            // path: a pane moved into another window would not restart, and a
            // window opened without the name would open a session the next
            // connect cannot find again.
            let isAskingAgain = remedy == .askAgain
            let replacement = Self.spawnRemoteWindow(
                shellCommand: connection.shellCommand,
                hostLabel: connection.hostLabel,
                quicHost: connection.quicHost,
                quicBootstrapCommand: connection.quicBootstrapCommand,
                deploySSHHost: deploySSHHost,
                deployBinaries: remoteDeployBinaries,
                reattachSessionID: isAskingAgain ? sessionID : 0,
                workspaceName: remoteWorkspaceName,
                reattachPolicy: isAskingAgain ? .attachOnly : .attachOrCreate,
                hostKey: remoteHostKey
            )
            if replacement != nil, replacement !== self {
                window?.close()
            }
        case .updateHost where remoteHostKey == Self.thisMacHostKey:
            // This Mac's host is taken over rather than replaced: the host the
            // app bundles starts and the older one hands it every session,
            // this window's among them, which a window dialled with this
            // window's own reference then reattaches. This window closes
            // first, so the new one is not matched to it. An upgrade that
            // left the window's host as it was says so, and the window stays
            // rather than dialling the same refusal again.
            guard let connection = remoteConnection else { return }
            let drive = remoteSurface?.drive
            let workspaceID = drive?.remoteWorkspaceID ?? 0
            let daemonInstanceID = drive?.remoteDaemonInstanceID ?? 0
            let socketName = remoteAttachment?.socketName ?? ""
            let workspaceName = remoteWorkspaceName
            let hostKey = remoteHostKey
            Task { @MainActor [weak self] in
                let report = await LocalHostUpgrade.now()
                guard let self, !self.isWindowClosed else { return }
                if !report.title.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = report.title
                    alert.informativeText = report.sentence
                    if let window = self.window, window.attachedSheet == nil {
                        alert.beginSheetModal(for: window, completionHandler: nil)
                    } else {
                        alert.runModal()
                    }
                    return
                }
                self.window?.close()
                Self.spawnRemoteWindow(
                    shellCommand: connection.shellCommand,
                    hostLabel: connection.hostLabel,
                    quicHost: connection.quicHost,
                    quicBootstrapCommand: connection.quicBootstrapCommand,
                    deploySSHHost: "",
                    deployBinaries: [:],
                    reattachSessionID: sessionID,
                    workspaceName: workspaceName,
                    reattachPolicy: .attachOrCreate,
                    hostKey: hostKey,
                    workspaceID: workspaceID,
                    daemonSocketName: socketName,
                    daemonInstanceID: daemonInstanceID
                )
            }
        case .updateHost:
            // A replacement rather than this window: this one's connection is
            // pinned to the daemon of the host being replaced, so dialling it
            // again after the install would reach the old host. The
            // replacement installs before it dials, and opens the session by
            // name on the new host.
            guard let connection = remoteConnection else { return }
            let replacement = Self.spawnRemoteWindow(
                shellCommand: connection.shellCommand,
                hostLabel: connection.hostLabel,
                quicHost: connection.quicHost,
                quicBootstrapCommand: connection.quicBootstrapCommand,
                deploySSHHost: deploySSHHost,
                deployBinaries: remoteDeployBinaries,
                reattachSessionID: 0,
                workspaceName: remoteWorkspaceName,
                reattachPolicy: .attachOrCreate,
                hostKey: remoteHostKey,
                updatingHostFor: remoteSurface?.drive.lastHostRefusal.map { String($0.hostPlatform) } ?? ""
            )
            if replacement != nil, replacement !== self {
                window?.close()
            }
        case .enterToken:
            presentAccessTokenSheet()
        case .manageHost:
            Self.showManagementForHost?(remoteHostKey)
        case .chooseAnother, .editAddress:
            Self.showConnectForHost?(remoteHostKey)
        case .closeWindow:
            window?.performClose(nil)
        case .tryAgain, .installAndConnect, .copyInstallCommands, .openSettings, .openSSHShell:
            Self.showConnectForHost?(remoteHostKey)
        @unknown default:
            break
        }
    }
}

#if UBIQUITTY_UI_TESTS
extension TerminalWindowController {
    /// Gives a local window the identity a remote one carries, so a scenario
    /// can put the refusal sheet up without a host refusing anything.
    ///
    /// - Parameters:
    ///   - hostKey: The pairing key.
    ///   - hostLabel: What the window calls the host.
    ///   - workspaceName: The session's name, empty for an unnamed one.
    ///   - shellCommand: The transport a replacement window spawns.
    ///   - deployBinaries: The bundled hosts an update would choose from.
    package func standUpRemoteIdentityForTesting(
        hostKey: String,
        hostLabel: String,
        workspaceName: String,
        shellCommand: String,
        deployBinaries: [String: String]
    ) {
        remoteHostKey = hostKey
        remoteHostLabel = hostLabel
        remoteWorkspaceName = workspaceName
        remoteDeployBinaries = deployBinaries
        remoteConnection = RemoteConnection(
            shellCommand: shellCommand,
            hostLabel: hostLabel,
            quicHost: "",
            quicBootstrapCommand: "",
            hostKey: hostKey
        )
    }
}
#endif
