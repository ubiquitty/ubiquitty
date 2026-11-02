// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// HostDirectoryModel.swift — what the Connect window knows about one saved
// host: how to reach it, the outline of what it is holding, and which connect
// to make.
//
// Neither the outline nor the connect rule is here. Core's directory client
// holds the host's tree and hands out the rows drawn from it, and answers the
// rule on that tree, the pairing this app remembered, the workspace name the
// saved row carries and the row the person selected, with the question to ask
// when nothing picks a workspace. What this file owns is the errand that asks
// the host and the window the answer opens. Core words the plan.
//
// The transport is Core's too: `localTransportPlan` and `remoteTransportPlan`
// derive every command from the host alone, so a window opened from here dials
// exactly what a window opened from anywhere else does.
//

import AppKit
import Observation
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

private typealias PeerBuild = Ubiquitty.`Protocol`.Sync.PeerBuild

/// Everything a connect to one host needs, derived from the host alone.
struct HostTransportPlan {
    /// The stdio transport command — the carrier that always works.
    let shellCommand: String
    /// The host a QUIC carrier dials, empty when QUIC is not offered.
    let quicHost: String
    /// The command printing the daemon's QUIC port, token and certificate pin,
    /// empty likewise.
    let quicBootstrapCommand: String
    /// The host `ubiquitty-host` may be installed on, empty for a host this app
    /// never pushes to.
    let deploySSHHost: String
}

/// Why a saved host cannot be dialled at all.
///
/// Told apart from a host that answered badly: neither of these reached a host,
/// and both are fixed in this window rather than on the far end.
enum HostTransportRefusal: Error, Equatable {
    /// This Mac has no `ubiquitty-host` to run.
    case missingLocalHostBinary
    /// The typed host is not a `[user@]host` this app will hand to `ssh`.
    case invalidSSHHost
}

/// The transport a saved host is reached over.
@MainActor
enum HostTransport {
    /// The plan for one saved host.
    ///
    /// - Parameter server: The saved host.
    /// - Returns: The plan, or why the host cannot be dialled.
    static func plan(for server: HostServer) -> Result<HostTransportPlan, HostTransportRefusal> {
        if let instance = server.daemonInstance {
            let target = server.isLocal ? "" : server.host
            // The local plan's own binary: what a window dials once the
            // picked daemon's pin is withdrawn.
            var quotedLocalBinary = ""
            if server.isLocal {
                guard let binary = ShareSessionSupport.localHostBinaryPath() else {
                    return .failure(.missingLocalHostBinary)
                }
                quotedLocalBinary = String(binary.withCxxStringView { Ubiquitty.Transport.shellSingleQuote($0) })
            }
            let plan = target.withCxxStringView { host in
                quotedLocalBinary.withCxxStringView { Ubiquitty.Session.hostInstanceTransportPlan(host, instance.coreValue, $0) }
            }
            guard !plan.shellCommand.empty() else { return .failure(.invalidSSHHost) }
            return .success(
                HostTransportPlan(
                    shellCommand: String(plan.shellCommand),
                    quicHost: String(plan.quicHost),
                    quicBootstrapCommand: String(plan.quicBootstrapCommand),
                    deploySSHHost: ""
                )
            )
        }
        switch server.isLocal {
        case true:
            guard let binary = ShareSessionSupport.localHostBinaryPath() else {
                return .failure(.missingLocalHostBinary)
            }
            let quoted = String(binary.withCxxStringView { Ubiquitty.Transport.shellSingleQuote($0) })
            let plan = quoted.withCxxStringView { Ubiquitty.Session.localTransportPlan($0) }
            return .success(
                HostTransportPlan(
                    shellCommand: String(plan.shellCommand),
                    quicHost: String(plan.quicHost),
                    quicBootstrapCommand: String(plan.quicBootstrapCommand),
                    // The loopback daemon is this app's own bundled binary, so
                    // there is nothing to install onto it.
                    deploySSHHost: ""
                )
            )
        case false:
            // Core's characterSet, not a second one written here: it is the floor
            // every frontend in this product dials through, and shell-quoting
            // alone would not stop a host read as an ssh option.
            guard server.host.withCxxStringView({ Ubiquitty.Transport.validateSSHHost($0) }) else {
                return .failure(.invalidSSHHost)
            }
            let plan = server.host.withCxxStringView { Ubiquitty.Session.remoteTransportPlan($0) }
            return .success(
                HostTransportPlan(
                    shellCommand: String(plan.shellCommand),
                    quicHost: String(plan.quicHost),
                    quicBootstrapCommand: String(plan.quicBootstrapCommand),
                    deploySSHHost: server.host
                )
            )
        }
    }

    /// The bundled `ubiquitty-host` binaries, keyed by the remote `uname -sm`
    /// they target.
    ///
    /// Empty for a host nothing may be installed on, which is what keeps the
    /// loopback daemon out of the deploy path entirely.
    ///
    /// - Parameter deploySSHHost: The host a push would target, empty for none.
    /// - Returns: The map the spawn hands the session.
    static func deployBinaries(forDeploySSHHost deploySSHHost: String) -> [String: String] {
        guard !deploySSHHost.isEmpty else {
            return [:]
        }
        let fileManager = FileManager.default
        var binaries: [String: String] = [:]
        var identity = utsname()
        if uname(&identity) == 0, let localBinary = ShareSessionSupport.localHostBinaryPath() {
            let systemName = platformName(identity.sysname)
            let machineName = platformName(identity.machine)
            if !systemName.isEmpty, !machineName.isEmpty {
                binaries["\(systemName) \(machineName)"] = localBinary
            }
        }
        // Present only in a packaged build; a development bundle carries this
        // Mac's own binary alone, which is the one a local push would use.
        let crossBuilt = [
            "Linux x86_64": "ubiquitty-host-linux-x86_64",
            "Linux aarch64": "ubiquitty-host-linux-arm64",
        ]
        for (platform, resource) in crossBuilt {
            guard let path = Bundle.main.path(forResource: resource, ofType: nil), fileManager.isReadableFile(atPath: path)
            else {
                continue
            }
            binaries[platform] = path
        }
        return binaries
    }

    /// One NUL-terminated `utsname` field as a string.
    ///
    /// The field arrives as a fixed-size tuple of characters, which is the only
    /// shape C arrays take in Swift; it is read as the bytes up to the first NUL
    /// rather than as the whole tuple, whose tail is padding.
    ///
    /// - Parameter field: The field.
    /// - Returns: Its text.
    private static func platformName<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// A sentence the window puts in front of the person, with nothing to decide.
///
/// Identifiable so the one place it is shown can tell a new one from the last.
struct HostDirectoryNotice: Identifiable, Equatable {
    let id = UUID()
    /// What happened.
    let title: String
    /// The host's own words where it sent any, else what this app can say.
    let message: String
    /// The session a terminate can be asked about again, 0 when asking again
    /// cannot change the answer.
    var askAgainSessionID: UInt32 = 0
}

/// Where a host's listing stands, as Core's phase reports it.
enum HostListingPhase: Equatable {
    /// Nothing has asked the host.
    case notAsked
    /// An ask is out; the rows are the previous answer, if any.
    case asking
    /// The host answered with the rows.
    case listed
    /// The last ask failed; the rows are the last answer that succeeded.
    case failed
}

/// Why a host's listing failed, as the facts Core reported.
struct HostListingFailure: Equatable {
    /// The failure kinds Core distinguishes.
    enum Kind: Equatable {
        case unreachable
        case signInRequired
        case authenticationAttemptsExhausted
        case endedBeforeAnswer
        /// The daemon the listing was pinned to is no longer running.
        case instanceGone
        case instanceUnreadable
        case notInstalled
        case refused
        case malformed
    }

