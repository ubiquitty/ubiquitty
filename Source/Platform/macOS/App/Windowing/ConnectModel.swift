// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ConnectModel.swift — the Connect window's one model: which place is
// selected, what the window was opened to do there, the saved hosts the
// sidebar lists, and the state the content area shows.
//
// One instance for the process, because the window is one: opening Connect
// from the menu, Welcome, Beam or a refusal sheet selects a place on this model
// rather than building a second window state that the first would not know
// about.
//
// Nothing here decides a connect or a row. The plan and the outline are Core's
// (the directory client, through ``HostDirectoryModel``), the address grammar
// is Core's
// (`parseConnectAddress`), and the remedies a failure offers are Core's
// (`connectRemedies`); this file maps those answers onto places, states and
// titles.
//

import AppKit
import Foundation
import Observation
import UbiquittyCore
import UbiquittyKit

import struct UbiquittyRenderKit.HostDaemonInstance
import struct UbiquittyRenderKit.HostOutlineRow
import enum UbiquittyRenderKit.HostWords

/// The Sync namespace, spelled where `Protocol` would parse as a metatype.
private typealias SyncWire = Ubiquitty.`Protocol`.Sync

/// A place the Connect sidebar can select.
enum ConnectPlace: Hashable {
    /// The `ubiquitty-host` daemon on this Mac.
    case thisMacHost
    /// The live tmux sessions on this Mac.
    case thisMacTmux
    /// The saved window arrangements on this Mac.
    case layouts
    /// The serial devices attached to this Mac.
    case serialPorts
    /// A one-off connection of a kind that has no saved host yet.
    case shell(ConnectKind)
    /// A host the person saved, by its row identity.
    case host(UUID)
    /// A target the person connected to without saving it.
    case recent(String)

    /// The accessibility identifier suffix for the place's sidebar row.
    var identifier: String {
        switch self {
        case .thisMacHost: "this-mac-host"
        case .thisMacTmux: "this-mac-tmux"
        case .layouts: "layouts"
        case .serialPorts: "serial-ports"
        case .shell(let kind): "shell-\(kind.rawValue)"
        case .host(let id): "host-\(id.uuidString)"
        case .recent(let target): "recent-\(target)"
        }
    }
}

/// What a place was selected for.
enum ConnectIntent: Equatable {
    /// Only to show it.
    case none
    /// To carry out Core's plan for the host when it acts without a person.
    case runPlan
    /// To choose among the sessions the host holds.
    case chooseSession
    /// To start a new session beside the ones the host holds.
    case newSession
}

/// What the content area shows for a host place, keyed by Core's facts.
///
/// One case per state the design names; the view picks its presentation from
/// this alone, and a scenario reads the same value, so the state a person sees
/// and the state a test asserts cannot disagree.
enum ConnectContentState: Equatable {
    case askingCold
    case unreachable
    case signInRequired
    case authenticationAttemptsExhausted
    case endedBeforeAnswer
    case notInstalled
    case needsToken
    case tokenInvalid
    case tokenExpired
    case tokenRevoked
    case tokenScope
    case olderHost
    case olderClient
    case refused
    case malformed
    case invalidAddress
    case hostBinaryMissing
    case empty
    case sessions

    /// Reads the state Core has already decided.
    init(_ state: Ubiquitty.Runtime.HostSectionState) {
        switch state {
        case .sessions: self = .sessions
        case .asking: self = .askingCold
        case .empty: self = .empty
        case .unreachable: self = .unreachable
        case .signInRequired: self = .signInRequired
        case .authenticationAttemptsExhausted: self = .authenticationAttemptsExhausted
        case .endedBeforeAnswer: self = .endedBeforeAnswer
        case .notInstalled: self = .notInstalled
        case .needsToken: self = .needsToken
        case .tokenInvalid: self = .tokenInvalid
        case .tokenExpired: self = .tokenExpired
        case .tokenRevoked: self = .tokenRevoked
        case .tokenScope: self = .tokenScope
        case .olderHost: self = .olderHost
        case .olderClient: self = .olderClient
        case .refused: self = .refused
        case .malformed: self = .malformed
        case .invalidAddress: self = .invalidAddress
        case .hostBinaryMissing: self = .hostBinaryMissing
        default: self = .unreachable
        }
    }

    /// The suffix of the content view's `connect-state-` identifier.
    var name: String {
        switch self {
        case .askingCold: "asking-cold"
        case .unreachable: "unreachable"
        case .signInRequired: "sign-in-required"
        case .authenticationAttemptsExhausted: "authentication-attempts-exhausted"
        case .endedBeforeAnswer: "ended-before-answer"
        case .notInstalled: "not-installed"
        case .needsToken: "needs-token"
        case .tokenInvalid: "token-invalid"
        case .tokenExpired: "token-expired"
        case .tokenRevoked: "token-revoked"
        case .tokenScope: "token-scope"
        case .olderHost: "older-host"
        case .olderClient: "older-client"
        case .refused: "refused"
        case .malformed: "malformed"
        case .invalidAddress: "invalid-address"
        case .hostBinaryMissing: "host-binary-missing"
        case .empty: "empty"
        case .sessions: "sessions"
        }
    }

    /// Whether the content area says the default button's sentence itself,
    /// so the footer leaves it out rather than repeating it.
    var showsPrimarySentence: Bool {
        switch self {
        case .askingCold, .empty: true
        default: false
        }
    }
}

/// What the footer beside the default button shows.
struct ConnectFooter: Equatable {
    /// The default button's sentence, nil when the content already says it.
    let sentence: String?
    /// Whether New Session stands beside the default button.
    let isNewSessionOffered: Bool
}

/// A one-line message above the content, with at most one action.
struct ConnectBanner: Equatable {
    /// What the action does.
    enum Action: Equatable {
        /// Ask the host for its listing again.
        case tryAgain
        /// Put a removed host back.
        case undoRemoval
        /// Ask the host to end a session again.
        case askAgain(UInt32)
    }

    let message: String
    let detail: String
    let action: Action?
}

/// What the last answer from one host said, for its sidebar row.
struct ConnectHostSummary: Equatable {
    let sessionCount: Int
    let state: ConnectContentState
    let markWords: String
}

/// A suggestion the search field offers for typed text.
struct ConnectSuggestion: Identifiable, Equatable {
    /// What choosing the suggestion does.
    enum Kind: Equatable {
        /// Select the saved host.
        case selectHost(UUID)
        /// Connect to the address as an Ubiquitty host.
        case connectHost
        /// Open a shell of a kind at the address.
        case openShell(ConnectKind)
        /// Save the address as a host first.
        case saveAsHost
        /// Nothing: the address is not one Core will dial; the title is
        /// Core's reason.
        case invalid
    }

    let kind: Kind
    let title: String
    let symbol: String

    var id: String { title }
}

/// A host removed from the list that can still be put back.
struct ConnectPendingRemoval: Equatable {
    let server: HostServer
    let index: Int
}

/// The Connect window's state.
@MainActor
@Observable
final class ConnectModel {
    /// The process's one model.
    static let shared = ConnectModel()

    /// The hosts the person saved, in their order.
    private(set) var hosts: [HostServer] = []

    /// The unsaved targets connected to recently, most recent first.
    private(set) var recents: [String] = []

    /// The selected place, nil for none.
    private(set) var selection: ConnectPlace?
    private(set) var hostInstances: [HostDaemonInstance] = []
    private(set) var selectedHostSocket = ""
    private var selectedHostInstance: HostDaemonInstance?
    private var defaultHostSocket = ""

    /// What the place was selected for.
    var intent: ConnectIntent = .none

    /// The search field's text. The selected host's outline is searched for
    /// it as it is typed; Core decides what matches.
    var searchText = "" {
        didSet {
            if searchText != oldValue {
                directory.outline.query = searchText
            }
        }
    }

    /// Whether the search field should hold the keyboard.
    var isSearchFocused = false

    /// Whether the inspector column is shown.
    var isInspectorPresented = false

    /// Whether a recovery action has asked for the selected host's secure token field.
    var isTokenEntryRequested = false

    /// Whether the Add Host sheet is up, and what it opened with.
    var addHostDraft: HostServer?

    /// Whether the New Named Session sheet is up.
    var isNamingSession = false

    /// The banner above the content, nil for none.
    var banner: ConnectBanner?

    /// The host removal Undo can still reverse.
    private(set) var pendingRemoval: ConnectPendingRemoval?

    /// What each host answered last, by pairing key.
    private(set) var summaries: [String: ConnectHostSummary] = [:]

    /// The selected host's outline and plan.
    let directory = HostDirectoryModel()

    /// The key the last selected place is remembered under.
    private static let lastPlaceKey = "UBConnectLastPlace"

    /// How long an Undo stays offered after a removal.
    private static let undoSeconds: Double = 8

    /// The built-in host for this Mac's daemon.
    ///
    /// A fixed identity rather than a saved row: This Mac is always present
    /// and cannot be deleted, so there is nothing to save.
    static let thisMac = HostServer(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000004C")!,
        name: "Ubiquitty Host",
        host: TerminalWindowController.thisMacHostKey,
        workspaceName: ""
    )

    // MARK: - Hosts

    /// Reads the saved hosts and recents again, keeping the selection when its
    /// row survives.
    func reload() {
        hosts = HostServers.all()
        recents = ConnectRecents.recent(for: .ubiquittyHost)
            .filter { target in
                target != "local" && !hosts.contains { $0.host == target }
            }
        if case .host(let id) = selection, !listedHosts.contains(where: { $0.id == id }) {
            select(hosts.contains { $0.id == id } ? .thisMacHost : nil)
        }
    }

    /// The saved hosts the sidebar lists: every row but those that duplicate
    /// This Mac, which already stands for this Mac's daemon.
    var listedHosts: [HostServer] {
        hosts.filter { !$0.isThisMacDuplicate }
    }

    /// Replaces the saved hosts and writes them through.
    ///
    /// - Parameter updated: The whole list.
    func saveHosts(_ updated: [HostServer]) {
        hosts = updated
        HostServers.save(updated)
    }

    /// Adds a host and selects it.
    ///
    /// Re-creating a host at an address a removal is still holding forgets
    /// that removal's pairing first: the new row is a new host to this app.
    ///
    /// - Parameter server: The host.
    func addHost(_ server: HostServer) {
        if let pending = pendingRemoval, pending.server.pairingKey == server.pairingKey {
            commitRemoval()
        }
        saveHosts(hosts + [server])
        select(.host(server.id))
    }

    /// Duplicates a saved host under a new name.
    ///
    /// - Parameter id: The host's row identity.
    func duplicateHost(_ id: UUID) {
        guard let original = hosts.first(where: { $0.id == id }) else { return }
        let copy = HostServer(
            id: UUID(),
            name: original.displayName + " copy",
            host: original.host,
            kind: original.kind,
            workspaceName: original.workspaceName,
            tmuxSession: original.tmuxSession,
            device: original.device,
            baudRate: original.baudRate,
            shouldForwardAgent: original.shouldForwardAgent,
            localePolicy: original.localePolicy
        )
        if let index = hosts.firstIndex(where: { $0.id == id }) {
            var updated = hosts
            updated.insert(copy, at: index + 1)
            saveHosts(updated)
        }
        select(.host(copy.id))
    }

    /// Moves saved hosts, as a drag in the sidebar does.
    ///
    /// - Parameters:
    ///   - source: The rows moved.
    ///   - destination: Where they land.
    func moveHosts(from source: IndexSet, to destination: Int) {
        var updated = hosts
        updated.move(fromOffsets: source, toOffset: destination)
        saveHosts(updated)
    }

    /// Commits an edit of one saved host.
    ///
    /// The address goes through Core's parser; one it refuses is not saved,
    /// and the reason is returned for the field to show.
    ///
    /// - Parameters:
    ///   - id: The row identity.
    ///   - name: The name.
    ///   - address: The typed address.
    ///   - workspaceName: The session name every connect opens, empty for none.
    /// - Returns: Core's reason when the address is refused, nil when saved.
    @discardableResult
    func updateHost(_ id: UUID, name: String, address: String, workspaceName: String) -> String? {
        guard var draft = hosts.first(where: { $0.id == id }) else { return nil }
        draft.name = name
        draft.host = address
        draft.workspaceName = workspaceName
        return updateHost(draft)
    }