    let kind: Kind
    /// The host's reason, read only for ``Kind/refused``.
    let deniedReason: Ubiquitty.`Protocol`.Sync.ByeReason
    /// The platform the host reported, empty when it said none.
    let remotePlatform: String
    /// Which end of a version refusal is older.
    let olderSide: Ubiquitty.`Protocol`.Sync.OlderSide
    /// Whether the refusing host stated its build; the two facts below are
    /// read only then.
    let isHostBuildKnown: Bool
    /// The protocol version the refusing host speaks.
    let hostWireVersion: UInt16
    /// The refusing host's app version, empty when it sent none.
    let hostAppVersion: String
    /// The carrier's or the host's words, verbatim.
    let detail: String

    /// The refusing host's build, as Core reads it.
    var hostBuild: Ubiquitty.`Protocol`.Sync.PeerBuild {
        var build = PeerBuild()
        build.isKnown = isHostBuildKnown
        build.wireVersion = hostWireVersion
        build.appVersion = std.string(hostAppVersion)
        return build
    }

    /// A failure as Core reported it.
    init(
        kind: Kind,
        deniedReason: Ubiquitty.`Protocol`.Sync.ByeReason,
        remotePlatform: String,
        olderSide: Ubiquitty.`Protocol`.Sync.OlderSide,
        hostBuild: Ubiquitty.`Protocol`.Sync.PeerBuild,
        detail: String
    ) {
        self.kind = kind
        self.deniedReason = deniedReason
        self.remotePlatform = remotePlatform
        self.olderSide = olderSide
        isHostBuildKnown = hostBuild.isKnown
        hostWireVersion = hostBuild.wireVersion
        hostAppVersion = String(hostBuild.appVersion)
        self.detail = detail
    }

    /// A failure with only a kind, for a caller standing one up without a
    /// host.
    ///
    /// - Parameter kind: The kind.
    /// - Returns: The failure, every other fact empty.
    static func of(_ kind: Kind, deniedReason: Ubiquitty.`Protocol`.Sync.ByeReason = .TokenMissing) -> HostListingFailure {
        HostListingFailure(kind: kind, deniedReason: deniedReason, remotePlatform: "", olderSide: .Unknown, hostBuild: .init(), detail: "")
    }
}

/// What Return does in the Connect window, said out loud.
///
/// The plan is Core's; this is the plan's title and the sentence that says
/// what it will do before the person presses it.
struct ConnectPrimaryAction: Equatable {
    /// What the default button does.
    enum Effect: Equatable {
        /// Carry out Core's plan.
        case connect(HostAttachPlan)
        /// Bring forward the window already showing the session.
        case showWindow
        /// Nothing until the host answers the connect that is waiting.
        case waiting
        /// Nothing: no host is selected.
        case none
    }

    let title: String
    let sentence: String
    let effect: Effect
    let isEnabled: Bool

    /// The plan the button carries out, nil for an effect that is not a plan.
    var plan: HostAttachPlan? {
        if case .connect(let plan) = effect {
            return plan
        }
        return nil
    }
}

/// One saved host's outline, and the connects made against it.
///
/// Core owns the control-only connection, the tree, the rows drawn from it and
/// the connect rule; this owns the errand that asks the host, the window the
/// answer opens. Core words the plan. The client is the
/// endpoint's, shared with every other window asking the same host.
@MainActor
@Observable
final class HostDirectoryModel {
    /// The host's outline: Core's rows, and the person's closed rows and
    /// search behind them.
    let outline = HostOutlineStore(platformMarks: [.progress, .progressInactive, .progressError, .notification])

    /// How many workspaces the host holds, counted off Core's rows with
    /// nothing closed and nothing searched for.
    private(set) var workspaceCount = 0

    /// How many sessions the host holds: the panes under its workspaces, as
    /// Core's rows count them.
    private(set) var heldSessionCount = 0

    /// Where the listing stands.
    private(set) var phase: HostListingPhase = .notAsked

    /// Why the last listing failed, nil when it did not.
    private(set) var failure: HostListingFailure?

    /// Core's sentence for the last failed listing, empty when it did not
    /// fail.
    private(set) var failureNotice = ""

    /// When the host last answered, nil before any answer.
    private(set) var answeredAt: Date?

    /// Whether a connect is waiting for the host's answer before deciding.
    ///
    /// Set when Core's rule answers that it cannot decide without the listing,
    /// and cleared when the answer lands (the connect then runs) or the ask
    /// fails (the connect is reported, never made blind).
    private(set) var isConnectPending = false

    /// The row the person selected. Core's rule is handed the session opening
    /// it attaches to as its chosen input.
    var selection: HostOutlineRowKey? {
        didSet {
            if selection != oldValue {
                refreshDecision()
            }
        }
    }

    /// The connect Core's rule makes over what the host holds, what this app
    /// remembered and the selected row; nil when the directory points at no
    /// host.
    private(set) var decision: HostConnectDecision?

    /// What that connect asks the person, in Core's words; nil when the rule
    /// picked a connect itself.
    private(set) var question: HostAttachQuestion?

    /// The question put in front of the person, nil when none is up.
    var presentedQuestion: HostAttachQuestion?

    /// Sessions a terminate is out for.
    private(set) var terminatingSessionIDs: Set<UInt32> = []

    /// The question Core asks before a request that ends sessions, waiting
    /// for the person's answer; nil when none is.
    var destructiveQuestion: HostDestructiveQuestion?

    /// Run when a connect that waited for the host's answer opens its window,
    /// so the window that asked can close then rather than when it asked.
    @ObservationIgnored
    var pendingConnectDidOpenWindow: (() -> Void)?

    /// The news waiting to be shown, or nil when there is none.
    var notice: HostDirectoryNotice?

    /// The host every errand on this directory is about.
    private(set) var server: HostServer?

    /// Why the host cannot be dialled at all, nil when it can.
    private(set) var transportRefusal: HostTransportRefusal?

    /// Whether an errand is out.
    var isListing: Bool { phase == .asking }

    /// The daemon incarnation that answered the last listing, 0 before any.
    var daemonInstanceID: UInt64 { endpoint?.snapshot.daemonInstanceID ?? 0 }

    /// Core's state and words for the section this directory presents.
    var sectionWords: Ubiquitty.Runtime.HostSectionWords {
        // The C++ endpoint is outside Observation; a published change makes
        // every view reading these words observe it.
        _ = sectionChangeCount
        let refusal: Ubiquitty.Runtime.HostTransportRefusal
        switch transportRefusal {
        case .invalidSSHHost: refusal = .invalidAddress
        case .missingLocalHostBinary: refusal = .missingLocalHostBinary
        case nil: refusal = .none
        }
        #if UBIQUITTY_UI_TESTS
        if var facts = sectionFactsForTesting {
            facts.isThisMachine = server?.isLocal ?? false
            facts.transportRefusal = refusal
            facts.workspaceCount = UInt32(clamping: workspaceCount)
            return Ubiquitty.Runtime.hostSectionWords(facts, std.string(server?.displayName ?? ""))
        }
        #endif
        if let endpoint {
            return endpoint.sectionWords(hostName: server?.displayName ?? "", isLocal: server?.isLocal ?? false, transportRefusal: refusal)
        }
        var facts = Ubiquitty.Runtime.HostSectionFacts()
        facts.isThisMachine = server?.isLocal ?? false
        facts.transportRefusal = refusal
        return Ubiquitty.Runtime.hostSectionWords(facts, std.string(server?.displayName ?? ""))
    }

    private var sectionChangeCount: UInt64 = 0

    /// The shared client for the endpoint, nil until the first ask.
    @ObservationIgnored
    private var endpoint: HostDirectoryEndpoint?
    var hostInstances: [HostDaemonInstance] { endpoint?.hostInstances ?? [] }
    var daemonSocketName: String { endpoint.map { String($0.snapshot.daemonSocketName) } ?? "" }

    @ObservationIgnored
    private var credentialRequestID = UUID()

    /// The rows the person closed on each host, by pairing key, so a host
    /// returned to is folded as it was left.
    @ObservationIgnored
    private var closedRows: [String: HostOutlineClosedRows] = [:]

    /// What each session a terminate is out for was called when it was
    /// asked, so the answer is worded with the name the person saw.
    @ObservationIgnored
    private var terminatingNames: [UInt32: String] = [:]

    /// The structure changes this window asked for that the host has not
    /// answered, by their numbers. The client is shared, so a change another
    /// window asked for settles here too and is not this window's to report.
    @ObservationIgnored
    private var structureRequests: Set<UInt64> = []

    /// The reader Core's rows are read with when nothing is closed and
    /// nothing is searched for: the one the workspaces are counted with and a
    /// question's candidates are named by.
    private var wholeReader: HostOutlineReader {
        var reader = HostOutlineReader()
        reader.fallbackName = server?.displayName ?? ""
        reader.host = server.map { RemoteWindowRegistry.readerHost(forKey: $0.pairingKey) } ?? ""
        reader.alreadyOpen = RemoteWindowRegistry.openWorkspaces()
        return reader
    }

    /// Points the directory at a host.
    ///
    /// A row whose name or workspace changed is the same host, and its tree
    /// stands: an outline is about the machine, not about what the row is
    /// called. A row whose endpoint changed is a different machine, so the
    /// tree and the errand's own carrier both go: an outline belonging to
    /// another host lists workspaces this one does not have.
    ///
    /// - Parameter server: The host, or nil to point at none.
    func point(at server: HostServer?) {
        guard self.server != server else {
            return
        }
        let isSameEndpoint =
            server != nil
            && self.server?.host == server?.host
            && self.server?.daemonInstance == server?.daemonInstance

        if let previous = self.server {
            closedRows[previous.pairingKey] = outline.closedRows
        }
        self.server = server
        guard !isSameEndpoint else {
            refreshDecision()
            return
        }
        credentialRequestID = UUID()
        endpoint?.setWatching(false, for: self)
        endpoint = nil
        #if UBIQUITTY_UI_TESTS
        sectionFactsForTesting = nil
        #endif
        outline.setSource(nil)
        workspaceCount = 0
        heldSessionCount = 0
        phase = .notAsked
        failure = nil
        failureNotice = ""
        transportRefusal = nil
        answeredAt = nil
        selection = nil
        presentedQuestion = nil
        destructiveQuestion = nil
        terminatingSessionIDs = []
        terminatingNames = [:]
        structureRequests = []
        dropPendingConnect()
        refreshDecision()
    }

    /// Asks the host what it holds, and follows it from then on.
    ///
    /// An ask made while another is out joins the one Core queues behind it,
    /// so a second ask is never refused.
    func refresh() {
        guard let server else {
            return
        }
        #if UBIQUITTY_UI_TESTS
        refreshCountForTesting += 1
        #endif
        let transport: HostTransportPlan
        switch HostTransport.plan(for: server) {
        case .success(let plan):
            transport = plan
        case .failure(let refusal):
            present(refusal, for: server)
            return
        }
        transportRefusal = nil
        let endpoint = attachEndpoint(transport)
        phase = .asking
        let requestID = UUID()
        credentialRequestID = requestID
        HostTokenStore.load(forHost: server.pairingKey) { [weak self, weak endpoint] token in
            guard let self, let endpoint, self.credentialRequestID == requestID,
                self.endpoint === endpoint, self.server?.pairingKey == server.pairingKey
            else { return }
            endpoint.setAuthToken(token ?? "")
            #if UBIQUITTY_UI_TESTS
            self.lastAuthTokenForTesting = token ?? ""
            if self.isDiallingSuppressedForTesting { return }
            #endif
            endpoint.refresh()
            endpoint.setWatching(true, for: self)
        }
    }

    /// Tells Core what this app has open, so a row in a workspace a window
    /// here already shows answers that opening it reveals that window.
    func stateOpenWindows() {
        guard let server else { return }
        outline.setPlace(
            host: RemoteWindowRegistry.readerHost(forKey: server.pairingKey),
            here: nil,
            alreadyOpen: RemoteWindowRegistry.openWorkspaces()
        )
        refreshActionFacts()
    }

    /// Stops following the host, as when the window showing it closes. The
    /// tree it last reported stays, as of then.
    func stopFollowing() {
        credentialRequestID = UUID()
        endpoint?.setWatching(false, for: self)
    }

    /// The endpoint for a transport, subscribed once and made the outline's
    /// source.
    private func attachEndpoint(_ transport: HostTransportPlan) -> HostDirectoryEndpoint {
        if let endpoint, endpoint.shellCommand == transport.shellCommand {
            return endpoint
        }
        let shared = HostDirectoryClients.shared.endpoint(for: transport.shellCommand, instance: server?.daemonInstance)
        shared.subscribe(self) { [weak self] in self?.hostDirectoryDidChange() }
        endpoint = shared
        outline.setFallbackName(server?.displayName ?? "")
        stateOpenWindows()
        outline.setSource(shared, closed: server.flatMap { closedRows[$0.pairingKey] } ?? HostOutlineClosedRows())
        return shared
    }