    /// Removes a saved host, holding its pairing until the Undo window closes.
    ///
    /// - Parameter id: The row identity.
    func removeHost(_ id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        if pendingRemoval != nil {
            commitRemoval()
        }
        let removed = hosts[index]
        var updated = hosts
        updated.remove(at: index)
        saveHosts(updated)
        pendingRemoval = ConnectPendingRemoval(server: removed, index: index)
        banner = ConnectBanner(message: "Removed “\(removed.displayName)”.", detail: "", action: .undoRemoval)
        if selection == .host(id) {
            select(.thisMacHost)
        }
        let removedID = removed.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard let self, self.pendingRemoval?.server.id == removedID else { return }
            self.commitRemoval()
        }
    }

    /// Puts the removed host back where it was.
    func undoRemoval() {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        var updated = hosts
        updated.insert(pending.server, at: min(pending.index, updated.count))
        saveHosts(updated)
        if banner?.action == .undoRemoval {
            banner = nil
        }
        select(.host(pending.server.id))
    }

    /// Makes a removal final: the pairing goes with the row it belonged to,
    /// unless another row still names the same host.
    func commitRemoval() {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        if banner?.action == .undoRemoval {
            banner = nil
        }
        // A remembered session nobody can see in order to forget is one the
        // next host typed at the same address would silently inherit.
        if !hosts.contains(where: { $0.pairingKey == pending.server.pairingKey }) {
            HostDirectory.forget(host: pending.server.pairingKey)
        }
    }

    // MARK: - Places

    /// The host the selected place stands for, nil for a place that is not a
    /// host.
    var selectedServer: HostServer? {
        guard var server = server(for: selection) else { return nil }
        server.daemonInstance = selectedHostInstance
        return server
    }

    var otherHostInstances: [HostDaemonInstance] { hostInstances.filter { $0.socketName != defaultHostSocket } }

    func selectHostInstance(_ socket: String) {
        guard socket.isEmpty || hostInstances.contains(where: { $0.socketName == socket }) else { return }
        selectedHostInstance = hostInstances.first { $0.socketName == socket }
        selectedHostSocket = socket
        directory.point(at: selectedServer)
        directory.refresh()
    }

    /// The host a place stands for.
    ///
    /// - Parameter place: The place.
    /// - Returns: The host, nil for a place that is not one.
    func server(for place: ConnectPlace?) -> HostServer? {
        switch place {
        case .thisMacHost:
            Self.thisMac
        case .host(let id):
            // Only a daemon host has sessions to list; a shell host opens a
            // window and holds nothing.
            hosts.first { $0.id == id && $0.kind == .ubiquittyHost }
        case .recent(let target):
            Self.recentServer(target)
        case .thisMacTmux, .layouts, .serialPorts, .shell, nil:
            nil
        }
    }

    /// The host an unsaved target stands for.
    ///
    /// A fixed identity per target, so selecting the same recent twice points
    /// the directory at one host rather than two.
    ///
    /// - Parameter target: The address.
    /// - Returns: The host.
    static func recentServer(_ target: String) -> HostServer {
        HostServer(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            name: target,
            host: target,
            workspaceName: ""
        )
    }

    /// What the window and the sidebar call a place.
    ///
    /// - Parameter place: The place.
    /// - Returns: The name.
    func title(for place: ConnectPlace?) -> String {
        switch place {
        case .thisMacHost: "Ubiquitty Host"
        case .thisMacTmux: "tmux"
        case .layouts: "Layouts"
        case .serialPorts: "Serial Ports"
        case .shell(let kind): kind.title
        case .host(let id): hosts.first { $0.id == id }?.displayName ?? "Connect"
        case .recent(let target): target
        case nil: "Connect"
        }
    }

    /// Selects a place, pointing the directory at its host and asking it what
    /// it holds.
    ///
    /// - Parameter place: The place, nil for none.
    func select(_ place: ConnectPlace?) {
        if selection != place {
            selectedHostSocket = ""
            defaultHostSocket = ""
            hostInstances = []
            selectedHostInstance = nil
        }
        selection = place
        isTokenEntryRequested = false
        launchFailure = nil
        if let place {
            UserDefaults.standard.set(Self.storageKey(for: place), forKey: Self.lastPlaceKey)
        }
        guard let server = selectedServer else {
            directory.point(at: nil)
            return
        }
        pointDirectoryAndAsk(at: server)
    }

    /// Points the directory at a host and asks it once, unless an ask is
    /// already out for the same endpoint.
    ///
    /// - Parameter server: The host.
    private func pointDirectoryAndAsk(at server: HostServer) {
        // The pairing memory is Core's and its store is this app's; a window
        // that recalled before installing it would decide as though it had
        // never been to the host.
        HostServers.installPairingPersistence()
        directory.point(at: server)
        if directory.phase != .asking {
            directory.refresh()
        }
    }

    /// The place a window opens on when nothing names one: the key terminal
    /// window's host, else the last place used, else This Mac.
    ///
    /// - Returns: The place.
    func defaultPlace() -> ConnectPlace {
        if let key = TerminalWindowController.keyRemoteHostKey(), !key.isEmpty {
            if key == "local" {
                return .thisMacHost
            }
            if let saved = hosts.first(where: { $0.pairingKey == key }) {
                return .host(saved.id)
            }
            return .recent(key)
        }
        if let stored = UserDefaults.standard.string(forKey: Self.lastPlaceKey), let place = place(forStorageKey: stored) {
            return place
        }
        return .thisMacHost
    }

    /// The place a host key stands for: This Mac, a saved host, or a recent
    /// target.
    ///
    /// - Parameter hostKey: The pairing key.
    /// - Returns: The place.
    func place(forHostKey hostKey: String) -> ConnectPlace {
        reload()
        if hostKey.isEmpty || hostKey == "local" {
            return .thisMacHost
        }
        if let saved = hosts.first(where: { $0.pairingKey == hostKey }) {
            return .host(saved.id)
        }
        return .recent(hostKey)
    }

    private static func storageKey(for place: ConnectPlace) -> String {
        switch place {
        case .host(let id): "host:" + id.uuidString
        case .recent(let target): "recent:" + target
        default: "place:" + place.identifier
        }
    }

    private func place(forStorageKey key: String) -> ConnectPlace? {
        if key.hasPrefix("host:"), let id = UUID(uuidString: String(key.dropFirst(5))), listedHosts.contains(where: { $0.id == id }) {
            return .host(id)
        }
        if key.hasPrefix("recent:") {
            let target = String(key.dropFirst(7))
            return recents.contains(target) ? .recent(target) : nil
        }
        let fixed: [ConnectPlace] = [.thisMacHost, .thisMacTmux, .layouts, .serialPorts]
        return fixed.first { "place:" + $0.identifier == key }
    }

    // MARK: - Content

    /// What the content area shows for the selected host.
    var contentState: ConnectContentState {
        Self.contentState(of: directory)
    }

    /// What the content area shows for a directory, from Core's facts alone.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The state.
    static func contentState(of directory: HostDirectoryModel) -> ConnectContentState {
        ConnectContentState(directory.sectionWords.state)
    }

    /// The footer the window draws beside the default button.
    ///
    /// A status line rather than a second copy of the content: the sentence is
    /// left out when the content is already saying it, and New Session appears
    /// only when Core offers it as an action different from the default.
    var footer: ConnectFooter {
        ConnectFooter(
            sentence: contentState.showsPrimarySentence ? nil : directory.primaryAction.sentence,
            isNewSessionOffered: directory.isNewSessionOffered
        )
    }

    /// The banner the content shows, the window's own first, else the
    /// directory's news, else Core's sentence for a tree that is no longer
    /// followed or a listing that failed over rows still on screen.
    var visibleBanner: ConnectBanner? {
        if let banner {
            return banner
        }
        if let notice = directory.notice {
            return ConnectBanner(
                message: notice.title,
                detail: notice.message,
                action: notice.askAgainSessionID == 0 ? nil : .askAgain(notice.askAgainSessionID)
            )
        }
        if directory.outline.freshness == .stale, !directory.outline.watchError.isEmpty {
            return ConnectBanner(message: directory.outline.watchError, detail: "", action: .tryAgain)
        }
        if let failure = directory.failure, failure.kind == .unreachable, directory.workspaceCount > 0 {
            return ConnectBanner(message: directory.failureNotice, detail: "", action: .tryAgain)
        }
        return nil
    }

    /// Clears the banner, the window's own or the directory's.
    func dismissBanner() {
        if banner?.action == .undoRemoval {
            commitRemoval()
        }
        banner = nil
        directory.notice = nil
    }

    /// The facts line under the window title.
    var subtitle: String {
        guard selectedServer != nil else {
            switch selection {
            case .thisMacTmux: return "tmux on This Mac"
            case .layouts: return "Saved window arrangements"
            case .serialPorts: return "Devices attached to this Mac"
            case .shell(let kind): return kind.subtitle
            default: return ""
            }
        }
        return String(directory.sectionWords.subtitle)
    }

    /// Records what the selected host answered, for its sidebar row.
    func noteDirectoryChanged() {
        guard let server = selectedServer else { return }
        // The daemon picked under Running Sessions stopped: it leaves the
        // picker, and the host's current daemon is listed in its place.
        let goneSocket = directory.failure?.kind == .instanceGone ? selectedHostSocket : ""
        let answeredSocket = directory.phase == .listed ? directory.daemonSocketName : ""
        let isGone = selectedHostSocket.withCxxStringView { picked in
            goneSocket.withCxxStringView { gone in
                answeredSocket.withCxxStringView { Ubiquitty.Session.isPickedDaemonGone(picked, gone, $0) }
            }
        }
        if isGone {
            let gone = selectedHostSocket
            hostInstances.removeAll { $0.socketName == gone }
            selectHostInstance("")
            return
        }
        if selectedHostSocket.isEmpty { defaultHostSocket = directory.daemonSocketName }
        if !directory.hostInstances.isEmpty { hostInstances = directory.hostInstances }
        summaries[server.pairingKey] = ConnectHostSummary(
            sessionCount: directory.workspaceCount,
            state: contentState,
            markWords: String(directory.sectionWords.markWords)
        )
    }

    // MARK: - Search

    /// The suggestions for the search text, Core's parse deciding whether it
    /// is an address at all.
    var suggestions: [ConnectSuggestion] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let exact = listedHosts.first(where: { $0.displayName == text || $0.host == text }) {
            return [ConnectSuggestion(kind: .selectHost(exact.id), title: exact.displayName, symbol: "bolt.horizontal.circle")]
        }
        let parsed = Self.parse(text)
        let looksLikeAddress =
            text.contains("@") || text.contains(".") || text.contains(":") || text.hasPrefix("/")
            || text.hasPrefix("-")
        guard parsed.isValid else {
            return looksLikeAddress ? [ConnectSuggestion(kind: .invalid, title: parsed.reason, symbol: "exclamationmark.triangle")] : []
        }
        guard looksLikeAddress else { return [] }
        return [
            ConnectSuggestion(kind: .connectHost, title: "Connect with Ubiquitty Host", symbol: "bolt.horizontal.circle"),
            ConnectSuggestion(kind: .openShell(.ssh), title: "Open SSH Shell", symbol: "terminal"),
            ConnectSuggestion(kind: .openShell(.mosh), title: "Open mosh Shell", symbol: "antenna.radiowaves.left.and.right"),
            ConnectSuggestion(kind: .openShell(.remoteTmux), title: "Attach tmux over SSH", symbol: "square.split.2x2"),
            ConnectSuggestion(kind: .saveAsHost, title: "Save as Host…", symbol: "plus.circle"),
        ]
    }

    /// Carries out one suggestion. Choosing is the only way the search field
    /// connects; typing alone only filters.
    ///
    /// - Parameter suggestion: The suggestion.
    func choose(_ suggestion: ConnectSuggestion) {
        let parsed = Self.parse(searchText)
        switch suggestion.kind {
        case .selectHost(let id):
            searchText = ""
            select(.host(id))
        case .connectHost:
            guard parsed.isValid else { return }
            searchText = ""
            ConnectRecents.record(parsed.destination, for: .ubiquittyHost)
            reload()
            select(.recent(parsed.destination))
        case .openShell(let kind):
            guard parsed.isValid else { return }
            searchText = ""
            if ConnectQuickConnect.run(kind: kind, target: parsed.destination) {
                ConnectWindowController.closeAfterSpawn()
            }
        case .saveAsHost:
            guard parsed.isValid else { return }
            searchText = ""
            addHostDraft = HostServer(id: UUID(), name: parsed.host, host: parsed.destination, workspaceName: "")
        case .invalid:
            break
        }
    }

    /// The saved hosts the search text matches, all of them when it is empty.
    var filteredHosts: [HostServer] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return listedHosts }
        return listedHosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(text) || $0.host.localizedCaseInsensitiveContains(text)
        }
    }

    // MARK: - Keys

    /// What Esc did.
    enum EscapeOutcome: Equatable {
        case clearedSearch
        case cancelledPendingConnect
        case dismissedBanner
        case closeWindow
    }

    /// Esc, layered: clear a search, else stop a connect that is waiting, else
    /// close the window.
    ///
    /// - Returns: What it did; ``EscapeOutcome/closeWindow`` asks the caller to
    ///   close this window and no other.
    func handleEscape() -> EscapeOutcome {
        if !searchText.isEmpty {
            searchText = ""
            return .clearedSearch
        }
        if directory.isConnectPending {
            directory.dropPendingConnect()
            return .cancelledPendingConnect
        }
        return .closeWindow
    }

    /// Readies the model for a fresh open of the window.
    ///
    /// - Parameters:
    ///   - place: The place to select, nil for the default.
    ///   - intent: What it is selected for.
    func open(place: ConnectPlace?, intent: ConnectIntent) {
        reload()
        searchText = ""
        addHostDraft = nil
        isNamingSession = false
        self.intent = intent
        select(place ?? defaultPlace())
    }

    /// Ends the window's life on screen: a removal still offering Undo
    /// becomes final.
    func windowWillClose() {
        commitRemoval()
        directory.dropPendingConnect()
        directory.stopFollowing()
    }

    // MARK: - Actions

    /// The longest session name the wire carries, in bytes.
    static let maxWorkspaceNameLength = Int(SyncWire.maxWorkspaceNameLength)

    /// Asks the selected host again.
    func refresh() {
        directory.refresh()
    }

    /// Carries out the default button, closing the window when a window
    /// opened or came forward.
    func performPrimaryAction() {
        #if UBIQUITTY_UI_TESTS
        if recordAction("primary") { return }
        #endif
        let directory = directory
        directory.pendingConnectDidOpenWindow = { ConnectWindowController.closeAfterSpawn() }
        if directory.performPrimaryAction() {
            noteConnected()
            ConnectWindowController.closeAfterSpawn()
        }
    }

    /// Whether Return carries out the default button: a host place whose plan
    /// can act, and no sheet or search holding the key.
    var isPrimaryKeyActive: Bool {
        selectedServer != nil && directory.primaryAction.isEnabled && searchText.isEmpty && addHostDraft == nil && !isNamingSession
    }

    /// Starts an unnamed session beside the ones the host holds.
    func newSession() {
        #if UBIQUITTY_UI_TESTS
        if recordAction("newSession") { return }
        #endif
        if directory.newSession() {
            noteConnected()
            ConnectWindowController.closeAfterSpawn()
        }
    }

    /// Records an unsaved target as recent once a connect to it opened, and
    /// the host as the one Reattach returns to.
    private func noteConnected() {
        if case .recent(let target) = selection {
            ConnectRecents.record(target, for: .ubiquittyHost)
        }
        if let server = selectedServer {
            UserDefaults.standard.set(server.pairingKey, forKey: Self.lastHostKey)
        }
    }

    // MARK: - Reattach and Beam

    /// The key the last host a connect opened on is remembered under.
    private static let lastHostKey = "UBConnectLastHost"

    /// The host Reattach returns to: the last one a connect opened on, if it
    /// is still saved, recent, or this Mac.
    var reattachTarget: HostServer? {
        guard let key = UserDefaults.standard.string(forKey: Self.lastHostKey), !key.isEmpty else { return nil }
        if key == "local" {
            return Self.thisMac
        }
        if let saved = HostServers.all().first(where: { $0.pairingKey == key && $0.kind == .ubiquittyHost }) {
            return saved
        }
        return ConnectRecents.recent(for: .ubiquittyHost).contains(key) ? Self.recentServer(key) : nil
    }

    /// File ▸ Reattach's title: the session Core would return to and the host.
    var reattachTitle: String {
        guard let server = reattachTarget else { return "Reattach" }
        let name = HostDirectory.rememberedWorkspaceName(host: server.pairingKey)
        let session = server.workspaceName.isEmpty ? name : server.workspaceName
        return session.isEmpty ? "Reattach to \(server.displayName)" : "Reattach “\(session)” on \(server.displayName)"
    }

    /// Carries out Core's plan for a host without showing Connect when the
    /// plan can act alone, and opens Connect on the host when it needs a
    /// person: a listing to wait for, a session to choose.
    ///
    /// The plan is decided over no listing, as Reattach and Beam have none:
    /// Core attaches a remembered session attach-only and opens a named one
    /// either way, and waits otherwise.
    ///
    /// - Parameter server: The host.
    func runPlan(for server: HostServer) {
        HostServers.installPairingPersistence()
        let place: ConnectPlace =
            server.isLocal ? .thisMacHost : (hosts.contains { $0.id == server.id } ? .host(server.id) : .recent(server.host))
        let decision = HostDirectory.decideBeforeListing(host: server.pairingKey, predefinedWorkspaceName: server.workspaceName)
        switch decision.plan {
        case .attachByID, .attachNamed, .createNamed:
            reload()
            selection = place
            directory.point(at: server)
            performPrimaryAction()
        case .awaitListing, .chooseFromList, .createNew:
            ConnectWindowController.show(place: place, intent: .chooseSession)
        }
    }

    /// File ▸ Reattach: Core's plan for the last host.
    func reattach() {
        guard let server = reattachTarget else { return }
        runPlan(for: server)
    }

    /// Keeps a host's access token and asks the host again with it.
    ///
    /// The keychain holds it; nothing of it reaches the defaults.
    ///
    /// - Parameter token: The token, as pasted.
    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = selectedServer, !trimmed.isEmpty else { return }
        HostTokenStore.save(trimmed, forHost: server.pairingKey) { [weak self] saved in
            guard let self, self.selectedServer?.pairingKey == server.pairingKey else { return }
            guard saved else {
                self.directory.notice = HostDirectoryNotice(
                    title: "Couldn’t Save Access Token",
                    message: "The token couldn’t be saved in your keychain. Try again."
                )
                return
            }
            self.directory.refresh()
        }
    }

    /// Removes the selected host's access token.
    func removeToken() {
        guard let server = selectedServer else { return }
        HostTokenStore.remove(forHost: server.pairingKey)
    }

    /// Whether the selected host has an access token stored.
    var hasToken: Bool {
        selectedServer.map { HostTokenStore.token(forHost: $0.pairingKey) != nil } ?? false
    }

    /// Commits an edit of one saved host of any kind.
    ///
    /// The address goes through Core's parser and a serial device must be a
    /// device path; a refused one is not saved, and the reason is returned for
    /// the field to show. An endpoint change asks the host once.
    ///
    /// - Parameter draft: The edited host.
    /// - Returns: The reason the edit was refused, nil when saved.
    @discardableResult
    func updateHost(_ draft: HostServer) -> String? {
        guard let index = hosts.firstIndex(where: { $0.id == draft.id }) else { return nil }
        let reason = Self.validationReason(for: draft)
        guard reason.isEmpty else { return reason }
        var saved = draft
        if saved.kind != .serial {
            saved.host = Self.parse(saved.host).destination
        }
        guard saved != hosts[index] else { return nil }
        var updated = hosts
        updated[index] = saved
        saveHosts(updated)
        if selection == .host(saved.id), saved.kind == .ubiquittyHost {
            pointDirectoryAndAsk(at: saved)
        } else if selection == .host(saved.id) {
            directory.point(at: nil)
        }
        return nil
    }

    /// Why a host could not be dialled as typed, empty when it can.
    ///
    /// - Parameter host: The host.
    /// - Returns: Core's reason, or the device sentence for a serial host.
    static func validationReason(for host: HostServer) -> String {
        if host.kind == .serial {
            return host.device.hasPrefix("/dev/") && host.device.count > 5 ? "" : "A serial port is a device path, like /dev/cu.usbserial."
        }
        let parsed = parse(host.host)
        if !parsed.isValid {
            return parsed.reason
        }
        if host.kind != .ubiquittyHost, parsed.destination == "local" {
            return "A shell needs an address, like you@server.example."
        }
        if host.kind == .ubiquittyHost, parsed.destination == "local", host.workspaceName.isEmpty {
            return "This Mac is already listed. Name a workspace for this host to open."
        }
        return ""
    }

    // MARK: - Shells, tmux, serial and layouts

    /// Why the last shell, tmux or serial launch opened no window.
    var launchFailure: ConnectLaunchFailure?

    /// What a saved shell host's button says.
    ///
    /// - Parameter server: The host.
    /// - Returns: The title.
    func shellTitle(for server: HostServer) -> String {
        switch server.kind {
        case .ssh, .mosh: "Open Shell"
        case .remoteTmux: "Attach “\(server.tmuxSession.isEmpty ? "main" : server.tmuxSession)”"
        case .serial: "Open"
        case .ubiquittyHost: "Connect"
        }
    }

    /// The sentence beside a saved shell host's button.
    ///
    /// - Parameter server: The host.
    /// - Returns: The sentence.
    func shellSentence(for server: HostServer) -> String {
        switch server.kind {
        case .ssh: "Opens an SSH shell on \(server.host) in a new window."
        case .mosh: "Opens a mosh shell on \(server.host) in a new window."
        case .remoteTmux: "Attaches to tmux on \(server.host) in control mode."
        case .serial: "Opens \(server.device) at \(server.baudRate) baud."
        case .ubiquittyHost: ""
        }
    }

    /// Opens a saved shell host, showing why when it does not open.
    ///
    /// - Parameter server: The host.
    func openShell(_ server: HostServer) {
        #if UBIQUITTY_UI_TESTS
        if recordAction("openShell") { return }
        #endif
        launchFailure = ConnectLauncher.open(server)
        if launchFailure == nil {
            ConnectWindowController.closeAfterSpawn()
        }
    }

    /// A tmux session on this Mac.
    struct TmuxSessionRow: Identifiable, Equatable {
        let name: String
        let windows: Int
        let attached: Int
        var id: String { name }
    }

    /// The tmux sessions on this Mac, as tmux last listed them.
    private(set) var tmuxSessions: [TmuxSessionRow] = []

    /// Asks this Mac's tmux which sessions it holds.
    ///
    /// No tmux, or no server, is no sessions; the attach reports a missing
    /// tmux itself.
    func reloadTmuxSessions() {
        guard let tmux = ConnectLauncher.resolveTool("tmux") else {
            tmuxSessions = []
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_attached}"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            tmuxSessions = []
            return
        }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tmuxSessions = text.split(separator: "\n")
            .compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 3 else { return nil }
                return TmuxSessionRow(name: String(fields[0]), windows: Int(fields[1]) ?? 0, attached: Int(fields[2]) ?? 0)
            }
    }

    /// Attaches to, or starts, a tmux session on this Mac.
    ///
    /// - Parameter session: The Session field: a name, or a tmux command.
    func openTmux(session: String) {
        #if UBIQUITTY_UI_TESTS
        if recordAction("openTmux") { return }
        #endif
        launchFailure = ConnectLauncher.openTmux(host: nil, session: session, localePolicy: .automatic)
        if launchFailure == nil {
            ConnectWindowController.closeAfterSpawn()
        }
    }

    /// The serial devices this Mac has.
    private(set) var serialDevices: [String] = []

    /// Reads the serial devices again.
    func reloadSerialDevices() {
        serialDevices = Self.availableSerialDevices()
    }

    /// The serial devices under `/dev`, call-out devices first, each group
    /// sorted: the `cu.` node is the one a dial-out opens, and the `tty.` node
    /// of the same port waits for carrier.
    static func availableSerialDevices() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let callOut = entries.filter { $0.hasPrefix("cu.") }.sorted()
        let dialIn = entries.filter { $0.hasPrefix("tty.") }.sorted()
        return (callOut + dialIn).map { "/dev/" + $0 }
    }

    /// Whether a new SSH launch forwards the agent, as Core resolves the
    /// configuration: the unset preference means no forwarding, and that
    /// default lives in one place.
    static func defaultForwardsSSHAgent() -> Bool {
        Ubiquitty.Network.remoteOptionsFromValues(Ubiquitty.Preferences.values().pointee, .FromConfig).forwardAgent
    }

    /// Opens a serial device, showing why when it does not open.
    ///
    /// - Parameters:
    ///   - device: The device path.
    ///   - baudRate: The line rate.
    func openSerial(device: String, baudRate: Int32) {
        launchFailure = ConnectLauncher.openSerial(device: device, baudRate: baudRate)
        if launchFailure == nil {
            ConnectWindowController.closeAfterSpawn()
        }
    }

    /// A saved window arrangement.
    struct LayoutEntry: Identifiable, Equatable {
        let id: String
        let source: String
        let name: String
        let subtitle: String
    }

    /// The saved window arrangements.
    private(set) var layouts: [LayoutEntry] = []

    /// Reads the saved arrangements again.
    func reloadLayouts() {
        let raw = (NSApp.delegate as? UBAppDelegate)?.sessionPickerEntries() ?? []
        layouts = raw.map {
            LayoutEntry(id: $0["id"] ?? "", source: $0["source"] ?? "workspace", name: $0["name"] ?? "", subtitle: $0["subtitle"] ?? "")
        }
    }

    /// Opens a saved arrangement beside what is already open.
    ///
    /// - Parameter id: The arrangement.
    func openLayout(_ id: String) {
        guard let entry = layouts.first(where: { $0.id == id }) else { return }
        (NSApp.delegate as? UBAppDelegate)?.openPickerEntry(fromSource: entry.source, identifier: entry.id)
        ConnectWindowController.closeAfterSpawn()
    }

    /// Whether any terminal window is open to save as a layout.
    var hasWindowsToSave: Bool {
        TerminalWindowController.spawnedControllers.contains { !$0.isWindowClosed }
    }

    /// The sentence beside Save Current Layout.
    var layoutFooter: String {
        hasWindowsToSave ? "" : "Open a window to save a layout."
    }

    /// Saves the open windows as a named layout.
    ///
    /// - Parameter name: The name.
    /// - Returns: Whether a layout was saved.
    @discardableResult
    func saveLayout(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, hasWindowsToSave else { return false }
        (NSApp.delegate as? UBAppDelegate)?.saveCurrentLayout(withName: trimmed)
        reloadLayouts()
        return true
    }

    /// The selected row of the outline, nil when none is selected.
    var selectedRow: HostOutlineRow? {
        directory.outline.row(for: directory.selection)
    }

    /// Asks about ending what the selected row offers to end: its workspace,
    /// or the session of the pane it is.
    func confirmTerminateSelection() {
        guard let row = selectedRow, let ending = directory.terminateRequest(for: row) else { return }
        #if UBIQUITTY_UI_TESTS
        if recordAction("terminate") { return }
        #endif
        directory.askToEnd(ending.request, ending.target, named: row.title)
    }

    /// Copies the link of a row's session, which names the host, the daemon
    /// and the session and nothing that grants access.
    ///
    /// - Parameter row: A row that names one session.
    func copyLink(for row: HostOutlineRow) {
        directory.copyLink(for: row)
    }

    /// Opens the Add Host sheet for the selected recent target, or for the
    /// address in the search field.
    func saveSelectionAsHost() {
        if case .recent(let target) = selection {
            addHostDraft = HostServers.blankRemote(host: target)
            return
        }
        if let save = suggestions.first(where: { $0.kind == .saveAsHost }) {
            choose(save)
        }
    }

    /// What the session Core says ended is called: the remembered one the
    /// host answered without. Nil while the host still lists what this app
    /// remembered, or before it answers.
    var endedSessionName: String? {
        guard let server = selectedServer, let decision = directory.decision, decision.vanishedSessionID != 0 else { return nil }
        let name = HostDirectory.rememberedWorkspaceName(host: server.pairingKey)
        return name.isEmpty ? HostWords.text(.lastSession) : name
    }

    // MARK: - Remedies

    /// Core's remedies for the selected host's failed listing, with the
    /// sentence beside them.
    struct RemedyList: Equatable {
        let remedies: [Ubiquitty.Session.Remedy]
        let sentence: String
        /// Core's headline for a version refusal, naming the older end; empty
        /// for every other failure.
        var versionTitle = ""
    }

    /// The remedies Core offers for the selected host's listing failure.
    var remedyFact: RemedyList {
        guard let failure = directory.failure, let server = selectedServer else {
            return RemedyList(remedies: [], sentence: "")
        }
        var fact = Ubiquitty.Session.ConnectFact()
        fact.kind = .listingFailed
        fact.surface = .connect
        switch failure.kind {
        case .unreachable: fact.listingFailure = .Unreachable
        case .signInRequired: fact.listingFailure = .SignInRequired
        case .authenticationAttemptsExhausted: fact.listingFailure = .AuthenticationAttemptsExhausted
        case .endedBeforeAnswer: fact.listingFailure = .EndedBeforeAnswer
        case .instanceGone: fact.listingFailure = .InstanceGone
        case .notInstalled: fact.listingFailure = .NotInstalled
        case .refused: fact.listingFailure = .Refused
        case .malformed: fact.listingFailure = .Malformed
        }
        fact.deniedReason = failure.deniedReason
        let binaries = HostTransport.deployBinaries(forDeploySSHHost: server.isLocal ? "" : server.host)
        // A host too old to name its platform is probed for it by the update.
        let hasBundledBinary = failure.remotePlatform.isEmpty ? !binaries.isEmpty : binaries[failure.remotePlatform] != nil
        fact.deployAction = failure.remotePlatform.withCxxStringView { platform in
            Ubiquitty.Session.decideDeployAction(
                settingBool(.RemoteAutoInstallHost),
                platform,
                hasBundledBinary,
                HostDirectory.isDeployTrusted(host: server.host)
            )
        }
        fact.update.host = failure.hostBuild
        fact.update.hostLabel = std.string(server.displayName)
        // Kind only: everywhere else this app names this machine This Mac.
        fact.update.localDevice.kind = .mac
        fact.update.heldSessionCount = directory.heldSessionCount
        // This Mac's host is taken over by the host this app bundles, never
        // pushed to or installed by hand.
        fact.update.isThisMachine = server.isLocal
        fact.update.hasBundledBinary = server.isLocal ? LocalHostUpgrade.isAvailable : hasBundledBinary
        fact.remotePlatform = std.string(failure.remotePlatform)
        var remedies: [Ubiquitty.Session.Remedy] = []
        let count = Ubiquitty.Session.connectRemedyCount(fact)
        for index in 0..<count {
            remedies.append(Ubiquitty.Session.connectRemedyAt(fact, index))
        }
        let isVersionRefusal = failure.kind == .refused && failure.deniedReason == .VersionMismatch
        return RemedyList(
            remedies: remedies,
            sentence: String(Ubiquitty.Session.connectRemedySentence(fact)),
            versionTitle: isVersionRefusal ? String(Ubiquitty.Session.versionRefusalTitle(fact.update)) : ""
        )
    }

    /// What a remedy's button says.
    ///
    /// - Parameter remedy: Core's remedy.
    /// - Returns: The title.
    func title(for remedy: Ubiquitty.Session.Remedy) -> String {
        RemedyTitles.title(
            for: remedy,
            host: selectedServer?.displayName ?? "Host",
            workspaceName: selectedServer?.workspaceName ?? "",
            isThisMachine: selectedServer?.isLocal ?? false
        )
    }

    /// The identifier suffix a remedy's button carries.
    ///
    /// - Parameter remedy: Core's remedy.
    /// - Returns: The suffix.
    func identifier(for remedy: Ubiquitty.Session.Remedy) -> String {
        RemedyTitles.identifier(for: remedy)
    }

    /// Carries out one of Core's remedies from the Connect window.
    ///
    /// - Parameter remedy: The remedy.
    func perform(_ remedy: Ubiquitty.Session.Remedy) {
        guard let server = selectedServer else { return }
        switch remedy {
        case .installAndConnect:
            // The press is the consent: the trust is Core's, written before
            // the window opens, so the window's deploy decision reads Push and
            // never asks a second time.
            HostDirectory.trustDeploy(host: server.host)
            if directory.newSession(named: server.workspaceName) {
                noteConnected()
                ConnectWindowController.closeAfterSpawn()
            }
        case .copyInstallCommands:
            let platform = directory.failure?.remotePlatform ?? ""
            let commands = platform.withCxxStringView {
                String(Ubiquitty.Session.manualHostInstallCommands($0, SyncWire.appVersion()))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commands, forType: .string)
        case .openSettings:
            (NSApp.delegate as? UBAppDelegate)?.showSettingsWindow(forCategory: "sessions")
        case .updateHost where server.isLocal:
            // The host this app bundles takes This Mac's over in place; the
            // listing then answers from it. What was left undone is said, not
            // asked again.
            Task { @MainActor [weak self] in
                let report = await LocalHostUpgrade.now()
                guard let self else { return }
                if !report.title.isEmpty {
                    self.directory.notice = HostDirectoryNotice(title: report.title, message: report.sentence)
                }
                self.directory.refresh()
            }
        case .updateHost:
            if directory.updateHost(named: server.workspaceName) {
                noteConnected()
                ConnectWindowController.closeAfterSpawn()
            }
        case .startNewNamed, .startNewSession:
            if directory.newSession(named: server.workspaceName) {
                noteConnected()
                ConnectWindowController.closeAfterSpawn()
            }
        case .enterToken:
            isTokenEntryRequested = true
        case .manageHost:
            HostManagementWindows.shared.show(server: server)
        case .tryAgain, .askAgain:
            directory.refresh()
        case .openSSHShell:
            if ConnectQuickConnect.run(kind: .ssh, target: server.host) {
                ConnectWindowController.closeAfterSpawn()
            }
        case .editAddress:
            isInspectorPresented = true
        case .chooseAnother, .closeWindow:
            break
        @unknown default:
            break
        }
    }

    #if UBIQUITTY_UI_TESTS
    /// Whether the actions that open windows or ask the host record their
    /// name instead, so a scenario can watch a key reach them without a
    /// window opening on a host that does not exist.
    var shouldRecordActionsForTesting = false

    /// The actions recorded while ``shouldRecordActionsForTesting`` is set.
    var recordedActionsForTesting: [String] = []

    /// Records an action instead of running it, when a scenario asked.
    ///
    /// - Parameter name: The action.
    /// - Returns: Whether it was recorded and must not run.
    private func recordAction(_ name: String) -> Bool {
        guard shouldRecordActionsForTesting else { return false }
        recordedActionsForTesting.append(name)
        return true
    }

    /// Records a row being opened instead of opening it, when a scenario
    /// asked.
    ///
    /// - Parameter row: The row.
    /// - Returns: Whether it was recorded and must not open.
    func recordOpenForTesting(_ row: HostOutlineRow) -> Bool {
        guard shouldRecordActionsForTesting else { return false }
        directory.selection = row.key
        return recordAction("open")
    }

    /// Stands a saved-host list up without the store, for a scenario.
    ///
    /// - Parameter servers: The hosts.
    func setHostsForTesting(_ servers: [HostServer]) {
        saveHosts(servers)
    }
    #endif

    // MARK: - Addresses

    /// Core's reading of a typed address, as the window uses it.
    struct ParsedAddress: Equatable {
        let isValid: Bool
        let reason: String
        let host: String
        let destination: String
    }

    /// Reads an address through Core's grammar.
    ///
    /// "local" is this Mac's daemon and needs no parse.
    ///
    /// - Parameter text: What was typed.
    /// - Returns: The facts the window needs.
    static func parse(_ text: String) -> ParsedAddress {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "local" {
            return ParsedAddress(isValid: true, reason: "", host: "local", destination: "local")
        }
        let address = trimmed.withCxxStringView { Ubiquitty.Transport.parseConnectAddress($0) }
        return ParsedAddress(
            isValid: address.isValid,
            reason: String(address.reason),
            host: String(address.host),
            destination: String(address.destination())
        )
    }
}