    /// Publishes Core's settled result without treating failure as an empty
    /// host.
    func hostDirectoryDidChange() {
        guard let endpoint, let server else { return }
        sectionChangeCount &+= 1
        #if UBIQUITTY_UI_TESTS
        sectionFactsForTesting = nil
        #endif
        let snapshot = endpoint.snapshot
        switch snapshot.phase {
        case .NotAsked:
            phase = .notAsked
        case .Asking:
            phase = .asking
        case .Listed:
            phase = .listed
        case .Failed:
            phase = .failed
        @unknown default:
            phase = .failed
        }
        // Every change may have moved the tree, how current it is, or the
        // facts the rule decides on, so the rows and the plan are read again
        // whatever the event.
        stateOpenWindows()
        outline.reload()
        let workspaces = endpoint.outline(for: wholeReader).rows.filter { $0.level == .workspace }
        workspaceCount = workspaces.count
        heldSessionCount = workspaces.reduce(0) { $0 + ($1.workspaceState == .restorable ? 0 : $1.paneCount) }
        if let selection, outline.row(for: selection) == nil, !outline.isSearching {
            self.selection = nil
        }
        refreshDecision()
        switch snapshot.event {
        case .SessionList:
            failure = nil
            failureNotice = ""
            answeredAt =
                snapshot.answeredAtUnixSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(snapshot.answeredAtUnixSeconds)) : Date()
            runPendingConnect()
        case .Failed:
            // A failed management errand says nothing about the listing; only
            // Core's phase does.
            guard snapshot.phase == .Failed else {
                break
            }
            let reason = String(snapshot.error)
            failure = Self.failure(from: snapshot)
            failureNotice = reason
            if isConnectPending {
                dropPendingConnect()
                let words = HostWords.listingFailedWhileConnecting(hostName: server.displayName, reason: reason)
                notice = HostDirectoryNotice(title: words.title, message: words.message)
            }
        case .TerminateSettled:
            terminateDidSettle(
                sessionID: snapshot.lastTerminateSessionID,
                outcome: HostSessionTerminateOutcome(rawValue: UInt8(snapshot.terminateOutcome.rawValue))
            )
        case .StructureSettled:
            structureDidSettle(endpoint.structureResult)
        case .SessionTree:
            // A watch's first report answers a connect that was waiting as a
            // listing's does.
            runPendingConnect()
        case .None, .ManagementReply, .WatchEnded, .WatchInterrupted:
            break
        @unknown default:
            break
        }
    }

    /// Core's failure facts as the window reads them.
    private static func failure(from snapshot: Ubiquitty.Runtime.HostDirectoryClient.Snapshot) -> HostListingFailure {
        let kind: HostListingFailure.Kind
        switch snapshot.failure {
        case .SignInRequired:
            kind = .signInRequired
        case .AuthenticationAttemptsExhausted:
            kind = .authenticationAttemptsExhausted
        case .EndedBeforeAnswer:
            kind = .endedBeforeAnswer
        case .InstanceGone:
            kind = .instanceGone
        case .InstanceUnreadable:
            kind = .instanceUnreadable
        case .NotInstalled:
            kind = .notInstalled
        case .Refused:
            kind = .refused
        case .Malformed:
            kind = .malformed
        case .None, .Unreachable:
            kind = .unreachable
        @unknown default:
            kind = .unreachable
        }
        return HostListingFailure(
            kind: kind,
            deniedReason: snapshot.deniedReason,
            remotePlatform: String(snapshot.remotePlatform),
            olderSide: snapshot.olderSide,
            hostBuild: snapshot.hostBuild,
            detail: String(snapshot.failureDetail)
        )
    }

    // MARK: - Ending sessions

    /// Whether a row names one session: a pane's row, or a row that stands
    /// for one pane, with a session to attach to.
    ///
    /// - Parameter row: The row.
    /// - Returns: Whether the row has a session's link to copy.
    func namesOneSession(_ row: HostOutlineRow) -> Bool {
        (row.level == .pane || row.foldedPane != nil) && row.open.how == .bySession
    }

    /// Copies the host, daemon and session locator, never an access token.
    func copyLink(for row: HostOutlineRow) {
        guard namesOneSession(row), let server,
            let locator = HostHandoffLocator(host: server.host, daemonInstanceID: daemonInstanceID, sessionID: row.open.sessionID)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(locator.url.absoluteString, forType: .string)
    }

    /// Core's process and lifetime details under one outline row.
    func sessionDetails(for row: HostOutlineRow) -> [Ubiquitty.Runtime.HostSessionDetails] {
        _ = outline.revision
        return endpoint?.sessionDetails(for: row) ?? []
    }

    /// The terminate a row offers and what it is asked about: a workspace's
    /// row ends the workspace, and a row that is one pane ends that pane's
    /// session. Core says, when asked, whether there is anything to end.
    ///
    /// - Parameter row: The row.
    /// - Returns: The request and its target, nil for a row that offers no
    ///   terminate.
    func terminateRequest(for row: HostOutlineRow) -> (request: HostDestructiveRequest, target: HostOutlineIdentity)? {
        guard row.workspaceState != .restorable else { return nil }
        if row.level == .workspace, let id = row.id {
            return (.terminateWorkspace, id)
        }
        if row.level == .pane, let id = row.id {
            return (.terminateSession, id)
        }
        if let pane = row.foldedPane {
            return (.terminateSession, pane)
        }
        return nil
    }

    /// The window a row is, nil for a row that is none: what Close Window is
    /// asked about.
    ///
    /// - Parameter row: The row.
    /// - Returns: The window's identity.
    func window(of row: HostOutlineRow) -> HostOutlineIdentity? {
        row.level == .window ? row.id : nil
    }

    /// Asks Core for the question a request that ends sessions is confirmed
    /// with, and puts it in front of the person; where Core says there is
    /// nothing to ask, shows its sentence for why.
    ///
    /// - Parameters:
    ///   - request: What would be asked of the host.
    ///   - target: What it is asked about.
    ///   - name: What the row asked about is called, for the notices a
    ///     terminate's answers are worded with.
    func askToEnd(_ request: HostDestructiveRequest, _ target: HostOutlineIdentity, named name: String) {
        guard let endpoint, let server else { return }
        let question = endpoint.confirmation(for: request, target: target, hostName: server.displayName)
        guard question.token != 0 else {
            if !question.whyNot.isEmpty {
                notice = HostDirectoryNotice(title: question.whyNot, message: "")
            }
            return
        }
        for sessionID in question.sessionIDs {
            terminatingNames[sessionID] = name
        }
        destructiveQuestion = question
    }

    /// Sends the request a question was about, once the person has answered
    /// it with the button that goes through.
    ///
    /// - Parameter question: The answered question.
    func carryOut(_ question: HostDestructiveQuestion) {
        destructiveQuestion = nil
        guard let endpoint else { return }
        switch question.request {
        case .closeWindow:
            note(endpoint.closeWindow(confirmedBy: question))
        case .terminateSession, .terminateWorkspace:
            let admission = endpoint.terminate(confirmedBy: question)
            guard admission.sessionCount > 0 else {
                if !admission.whyNot.isEmpty {
                    notice = HostDirectoryNotice(title: admission.whyNot, message: "")
                }
                return
            }
            terminatingSessionIDs.formUnion(question.sessionIDs)
        }
    }

    /// Shows how a terminate settled, in the five words the daemon can answer
    /// in.
    ///
    /// - Parameters:
    ///   - sessionID: The session the answer is about.
    ///   - outcome: What the host answered, or nil for an answer this build does
    ///     not know.
    func terminateDidSettle(sessionID: UInt32, outcome: HostSessionTerminateOutcome?) {
        terminatingSessionIDs.remove(sessionID)
        let name = terminatingNames[sessionID] ?? ""
        if outcome == .terminated || outcome == .failed || outcome == .refused || outcome == nil {
            terminatingNames[sessionID] = nil
        }
        if outcome == .terminated {
            // The tree drops the row itself: the watch reports the host
            // without the session, or the listing asked for here does.
            if endpoint?.freshness != .live {
                endpoint?.refresh()
            }
        } else if let words = HostWords.terminateOutcome(outcome?.rawValue ?? UInt8.max, name: name, sessionID: sessionID) {
            notice = HostDirectoryNotice(
                title: words.title,
                message: words.message,
                askAgainSessionID: words.doesOfferAskingAgain ? sessionID : 0
            )
        }
    }

    /// Asks about ending a session again, after its people declined or did
    /// not answer: Core words the question anew, on the tree as it stands.
    ///
    /// - Parameter sessionID: The session.
    func terminateAgain(_ sessionID: UInt32) {
        notice = nil
        askToEnd(
            .terminateSession,
            HostOutlineIdentity(kind: .session, number: UInt64(sessionID)),
            named: terminatingNames[sessionID] ?? String(Ubiquitty.Runtime.unnamedSessionWords(sessionID))
        )
    }

    // MARK: - Changing the host's structure

    /// Gives the workspace a row is or belongs to its name, or takes the name
    /// away with an empty one.
    ///
    /// - Parameters:
    ///   - row: A workspace's row.
    ///   - name: The name.
    func renameWorkspace(_ row: HostOutlineRow, to name: String) {
        guard let endpoint, row.level == .workspace, let id = row.id else { return }
        note(endpoint.renameWorkspace(id, to: name))
    }

    /// Gives the tab a row is or stands for its name, or takes the name away
    /// with an empty one.
    ///
    /// - Parameters:
    ///   - row: A tab's row, or a row a tab folded into.
    ///   - name: The name.
    func renameTab(_ row: HostOutlineRow, to name: String) {
        guard let endpoint, let place = row.tabPlace else { return }
        note(endpoint.renameTab(place.tab, to: name))
    }

    /// Sets or clears the label of one level a row is or stands for.
    ///
    /// - Parameters:
    ///   - label: The label; empty clears it.
    ///   - level: The level, as the row states it.
    func setLabel(_ label: String, on level: HostOutlineOwn) {
        guard let endpoint else { return }
        note(endpoint.setLabel(label, on: level.id))
    }

    /// Replaces the hand-put tags of one level a row is or stands for.
    ///
    /// - Parameters:
    ///   - tags: The tags, in the order they are drawn; none clears them.
    ///   - level: The level, as the row states it.
    func setTags(_ tags: [String], on level: HostOutlineOwn) {
        guard let endpoint else { return }
        note(endpoint.setTags(tags, on: level.id))
    }

    /// Moves a tab one place among its window's tabs, where the row says the
    /// host would accept the move.
    ///
    /// - Parameters:
    ///   - place: Where the tab stands, as its row states it.
    ///   - isEarlier: Whether it moves towards the first tab.
    func moveTab(_ place: HostOutlineTabPlace, earlier isEarlier: Bool) {
        guard let endpoint, isEarlier ? place.canMoveEarlier : place.canMoveLater else { return }
        note(endpoint.moveTab(place.tab, toWindow: place.window, at: isEarlier ? place.index - 1 : place.index + 1))
    }

    /// Moves a tab to another window of its workspace, to the place the row
    /// states for that window.
    ///
    /// - Parameters:
    ///   - place: Where the tab stands, as its row states it.
    ///   - destination: One of the windows the row says have room for it.
    func moveTab(_ place: HostOutlineTabPlace, to destination: HostOutlineTabDestination) {
        guard let endpoint else { return }
        note(endpoint.moveTab(place.tab, toWindow: destination.window, at: destination.index))
    }

    /// Keeps a change's number until the host answers it. One refused before
    /// anything was sent settles after the ask returns, as every other does.
    private func note(_ requestID: UInt64) {
        guard requestID != 0 else { return }
        structureRequests.insert(requestID)
    }

    /// Shows a change that was not made, with the reason in the host's words
    /// or Core's and nothing added to it.
    ///
    /// - Parameter result: How the change that settled last ended.
    private func structureDidSettle(_ result: HostDirectoryEndpoint.StructureResult?) {
        guard let result, structureRequests.remove(result.requestID) != nil, !result.isServed else { return }
        notice = HostDirectoryNotice(title: result.reason, message: "")
    }

    // MARK: - Connecting

    /// The session Core's rule is handed as the person's choice: the one
    /// opening the selected row attaches to, 0 with no row selected and for a
    /// row that opens no session.
    private var chosenSessionID: UInt32 {
        guard let open = outline.row(for: selection)?.open, open.how == .bySession else { return 0 }
        return open.sessionID
    }

    /// The pane the selected row opens at, 0 for wherever the host's own
    /// focus is.
    private var chosenPaneID: UInt32 {
        guard let open = outline.row(for: selection)?.open, open.how == .bySession else { return 0 }
        return open.paneID
    }

    /// Asks Core's rule again, over what the directory holds now.
    private func refreshDecision() {
        defer { refreshActionFacts() }
        guard let server else {
            decision = nil
            question = nil
            return
        }
        guard let endpoint else {
            // No client yet: the rule decides on what this app remembered and
            // the saved name alone, and never reads that as an empty host.
            decision = HostConnectDecision(
                UbiquittyKit.HostDirectory.decideBeforeListing(host: server.pairingKey, predefinedWorkspaceName: server.workspaceName)
            )
            question = nil
            return
        }
        decision = endpoint.decideAttach(
            hostKey: server.pairingKey,
            predefinedWorkspaceName: server.workspaceName,
            chosenSessionID: chosenSessionID,
            reader: wholeReader
        )
        question = endpoint.attachQuestion
    }

    /// Connects to the host, doing whatever Core's rule says this connect is.
    ///
    /// The rule reads what this app remembered about the host, the workspace
    /// name the saved row carries, the host's tree while it is held fresh and
    /// the row the person selected, and a frontend that weighed them itself
    /// would connect differently from every other frontend.
    ///
    /// A connect the rule cannot decide before the host answers waits for the
    /// answer: the directory asks if nothing is out, and the connect runs from
    /// the answer, or is reported if the ask fails. A connect the rule cannot
    /// decide without the person puts Core's question in front of them.
    ///
    /// - Returns: Whether a window opened. A false answer with
    ///   ``presentedQuestion`` set is the rule asking the person, and with
    ///   ``isConnectPending`` set it is the connect waiting for the host;
    ///   neither is a failure.
    @discardableResult
    func connect() -> Bool {
        refreshDecision()
        guard let decision else {
            return false
        }
        switch decision.plan {
        case .chooseFromList:
            presentedQuestion = question
            return false
        case .awaitListing:
            isConnectPending = true
            if !isListing {
                refresh()
            }
            return false
        case .attachByID, .createNamed, .attachNamed, .createNew:
            // The plan's values verbatim: an attach door reads a session id
            // and a name together, and a frontend that substituted either would
            // be making the choice the rule was asked for. Every session opened
            // here outlives the window that opened it; a return to a remembered
            // one is attach-only, so a session that ended is refused and shown
            // rather than replaced by a shell the person would take for theirs.
            return open(
                reattachSessionID: decision.reattachSessionID,
                workspaceID: decision.workspaceID,
                workspaceName: decision.workspaceName,
                reattachPolicy: decision.plan == .attachByID ? .attachOnly : .attachOrCreate,
                opening: decision.plan == .createNamed || decision.plan == .createNew ? .Creates : .OpensListed,
                // Attaching by a pane's session binds its whole workspace and
                // leaves the host's focus where it was, so a row opened at a
                // pane asks for that pane to be shown once attached.
                doesRevealPane: decision.plan == .attachByID && decision.sessionID == chosenSessionID && chosenPaneID != 0
            )
        }
    }

    /// Carries out what the default button says: brings forward the window
    /// showing the session, or makes Core's connect.
    ///
    /// A selected row Core says opens no session is not a choice for the
    /// rule: one the host would restore is asked for by the name Core gives,
    /// and one that cannot be opened says why, in Core's sentence.
    ///
    /// - Returns: Whether a window opened or came forward.
    @discardableResult
    func performPrimaryAction() -> Bool {
        stateOpenWindows()
        refreshDecision()
        if let target = outline.row(for: selection)?.open, target.how != .bySession {
            return attach(target)
        }
        if primaryAction.effect == .showWindow, let match = existingWindowMatch() {
            match.controller.activateRemotePane(match.pane)
            return true
        }
        return connect()
    }

    /// Attaches to what Core says opening a row, or picking a candidate,
    /// attaches to.
    ///
    /// - Parameter target: Core's value, handed back as it is.
    /// - Returns: Whether a window opened or came forward.
    private func attach(_ target: HostOutlineOpen) -> Bool {
        switch target.how {
        case .cannot:
            notice = HostDirectoryNotice(title: target.obstacle, message: "")
            return false
        case .byRestoring:
            return open(
                reattachSessionID: 0,
                workspaceID: 0,
                workspaceName: target.workspaceName,
                reattachPolicy: .attachOrCreate,
                opening: .OpensListed
            )
        case .byRevealing:
            // A window here already shows the workspace: Core hands back the
            // session it was told the window holds, and nothing is attached.
            guard let server else { return false }
            return RemoteWindowRegistry.reveal(hostKey: server.pairingKey, sessionID: target.sessionID, paneID: target.paneID)
        case .bySession:
            guard let endpoint, let server else { return false }
            let chosen = endpoint.decideAttach(
                hostKey: server.pairingKey,
                predefinedWorkspaceName: server.workspaceName,
                chosenSessionID: target.sessionID,
                reader: wholeReader
            )
            // The decide above is the last one the client made, so the plan
            // and the question are read again for whatever is drawn next.
            defer { refreshDecision() }
            guard chosen.plan == .attachByID else {
                return false
            }
            return open(
                reattachSessionID: chosen.reattachSessionID,
                workspaceID: chosen.workspaceID,
                workspaceName: chosen.workspaceName,
                reattachPolicy: .attachOnly,
                opening: .OpensListed,
                doesRevealPane: target.paneID != 0
            )
        }
    }

    /// Opens what a row stands for: selects it, so Core's rule is handed it
    /// as the person's choice, and carries the plan out.
    ///
    /// - Parameter row: The row.
    /// - Returns: Whether a window opened or came forward.
    @discardableResult
    func open(_ row: HostOutlineRow) -> Bool {
        selection = row.key
        return performPrimaryAction()
    }

    /// Attaches to the workspace the person picked in answer to Core's
    /// question.
    ///
    /// - Parameter candidate: The candidate, as Core listed it.
    /// - Returns: Whether a window opened or came forward.
    @discardableResult
    func answerQuestion(with candidate: HostAttachQuestion.Candidate) -> Bool {
        presentedQuestion = nil
        return attach(candidate.open)
    }

    /// Runs the connect that was waiting for the host's answer, now that it is
    /// here.
    private func runPendingConnect() {
        guard isConnectPending else {
            return
        }
        isConnectPending = false
        let didOpenWindow = pendingConnectDidOpenWindow
        pendingConnectDidOpenWindow = nil
        if connect() {
            didOpenWindow?()
        }
    }

    /// Forgets a connect that was waiting, because the host it waited on is no
    /// longer the one this directory is about, cannot be asked, or the person
    /// cancelled it.
    func dropPendingConnect() {
        isConnectPending = false
        pendingConnectDidOpenWindow = nil
    }

    /// The open window and pane that executing Core's plan would reuse.
    /// This also works before a host has answered with a workspace row.
    private func existingWindowMatch() -> RemoteWindowRegistry.Match? {
        guard let request = existingWindowRequest else { return nil }
        return RemoteWindowRegistry.existingWindow(for: request)
    }

    /// The plan's exact target, reported to the same registry the spawn uses.
    private var existingWindowRequest: RemoteWindowRegistry.Request? {
        guard let server, let decision, case .success(let transport) = HostTransport.plan(for: server) else { return nil }
        let snapshot = endpoint?.snapshot
        return RemoteWindowRegistry.Request(
            shellCommand: transport.shellCommand,
            workspaceID: decision.workspaceID,
            sessionID: decision.reattachSessionID,
            workspaceName: decision.workspaceName,
            daemonSocketName: snapshot.map { String($0.daemonSocketName) } ?? "",
            daemonInstanceID: decision.reattachSessionID == 0 ? 0 : (snapshot?.daemonInstanceID ?? 0)
        )
    }

    /// Whether an open window here shows a workspace.
    ///
    /// - Parameter row: A workspace's row.
    /// - Returns: Whether one does.
    func isShownHere(_ row: HostOutlineRow) -> Bool {
        guard row.level == .workspace, row.workspaceState != .restorable, let id = row.id, let workspaceID = UInt32(exactly: id.number),
            let server, case .success(let transport) = HostTransport.plan(for: server)
        else {
            return false
        }
        let snapshot = endpoint?.snapshot
        return
            !RemoteWindowRegistry.matches(
                for: RemoteWindowRegistry.Request(
                    shellCommand: transport.shellCommand,
                    workspaceID: workspaceID,
                    sessionID: 0,
                    workspaceName: "",
                    daemonSocketName: snapshot.map { String($0.daemonSocketName) } ?? "",
                    daemonInstanceID: 0
                )
            )
            .isEmpty
    }

    /// Core's word on a workspace's row: the one a remembered pairing returns
    /// to, or the one the saved host always opens.
    enum RowMarker: Equatable {
        case lastUsed
        case alwaysOpens
    }

    /// The marker Core's plan puts on a row, nil for none.
    ///
    /// - Parameter row: The row.
    /// - Returns: The marker, on the row of the workspace the plan lands in.
    func marker(for row: HostOutlineRow) -> RowMarker? {
        let workspaceID = row.level == .workspace ? UInt32(exactly: row.id?.number ?? 0) ?? 0 : 0
        switch Ubiquitty.Runtime.connectRowMarker(connectActionFacts, workspaceID) {
        case .lastUsed: return .lastUsed
        case .alwaysOpens: return .alwaysOpens
        default: return nil
        }
    }

    /// Core's facts are derived once when the plan, selection or open windows
    /// change, not by every row asking for its marker.
    private var decidedActionFacts = Ubiquitty.Runtime.ConnectActionFacts()

    private func refreshActionFacts() {
        var facts = Ubiquitty.Runtime.ConnectActionFacts()
        if let server, let decision {
            if let endpoint {
                facts = endpoint.connectActionFacts(
                    hostName: server.displayName,
                    decision: decision,
                    reader: wholeReader,
                    selected: outline.row(for: selection)
                )
            } else {
                facts.hostName = std.string(server.displayName)
                facts.isDecided = true
                facts.plan = decision.core.plan
                facts.decidedSessionID = decision.sessionID
                facts.decidedWorkspaceID = decision.workspaceID
                facts.decidedWorkspaceName = std.string(decision.workspaceName)
            }
            facts.isLandingShownHere = facts.isLandingShownHere || existingWindowMatch() != nil
        }
        decidedActionFacts = facts
    }

    /// Core's connect facts with the window's pending action reported.
    private var connectActionFacts: Ubiquitty.Runtime.ConnectActionFacts {
        var facts = decidedActionFacts
        facts.isConnectPending = isConnectPending
        return facts
    }

    /// Whether New Session stands beside the default button as a different
    /// action, as Core's plan says. False on a host that answered none, where
    /// the default button is already the new session.
    var isNewSessionOffered: Bool {
        decision?.isNewSessionOffered ?? false
    }

    /// What Return does, titled from Core's plan.
    var primaryAction: ConnectPrimaryAction {
        let action = Ubiquitty.Runtime.connectAction(connectActionFacts)
        let effect: ConnectPrimaryAction.Effect
        switch action.effect {
        case .waiting: effect = .waiting
        case .reveal: effect = .showWindow
        case .connect: effect = .connect(HostAttachPlan(rawValue: action.plan.rawValue) ?? .awaitListing)
        default: effect = .none
        }
        return ConnectPrimaryAction(
            title: String(action.title),
            sentence: String(action.sentence),
            effect: effect,
            isEnabled: action.isEnabled
        )
    }

    /// A count of sessions, inflected.
    ///
    /// - Parameter count: How many.
    /// - Returns: "1 session", "3 sessions".
    static func sessionCount(_ count: Int) -> String {
        HostWords.sessionCount(count)
    }

    #if UBIQUITTY_UI_TESTS
    private var sectionFactsForTesting: Ubiquitty.Runtime.HostSectionFacts?

    /// How many times the host has been asked, for a scenario counting asks.
    @ObservationIgnored
    var refreshCountForTesting = 0

    /// The token the last ask presented, for a scenario.
    @ObservationIgnored
    var lastAuthTokenForTesting = ""

    /// Whether an ask stops short of dialling, for a scenario that stands the
    /// host up itself: a real errand to an address that resolves nowhere
    /// would settle later and report over the tree the scenario held.
    @ObservationIgnored
    var isDiallingSuppressedForTesting = false

    /// The plan ``connect()`` would carry out, without opening a window.
    ///
    /// - Returns: The plan, or nil when the directory points at no host.
    func plannedConnectForTesting() -> HostConnectDecision? {
        refreshDecision()
        return decision
    }

    /// What the default button says and does, as the window would show it.
    ///
    /// - Returns: The title, the sentence, the plan and whether it is enabled.
    func primaryActionForTesting() -> ConnectPrimaryAction {
        refreshDecision()
        return primaryAction
    }

    /// Stands the showcase host up in the directory's own client as though
    /// the host had answered with it.
    ///
    /// The errand needs a daemon and a carrier; the rows, the rule over them
    /// and the question it asks need neither, and this is what lets a
    /// scenario drive them through the client the window reads. A connect
    /// waiting for the answer runs from it, as it would from the host's.
    ///
    /// - Parameter state: How the tree is held.
    func holdShowcaseHostForTesting(_ state: UBShowcaseHostState) {
        guard let server, case .success(let transport) = HostTransport.plan(for: server) else { return }
        attachEndpoint(transport).holdShowcaseHostForTesting(state)
    }

    /// Stands an errand up as though one were out and unanswered, without
    /// dialling anything.
    func markListingOutstandingForTesting() {
        phase = .asking
        var facts = Ubiquitty.Runtime.HostSectionFacts()
        facts.progress = .asking
        sectionFactsForTesting = facts
    }

    /// Stands a listing outcome up as though Core had reported it.
    ///
    /// - Parameters:
    ///   - phase: Where the listing stands.
    ///   - failure: Why it failed, nil for none.
    func setSnapshotForTesting(phase: HostListingPhase, failure: HostListingFailure?) {
        self.phase = phase
        self.failure = failure
        var facts = Ubiquitty.Runtime.HostSectionFacts()
        switch phase {
        case .notAsked: facts.progress = .notAsked
        case .asking: facts.progress = .asking
        case .listed: facts.progress = .listed
        case .failed: facts.progress = .failed
        }
        if let failure {
            switch failure.kind {
            case .unreachable: facts.failure = .Unreachable
            case .notInstalled: facts.failure = .NotInstalled
            case .signInRequired: facts.failure = .SignInRequired
            case .authenticationAttemptsExhausted: facts.failure = .AuthenticationAttemptsExhausted
            case .endedBeforeAnswer: facts.failure = .EndedBeforeAnswer
            case .instanceGone: facts.failure = .InstanceGone
            case .instanceUnreadable: facts.failure = .InstanceUnreadable
            case .malformed: facts.failure = .Malformed
            case .refused: facts.failure = .Refused
            }
            facts.deniedReason = failure.deniedReason
            facts.olderSide = failure.olderSide
            facts.remotePlatform = std.string(failure.remotePlatform)
        }
        sectionFactsForTesting = facts
        if phase == .failed, isConnectPending {
            dropPendingConnect()
        }
    }
    #endif

    /// Starts a session the host was not already holding.
    ///
    /// Unnamed unless a name is given, whatever the saved row's workspace name
    /// says: the saved name is what makes a connect attach-or-create, and a
    /// person asking for a new session beside the named one is asking for one
    /// the name does not answer for. It outlives the window that opened it, as
    /// every session on the host does.
    ///
    /// - Parameter workspaceName: The name to create the session under, empty
    ///   for an unnamed one.
    /// - Returns: Whether a window opened.
    @discardableResult
    func newSession(named workspaceName: String = "") -> Bool {
        presentedQuestion = nil
        return open(reattachSessionID: 0, workspaceID: 0, workspaceName: workspaceName, reattachPolicy: .attachOrCreate, opening: .Creates)
    }

    /// Updates the host this directory refused for its version, in a window
    /// that installs before it dials and then opens the session by name.
    ///
    /// The window is not pinned to the daemon the listing reached: that
    /// daemon runs the build being replaced.
    ///
    /// - Parameter workspaceName: The name to open the session under once the
    ///   new host is installed, empty for an unnamed one.
    /// - Returns: Whether a window opened.
    @discardableResult
    func updateHost(named workspaceName: String = "") -> Bool {
        open(
            reattachSessionID: 0,
            workspaceID: 0,
            workspaceName: workspaceName,
            reattachPolicy: .attachOrCreate,
            opening: .Creates,
            hostUpdatePlatform: failure?.remotePlatform ?? ""
        )
    }

    /// Opens a window on the host with one attach spelled out.
    ///
    /// - Parameters:
    ///   - reattachSessionID: The session to re-home to, or 0 for a fresh one.
    ///   - workspaceID: The workspace Core's plan lands in, 0 for none.
    ///   - workspaceName: The workspace to attach under or create under, empty
    ///     for none.
    ///   - reattachPolicy: What the attach asks when `reattachSessionID` has
    ///     ended.
    ///   - opening: Whether the window creates what it opens or opens what
    ///     the listing showed, which decides the daemon it dials.
    ///   - hostUpdatePlatform: When set, the window updates the host for that
    ///     `uname -sm` before it dials, unpinned from the listed daemon.
    ///   - doesRevealPane: Whether the attached session's pane is shown on
    ///     its host once the layout has arrived.
    /// - Returns: Whether a window opened.
    private func open(
        reattachSessionID: UInt32,
        workspaceID: UInt32,
        workspaceName: String,
        reattachPolicy: RemoteReattachPolicy,
        opening: Ubiquitty.Session.ListedOpen,
        hostUpdatePlatform: String? = nil,
        doesRevealPane: Bool = false
    ) -> Bool {
        guard var server else {
            return false
        }
        let snapshot = endpoint?.snapshot
        let listedSocket = snapshot.map { String($0.daemonSocketName) } ?? ""
        let pin = listedSocket.withCxxStringView {
            Ubiquitty.Session.pinForListedOpen(
                hostUpdatePlatform == nil ? opening : .Creates,
                reattachSessionID,
                $0,
                snapshot?.daemonInstanceID ?? 0
            )
        }
        // A window that creates dials the host's current daemon, so it does
        // not go through the daemon the person picked to list.
        if pin.socketName.empty() {
            server.daemonInstance = nil
        }
        let transport: HostTransportPlan
        switch HostTransport.plan(for: server) {
        case .success(let plan):
            transport = plan
        case .failure(let refusal):
            present(refusal, for: server)
            return false
        }
        let window = TerminalWindowController.spawnRemoteWindow(
            shellCommand: transport.shellCommand,
            hostLabel: server.displayName,
            quicHost: transport.quicHost,
            quicBootstrapCommand: transport.quicBootstrapCommand,
            deploySSHHost: transport.deploySSHHost,
            deployBinaries: HostTransport.deployBinaries(forDeploySSHHost: transport.deploySSHHost),
            reattachSessionID: reattachSessionID,
            workspaceName: workspaceName,
            reattachPolicy: reattachPolicy,
            hostKey: server.pairingKey,
            workspaceID: hostUpdatePlatform == nil && reattachSessionID != 0 ? workspaceID : 0,
            daemonSocketName: String(pin.socketName),
            daemonInstanceID: pin.daemonInstanceID,
            updatingHostFor: hostUpdatePlatform
        )
        guard let window else {
            let words = HostWords.windowNotOpened(hostName: server.displayName)
            notice = HostDirectoryNotice(title: words.title, message: words.message)
            return false
        }
        if doesRevealPane {
            window.remoteSurface?.drive.revealRemoteWorkspacePaneWhenAttached()
        }
        return true
    }

    /// Puts a refusal to dial in front of the person, in this app's own words.
    ///
    /// - Parameters:
    ///   - refusal: Why the host cannot be dialled.
    ///   - server: The host.
    private func present(_ refusal: HostTransportRefusal, for server: HostServer) {
        phase = .notAsked
        dropPendingConnect()
        // A state of the window, never an alert: the content says why and
        // offers to edit the host, and nothing modal stands between the
        // person and the fix.
        transportRefusal = refusal
    }

    /// The connect Core's rule makes for a name the person typed for a new
    /// session.
    ///
    /// - Parameter workspaceName: The typed name.
    /// - Returns: The plan, or nil when the directory points at no host.
    func plannedConnect(named workspaceName: String) -> HostConnectDecision? {
        guard let server else {
            return nil
        }
        guard let endpoint else {
            return HostConnectDecision(
                UbiquittyKit.HostDirectory.decideBeforeListing(host: server.pairingKey, predefinedWorkspaceName: workspaceName)
            )
        }
        return endpoint.decideAttach(
            hostKey: server.pairingKey,
            predefinedWorkspaceName: workspaceName,
            chosenSessionID: 0,
            reader: wholeReader
        )
    }
}

/// Core's question before a request that ends sessions, as an alert.
///
/// The alert and the reading of its answer are one piece, so a caller cannot
/// pair the buttons with the wrong response. Every word is Core's; what is
/// decided here is the shape every destructive alert in this app takes: the
/// button that ends nothing is first and so is the one Return picks.
enum HostDestructiveAlert {
    /// Presents the same safe-default question on any host-outline window.
    ///
    /// - Parameters:
    ///   - question: Core's question and authorization token.
    ///   - directory: The client that asked it and will carry it out.
    ///   - window: The window the person acted in.
    /// - Returns: The presented alert, or nil while another sheet is up.
    @MainActor
    static func present(_ question: HostDestructiveQuestion, for directory: HostDirectoryModel, on window: NSWindow) -> NSAlert? {
        guard window.attachedSheet == nil else { return nil }
        let alert = alert(for: question)
        // AppKit reserves Escape for a button called Cancel. Core names the
        // safe button for what it keeps, so Escape explicitly picks it.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak alert] event in
            guard event.keyCode == 53, let window, let sheet = alert?.window, window.attachedSheet === sheet else { return event }
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            return nil
        }
        alert.beginSheetModal(for: window) { response in
            if let escape { NSEvent.removeMonitor(escape) }
            if isConfirmed(response) {
                directory.carryOut(question)
            } else if directory.destructiveQuestion == question {
                directory.destructiveQuestion = nil
            }
        }
        return alert
    }

    /// The alert, unpresented.
    ///
    /// - Parameter question: Core's question.
    /// - Returns: The alert to run.
    @MainActor
    static func alert(for question: HostDestructiveQuestion) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.body
        alert.alertStyle = .critical
        // Each button is styled from the role Core gives it, never from its
        // place: the safe default first, so it is the one Return picks.
        for button in question.buttons {
            alert.addButton(withTitle: button.title).hasDestructiveAction = button.isDestructive
        }
        return alert
    }

    /// Whether a modal response is the one that goes through.
    ///
    /// Anything but the explicit second button ends nothing, so a dismissed
    /// alert leaves every session alone.
    ///
    /// - Parameter response: What the alert returned.
    /// - Returns: Whether to send the request.
    static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }
}
