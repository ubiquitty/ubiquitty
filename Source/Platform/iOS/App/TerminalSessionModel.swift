// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Crypto
import Foundation
import NIOSSH
import Observation
import UIKit
import UbiquittyAppleCallbacks
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittyKit
import UbiquittySSH
import UniformTypeIdentifiers
import UserNotifications

import enum UbiquittyRenderKit.ConsentDecision
import struct UbiquittyRenderKit.HostDaemonInstance
import struct UbiquittyRenderKit.HostOutline
import struct UbiquittyRenderKit.HostOutlineIdentity
import struct UbiquittyRenderKit.HostOutlineOpenWorkspace
import struct UbiquittyRenderKit.HostOutlineReader
import struct UbiquittyRenderKit.HostOutlineRow
import struct UbiquittyRenderKit.HostOutlineWindowPlace
import class UbiquittyRenderKit.RuntimeDrive

/// What a connect should do about the host's sessions.
///
/// Never chosen by this shell: every case is made from a plan
/// ``UbiquittyKit/HostDirectory/decideBeforeListing(host:predefinedWorkspaceName:)``
/// or ``TerminalSessionModel/decideHostAttach(on:)`` answered, or from a row the person picked out of the list that plan asked
/// for. The three cases are the three shapes the attach doors take —
/// `reattachSessionID`, `workspaceName`, or neither.
enum HostAttachIntent: Hashable, Codable {
    /// A fresh unnamed session.
    case newSession
    /// Re-home to a session the host listed.
    case session(UInt32, daemonSocketName: String, daemonInstanceID: UInt64, hostInstance: HostDaemonInstance? = nil)
    /// Attach to the workspace bearing this name, or create it under the name.
    case workspace(String, daemonSocketName: String = "", daemonInstanceID: UInt64 = 0, hostInstance: HostDaemonInstance? = nil)

    var daemonSocketName: String {
        switch self {
        case .newSession: ""
        case .session(_, let socketName, _, _), .workspace(_, let socketName, _, _): socketName
        }
    }

    var daemonInstanceID: UInt64 {
        switch self {
        case .newSession: 0
        case .session(_, _, let instanceID, _), .workspace(_, _, let instanceID, _): instanceID
        }
    }

    var hostInstance: HostDaemonInstance? {
        switch self {
        case .newSession: nil
        case .session(_, _, _, let instance), .workspace(_, _, _, let instance): instance
        }
    }

    /// This intent on the daemon the person picked, for an intent that opens
    /// what that daemon listed.
    ///
    /// A new session is never pinned: it is created on the host's current
    /// daemon, which a remembered or picked daemon may no longer be.
    func targeting(_ instance: HostDaemonInstance?, socket: String, daemon: UInt64) -> Self {
        guard let instance else { return self }
        switch self {
        case .newSession: return self
        case .session(let id, let socket, let daemon, _):
            return .session(id, daemonSocketName: socket, daemonInstanceID: daemon, hostInstance: instance)
        case .workspace(let name, let heldSocket, let heldDaemon, _):
            return .workspace(
                name,
                daemonSocketName: heldSocket.isEmpty ? socket : heldSocket,
                daemonInstanceID: heldDaemon == 0 ? daemon : heldDaemon,
                hostInstance: instance
            )
        }
    }

    /// The initial bootstrap is bound to the same daemon as the selected row.
    var bootstrapCommand: String? {
        let socketName = daemonSocketName
        if case .session = self, socketName.isEmpty { return nil }
        guard socketName.isEmpty == (daemonInstanceID == 0),
            socketName.utf8.count <= Int(UInt16.max),
            socketName.utf8.allSatisfy({ byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte == 46 || byte == 95 || byte == 45
            })
        else { return nil }
        let baseCommand = String(Ubiquitty.Session.quicBootstrapRemoteCommand())
        let command = hostInstance?.bootstrap(baseCommand, pinInitialOwner: false) ?? baseCommand
        guard !command.isEmpty else { return nil }
        return command.withCString { commandBytes in
            socketName.withCString { socketBytes in
                String(Ubiquitty.Session.substituteReattachSocket(std.string_view(commandBytes), std.string_view(socketBytes)))
            }
        }
    }
}

/// How a request to end one of a host's sessions settled.
///
/// The session is carried beside the outcome because a picker holding several
/// rows cannot tell which one an answer is about without it.
struct HostSessionTerminateReport: Identifiable {
    let id = UUID()
    let sessionID: UInt32
    /// What the daemon did, or nil for an outcome this build does not know —
    /// which is never read as the session being gone.
    let outcome: HostSessionTerminateOutcome?
    /// Whether the request reached the host at all.
    ///
    /// False when the device could not send it — the directory was busy with
    /// another errand, or there was none — and then `outcome` says nothing,
    /// because the host saw nothing. The five outcomes are Core's vocabulary
    /// for what a HOST answered, and a request that never left the device is
    /// not one of them.
    var didReachTheHost = true
    /// Core's sentence for why a request was not sent; empty when it was.
    var whyNotSent = ""
}

/// A change asked of the host's structure that was not made, and why.
struct HostStructureRefusal: Identifiable, Equatable {
    /// The change's number, so two refusals in a row are two reports.
    let requestID: UInt64
    /// Why, as Core or the host worded it.
    let reason: String

    var id: UInt64 { requestID }
}

/// A picked session the connect could not reach, and why.
///
/// Held until the person answers it: a session kept on the host is reached
/// only over its QUIC carrier, and a login shell opened in its place is a
/// different shell under the same chrome.
struct UnreachedPick: Equatable {
    /// The picked session, as the person knows it.
    let name: String
    /// Why it was not reached, in one sentence.
    let reason: String
    /// Whether a login shell over SSH is a way forward: only when the host was
    /// reached and the workspace's QUIC carrier is what it could not have.
    /// A host that was never reached would fail a login shell the same way.
    var offersLoginShell = false
}

/// What asking a host for its QUIC carrier came to.
private enum QUICCarrierAnswer {
    /// A factory for the carrier, held for the session's whole life.
    case carrier(OpaquePointer)
    /// The host was reached and offered none; the sentence says so.
    case declined(String)
    /// The host was never reached; the sentence says why.
    case unreachable(String)
}

/// One live terminal: a connection, the shared surface, and the wire between.
///
/// The model, the parser, the renderer and the grid are all the surface's —
/// which is to say Core's, and shared with the macOS app. This holds the two
/// things that are genuinely this shell's: which host is dialled, and what the
/// person sees about the link.
@Observable
@MainActor
final class TerminalSessionModel: TerminalSurfaceObserver {
    /// The title the shell most recently set, empty until it sets one.
    private(set) var title = ""
    private(set) var hasUnheardBell = false
    private(set) var programStatusLabel = ""
    private(set) var programStatusColor: UIColor?
    /// Whether a terminal screen for this session is on screen.
    var isScreenVisible: Bool { visibleScreenCount > 0 }

    /// How many terminal screens for this session are on screen.
    ///
    /// A count rather than a flag: a window whose width class changes can put
    /// the new screen up before it takes the old one down, and a flag the old
    /// screen cleared last would read as nothing on screen while one is.
    private var visibleScreenCount = 0

    /// Records a terminal screen for this session coming on screen.
    func screenDidAppear() {
        visibleScreenCount += 1
        clearUnheardBellIfActive()
    }

    /// Records a terminal screen for this session going off screen.
    func screenDidDisappear() {
        assert(visibleScreenCount > 0, "a screen disappeared that never appeared")
        visibleScreenCount = max(0, visibleScreenCount - 1)
    }

    func clearUnheardBellIfActive() {
        if isScreenVisible && UIApplication.shared.applicationState == .active {
            hasUnheardBell = false
        }
    }

    /// A short line for the status area: what the link is doing, or why it stopped.
    private(set) var statusDetail = "Connecting…"
    private(set) var isConnected = false {
        didSet {
            followTheHostWhileWanted()
            if !shouldShowCommandAccessory { keyboardModifiers.clear(.command) }
        }
    }
    private(set) var hasExited = false
    /// Whether the session ended with a reason worth keeping on screen.
    private(set) var hasFailed = false
    /// Presentation history survives detaching the refused carrier. It grants
    /// no authority and is cleared only for a new explicit connection attempt.
    private(set) var lastHostRefusalReason: Ubiquitty.`Protocol`.Sync.ByeReason?
    /// A direct SSH login shell's recovery, never a kept workspace resume claim.
    private(set) var sshFailureSummary: SSHFailurePresentation.Summary?
    /// Why the last attempt failed and what to do about it, from the typed
    /// fact it failed with; nil while nothing has failed.
    private(set) var failure: ConnectionFailure?
    /// How far the connection being made has got, in the words the title
    /// shows while connecting: "Connecting…", "Signing in…", "Starting
    /// session…".
    private(set) var connectingStep = String(localized: "Connecting…")
    /// The picked session this connect could not reach, nil unless one is
    /// waiting on the person's answer.
    private(set) var unreachedPick: UnreachedPick?

    /// Whether this model holds a connection worth returning to: one started
    /// and neither failed nor ended.
    ///
    /// A failed or ended model is not one to go back to. Reopening a host
    /// whose model reads false starts over, and asks again for a password
    /// the last attempt may have been refused with.
    var isLive: Bool { hasBegunConnecting && !hasFailed && !hasExited }

    /// Whether Core is waiting out a backoff before its next dial, which a
    /// person may cut short.
    ///
    /// Read from Core rather than kept here, so it cannot outlive the state it
    /// describes; the status line it sits beside changes with every move, which
    /// is what redraws it.
    var isReconnecting: Bool {
        transport != .ssh && !hasExited && ownedSurface?.drive.remoteState == .Reconnecting
    }

    /// Whether an SSH login shell carrier exists, opened or opening.
    var hasLoginShellCarrier: Bool { carrier != nil }

    /// The host and port this model last dialled, for the sentence a failed
    /// connect is reported in.
    private var dialledHost = ""
    /// The saved host that owns this model, absent for standalone test models.
    var savedHostID: UUID?
    /// This model's attachment incarnation, renewed on every disconnect so a
    /// banner posted before it never answers for the attachment after it.
    private var notificationIncarnationID = UUID()
    /// The dialled host's name as the person knows it, for a sentence that
    /// names it.
    private var dialledHostLabel = ""
    private var dialledPort = 0

    /// The gesture lesson to show, empty when there is nothing to teach.
    ///
    /// Both the words and how long they stand are Core's; the surface hands
    /// over each change and this holds the latest. A phone with no keyboard
    /// attached is never given one at all -- every lesson names a modifier,
    /// and the ladder answers nothing when the reader has none -- so this
    /// staying empty on a bare phone is the intended behaviour, not a shell
    /// that forgot to show it.
    private(set) var hint = ""

    /// The grid the surface opens with, before it is laid out.
    let rows = 24
    let columns = 80
    private(set) var fontError = ""
    /// The family panes draw in, from Core's fold of the live document.
    var fontFamily: String {
        _ = configurationEpoch
        return TerminalSurface.family(of: Ubiquitty.Preferences.Effective.liveRenderConfiguration())
    }
    /// The size panes draw at before their own zoom, from the same fold.
    var fontPointSize: Double {
        _ = configurationEpoch
        return Ubiquitty.Preferences.Effective.liveRenderConfiguration().fontSizePoints
    }
    var accessorySymbols: [TerminalAccessoryKey] {
        _ = configurationEpoch
        return TerminalAccessoryKey.configuredSymbols
    }

    /// Moves on every configure, so native controls redraw from the live preference.
    private(set) var configurationEpoch: UInt64 = 0
    /// Re-dresses every pane when Core is configured again; made with the
    /// first pane.
    @ObservationIgnored
    private var configurationSubscription: Ubiquitty.Preferences.ConfigurationSubscription?

    /// The fingerprint the server offered, once it has offered one.
    var presentedHostKeyFingerprint: String { carrier?.presentedFingerprint ?? bootstrapHostKeyFingerprint }

    /// Whether a keyboard is on screen.
    ///
    /// Read by the surface to decide what a tap means: a reader who can
    /// already type has no other way to press a button, so the tap becomes a
    /// click once the keyboard is up.
    var isKeyboardPresented = false {
        didSet { surface?.isKeyboardPresented = isKeyboardPresented }
    }

    /// Raised when the reader taps with no keyboard up.
    var onKeyboardRequested: (() -> Void)?
    /// Presents the same confirmation used by the on-screen paste action.
    var onPasteRequested: ((String) -> Void)?
    var keyboardModifiers = TerminalKeyboardModifiers()

    /// Raised when the reader swipes two fingers sideways, asking for another connection.
    ///
    /// The model relays it and does nothing else. Which connections are open, and in what order,
    /// is the app's: a model knows only its own.
    var onConnectionSwitchRequested: ((SwipeStep) -> Void)?

    /// A line shown briefly over the grid, empty when none stands — which tab a
    /// swipe landed on, or that there was nowhere to go.
    ///
    /// Held here rather than in the screen because a connection switch
    /// announces on the screen it arrives at, which does not exist yet when
    /// the announcement is made; the model it will draw does.
    private(set) var notice = ""

    /// How long a notice stands.
    static let noticeDuration: Duration = .milliseconds(1200)

    /// What the person is told when the host recreated the workspace after it
    /// restarted: the panes are back, and what they showed is not.
    static let hostRestartNotice = "Restored after the host restarted. Earlier output is gone."

    /// How long that notice stands: a sentence to read, not a tab name to glance at.
    static let hostRestartNoticeDuration: Duration = .seconds(6)

    /// Which notice the pending clear belongs to.
    private var noticeGeneration = 0

    /// Raised when the reader asks for settings with two fingers.
    ///
    /// A closure rather than a published flag, matching the keyboard above: the
    /// ask is an event, and a flag would answer "is the sheet up" — a different
    /// question, owned by the view that presents it.
    var onSettingsRequested: (() -> Void)?

    /// Which carrier a live session actually got.
    ///
    /// Published, and shown, because the two are indistinguishable from the
    /// grid: a QUIC dial that fails falls back to SSH and the session works
    /// perfectly, so a reader who asked for QUIC has no way to learn they did
    /// not get it. This item exists to make the phone speak QUIC; a silent
    /// fallback would let it be called done while never once dialling.
    enum Transport: String {
        /// Bytes over the SSH channel itself.
        case ssh = "SSH"
        /// Sync over a pinned QUIC carrier.
        case quic = "QUIC"
        /// The same kept host session's Sync stream over a pinned SSH exec channel.
        case syncSSH = "Sync+SSH"
    }

    /// The transport in force, once one is.
    private(set) var transport: Transport = .ssh
    /// Why QUIC was not used, when it was asked for and not obtained.
    ///
    /// Kept so the settings sheet can say what happened rather than silently
    /// showing SSH: "the host offered no QUIC bootstrap" is a fact about the
    /// host worth reading, not a failure to hide.
    private(set) var quicRefusal = ""
    /// Every step of the current connection attempt, for the settings sheet.
    ///
    /// Beside quicRefusal rather than replacing it: the refusal is the one line
    /// a reader needs, and this is the trail behind it for when that line is
    /// not enough to say which end is at fault.
    let connectionLog = ConnectionLog()

    /// The theme in force, by name, or empty for the default.
    ///
    /// Held here rather than read back from the surface because it survives the
    /// surface: SwiftUI rebuilds the view, and the theme a person chose has to
    /// outlive that.
    private(set) var themeName: String = ""
    private var systemAppearance: Ubiquitty.Themes.AutomaticAppearance = .Dark
    private var appliedDefaultTheme: Int32?
    private var appliedRemoteTheme: Int32?
    private var isRefreshingPanes = false

    /// A saved host can override the app theme; otherwise Core resolves the system pair.
    private var preferredThemeIndex: Int32 {
        if let index = TerminalSurface.themeNames.firstIndex(of: themeName) { return Int32(index) }
        let values = Ubiquitty.Preferences.values().pointee
        if Ubiquitty.Preferences.followSystemAppearanceEffective(values.followSystemAppearance) {
            return Ubiquitty.Themes.resolvedAutomaticThemeIndex(systemAppearance)
        }
        return Ubiquitty.Runtime.launchThemeIndex(values)
    }

    func setSystemAppearance(isDark: Bool) {
        systemAppearance = isDark ? .Dark : .Light
        applyDefaultThemeIfChanged()
    }

    private func applyDefaultThemeIfChanged() {
        applyRemoteThemeIfNeeded()
        guard themeName.isEmpty else { return }
        let index = preferredThemeIndex
        guard index >= 0, appliedDefaultTheme != index else { return }
        appliedDefaultTheme = index
        if let ownedSurface { apply(themeAt: Int(index), to: ownedSurface) }
        for pane in paneSurfaces.values where pane !== ownedSurface { apply(themeAt: Int(index), to: pane) }
        refreshGround()
    }

    /// Sends the selected palette after admission; a pre-attach local palette
    /// is replaced by the host's first checkpoint.
    private func applyRemoteThemeIfNeeded() {
        guard let anchor = ownedSurface, anchor.isRemoteAttached else { return }
        guard anchor.drive.remoteState == .Connected else {
            appliedRemoteTheme = nil
            return
        }
        let index = preferredThemeIndex
        guard appliedRemoteTheme != index, anchor.applyTheme(at: Int(index)) else { return }
        appliedRemoteTheme = index
    }

    /// The rows of the host's outline: Core's, over the tree the host last
    /// answered with. Empty before the first answer, for a host holding
    /// nothing, and for a question that could not be asked; the connect rule
    /// tells those apart with ``hasHostAnsweredSessions``.
    ///
    /// Compact, as a phone lists a host: each workspace starts closed on one
    /// row that carries what it hides, and opening it lists its tabs.
    let hostOutline = HostOutlineStore(platformMarks: [], density: .compact)
    /// The same tree read with every row open, for the rows that need the
    /// person wherever they are: Core's second line names a question, a
    /// request or a failure on the row that stands for one pane.
    let hostOutlineEveryRow = HostOutlineStore(platformMarks: [])
    /// The same tree as the Hosts screen reads it under this host's row:
    /// compact, with a search of its own, so filtering the hosts does not
    /// filter the host's own workspaces screen.
    let hostListOutline = HostOutlineStore(platformMarks: [], density: .compact)

    /// How current Core says the tree behind the outlines is.
    private(set) var hostTreeFreshness = HostOutlineFreshness.none

    /// Whether the outline is the host's word now: this device's connection
    /// is up and a connected watch follows the host's tree. Anything else —
    /// a listing answered before, a watch that lost its host — is not shown
    /// as what the host holds.
    var isHostOutlineLive: Bool { isConnected && hostTreeFreshness == .live }

    /// Whether a screen that lists the host's outline beside its connection
    /// is on screen, which is what makes the host worth following.
    private var isHostOutlineShown = false
    /// Whether this model asked Core to follow the host.
    private var isFollowingHost = false
    /// Whether the app is in the background, where nothing is drawn and a
    /// watch would hold a connection for no one.
    private var isBackgroundedForFollowing = false
    private(set) var hostSessionDaemonSocketName = ""
    private(set) var hostSessionDaemonInstanceID: UInt64 = 0
    /// The socket of the pinned daemon this model's bootstrap last reported
    /// gone, empty when none was.
    private(set) var goneDaemonSocketName = ""

    /// Whether a daemon picked to list has gone, as Core decides it from
    /// what this model's bootstrap and listing reported.
    ///
    /// - Parameter picked: The daemon the person picked.
    /// - Returns: Whether the pick gives way to the host's current daemon.
    func isGone(_ picked: HostDaemonInstance) -> Bool {
        let answered = hasHostAnsweredSessions ? hostSessionDaemonSocketName : ""
        return picked.socketName.withCString { pickedName in
            goneDaemonSocketName.withCString { goneName in
                answered.withCString {
                    Ubiquitty.Session.isPickedDaemonGone(std.string_view(pickedName), std.string_view(goneName), std.string_view($0))
                }
            }
        }
    }

    /// Retains the authority that supplied a selected session row.
    func attachIntent(forSession sessionID: UInt32) -> HostAttachIntent {
        .session(sessionID, daemonSocketName: hostSessionDaemonSocketName, daemonInstanceID: hostSessionDaemonInstanceID)
    }

    /// Retains the directory authority for a named workspace selection.
    func attachIntent(forWorkspace workspaceName: String) -> HostAttachIntent {
        .workspace(workspaceName, daemonSocketName: hostSessionDaemonSocketName, daemonInstanceID: hostSessionDaemonInstanceID)
    }

    /// The connect opening one of the outline's rows makes, as Core's row
    /// says it is opened: the pane's session, revealed where it stands, or
    /// the workspace restored; nil for a row Core says cannot be opened.
    ///
    /// - Parameter row: The row.
    /// - Returns: The connect, or nil.
    func attachIntent(for row: HostOutlineRow) -> HostAttachIntent? {
        switch row.open.how {
        case .bySession: return attachIntent(forSession: row.open.sessionID)
        case .byRevealing:
            guard let selected = heldSurface(for: row) else { return nil }
            return attachIntent(forSession: selected.remoteSessionID)
        case .byRestoring: return attachIntent(forWorkspace: row.open.workspaceName)
        case .cannot: return nil
        }
    }

    /// Opens a row in this model, preserving the carrier when Core says its
    /// workspace is already held. The held session identifies the connection;
    /// the pane identifies what the person chose inside it.
    func openHostOutlineRow(_ row: HostOutlineRow) -> HostAttachIntent? {
        guard row.open.how == .bySession || row.open.how == .byRevealing,
            let selected = heldSurface(for: row), let attachedIntent
        else { return attachIntent(for: row) }
        selectPane(row.open.paneID)
        selected.drive.revealRemoteWorkspacePaneWhenAttached()
        return attachedIntent
    }

    private func heldSurface(for row: HostOutlineRow) -> TerminalSurface? {
        guard let anchor = ownedSurface,
            anchor.drive.matchesRemoteWorkspace(
                shellCommand: "",
                workspaceID: row.open.workspaceID,
                sessionID: row.open.sessionID,
                workspaceName: row.open.workspaceName,
                daemonSocketName: hostSessionDaemonSocketName,
                daemonInstanceID: hostSessionDaemonInstanceID
            )
        else { return nil }
        return paneSurfaces[row.open.paneID]
    }

    /// Whether ``hostOutline`` draws the host's answer, rather than the rows
    /// left by an ask that never reached it.
    ///
    /// An empty list the host sent means it holds nothing; an empty list
    /// because nobody heard back means nothing at all, and the connect rule
    /// reading the second as the first would open a fresh session beside the
    /// one the host still holds.
    private(set) var hasHostAnsweredSessions = false

    /// Whether a directory errand is in flight.
    private(set) var isAskingHostForSessions = false

    /// Whether the host's answer still describes what it holds, as far as
    /// this device knows.
    ///
    /// An answer is read before a connect and not after it: attaching or
    /// starting a workspace changes what the host holds, so the answer from
    /// before is out of date the moment this model connects, and an empty
    /// one would claim the host holds nothing while this device is attached
    /// to a workspace on it. A screen shows such an answer as being asked
    /// again, never as the host's word.
    private(set) var isHostAnswerCurrent = false

    /// A listing superseded by an attach. Its queued notification can still
    /// drain, but only a later tree may complete the next listing request.
    private var supersededHostTreeRevision: UInt64?

    /// When the host last answered, for a screen that says how current its
    /// list is; nil before an answer.
    private(set) var hostAnsweredAt: Date?

    /// How a change asked of the host's structure ended — a rename — once it
    /// was refused or went unanswered; nil until one does. A served change
    /// needs no report: the listing that follows it shows it.
    private(set) var lastStructureRefusal: HostStructureRefusal?

    /// Whether this model has been asked to connect since it was made.
    private var hasAskedToConnect = false
    #if UBIQUITTY_IOS_UI_TESTS
    /// How many asks a seeded host's directory has refused.
    private var seededRefusals = 0
    #endif

    /// How many times in a row the host's directory was too busy to be asked.
    private var listingRetries = 0
    /// The ask waiting to be made again once the directory is free.
    private var listingRetry: Task<Void, Never>?

    /// How many times an errand has settled, either way.
    ///
    /// A count rather than the two flags a screen could watch: an errand that
    /// ends without ever reaching the host leaves the rows and the flag exactly
    /// as it found them, and a screen waiting on a change would wait forever.
    /// This moves on every answer, including the empty one.
    private(set) var hostSessionAnswers = 0

    /// The host's own sentence for a reattach it would not honour, empty
    /// unless one was refused.
    ///
    /// Kept after the failed attach so the picker the person lands back on can
    /// say why they are looking at it. Cleared when the next listing starts.
    private(set) var reattachRefusal = ""

    /// How the last terminate settled, nil until one does.
    private(set) var lastTerminateReport: HostSessionTerminateReport?

    /// How many clients other than this one are attached to this session.
    ///
    /// Core's count, refreshed by ``refreshAttendance()`` when a screen is
    /// about to show it: the roster arrives as an event this shell has no
    /// chrome of its own to spend on, and the settings sheet is the one place
    /// it is read.
    private(set) var otherAttendeeCount = 0

    /// The session this screen is for, as a sentence a person can read.
    ///
    /// The screen knows which session it asked for the moment it is pushed, and
    /// which one the host acknowledged once the handshake lands, and it shows
    /// them: without either, a person on a shared host cannot tell which of its
    /// sessions they are looking at. The asked-for id is kept while the answer
    /// is outstanding rather than left blank: a connect that never completes is
    /// exactly when knowing what was asked for matters.
    private enum SessionSummary {
        case connecting(String)
        case settled(String)
    }
    private var summaryState = SessionSummary.settled("")
    var sessionSummary: String {
        switch summaryState {
        case .connecting(let target): return target + (hasFailed ? ", not reached" : ", connecting…")
        case .settled(let summary): return summary
        }
    }

    /// What this model was last asked to reach, so a later ask can be told
    /// apart from the same screen returning.
    private var attachedIntent: HostAttachIntent?

    /// The attachment to resume when returning to an existing connection.
    var currentAttachIntent: HostAttachIntent { attachedIntent ?? .newSession }

    /// Whether a connection has been started on this model.
    ///
    /// Read by the screens rather than "does a model exist": the directory
    /// errand builds a model for a host nobody has connected to yet, so the
    /// store holding one no longer means the host is live.
    private(set) var hasBegunConnecting = false

    /// Whether the host was reached and declined a QUIC bootstrap.
    ///
    /// A host that answered "no bootstrap" once is not asked again by the
    /// attach that follows the listing: the answer is about the host, and a
    /// second ssh round trip would buy the same sentence twice. A host that
    /// could not be reached is asked again, because the next attempt may be
    /// made from a network that reaches it.
    private var hasHostDeclinedBootstrap = false

    /// The key the host's pairing is remembered against, empty until a connect
    /// or a listing names one.
    private var pairingKey = ""

    /// The workspace the live attach was made under, empty for an unnamed
    /// session. Half of the pairing that is stored once the host pins an id.
    private var attachedWorkspaceName = ""

    /// Whether the person has been told that the host restarted and this
    /// workspace was recreated, which is said once per attach.
    private var hasAnnouncedHostRestart = false

    /// The surface this session draws on, built here rather than by the view.
    ///
    /// The directory errand runs before any terminal is on screen and needs a
    /// surface to run through, and the attach that follows has to happen on the
    /// same one the terminal will draw — a second surface would list through
    /// one connection and attach through another.
    private var ownedSurface: TerminalSurface?
    private var paneSurfaces: [UInt32: TerminalSurface] = [:]
    private(set) var panes: [TerminalPane] = []
    /// The host's tabs in its order, each with its panes laid out as the
    /// host's split tree lays them: what the tab overview and the tab strip
    /// draw. Set where the panes are listed, and by the seeded workspace.
    var tabs: [TerminalTab] = []
    /// Whether the tab overview is up.
    ///
    /// The model's rather than a screen's, so every control that opens it —
    /// the Tabs button, the title menu, a hardware shortcut — opens the one
    /// overview, and a screen rebuilt by a width change keeps it up.
    var isShowingTabOverview = false
    /// What went wrong with a request about one tab, drawn on that tab's card
    /// rather than in a message row of its own; keyed by the host's tab.
    var tabProblems: [UInt32: String] = [:]
    /// The tabs a request is out for, drawn with progress on their cards.
    var pendingTabIDs: Set<UInt32> = []
    /// The close request out for a tab, read back where the host's answers land.
    var pendingTabClose: (tab: UInt32, surface: TerminalSurface)?
    /// Whether the find bar is up over the focused pane.
    var isFindingInScrollback = false
    /// What the last search of the scrollback answered; nil before one ran.
    var findStatus: TerminalFindStatus?
    /// The pane whose scrollback the find bar last searched, so a search
    /// that moves to another pane clears the matches it left behind.
    weak var findSurface: TerminalSurface?
    /// Whether the panes are the seeded showcase workspace, whose requests
    /// the model answers itself because no host stands behind it.
    var isSeededWorkspace = false
    /// Where the focused pane's view stands in its scrollback, as its surface
    /// last reported; nil before it has reported.
    private(set) var scrollback: TerminalScrollbackPosition?
    private(set) var activePaneID: UInt32 = 0
    var keyboardCloseRequest: KeyboardCloseRequest?
    private(set) var workspaceMessage = ""
    private(set) var completedPaneChanges = 0
    var isChangingPanes: Bool { pendingPaneChangeSurface != nil }
    var canChangePanes: Bool { supportsWorkspace && isConnected && !isChangingPanes }
    private var pendingPaneChangeSurface: TerminalSurface?
    private var pendingCreatedPaneID: UInt32?
    private var pendingClosedPaneID: UInt32?
    private var shouldOpenCreatedTab = false
    private var hasPaneChangeAcknowledgment = false
    private var paneChangeDeadline: Task<Void, Never>?
    /// The panes a wide window shows together, in their places; see
    /// ``TerminalPaneArrangement``. Kept whatever the width, so a window that
    /// widens again shows the pair it showed before.
    private(set) var arrangedPaneIDs: [UInt32] = []
    /// Whether a wide window shows two panes when the workspace has them.
    var prefersTwoPanes = true
    /// The one controller each surface is hosted through.
    ///
    /// A view belongs to at most one view controller, and UIKit raises when a
    /// second claims it. A width change can build a new host before it tears
    /// down the old one, so every host borrows the surface's own controller
    /// rather than making another; see `PaneSurfaceContainer`.
    private var surfaceControllers: [ObjectIdentifier: TerminalSurfaceViewController] = [:]
    /// The pane shown beside the focused one, when two are on screen.
    var visibleCompanionPaneID: UInt32?
    var consentRequest: TerminalConsentRequest?
    /// The pane whose typing may not have reached the host, with Core's
    /// notice for it: the focused pane's when it has one. Nil while no pane
    /// awaits the person's decision.
    private(set) var inputInDoubt: TerminalInputInDoubt?
    var fileDownloadRequest: TerminalFileDownloadRequest?
    var fileMessage = ""
    /// Each transfer that settled and whether it went through, for the
    /// success or error haptic the Files sheet plays.
    private(set) var fileTransferOutcome = SettledOutcome()
    var receivedFile: TerminalFileDocument?
    var receivedFileName = "Download"
    private var requestedFileID: UInt32 = 0
    private var requestedFileSurface: ObjectIdentifier?

    var supportsWorkspace: Bool { ownedSurface?.drive.remoteWorkspaceID != 0 && ownedSurface?.isRemoteAttached == true }
    var supportsFiles: Bool { surface?.isRemoteAttached == true }

    private var carrier: SSHCarrierClient?

    /// What the sign-in is waiting on the person for; nil while it waits on
    /// nobody.
    private(set) var signInPrompt: SignInPrompt?
    /// Takes the person's answer to the password the server asked for.
    @ObservationIgnored
    private var pendingPasswordAnswer: (@Sendable (String?) -> Void)?
    /// Whether the dialled host may keep a password typed at a prompt: it
    /// signs in with a password and nothing usable is saved, so saving one
    /// replaces no key and no credential a kept workspace was sealed with.
    @ObservationIgnored
    private var dialledCanSavePassword = false
    @ObservationIgnored
    private var dialledUsername = ""
    /// A password the person asked to save, held until the server accepts it,
    /// so a mistyped one is never kept.
    @ObservationIgnored
    private var passwordAwaitingAcceptance: String?
    /// Whether this attempt has noted reaching the host, so the step is said
    /// once whichever connection reached it first.
    @ObservationIgnored
    private var hasNotedReach = false
    /// Receives a password the server accepted that the person asked to save.
    @ObservationIgnored
    var onPasswordAccepted: ((String) -> Void)?
    /// Asks the person at most once for every connection of this attempt: the
    /// session listing, the bootstrap ask, the carrier and its reconnects.
    /// Made on the first connection and dropped by ``disconnect()``, so a
    /// refused password is asked for again on the next attempt.
    @ObservationIgnored
    private var signInInteraction: SSHAuthenticationInteraction?

    /// The in-flight bootstrap ask, held so a disconnect can cancel it.
    private var bootstrapProbe: (any QUICBootstrapAsking)?
    /// Makes one bootstrap ask. The probe over SSH; a smoke scripts the
    /// answers in its place.
    @ObservationIgnored
    var makeBootstrapAsk:
        (HostRecord, SSHAuthentication, String, @escaping (QUICBootstrapProbe.Outcome) -> Void) -> any QUICBootstrapAsking =
            TerminalSessionModel.probeOverSSH
    /// Lets a smoke replace provider carriers before any request can open I/O.
    @ObservationIgnored
    var configureCarrierProvider: ((QUICCarrierProvider) -> Void)?

    /// Asks a host for its QUIC bootstrap over an SSH exec session.
    nonisolated private static func probeOverSSH(
        _ record: HostRecord,
        _ credentials: SSHAuthentication,
        _ bootstrapCommand: String,
        _ answer: @escaping (QUICBootstrapProbe.Outcome) -> Void
    ) -> any QUICBootstrapAsking {
        QUICBootstrapProbe(
            host: record.hostName,
            port: record.port,
            username: record.username,
            credentials: credentials,
            pinnedFingerprint: record.pinnedHostKeyFingerprint,
            bootstrapCommand: bootstrapCommand,
            answer: answer
        )
    }

    private var bootstrapGeneration = UUID()
    private var bootstrapDeadline: Task<Void, Never>?
    /// The wait before asking again after an ask failed the way a path still
    /// coming up fails; nil when none is pending.
    private var bootstrapRetry: Task<Void, Never>?
    /// Asks that failed since this connect began, which Core's retry schedule
    /// is read against.
    private var bootstrapFailures = 0
    private var bootstrapWaiters: [(QUICCarrierAnswer) -> Void] = []
    private var bootstrapHostKeyFingerprint = ""
    /// The QUIC carrier factory, held for the session's whole life. See
    /// askForQUICCarrier for why releasing it early breaks reconnection.
    private var quicFactory: OpaquePointer?
    /// The provider behind ``quicFactory``, which the directory errand's own
    /// factory shares.
    private var quicProvider: QUICCarrierProvider?
    /// The running daemon selected in the host directory, independently of the SSH host.
    var hostInstance: HostDaemonInstance?

    var hostInstances: [HostDaemonInstance] { ownedSurface?.drive.hostInstances ?? [] }
    private var coldResume: ColdResumeSession?
    /// The directory errand's factory, from the same provider as the attach's
    /// but a requester of its own, so neither ask replaces the other. Held for
    /// the session's whole life, as ``quicFactory`` is.
    private var directoryQUICFactory: OpaquePointer?
    /// Watches the device's network path so a moved path redials at once rather
    /// than waiting out a backoff measured for a flaky link.
    private var pathWatch: NetworkPathWatch?
    private weak var surface: TerminalSurface?
    private var pendingInbound: [UInt8] = []

    /// The surface for this session, built on the first ask.
    ///
    /// - Returns: The surface, or nil when Core declined a session.
    func surfaceForDrawing() -> TerminalSurface? {
        if let selected = paneSurfaces[activePaneID] { return selected }
        if let ownedSurface {
            return ownedSurface
        }
        guard let created = makePaneSurface() else { return nil }
        ownedSurface = created
        adopt(created)
        return created
    }

    /// Builds every pane with a renderer and the workspace's current appearance.
    ///
    /// The renderer is dressed in Core's fold of the live document — the font,
    /// the frame style, the colour space, the picture behind the grid — the
    /// same call a configure makes on every pane already open.
    func makePaneSurface() -> TerminalSurface? {
        followConfiguration()
        guard let created = TerminalSurface(rows: rows, columns: columns) else { return nil }
        created.adopt(configuration: Ubiquitty.Preferences.Effective.liveRenderConfiguration(), systemTransparency: Self.systemTransparency)
        guard created.renderer != nil else { return nil }
        created.observer = self
        configureFileLinks(on: created)
        // The pane's clients, registered at launch: a clipboard that reaches
        // UIPasteboard through the PAL seam, so a remote program's allowed
        // copy lands, and the frontend's capability policy.
        created.drive.installDefaultClients()
        // The host's chosen theme, else the configured launch theme: the
        // ground the screen already shows, so adopting this pane changes it
        // to nothing. A pane that then attaches beside another takes that
        // session's theme in Core.
        _ = created.applyTheme(at: Int(preferredThemeIndex))
        created.drive.republishSnapshot()
        return created
    }

    /// Whether the system asks for translucency to be given up.
    private static var systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency {
        UIAccessibility.isReduceTransparencyEnabled ? .Reduced : .Allowed
    }

    /// Subscribes to Core's configuration, once.
    private func followConfiguration() {
        guard configurationSubscription == nil else { return }
        configurationSubscription = Ubiquitty.Preferences.ConfigurationSubscription.notifying(
            Ubiquitty.Apple.ownedCallback { [weak self] in
                // Core calls subscribers on the main thread, after the live
                // values are replaced.
                MainActor.assumeIsolated { self?.applyConfiguration() }
            }
        )
    }

    /// Dresses every pane in the live configuration.
    private func applyConfiguration() {
        configurationEpoch &+= 1
        coldResume?.reconcileHistoryPreference()
        let configuration = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
        let surfaces = Array(paneSurfaces.values) + (ownedSurface.map { [$0] } ?? [])
        var visited = Set<ObjectIdentifier>()
        var isRefused = false
        for pane in surfaces where visited.insert(ObjectIdentifier(pane)).inserted {
            if !pane.adopt(configuration: configuration, systemTransparency: Self.systemTransparency) {
                isRefused = true
            }
        }
        fontError = isRefused ? "This font could not be loaded. Choose another font." : ""
        applyDefaultThemeIfChanged()
        refreshTabTitles()
        hostOutline.reload()
        hostOutlineEveryRow.reload()
        hostListOutline.reload()
    }

    /// The surface of one of the workspace's panes, or nil when the host no
    /// longer lists it.
    func surface(forPane id: UInt32) -> TerminalSurface? {
        paneSurfaces[id]
    }

    /// The surface of the focused pane, which typing and the find bar reach.
    var focusedSurface: TerminalSurface? { surface }

    /// Core's host-platform answer for the focused pane's software keyboard.
    var shouldShowCommandAccessory: Bool {
        #if UBIQUITTY_IOS_UI_TESTS
        if let platform = SmokeLaunch.commandAccessoryHostPlatform {
            return platform.withCString { Ubiquitty.Session.isMacOSHostPlatform(std.string_view($0)) }
        }
        #endif
        return isConnected && focusedSurface?.drive.shouldShowCommandAccessory == true
    }

    /// The surface that holds the workspace's connection, which every request
    /// about the workspace's structure goes through.
    var workspaceAnchor: TerminalSurface? { ownedSurface }

    /// Replaces the panes and their surfaces with a workspace no host stands
    /// behind, as the showcase seed builds it.
    ///
    /// - Parameters:
    ///   - listed: The panes, grouped by tab in order.
    ///   - surfaces: Each pane's surface.
    func adoptSeededPanes(_ listed: [TerminalPane], surfaces: [UInt32: TerminalSurface]) {
        paneSurfaces = surfaces
        panes = listed
    }

    /// The controller a surface is hosted through, made on the first ask.
    func controller(for surface: TerminalSurface) -> TerminalSurfaceViewController {
        let key = ObjectIdentifier(surface)
        if let existing = surfaceControllers[key] { return existing }
        let made = TerminalSurfaceViewController(surface: surface)
        surfaceControllers[key] = made
        return made
    }

    /// The two panes a wide window shows, or nil when there are not two.
    var arrangedPanePair: (primary: UInt32, secondary: UInt32)? {
        guard prefersTwoPanes, arrangedPaneIDs.count == TerminalPaneArrangement.capacity else { return nil }
        return (arrangedPaneIDs[0], arrangedPaneIDs[1])
    }

    /// Takes the surface the host built, and gives it anything already arrived.
    ///
    /// Bytes can reach a connection before a view exists — the carrier opens on
    /// its own thread and SwiftUI builds when it builds — so they are held
    /// rather than dropped, which is the difference between a shell prompt and
    /// a blank screen on a fast connection.
    func adopt(_ surface: TerminalSurface) {
        guard self.surface !== surface else { return }
        keyboardModifiers = TerminalKeyboardModifiers()
        self.surface = surface
        // The watch reports a cost only when it changes; a surface adopted
        // after the first report is told the one standing.
        if let cost = pathWatch?.cost { surface.setNetworkCost(cost) }
        // The title and status shown are the active surface's. Each surface
        // reports a change only when its own value moves, so a pane focused
        // with a title it already holds never reports it again.
        title = surface.title
        showProgramStatus(of: surface)
        surface.isKeyboardPresented = isKeyboardPresented
        // Before the held bytes, so the first frame a person sees is already
        // themed rather than repainting a moment later.
        applyThemeToSurface()
        if !pendingInbound.isEmpty {
            surface.feed(Data(pendingInbound))
            surface.serviceIngestEvents()
            pendingInbound.removeAll()
        }
        refreshGround()
        hasSelection = surface.hasSelection
        // A pane reports its position only when it moves, and one taken up
        // again may be scrolled back already.
        scrollback = surface.reportedScrollbackPosition
    }

    /// The terminal's effective default background, which the chrome around
    /// the grid is painted in.
    ///
    /// Core's colour, read from the published snapshot: the palette's, with
    /// a program's OSC 11 and DECSCNM's swap already applied. A colour of the
    /// screen's own would frame the grid in a band the grid does not have.
    ///
    /// Before any pane exists it is the launch theme's ground, by the same
    /// Core fold, so the screen's first frame is the theme the pane will
    /// open in rather than a colour of the shell's own.
    private(set) var groundColor = UIColor(ground: TerminalSessionModel.launchGround)
    /// Whether ``groundColor`` reads as dark, by Core's lightness rule, so
    /// the chrome over it takes the colour scheme that stays legible on it.
    private(set) var isGroundDark = TerminalSessionModel.launchGround.isDark

    /// The configured launch theme's ground, as Core derives it.
    private static var launchGround: Ubiquitty.Runtime.ChromeTint {
        Ubiquitty.Runtime.launchGround(Ubiquitty.Preferences.values().pointee)
    }
    /// Whether the focused pane holds a selection, as the surface reports it.
    private(set) var hasSelection = false

    /// Re-reads the ground from the focused surface's snapshot, writing only
    /// a change so an unchanged frame invalidates nothing.
    func refreshGround() {
        guard let surface else { return }
        let snapshot = surface.drive.readSnapshot()
        let color = UIColor(
            red: CGFloat(snapshot.defaultBackgroundRed),
            green: CGFloat(snapshot.defaultBackgroundGreen),
            blue: CGFloat(snapshot.defaultBackgroundBlue),
            alpha: 1
        )
        if !color.isEqual(groundColor) {
            groundColor = color
        }
        let isDark = Ubiquitty.Runtime.scrollerChrome(snapshot).prefersLightKnob
        if isDark != isGroundDark {
            isGroundDark = isDark
        }
    }

    /// Switches the theme, mid-session.
    ///
    /// Applying reaches the program as well as the pixels: the terminal's
    /// palette is what an application reads when it chooses its own colours,
    /// and one that subscribed to the scheme notification is told the moment
    /// this lands. Nothing is re-dialled and nothing is redrawn by hand.
    ///
    /// - Parameter name: The theme's name, or empty for Core's default.
    func selectTheme(named name: String) {
        themeName = name
        let index = Int(preferredThemeIndex)
        appliedDefaultTheme = nil
        appliedRemoteTheme = nil
        if let ownedSurface { apply(themeAt: index, to: ownedSurface) }
        for pane in paneSurfaces.values where pane !== ownedSurface { apply(themeAt: index, to: pane) }
        refreshGround()
        applyRemoteThemeIfNeeded()
    }

    /// Puts ``themeName`` on the surface, if there is one and Core knows it,
    /// and the chrome on the ground it gives.
    private func applyThemeToSurface() {
        guard let surface else { return }
        apply(themeAt: Int(preferredThemeIndex), to: surface)
        refreshGround()
    }

    /// Applies a theme and publishes the snapshot it changed.
    ///
    /// The ground is read from the published snapshot, which a palette write
    /// leaves unpublished until the next drain; a session with nothing
    /// arriving would keep the chrome on the previous theme's ground.
    private func apply(themeAt index: Int, to surface: TerminalSurface) {
        guard surface.applyTheme(at: index) else { return }
        surface.drive.republishSnapshot()
    }

    /// Whether hardware keys bypass text composition for position reports.
    var shouldReportKeyPositions: Bool { surface?.drive.readSnapshot().modes.shouldReportKeyPositions == true }

    /// Reports one key press to the terminal, which decides the bytes.
    ///
    /// - Parameter press: What the platform knows.
    /// - Returns: Whether anything was sent.
    @discardableResult
    func sendKey(_ press: Ubiquitty.Runtime.KeyPress) -> Bool {
        guard let surface else { return false }
        return surface.sendKey(press)
    }

    /// The control row's keys, by name — the row offers keys a soft keyboard
    /// has none of, and names them rather than spelling their bytes.
    ///
    /// - Parameter key: The key pressed.
    @discardableResult
    func sendKey(named key: Ubiquitty.Keys.VirtualKey) -> Bool {
        sendKey(TerminalKeyTranslation.keyPress(for: key))
    }

    /// Sends a software accessory key through Core with its pending modifiers.
    @discardableResult
    func sendAccessoryKey(_ key: Ubiquitty.Keys.VirtualKey) -> Bool {
        guard !isComposing else { return false }
        var press = TerminalKeyTranslation.keyPress(for: key)
        press.modifiers = keyboardModifiers.consume()
        press.wasModified = press.modifiers != 0
        return sendKey(press)
    }

    /// Sends a key from the accessory row or the shortcuts bar with its
    /// pending modifiers. A character goes the way a typed one does, so a
    /// latched Control or Alt applies to it and Core encodes the chord.
    @discardableResult
    func sendAccessory(_ key: TerminalAccessoryKey) -> Bool {
        switch key.press {
        case .key(let virtualKey):
            return sendAccessoryKey(virtualKey)
        case .character(let scalar):
            guard !isComposing else { return false }
            insertKeyboardText(String(scalar))
            return true
        }
    }

    /// Sends a Control chord picked from the Control key, with whatever
    /// other modifiers are pending.
    @discardableResult
    func sendControlChord(_ chord: TerminalControlChord) -> Bool {
        guard !isComposing else { return false }
        var press = Ubiquitty.Runtime.KeyPress()
        press.unshiftedCodePoint = chord.letter.value
        press.shiftedCodePoint = chord.letter.value
        press.modifiers = keyboardModifiers.consume() | TerminalKeyboardModifiers.Modifier.control.bits
        press.wasModified = true
        return sendKey(press)
    }

    /// Keeps input-method commits intact while encoding a modified single key.
    func insertKeyboardText(_ text: String) {
        guard !isComposing, keyboardModifiers.bits != 0, text.unicodeScalars.count == 1,
            let scalar = text.unicodeScalars.first
        else {
            commitComposition(text == "\n" ? "\r" : text)
            return
        }
        if text == "\n" || text == "\r" {
            sendAccessoryKey(.Return)
            return
        }
        var press = Ubiquitty.Runtime.KeyPress()
        press.modifiers = keyboardModifiers.consume()
        press.wasModified = true
        press.unshiftedCodePoint = scalar.value
        let shifted = text.uppercased().unicodeScalars
        press.shiftedCodePoint =
            press.modifiers & UInt32(Ubiquitty.Keys.Keymap.keymapModifierShift) != 0 && shifted.count == 1
            ? shifted.first?.value ?? scalar.value : scalar.value
        if press.modifiers & UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl) == 0 {
            press.text.0 = press.shiftedCodePoint
            press.textLength = 1
        }
        _ = sendKey(press)
    }

    /// A control chord from the row, as the letter it is formed from.
    ///
    /// The fold to a control byte is the terminal's: it depends on
    /// modifyOtherKeys and the Kitty flags, and a row that folded it itself
    /// would send 0x03 to a host that asked to see Ctrl and C separately.
    ///
    /// - Parameters:
    ///   - letter: The letter the chord is formed from.
    ///   - control: Whether Control was held.
    @discardableResult
    func sendKey(letter: Character, control: Bool) -> Bool {
        var press = Ubiquitty.Runtime.KeyPress()
        let scalar = letter.unicodeScalars.first?.value ?? 0
        press.unshiftedCodePoint = scalar
        press.shiftedCodePoint = scalar
        if control {
            press.modifiers = UInt32(Ubiquitty.Keys.Keymap.keymapModifierCtrl)
            press.wasModified = true
        }
        return sendKey(press)
    }

    /// Whether an input method is composing into this session.
    var isComposing: Bool {
        surface?.isComposing ?? false
    }

    /// The composition in flight, empty when none is.
    var composedText: String {
        surface?.composedText ?? ""
    }

    /// Replaces the composition in flight.
    ///
    /// - Parameter text: The composition as the input method now spells it.
    func compose(_ text: String) {
        surface?.composeText(text)
    }

    /// Abandons the composition without sending it.
    func cancelComposition() {
        surface?.cancelComposition()
    }

    /// Commits composed text to the host.
    ///
    /// - Parameter text: The committed text.
    func commitComposition(_ text: String) {
        surface?.commitComposedText(text)
    }

    /// Where the candidate window belongs, in the asking view's coordinates.
    ///
    /// The composition is anchored to the cursor cell, which is the surface's
    /// geometry — so the rectangle is converted out of the surface rather than
    /// read from the responder, which is a one-point view behind the grid and
    /// would put the candidates in the corner.
    ///
    /// - Parameter view: The view asking, which is the keyboard's responder.
    /// - Returns: The cursor cell in that view's coordinates, or `.zero`.
    func compositionAnchorRect(in view: UIView) -> CGRect {
        guard let surface else { return .zero }
        return view.convert(surface.compositionAnchorRect(), from: surface)
    }

    /// Opens a session to a saved host.
    ///
    /// - Parameters:
    ///   - record: The host to dial.
    ///   - secret: The password, or the PEM text of a private key.
    ///   - attach: What to do about the host's sessions, as Core's plan or the
    ///     person's pick decided it.
    func connect(to record: HostRecord, secret: String, attach: HostAttachIntent) {
        if hostInstance != attach.hostInstance, quicFactory != nil { disconnect() }
        hostInstance = attach.hostInstance
        // Idempotent while the connection lives, because a screen cannot tell
        // a first visit from a return one: the session outlives the view, and
        // the directory errand builds this model before anything has
        // connected.
        //
        // Idempotent for one ask repeated, and not for a different one. A host
        // holds one model, so a pick for a different session arrives here as a
        // repeat visit; a differing ask re-homes this model onto it, and the
        // session left behind is detached, not ended, and stays on the host's
        // list to be picked again. A connection that failed or ended is not
        // one to keep: the same ask dials again.
        // A refused reattach retires its carrier and clears the connecting
        // flag, but may still hold the prepared store and factory. An explicit
        // recovery must release those owners before adopting the next pick.
        if hasBegunConnecting || (hasFailed && attachedIntent != nil) {
            let hasEnded = hasFailed || hasExited
            guard let attachedIntent, hasEnded || attachedIntent != attach else { return }
            connectionLog.note(
                hasEnded
                    ? "Dialing again after the last attempt ended"
                    : "Moving this host’s screen to the session just picked"
            )
            // disconnect() drops the carrier, the probe and the QUIC factory;
            // the connect below opens new ones and binds the surface to what
            // was asked for. There is no separate detach: an attach replaces
            // what the surface was bound to.
            disconnect()
            forgetTheLastAttempt()
        }
        themeName = record.themeName
        applyThemeToSurface()
        attachedIntent = attach
        // What the host holds is about to change by this connect, so the
        // answer read before it no longer says what the host holds.
        isHostAnswerCurrent = false
        supersededHostTreeRevision = ownedSurface?.drive.hostSessionTreeRevision
        hasAskedToConnect = true
        resetConnectionFailurePresentation()
        hasFailed = false
        hasExited = false
        hasBegunConnecting = true
        pairingKey = record.pairingKey
        dialledHost = record.hostName
        dialledHostLabel = record.displayName
        noteDialledCredentials(of: record)
        for surface in Array(paneSurfaces.values) + (ownedSurface.map { [$0] } ?? []) { configureFileLinks(on: surface) }
        dialledPort = record.port
        // What this screen was asked for, before a carrier has been chosen. The
        // question "which session am I on" has an answer from the moment the
        // screen exists, and the paths that fail — no carrier, a refused
        // reattach — are exactly when a person needs it.
        summaryState = .connecting(summary(forIntent: attach))
        reattachRefusal = ""
        connectionLog.begin(
            "Connecting to \(record.username)@\(record.hostName):\(record.port)"
        )
        #if UBIQUITTY_IOS_UI_TESTS
        if SmokeLaunch.isSeedingBuildRefusal {
            settleOnTheSeededBuildRefusal()
            return
        }
        if SmokeLaunch.isSeedingWorkspace {
            // Drawn as a session that came up, so the screen shows what a
            // person sees once connected rather than the connecting notice.
            isConnected = true
            seedShowcaseWorkspace()
            return
        }
        if SmokeLaunch.isSeedingSignInPrompt {
            askTheSeededPassword(of: record)
            return
        }
        if SmokeLaunch.isSeedingConnectedHost {
            settleOnTheSeededConnection()
            return
        }
        #endif

        guard let credentials = credentials(for: record, secret: secret) else { return }

        guard attach.bootstrapCommand != nil else {
            holdTheUnreachedPick(
                attach,
                of: record,
                because: "Ubiquitty couldn’t identify the host for this workspace. Refresh the workspace list and try again.",
                offersLoginShell: true
            )
            return
        }

        if case .workspace(let workspace, _, _, _) = attach, attach.hostInstance == nil {
            do {
                if let prepared = try ColdResumeSession.prepare(
                    host: record,
                    secret: secret,
                    workspace: workspace,
                    stop: { [weak self] owner in self?.retireColdResume(owner) }
                ) {
                    guard installColdResume(prepared),
                        let factory = makeQUICFactory(for: record, credentials: credentials, bootstrap: nil), prepared.seed(factory)
                    else {
                        disconnect()
                        prepared.abandonPreparation()
                        finish(
                            isFailure: true,
                            reason: "Protected session data isn’t available yet. Unlock this device, then reconnect."
                        )
                        return
                    }
                    attachOverQUIC(factory, to: record, credentials: credentials, attach: attach)
                    return
                }
            } catch {
                finish(
                    isFailure: true,
                    reason:
                        "Protected session storage isn’t available, so Ubiquitty didn’t connect. Unlock this device and try again."
                )
                return
            }
        }

        // QUIC first when this host asked for it. The probe is a separate,
        // short-lived SSH connection that asks the daemon for a port, a
        // one-time token and a certificate pin; the session itself opens only
        // once it has answered, either way. Sequential rather than racing the
        // two: a session that opened over SSH while the probe was still running
        // would have to be torn down and reopened, and the reader would watch a
        // shell appear and vanish.
        guard record.prefersQUIC else {
            guard attach == .newSession else {
                holdTheUnreachedPick(
                    attach,
                    of: record,
                    because:
                        "This workspace needs QUIC, which is turned off for this host. Turn on Prefer QUIC in the host’s settings, then try again.",
                    offersLoginShell: true
                )
                return
            }
            connectionLog.note("This host is not set to ask for QUIC; opening SSH")
            openSSHSession(to: record, credentials: credentials)
            return
        }
        statusDetail = "Asking for QUIC…"
        askForQUICCarrier(record, credentials: credentials, attach: attach) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .carrier(let factory):
                self.attachOverQUIC(factory, to: record, credentials: credentials, attach: attach)
            case .declined(let reason), .unreachable(let reason):
                guard attach == .newSession else {
                    var isDeclined = false
                    if case .declined = answer { isDeclined = true }
                    self.holdTheUnreachedPick(attach, of: record, because: reason, offersLoginShell: isDeclined)
                    return
                }
                if case .unreachable = answer {
                    // The login shell would dial the same host the probe
                    // could not reach, and fail the same way a second time.
                    self.finish(isFailure: true, reason: reason, failure: self.bootstrapFailure)
                    return
                }
                self.openSSHSession(to: record, credentials: credentials)
            }
        }
    }

    /// Opens a login shell over SSH in place of a picked session that could
    /// not be reached, because the person asked for one.
    ///
    /// - Parameters:
    ///   - record: The host to dial.
    ///   - secret: The password, or the PEM text of a private key.
    func openLoginShellInstead(to record: HostRecord, secret: String) {
        disconnect()
        forgetTheLastAttempt()
        attachedIntent = .newSession
        hasBegunConnecting = true
        dialledHost = record.hostName
        dialledHostLabel = record.displayName
        dialledPort = record.port
        noteDialledCredentials(of: record)
        summaryState = .settled("Login shell over SSH")
        connectionLog.begin("Opening a login shell on \(record.username)@\(record.hostName):\(record.port)")
        guard let credentials = credentials(for: record, secret: secret) else { return }
        openSSHSession(to: record, credentials: credentials)
    }

    /// Forgets an unreached pick the person chose to walk away from. The
    /// failure stays, so the next visit dials again.
    func setAsideUnreachedPick() {
        unreachedPick = nil
    }

    /// Clears what the last attempt learned, so the next one starts fresh.
    private func forgetTheLastAttempt() {
        resetConnectionFailurePresentation()
        hasBegunConnecting = false
        isConnected = false
        hasFailed = false
        hasExited = false
        unreachedPick = nil
        hasHostDeclinedBootstrap = false
        quicRefusal = ""
        transport = .ssh
        statusDetail = "Connecting…"
        connectingStep = String(localized: "Connecting…")
        hasNotedReach = false
        passwordAwaitingAcceptance = nil
    }

    /// Records who signs in to the host being dialled and whether a password
    /// typed for it may be kept.
    private func noteDialledCredentials(of record: HostRecord) {
        dialledUsername = record.username
        dialledCanSavePassword =
            savedHostID == record.id && record.canSavePromptedPassword
            && (SecretStore.secret(for: record.id) ?? "").isEmpty
        hasNotedReach = false
        passwordAwaitingAcceptance = nil
        connectingStep = String(localized: "Connecting…")
    }

    /// Notes that the dialled host was reached, once per attempt.
    private func noteReached() {
        guard !hasNotedReach else { return }
        hasNotedReach = true
        connectionLog.step(String(localized: "Reached \(dialledHost):\(String(dialledPort))"), .succeeded)
        connectingStep = String(localized: "Signing in…")
    }

    /// Notes that the server accepted the sign-in, and keeps a password the
    /// person asked to save now that it is known to be right.
    private func noteSignedIn() {
        noteReached()
        connectionLog.step(String(localized: "Signed in as \(dialledUsername)"), .succeeded)
        connectingStep = String(localized: "Starting session…")
        if let password = passwordAwaitingAcceptance {
            passwordAwaitingAcceptance = nil
            onPasswordAccepted?(password)
        }
    }

    /// Stops a connection still being made, because the person asked to.
    ///
    /// The attempt ends as a failure that says it was canceled, with Try
    /// Again beside it, rather than leaving a screen with no connection and
    /// nothing saying why.
    func cancelConnecting() {
        guard hasBegunConnecting, !isConnected, !hasFailed, !hasExited else { return }
        connectionLog.note("The person canceled the connection")
        disconnect()
        // No carrier speaks for the session any longer, so nothing reports
        // the remote state that would otherwise overwrite this ending.
        transport = .ssh
        finish(isFailure: true, reason: "", classification: .cancelled)
    }

    /// Stops on a picked session the host could not hand over, rather than
    /// opening some other shell in its place.
    ///
    /// The grid alone cannot tell a reattach from a fresh login, so a login
    /// shell substituted here would read as the session the person picked
    /// while being a different one. The person answers instead: try again,
    /// take a login shell, or go back.
    ///
    /// - Parameters:
    ///   - attach: The pick that was not reached.
    ///   - record: The host it was picked on.
    ///   - reason: Why, in one sentence.
    private func holdTheUnreachedPick(
        _ attach: HostAttachIntent,
        of record: HostRecord,
        because reason: String,
        offersLoginShell: Bool = false
    ) {
        connectionLog.note("The chosen workspace was not reached, and no other shell was opened in its place")
        summaryState = .settled(summary(forLostPick: attach))
        unreachedPick = UnreachedPick(name: pickName(attach), reason: reason, offersLoginShell: offersLoginShell)
        failure = ConnectionFailure(cause: reason, actions: offersLoginShell ? [.tryAgain, .openLoginShell] : [.tryAgain])
        connectionLog.step(reason, .failed)
        hasFailed = true
        hasExited = true
        isConnected = false
        statusDetail = reason
    }

    /// What a pick is called on screen.
    private func pickName(_ attach: HostAttachIntent) -> String {
        switch attach {
        case .session(let id, _, _, _):
            // The workspace the session runs, by the name the host's outline
            // gives it: a person picked a row by that name, never by the
            // session's number.
            let workspace = hostOutline.rows.first { $0.open.sessionID == id }?.open.workspaceName ?? ""
            return workspace.isEmpty ? String(localized: "the workspace") : workspace
        case .workspace(let name, _, _, _): return name
        case .newSession: return String(localized: "a new workspace")
        }
    }

    /// The sentence for a connect that failed, from the facts the carrier
    /// typed.
    ///
    /// Core's sentence when the connect's failure was typed, and the
    /// carrier's own when it was not: an authentication or host-key refusal
    /// already describes itself.
    ///
    /// - Parameters:
    ///   - reason: The carrier's description.
    ///   - reachFailure: Why the host was never reached, when typed.
    /// - Returns: The sentence a person reads.
    private func sentence(for reason: String, reachFailure: SSHReachFailure?) -> String {
        Self.sentence(for: reason, reachFailure: reachFailure, host: dialledHost, port: dialledPort)
    }

    /// The sentence for a connect to a host that failed.
    ///
    /// - Parameters:
    ///   - reason: The carrier's description.
    ///   - reachFailure: Why the host was never reached, when typed.
    ///   - host: The host as the person typed it.
    ///   - port: The port dialled.
    /// - Returns: The sentence a person reads.
    static func sentence(
        for reason: String,
        reachFailure: SSHReachFailure?,
        host: String,
        port: Int,
        classification: SSHCloseClassification? = nil
    ) -> String {
        SSHFailurePresentation.sentence(reason: reason, reachFailure: reachFailure, classification: classification, host: host, port: port)
    }

    /// Reads what this record may offer the server.
    ///
    /// Offers, not a method chosen in advance: each connection asks the server
    /// to accept it with no credential first, and a saved credential is
    /// offered only for a method the server then lists. A password is asked
    /// for only when the server lists one and none is saved.
    ///
    /// - Parameters:
    ///   - record: The host being dialled.
    ///   - secret: What the keychain holds for it: a password, or the PEM text
    ///     of a private key, as the record's saved credential says.
    /// - Returns: The offers and who to ask, or nil when the record cannot be
    ///   dialled, in which case the session is already reported as finished.
    private func credentials(for record: HostRecord, secret: String) -> SSHAuthentication? {
        var offers: [SSHCredential] = []
        let saved = secret.isEmpty ? HostSavedCredential.none : record.savedCredential
        switch saved {
        case .privateKey:
            let read = SSHPrivateKeyText.read(secret)
            guard case .key(let key) = read else {
                guard case .refused(let reason) = read else { return nil }
                hasFailed = true
                // The parser's sentence rather than one written here: it names
                // the container the paste actually carried, and a refusal that
                // names no cause sends a reader to sshd logs for a file problem.
                statusDetail = reason
                failure = ConnectionFailure(cause: reason, actions: [.editHost])
                hasExited = true
                connectionLog.step(reason, .failed, detail: "The private key was refused: \(reason)")
                return nil
            }
            offers.append(.privateKey(key))
        case .password:
            offers.append(.password(secret))
        case .none:
            break
        }
        if record.authenticationKind == .privateKey, offers.isEmpty {
            // A key-only host whose key is not in the keychain: the editor
            // never saves an empty one, so the store lost it or refused it.
            hasFailed = true
            statusDetail = "The keychain holds no key for this host. Open the host’s editor and paste the key again."
            failure = ConnectionFailure(
                cause: String(localized: "The keychain holds no key for this host."),
                fix: String(localized: "Paste the key again in the host’s settings."),
                actions: [.editHost]
            )
            hasExited = true
            connectionLog.step(failure?.cause ?? statusDetail, .failed, detail: "The keychain holds no key for this host")
            return nil
        }
        // Asked only when nothing saved answers a password request: a refused
        // key falls back to the person, as OpenSSH's client does, and a
        // refused saved password is a password to fix in the editor.
        if saved != .password {
            offers.append(.askedPassword)
        }
        let interaction = signInInteraction ?? SSHAuthenticationInteraction(person: SignInPerson(model: self))
        signInInteraction = interaction
        return SSHAuthentication(offers: offers, interaction: interaction)
    }

    /// Shows the person the password the server asked for.
    ///
    /// - Parameters:
    ///   - request: Who is signing in where, and the server's text.
    ///   - answer: Takes the password, or nil when the person cancelled.
    func askForPassword(_ request: SSHPasswordRequest, answer: @escaping @Sendable (String?) -> Void) {
        pendingPasswordAnswer?(nil)
        pendingPasswordAnswer = answer
        noteReached()
        connectionLog.note("The server asked for a password")
        signInPrompt = SignInPrompt(kind: .password(request), hostLabel: dialledHostLabel, canSavePassword: dialledCanSavePassword)
    }

    /// Records a banner the server sent while signing in, and shows one that
    /// carries a link the server is waiting on.
    func showSignInBanner(_ banner: SSHAuthenticationBanner) {
        connectionLog.note("The server sent a message: \(banner.message)")
        guard banner.link != nil, pendingPasswordAnswer == nil else { return }
        signInPrompt = SignInPrompt(kind: .approval(banner), hostLabel: dialledHostLabel)
    }

    /// Puts away an approval the server has answered.
    func endSignInApproval() {
        if case .approval = signInPrompt?.kind { signInPrompt = nil }
    }

    /// Takes the person's answer to the sign-in prompt.
    ///
    /// - Parameter password: The password typed, or nil when the person
    ///   cancelled. Cancelling an approval ends the connection the server is
    ///   holding.
    ///   - savesPassword: Whether to keep the password once the server
    ///     accepts it; honoured only where the prompt offered saving.
    func answerSignInPrompt(_ password: String?, savesPassword: Bool = false) {
        let prompt = signInPrompt
        signInPrompt = nil
        if let answer = pendingPasswordAnswer {
            pendingPasswordAnswer = nil
            if savesPassword, prompt?.canSavePassword == true, let password, !password.isEmpty {
                passwordAwaitingAcceptance = password
            }
            answer(password)
            return
        }
        guard case .approval = prompt?.kind, password == nil else { return }
        connectionLog.note("The sign-in was canceled")
        disconnect()
        finish(isFailure: true, reason: "Sign-in was canceled.", classification: .authenticationCancelled)
    }

    /// Gets one QUIC carrier factory, sharing an in-flight initial bootstrap.
    ///
    /// The factory is held for as long as the session is: Core asks it for a
    /// fresh carrier on every reconnect, so releasing it after the attach would
    /// leave the session redialling through a dangling pointer the first time
    /// the network moved — which is exactly when a QUIC session is supposed to
    /// come back. Each physical connection obtains its own one-time bootstrap,
    /// including the directory connection and the attach that follows it.
    ///
    /// - Parameters:
    ///   - record: The host to ask.
    ///   - credentials: What the bootstrap connection authenticates with.
    ///   - then: Handed the factory, or why there is none.
    private func askForQUICCarrier(
        _ record: HostRecord,
        credentials: SSHAuthentication,
        attach: HostAttachIntent = .newSession,
        then hand: @escaping (QUICCarrierAnswer) -> Void
    ) {
        if let quicFactory {
            hand(.carrier(quicFactory))
            return
        }
        if hasHostDeclinedBootstrap {
            hand(.declined(Self.declinedSentence(for: record)))
            return
        }
        guard let initialCommand = attach.bootstrapCommand else {
            hand(.declined("Ubiquitty couldn’t identify the host for this workspace. Refresh the workspace list and try again."))
            return
        }
        let bootstrapCommand =
            attach.hostInstance == nil ? (hostInstance?.bootstrap(initialCommand, pinInitialOwner: true) ?? initialCommand) : initialCommand
        guard !bootstrapCommand.isEmpty else {
            hand(.declined("The selected host is no longer available. Refresh the workspace list and try again."))
            return
        }
        bootstrapWaiters.append(hand)
        guard bootstrapProbe == nil, bootstrapRetry == nil else { return }
        bootstrapFailures = 0
        startBootstrapAsk(record, credentials: credentials, bootstrapCommand: bootstrapCommand)
    }

    /// Starts one bootstrap ask, with its deadline, for the waiters already
    /// queued.
    private func startBootstrapAsk(_ record: HostRecord, credentials: SSHAuthentication, bootstrapCommand: String) {
        let generation = UUID()
        bootstrapGeneration = generation
        dialledHost = record.hostName
        dialledHostLabel = record.displayName
        dialledPort = record.port
        connectionLog.note("Asking the host for QUIC connection details over SSH")
        let probe = makeBootstrapAsk(record, credentials, bootstrapCommand) { [weak self] outcome in
            Task { @MainActor in
                self?
                    .settleQUICBootstrap(
                        outcome,
                        generation: generation,
                        record: record,
                        credentials: credentials,
                        bootstrapCommand: bootstrapCommand
                    )
            }
        }
        bootstrapProbe = probe
        bootstrapDeadline = Task { [weak self, weak probe] in
            do { try await QUICBootstrapProbe.waitOutDeadline(.seconds(30), signIn: credentials.interaction) } catch { return }
            guard let probe else { return }
            self?
                .settleQUICBootstrap(
                    probe.deadlineOutcome,
                    generation: generation,
                    record: record,
                    credentials: credentials,
                    bootstrapCommand: bootstrapCommand
                )
        }
        probe.start()
    }

    /// Hands every waiter the one answer a bootstrap came to: a carrier, a
    /// host that declined, or a host never reached, each with the sentence a
    /// person reads.
    private func settleQUICBootstrap(
        _ outcome: QUICBootstrapProbe.Outcome,
        generation: UUID,
        record: HostRecord,
        credentials: SSHAuthentication,
        bootstrapCommand: String
    ) {
        guard bootstrapGeneration == generation else { return }
        bootstrapGeneration = UUID()
        bootstrapDeadline?.cancel()
        bootstrapDeadline = nil
        let fingerprint = bootstrapProbe?.presentedFingerprint ?? ""
        bootstrapProbe?.cancel()
        bootstrapProbe = nil
        let waiters = bootstrapWaiters
        bootstrapWaiters.removeAll()
        let answer: QUICCarrierAnswer
        switch outcome {
        case .ready(let port, _, let certificate, _):
            bootstrapHostKeyFingerprint = fingerprint
            noteSignedIn()
            connectionLog.note(bootstrapAnswered: port, certificateSHA256: certificate)
            connectionLog.step(String(localized: "The host offered a fast connection"), .succeeded)
            var pinnedRecord = record
            if pinnedRecord.pinnedHostKeyFingerprint.isEmpty { pinnedRecord.pinnedHostKeyFingerprint = fingerprint }
            if let factory = makeQUICFactory(
                for: pinnedRecord,
                credentials: credentials,
                bootstrap: outcome,
                bootstrapCommand: bootstrapCommand
            ) {
                answer = .carrier(factory)
            } else {
                connectionLog.note("The QUIC connection details the host sent couldn’t be used")
                hasHostDeclinedBootstrap = true
                answer = .declined(Self.declinedSentence(for: record))
            }
        case .declined(let reason):
            noteSignedIn()
            connectionLog.step(
                String(localized: "The host didn’t offer a fast connection"),
                .failed,
                detail: "No QUIC connection details: \(reason)"
            )
            quicRefusal = reason
            // This outcome follows an authenticated exec opening, never a
            // login or trust refusal. Retain that verified SSH identity so a
            // control-only passive directory can work without a QUIC listener.
            var pinnedRecord = record
            if pinnedRecord.pinnedHostKeyFingerprint.isEmpty { pinnedRecord.pinnedHostKeyFingerprint = fingerprint }
            if !pinnedRecord.pinnedHostKeyFingerprint.isEmpty,
                let factory = makeQUICFactory(
                    for: pinnedRecord,
                    credentials: credentials,
                    bootstrap: outcome,
                    bootstrapCommand: bootstrapCommand
                )
            {
                bootstrapHostKeyFingerprint = pinnedRecord.pinnedHostKeyFingerprint
                answer = .carrier(factory)
            } else {
                hasHostDeclinedBootstrap = true
                answer = .declined(Self.declinedSentence(for: record))
            }
        case .instanceGone(let socketName):
            // The picked daemon stopped. The connect goes on through the
            // factory, whose first ask hands Core this answer: Core drops the
            // pin and asks the host's current daemon for the same workspace.
            connectionLog.note("The daemon on \(socketName) is no longer running; asking the host’s current one")
            goneDaemonSocketName = socketName
            var pinnedRecord = record
            if pinnedRecord.pinnedHostKeyFingerprint.isEmpty { pinnedRecord.pinnedHostKeyFingerprint = fingerprint }
            if !pinnedRecord.pinnedHostKeyFingerprint.isEmpty,
                let factory = makeQUICFactory(
                    for: pinnedRecord,
                    credentials: credentials,
                    bootstrap: outcome,
                    bootstrapCommand: bootstrapCommand
                )
            {
                bootstrapHostKeyFingerprint = pinnedRecord.pinnedHostKeyFingerprint
                answer = .carrier(factory)
            } else {
                answer = .declined(Self.declinedSentence(for: record))
            }
        case .unreachable(let reason, let reachFailure, let classification):
            // The raw description goes to the log and nowhere else; the
            // person reads Core's sentence for what failed.
            connectionLog.note("The host couldn’t be reached for QUIC connection details: \(reason)")
            bootstrapFailures += 1
            // A failure a path still coming up also produces is asked again
            // before anyone is told: the tunnel or radio is often up a second
            // later, and every Try Again a person taps is one more of these.
            if let reachFailure, reachFailure.isWorthWaitingOut,
                let delay = Ubiquitty.Transport.connectRetryDelaySeconds(UInt32(bootstrapFailures)).value
            {
                bootstrapWaiters = waiters
                statusDetail = "Waiting for the network…"
                connectionLog.note("Asking again in \(Int(delay)) s")
                bootstrapRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self else { return }
                    self.bootstrapRetry = nil
                    self.startBootstrapAsk(record, credentials: credentials, bootstrapCommand: bootstrapCommand)
                }
                return
            }
            let readable = Self.sentence(
                for: reason,
                reachFailure: reachFailure,
                host: dialledHost,
                port: dialledPort,
                classification: classification
            )
            quicRefusal = readable
            bootstrapFailure = SSHFailurePresentation.failure(
                reason: reason,
                reachFailure: reachFailure,
                classification: classification,
                host: dialledHost,
                port: dialledPort
            )
            connectionLog.step(readable, .failed)
            answer = .unreachable(readable)
        }
        let settledGeneration = bootstrapGeneration
        for waiter in waiters {
            guard bootstrapGeneration == settledGeneration else { break }
            // A waiter run before this one may have replaced the factory.
            if case .carrier(let factory) = answer, factory != quicFactory {
                waiter(.unreachable(Self.replacedCarrierSentence))
                continue
            }
            waiter(answer)
        }
    }

    /// What a waiter reads when the factory it was settled with was replaced
    /// before its turn came.
    private static let replacedCarrierSentence = "The connection was restarted before this request was answered."

    /// What a person reads when a host was reached and offered no QUIC
    /// carrier. The host's own reason stays in the log and the settings
    /// sheet, where whoever debugs the host's setup reads it.
    private static func declinedSentence(for record: HostRecord) -> String {
        "\(record.displayName) didn’t offer the QUIC connection its workspaces need."
    }

    private func makeQUICFactory(
        for record: HostRecord,
        credentials: SSHAuthentication,
        bootstrap: QUICBootstrapProbe.Outcome?,
        bootstrapCommand: String? = nil
    ) -> OpaquePointer? {
        let provider = QUICCarrierProvider(
            record: record,
            credentials: credentials,
            initialBootstrap: bootstrap,
            initialBootstrapCommand: bootstrapCommand,
            hostInstance: hostInstance
        ) { [weak self] message in
            self?.connectionLog.note(message)
        }
        provider.noteVerifiedBootstrap = { [weak self] outcome, fingerprint in
            self?.coldResume?.noteBootstrap(outcome, fingerprint: fingerprint)
        }
        configureCarrierProvider?(provider)
        quicProvider = provider
        quicFactory = provider.makeFactory()
        return quicFactory
    }

    /// Keeps the authenticated physical owner beside the protected cold proof.
    /// A failed write leaves the older safe metadata authoritative; it never
    /// substitutes a default daemon for a missing owner.
    private func persistColdResumeDaemonOwner() {
        guard let coldResume, let quicFactory else { return }
        let length = ubiquittyIOSQUICFactoryPinnedDaemonOwner(quicFactory, nil, 0)
        guard length > 0, length <= Int(UInt16.max) else { return }
        var bytes = [CChar](repeating: 0, count: length)
        let copied = bytes.withUnsafeMutableBufferPointer {
            ubiquittyIOSQUICFactoryPinnedDaemonOwner(quicFactory, $0.baseAddress, $0.count)
        }
        guard copied == length else { return }
        let owner = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        _ = coldResume.noteConnectedDaemonOwner(owner)
    }

    /// Opens the session over a pinned QUIC carrier.
    ///
    /// - Parameters:
    ///   - factory: The carrier factory, held for the session's whole life.
    ///   - record: The host being attached to.
    ///   - credentials: What an SSH fallback would authenticate with.
    ///   - attach: What to do about the host's sessions.
    private func attachOverQUIC(
        _ factory: OpaquePointer,
        to record: HostRecord,
        credentials: SSHAuthentication,
        attach: HostAttachIntent
    ) {
        guard let surface = surfaceForDrawing() else {
            if coldResume != nil {
                disconnect()
                finish(isFailure: true, reason: "The protected session couldn’t be prepared, so Ubiquitty didn’t open an unprotected one.")
                return
            }
            guard attach == .newSession else {
                ubiquittyIOSQUICFactoryDestroy(factory)
                quicFactory = nil
                holdTheUnreachedPick(attach, of: record, because: "The terminal for the selected workspace couldn’t be prepared.")
                return
            }
            connectionLog.note("Falling back to SSH: the terminal couldn’t be prepared for QUIC")
            quicRefusal = "QUIC wasn’t used because the terminal couldn’t be prepared."
            openSSHSession(to: record, credentials: credentials)
            return
        }
        let reattachSessionID: UInt32
        let workspaceName: String
        switch attach {
        case .newSession:
            reattachSessionID = 0
            workspaceName = ""
        case .session(let sessionID, _, _, _):
            reattachSessionID = sessionID
            workspaceName = ""
        case .workspace(let name, _, _, _):
            reattachSessionID = 0
            workspaceName = name
        }
        attachedWorkspaceName = workspaceName
        hasAnnouncedHostRestart = false
        summaryState = .connecting(summary(forRequested: reattachSessionID, workspaceName: workspaceName))
        let address = ubiquittyIOSQUICFactoryAddress(factory)
        guard
            address != 0,
            surface.attachRemoteOverCarrier(
                carrierFactory: address,
                reattachSessionID: reattachSessionID,
                workspaceName: workspaceName,
                daemonSocketName: attach.daemonSocketName,
                daemonInstanceID: attach.daemonInstanceID
            )
        else {
            ubiquittyIOSQUICFactoryDestroy(factory)
            quicFactory = nil
            if coldResume != nil {
                finish(isFailure: true, reason: "The protected session couldn’t attach, so Ubiquitty didn’t open an unprotected one.")
                return
            }
            guard attach == .newSession else {
                holdTheUnreachedPick(
                    attach,
                    of: record,
                    because: "The selected workspace refused the QUIC connection. Refresh the workspace list and try again."
                )
                return
            }
            connectionLog.note("Falling back to SSH: the session refused the QUIC connection")
            quicRefusal = "QUIC wasn’t used because the session refused it."
            openSSHSession(to: record, credentials: credentials)
            return
        }
        connectionLog.note("Connecting over QUIC")
        transport = .quic
        quicRefusal = ""
        updateRemoteStatus()
        watchTheNetworkPath()
    }

    /// Reattaches the workspace after the app could no longer service its carrier.
    ///
    /// - Parameter secondsSuspended: How long the app was in the background;
    ///   negative when that is unknown. Core decides from it whether the
    ///   connection can be kept.
    /// Tells every pane the app went to the background or came back: in the
    /// background no pane is shown, so the host sends none its screen.
    ///
    /// - Parameter isBackgrounded: Whether the app is in the background.
    func noteApplicationBackgrounded(_ isBackgrounded: Bool) {
        isBackgroundedForFollowing = isBackgrounded
        followTheHostWhileWanted()
        let surfaces = Array(paneSurfaces.values) + (ownedSurface.map { [$0] } ?? [])
        var visited = Set<ObjectIdentifier>()
        for surface in surfaces where visited.insert(ObjectIdentifier(surface)).inserted {
            surface.noteApplicationBackgrounded(isBackgrounded)
        }
    }

    /// Tells the host this client is about to be suspended and lets the
    /// carrier go, so the host holds the attachment at once and sends nothing
    /// into a suspended app. Only for the carrier `resumeAfterSuspension`
    /// brings back: a session left waiting with nothing to resume it would
    /// stay down.
    func suspendForBackground() {
        guard transport != .ssh, let ownedSurface, ownedSurface.isRemoteAttached else { return }
        connectionLog.note("Telling the host the app is being suspended")
        ownedSurface.drive.suspendRemote()
        updateRemoteStatus()
    }

    func resumeAfterSuspension(secondsSuspended: Double) {
        guard transport != .ssh, let ownedSurface, ownedSurface.isRemoteAttached else { return }
        connectionLog.note("Resuming the workspace after app suspension")
        ownedSurface.drive.resumeAfterSuspension(secondsSuspended: secondsSuspended)
        updateRemoteStatus()
    }

    /// The last remote transition the log was told about, so a status redraw
    /// with nothing new adds no line.
    @ObservationIgnored
    private var lastLoggedTransition = ""
    /// Whether this attempt has noted the workspace opening, so a reconnect's
    /// Connected adds no second step.
    @ObservationIgnored
    private var isConnectedStepNoted = false
    /// The typed failure the last bootstrap ask that never reached the host
    /// came to, for the attempt that ends on it.
    @ObservationIgnored
    private var bootstrapFailure: ConnectionFailure?

    /// Dials a reconnecting session now rather than at the end of its backoff.
    func reconnectNow() {
        guard let ownedSurface, ownedSurface.drive.reconnectRemoteNow() else { return }
        connectionLog.note("Dialing again now, as asked")
        updateRemoteStatus()
    }

    /// Sends the typing in doubt again, at the person's word: Core never
    /// does it unasked, since it can run a command twice.
    func resendInputInDoubt() {
        guard let inputInDoubt, let surface = observedSurface(inputInDoubt.surface) else { return }
        surface.drive.resendInputInDoubt()
        connectionLog.note("Sending typed input again, as asked")
        updateInputInDoubt()
    }

    /// Drops the typing in doubt, at the person's word, and lets what waited
    /// behind it go.
    func discardInputInDoubt() {
        guard let inputInDoubt, let surface = observedSurface(inputInDoubt.surface) else { return }
        surface.drive.discardInputInDoubt()
        connectionLog.note("Discarding typed input, as asked")
        updateInputInDoubt()
    }

    /// Reads again which pane, if any, awaits the person's decision about
    /// typing in doubt; the focused pane is asked first.
    private func updateInputInDoubt() {
        let surfaces = [surface].compactMap { $0 } + Array(paneSurfaces.values) + (ownedSurface.map { [$0] } ?? [])
        inputInDoubt =
            surfaces.lazy
            .compactMap { candidate in
                candidate.drive.inputInDoubtNotice.map { TerminalInputInDoubt(surface: ObjectIdentifier(candidate), notice: $0) }
            }
            .first
    }

    /// Core's sentence for a version refusal, naming this device by its kind
    /// and the host by the name the person gave it.
    ///
    /// - Parameter hostBuild: What the refusing host said about its build.
    /// - Returns: The sentence.
    private func versionRefusalSentence(hostBuild: Ubiquitty.`Protocol`.Sync.PeerBuild) -> String {
        var facts = Ubiquitty.Session.UpdateFacts()
        facts.host = hostBuild
        facts.hostLabel = std.string(dialledHostLabel)
        // The kind alone: the name UIKit reports is the model's, not the one
        // its owner gave it.
        facts.localDevice.kind = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        return String(Ubiquitty.Session.versionRefusalSentence(facts))
    }

    #if UBIQUITTY_IOS_UI_TESTS
    /// Settles this connect on a host of an older build refusing it, through
    /// the presentation a refusal read from the carrier takes.
    ///
    /// The host states a build that orders below this app's own, so Core's
    /// sentence names the host as the end to update. An app whose own version
    /// does not order, an unversioned build, stands in a host that states no
    /// build instead, which Core also reads as the older end.
    private func settleOnTheSeededBuildRefusal() {
        var refusal = Ubiquitty.Session.HostRefusal()
        refusal.hasRefusal = true
        refusal.reason = .VersionMismatch
        var facts = Ubiquitty.Session.UpdateFacts()
        // This app's own build, which states this wire version, under an
        // older app version.
        refusal.hostBuild = facts.local
        refusal.hostBuild.appVersion = std.string("0.0.1.1")
        facts.host = refusal.hostBuild
        if Ubiquitty.Session.olderSideOf(facts) != .Host {
            refusal.hostBuild = .init()
        }
        facts.host = refusal.hostBuild
        refusal.olderSide = Ubiquitty.Session.olderSideOf(facts)
        applyRemoteConnectionPresentation(
            state: .Failed,
            carrier: "",
            refusal: refusal,
            failureDetail: "",
            cause: "",
            linkDetail: ""
        )
    }
    #endif

    #if UBIQUITTY_IOS_UI_TESTS
    /// Asks for the password a server would, then settles on the refusal a
    /// wrong one meets, or on the cancel the person chose.
    private func askTheSeededPassword(of record: HostRecord) {
        noteReached()
        let request = SSHPasswordRequest(username: record.username, host: record.hostName, banner: nil)
        askForPassword(request) { [weak self] password in
            Task { @MainActor in
                guard let self else { return }
                if password == nil {
                    self.finish(isFailure: true, reason: "", classification: .authenticationCancelled)
                } else {
                    self.finish(isFailure: true, reason: "The server refused the password", classification: .authenticationRefused)
                }
            }
        }
    }

    /// Settles this connect as connected without opening a carrier, through
    /// the presentation a connected carrier takes, so a case can reach what
    /// a live connection shows with no host to dial.
    private func settleOnTheSeededConnection() {
        applyRemoteConnectionPresentation(
            state: .Connected,
            carrier: "",
            refusal: nil,
            failureDetail: "",
            cause: "",
            linkDetail: ""
        )
    }
    #endif

    private func updateRemoteStatus() {
        guard transport != .ssh, let ownedSurface else { return }
        let state = ownedSurface.drive.remoteState
        let carrier = ownedSurface.drive.remoteCarrierFact().carrier
        switch carrier {
        case .quic: transport = .quic
        case .stream: transport = .syncSSH
        default: break
        }
        applyRemoteConnectionPresentation(
            state: state,
            carrier: carrier == .none ? "" : transport.rawValue,
            refusal: ownedSurface.drive.lastHostRefusal,
            failureDetail: ownedSurface.remoteFailureDetail,
            cause: ownedSurface.drive.lastRemoteTransitionDetail,
            linkDetail: ownedSurface.drive.paneLinkIndicatorText
        )
        applyRemoteThemeIfNeeded()
    }

    /// Projects already-decided Core facts. This never opens, closes or retries
    /// a carrier; keeping it separate lets the post-detach state be verified.
    func applyRemoteConnectionPresentation(
        state: Ubiquitty.Session.State,
        carrier: String,
        refusal: Ubiquitty.Session.HostRefusal?,
        failureDetail: String,
        cause: String,
        linkDetail: String
    ) {
        if state == .Failed, let refusal { lastHostRefusalReason = refusal.reason }
        if lastHostRefusalReason != nil && state != .Failed {
            // detachRemote retires the authority and emits Idle; that must not
            // erase the refusal the person is still choosing a recovery for.
            isConnected = false
            hasFailed = true
            return
        }
        let detail: String
        isConnected = state == .Connected
        hasFailed = state == .Failed
        switch state {
        case .Connected:
            persistColdResumeDaemonOwner()
            detail = carrier.isEmpty ? "Connected" : "Connected over \(carrier)"
            if !isConnectedStepNoted {
                isConnectedStepNoted = true
                connectionLog.step(String(localized: "Opened the workspace"), .succeeded)
            }
        case .Connecting:
            detail = carrier.isEmpty ? "Connecting…" : "Connecting over \(carrier)…"
            connectingStep = String(localized: "Starting session…")
        case .Reconnecting:
            detail = carrier.isEmpty ? "Reconnecting…" : "Reconnecting over \(carrier)…"
        case .Deploying:
            detail = "Preparing the host…"
        case .Failed:
            if let refusal, refusal.reason == .VersionMismatch {
                detail = versionRefusalSentence(hostBuild: refusal.hostBuild)
            } else if let refusal {
                detail = String(Ubiquitty.Session.connectRefusalNotice(refusal.reason))
            } else {
                detail = failureDetail.isEmpty ? "Connection ended" : failureDetail
            }
            if let refusal {
                failure = ConnectionFailure(
                    refusal: refusal.reason,
                    cause: detail,
                    hasWorkspaceName: attachedIntent.map(Self.namesWorkspace) ?? false
                )
            } else {
                // The host's own words are a diagnostic, kept in the log.
                failure = ConnectionFailure(cause: String(localized: "The connection to \(dialledHostLabel) failed."))
            }
            connectionLog.step(failure?.cause ?? detail, .failed)
        case .Idle:
            detail = "Not connected"
        @unknown default:
            // A state this build has no sentence for leaves the last one
            // standing rather than announcing one it cannot vouch for.
            return
        }
        // Logged per transition with Core's cause, not per sentence: two
        // reconnects in a row read the same on screen and differ in why.
        let transition = "\(detail)\n\(cause)"
        if transition != lastLoggedTransition { connectionLog.noteTransition(detail, diagnostic: cause) }
        lastLoggedTransition = transition
        statusDetail = state == .Connected && !linkDetail.isEmpty ? linkDetail : detail
    }

    /// Starts a new presentation history only when the caller explicitly dials.
    func resetConnectionFailurePresentation() {
        lastHostRefusalReason = nil
        sshFailureSummary = nil
        failure = nil
        bootstrapFailure = nil
        isConnectedStepNoted = false
    }

    /// Whether an intent carried a workspace name, which decides whether a
    /// new workspace opens under it.
    private static func namesWorkspace(_ intent: HostAttachIntent) -> Bool {
        if case .workspace = intent { return true }
        return false
    }

    /// Starts watching the network path for this session.
    ///
    /// Started at attach rather than at init: a model with no session has
    /// nothing to redial, and the first observation is the path it opened on.
    private func watchTheNetworkPath() {
        guard pathWatch == nil else { return }
        let watch = NetworkPathWatch(
            onMove: { [weak self] in
                guard let self, let surface = self.surface else { return }
                // Core decides what a moved path means for the carrier it holds —
                // a QUIC one migrates, anything else is torn down and redialled.
                // Reporting it is all this shell knows how to do.
                surface.networkPathChanged()
                self.connectionLog.note("The network path changed")
                self.updateRemoteStatus()
            },
            onCost: { [weak self] cost in
                // What the link costs is Core's to tell the host, which then
                // pushes a metered phone no history it did not scroll to.
                self?.surface?.setNetworkCost(cost)
            }
        )
        pathWatch = watch
        watch.start()
    }

    /// Opens the session over the SSH channel itself.
    private func openSSHSession(to record: HostRecord, credentials: SSHAuthentication) {
        guard carrier == nil else { return }
        connectionLog.note("Opening the SSH session")
        transport = .ssh
        statusDetail = "Connecting…"
        let client = SSHCarrierClient(
            host: record.hostName,
            port: record.port,
            username: record.username,
            credentials: credentials,
            pinnedFingerprint: record.pinnedHostKeyFingerprint,
            terminalType: "xterm-256color"
        )
        // The carrier answers on its own thread; the surface and everything
        // published here belong to the main actor, so each hop is explicit.
        client.onTransportOpen = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.carrier === client else { return }
                self.noteReached()
            }
        }
        client.onConnect = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.carrier === client else { return }
                self.noteSignedIn()
                self.connectionLog.step(String(localized: "Started a login shell"), .succeeded)
                self.isConnected = true
                self.statusDetail = "Connected"
                self.watchTheNetworkPath()
            }
        }
        client.onBytes = { [weak self, weak client] bytes in
            let copy = Array(bytes.bindMemory(to: UInt8.self))
            Task { @MainActor in
                guard let self, let client, self.carrier === client else { return }
                self.receive(copy)
            }
        }
        client.onClose = { [weak self, weak client] isFailure, reason, reachFailure, classification in
            Task { @MainActor in
                guard let self, let client, self.carrier === client else { return }
                self.finish(isFailure: isFailure, reason: reason, reachFailure: reachFailure, classification: classification)
            }
        }
        carrier = client
        // The surface's session has no stream of its own over SSH, so
        // everything it writes to the host leaves through the carrier from
        // here: keys and pastes, the button and wheel reports the pointer
        // ladder encodes, and the replies the host's queries provoke. One
        // way out, so no byte reaches the carrier twice and none is dropped
        // for want of a frontend that saw it.
        surfaceForDrawing()?.drive
            .setReplyHandler { [weak self, weak client] reply in
                MainActor.assumeIsolated {
                    guard let self, let client, self.carrier === client else { return }
                    reply.withUnsafeBytes { client.send($0) }
                }
            }
        if !client.start() {
            finish(isFailure: true, reason: "The connection could not be started.")
            return
        }
        // A surface laid out before this carrier existed published its grid to
        // nobody: its resize callback found no carrier, and the grid moves
        // again only when the view's bounds do. The PTY request carries it
        // from here rather than the carrier's 80x24 default.
        if let grid = surfaceForDrawing()?.publishedGrid, grid.rows > 0, grid.columns > 0 {
            client.setWindowSize(columns: grid.columns, rows: grid.rows)
        }
    }

    // MARK: - The host's sessions

    /// Asks the host what sessions it is holding.
    ///
    /// Separate from connecting and callable before it: the person is offered a
    /// choice, so what there is to choose from has to be known before this
    /// session binds itself to any of it. The answer arrives through the
    /// surface's observer and lands in ``hostOutline``.
    ///
    /// - Parameters:
    ///   - record: The host to ask.
    ///   - secret: The password, or the PEM text of a private key.
    func askHostForSessions(on record: HostRecord, secret: String) {
        pairingKey = record.pairingKey
        guard record.canListSessions else {
            // A plain-SSH host runs a login shell down a channel and holds
            // nothing to list, so the question has no answer there rather than
            // an empty one.
            settleTheListing(answered: false)
            return
        }
        #if UBIQUITTY_IOS_UI_TESTS
        if let seeded = SmokeLaunch.seededHostTree(hasConnected: hasAskedToConnect, refusals: seededRefusals),
            let drive = listingSurface()?.drive
        {
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            switch seeded {
            case .showcase: drive.holdHostSessionTreeForTesting(ubiquittyShowcaseHostTree(now))
            case .empty: drive.holdHostSessionTreeForTesting(Ubiquitty.Session.SessionTree())
            case .unanswered:
                settleTheListing(answered: false)
                return
            case .busy:
                // Through the door a live refusal takes, so a case covers
                // what the screen does while the directory is busy.
                seededRefusals += 1
                isAskingHostForSessions = true
                askAgainOnceTheDirectoryIsFree(on: record, secret: secret)
                return
            }
            settleTheListing(answered: true)
            return
        }
        #endif
        guard !isAskingHostForSessions else { return }
        isAskingHostForSessions = true
        guard let credentials = credentials(for: record, secret: secret) else {
            settleTheListing(answered: false)
            return
        }
        askForQUICCarrier(record, credentials: credentials) { [weak self] answer in
            guard let self else { return }
            guard case .carrier = answer, let factory = self.directoryCarrierFactory(), let surface = self.listingSurface() else {
                // The wire carries no reason with an empty answer, so this is
                // reported the way the host's own empty answer is: there is
                // nothing here to attach to. The connect that follows says why,
                // in the host's words, on the screen that dialled.
                self.settleTheListing(answered: false)
                return
            }
            let address = ubiquittyIOSQUICFactoryAddress(factory)
            guard address != 0 else {
                self.settleTheListing(answered: false)
                return
            }
            guard surface.listHostSessions(carrierFactory: address) else {
                // The directory is busy with another errand — a terminate, a
                // rename, the listing a served change asks for — and refused
                // rather than queued this one. The answer it holds is the one
                // from before, so the ask stays open and is made again once
                // the directory is free, rather than the old answer being
                // shown as the host's word.
                self.askAgainOnceTheDirectoryIsFree(on: record, secret: secret)
                return
            }
            self.listingRetries = 0
        }
    }

    /// Says whether a screen that lists the host's outline beside its
    /// connection is on screen; the host is followed while one is and the
    /// connection is up.
    ///
    /// - Parameter isShown: Whether one is.
    func setHostOutlineShown(_ isShown: Bool) {
        isHostOutlineShown = isShown
        followTheHostWhileWanted()
    }

    /// Starts or stops following the host's tree, so a watch runs exactly
    /// while its outline is on screen, the app is in front and this
    /// device's connection is up.
    private func followTheHostWhileWanted() {
        let isWanted = isHostOutlineShown && isConnected && !isBackgroundedForFollowing
        guard isWanted != isFollowingHost else { return }
        guard isWanted else {
            stopFollowingTheHost()
            return
        }
        #if UBIQUITTY_IOS_UI_TESTS
        if SmokeLaunch.isSeedingConnectedHost, let drive = listingSurface()?.drive {
            drive.holdWatchedHostSessionTreeForTesting(ubiquittyShowcaseHostTree(UInt64(Date().timeIntervalSince1970 * 1000)))
            isFollowingHost = true
            settleTheListing(answered: true)
            return
        }
        #endif
        // A host reached over QUIC is the one that keeps workspaces to
        // follow; the watch asks for its carriers the way the listing does.
        guard quicProvider != nil, let factory = directoryCarrierFactory(), let surface = listingSurface() else { return }
        let address = ubiquittyIOSQUICFactoryAddress(factory)
        guard address != 0 else { return }
        isFollowingHost = surface.watchHostSessions(carrierFactory: address)
    }

    /// Stops following the host. The tree Core keeps is then one nothing
    /// follows, which no screen shows as the host's word.
    private func stopFollowingTheHost() {
        guard isFollowingHost else { return }
        isFollowingHost = false
        ownedSurface?.stopWatchingHostSessions()
        // A listing that is out settles the outline itself when it answers.
        if !isAskingHostForSessions { settleTheListing(answered: hasHostAnsweredSessions) }
    }

    /// The surface the host's listing is asked on and read from.
    ///
    /// The owned surface, which a pane switch does not move: an answer asked
    /// on the pane on screen and read from the owned one would draw the
    /// tree the owned surface held from before, a stale answer shown as new.
    private func listingSurface() -> TerminalSurface? {
        if let ownedSurface { return ownedSurface }
        _ = surfaceForDrawing()
        return ownedSurface
    }

    /// Makes a refused ask again after a moment, a bounded number of times.
    ///
    /// - Parameters:
    ///   - record: The host to ask.
    ///   - secret: The password, or the PEM text of a private key.
    private func askAgainOnceTheDirectoryIsFree(on record: HostRecord, secret: String) {
        listingRetry?.cancel()
        guard listingRetries < Self.listingRetryLimit else {
            listingRetries = 0
            settleTheListing(answered: false)
            return
        }
        listingRetries += 1
        let delay = Self.listingRetryDelay * Double(listingRetries)
        listingRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.isAskingHostForSessions = false
            self.askHostForSessions(on: record, secret: secret)
        }
    }

    /// How many times a refused ask is made again before the screen says the
    /// host could not be asked, and the pause before the first; each later
    /// pause is longer by as much again.
    private static let listingRetryLimit = 6
    private static let listingRetryDelay = 0.5

    /// The factory the directory errand asks for its carriers through, made
    /// on first use from the provider the attach's factory came from.
    private func directoryCarrierFactory() -> OpaquePointer? {
        if let directoryQUICFactory { return directoryQUICFactory }
        directoryQUICFactory = quicProvider?.makeFactory()
        return directoryQUICFactory
    }

    /// Ends an errand and reads its rows again.
    ///
    /// - Parameter answered: Whether the host answered; a question that could
    ///   not be asked leaves the outline empty without claiming the host is.
    private func settleTheListing(answered: Bool) {
        let drive = ownedSurface?.drive
        if answered, let supersededHostTreeRevision,
            drive?.hostSessionTreeRevision == supersededHostTreeRevision
        {
            return
        }
        if answered { supersededHostTreeRevision = nil }
        let isAnswer = answered && drive?.hasHostAnsweredListing == true
        let stated = HostOutlineFreshness(rawValue: drive?.hostSessionTreeFreshness ?? 0) ?? HostOutlineFreshness.none
        let freshness: HostOutlineFreshness = isAnswer ? stated : .none
        listingRetry?.cancel()
        listingRetry = nil
        hostSessionDaemonSocketName = isAnswer ? (drive?.hostSessionDaemonSocketName ?? "") : ""
        hostSessionDaemonInstanceID = isAnswer ? (drive?.hostSessionDaemonInstanceID ?? 0) : 0
        hasHostAnsweredSessions = isAnswer
        // A tree a watch left behind when it lost the host is what the host
        // held then, not what it holds.
        isHostAnswerCurrent = isAnswer && freshness != .stale
        hostTreeFreshness = freshness
        if isHostAnswerCurrent { hostAnsweredAt = Date() }
        isAskingHostForSessions = false
        // The workspace this device is attached to, so its row says so and
        // starts open; nothing before the connection is live.
        let here = isLive ? listedPlace(of: drive) : nil
        let alreadyOpen = here.map { [HostOutlineOpenWorkspace(host: "", workspaceID: $0.workspaceID, sessionID: $0.sessionID)] } ?? []
        hostOutline.setPlace(host: "", here: here, alreadyOpen: alreadyOpen)
        hostOutlineEveryRow.setPlace(host: "", here: here, alreadyOpen: alreadyOpen)
        hostListOutline.setPlace(host: "", here: here, alreadyOpen: alreadyOpen)
        hostOutline.setSource(isAnswer ? self : nil, closed: hostOutline.closedRows)
        hostOutlineEveryRow.setSource(isAnswer ? self : nil)
        hostListOutline.setSource(isAnswer ? self : nil, closed: hostListOutline.closedRows)
        hostSessionAnswers += 1
    }

    /// Where this device's connection is on the listed host, as the outline
    /// compares rows with it.
    ///
    /// - Parameter drive: The owned surface's drive.
    /// - Returns: The place; nil before the host has named a workspace.
    private func listedPlace(of drive: RuntimeDrive?) -> HostOutlineWindowPlace? {
        guard let drive, drive.remoteWorkspaceID != 0 else { return nil }
        return HostOutlineWindowPlace(host: "", workspaceID: drive.remoteWorkspaceID, paneID: 0, sessionID: drive.remoteSessionID)
    }

    /// The connect Core's rule makes to a host this model listed.
    ///
    /// - Parameter record: The host.
    /// - Returns: The plan, over the host's tree and this device's pairing.
    func decideHostAttach(on record: HostRecord) -> HostAttachDecision? {
        ownedSurface?.decideHostAttach(host: record.pairingKey, predefinedWorkspaceName: record.workspaceName)
    }

    /// Asks the host again, over the carrier it already answered on.
    ///
    /// - Parameters:
    ///   - record: The host to ask.
    ///   - secret: The password, or the PEM text of a private key.
    func refreshHostSessions(on record: HostRecord, secret: String) {
        // Through the same door, because a refresh over a carrier already built
        // is what the seam already does with a factory it has dialled.
        askHostForSessions(on: record, secret: secret)
    }

    /// Core's question for ending what a row stands for, worded from the
    /// tree the host answered with.
    ///
    /// - Parameters:
    ///   - request: Ending one session or a whole workspace.
    ///   - target: What the row stands for.
    ///   - hostName: The host as the person names it.
    /// - Returns: The question, or Core's sentence for why there is none.
    func terminateQuestion(
        _ request: RuntimeDrive.HostDestructiveRequest,
        target: HostOutlineIdentity,
        hostName: String
    ) -> Result<RuntimeDrive.HostDestructiveConfirmation, RuntimeDrive.HostDestructiveRefusal>? {
        ownedSurface?.drive.hostDestructiveConfirmation(request, target: target, hostName: hostName)
    }

    /// Sends what an answered question confirmed.
    ///
    /// A request that never leaves is neither a session that ended nor the
    /// host refusing: it is reported with Core's sentence for why it was not
    /// sent, so nobody is sent to the host to find out.
    ///
    /// - Parameters:
    ///   - request: What the question asked about.
    ///   - target: What it was asked about.
    ///   - confirmation: The question the person answered.
    func terminate(
        _ request: RuntimeDrive.HostDestructiveRequest,
        target: HostOutlineIdentity,
        confirmedBy confirmation: RuntimeDrive.HostDestructiveConfirmation
    ) {
        guard let drive = ownedSurface?.drive else { return }
        if case .failure(.refused(let sentence)) = drive.terminateOnHost(request, target: target, confirmedBy: confirmation) {
            lastTerminateReport = HostSessionTerminateReport(
                sessionID: 0,
                outcome: nil,
                didReachTheHost: false,
                whyNotSent: sentence
            )
        }
    }

    /// Forgets the answer to a terminate once a screen has shown it.
    func clearTerminateReport() {
        lastTerminateReport = nil
    }

    /// Asks the host to give a workspace a name, or to take its name away
    /// with an empty one.
    ///
    /// The host's listing that follows a served change shows the name; a
    /// refusal, in Core's or the host's words, lands in
    /// ``lastStructureRefusal``.
    ///
    /// - Parameters:
    ///   - workspace: The workspace's identity, from its row.
    ///   - name: The name.
    func renameWorkspace(_ workspace: HostOutlineIdentity, to name: String) {
        guard let drive = ownedSurface?.drive else { return }
        lastStructureRefusal = nil
        _ = drive.renameHostWorkspace(workspace, name)
    }

    /// Forgets a refused change once a screen has shown it.
    func clearStructureRefusal() {
        lastStructureRefusal = nil
    }

    /// Re-reads how many others are attached to this session.
    func refreshAttendance() {
        otherAttendeeCount = ownedSurface?.otherAttendeeCount ?? 0
    }

    /// Ends the session.
    func disconnect() {
        notificationIncarnationID = UUID()
        let hasDeniedPicture = coldResume?.isLocallyDenied == true
        keyboardModifiers = TerminalKeyboardModifiers()
        // The probe too: a disconnect while it is still asking would otherwise
        // leave an SSH connection open and answer into a model nobody is
        // watching, opening a session after the reader closed one.
        clearPendingPaneChange()
        if let request = fileDownloadRequest { answerFileDownload(request, download: false) }
        consentRequest = nil
        workspaceMessage = ""
        bootstrapGeneration = UUID()
        bootstrapDeadline?.cancel()
        bootstrapDeadline = nil
        bootstrapRetry?.cancel()
        bootstrapRetry = nil
        bootstrapHostKeyFingerprint = ""
        bootstrapProbe?.cancel()
        bootstrapProbe = nil
        bootstrapWaiters.removeAll()
        if isAskingHostForSessions { settleTheListing(answered: false) }
        // Before the factories below: the watch borrows the directory's.
        stopFollowingTheHost()
        signInPrompt = nil
        pendingPasswordAnswer?(nil)
        pendingPasswordAnswer = nil
        signInInteraction = nil
        pathWatch?.stop()
        pathWatch = nil
        let stoppedCarrier = carrier
        carrier = nil
        stoppedCarrier?.stop()
        pendingInbound.removeAll()
        for pane in paneSurfaces.values where pane !== ownedSurface { pane.drive.close() }
        paneSurfaces.removeAll()
        panes.removeAll()
        tabs.removeAll()
        appliedRemoteTheme = nil
        activePaneID = 0
        arrangedPaneIDs.removeAll()
        visibleCompanionPaneID = nil
        surfaceControllers = surfaceControllers.filter { key, _ in
            ownedSurface.map { ObjectIdentifier($0) == key } ?? false
        }
        // Detached, not closed: the owned surface is the one the next pick
        // draws on, and a closed session has no terminal left to attach.
        ownedSurface?.drive.detachRemote()
        if let ownedSurface { adopt(ownedSurface) }
        // After the session, never before: Core holds this by address and asks
        // it for a carrier on every reconnect.
        if let quicFactory {
            ubiquittyIOSQUICFactoryDestroy(quicFactory)
        }
        quicFactory = nil
        if let directoryQUICFactory {
            ubiquittyIOSQUICFactoryDestroy(directoryQUICFactory)
        }
        directoryQUICFactory = nil
        quicProvider = nil
        coldResume?.abandonPreparation()
        coldResume = nil
        hasHostDeclinedBootstrap = false
        isConnected = false
        inputInDoubt = nil
        if hasDeniedPicture { discardRetiredSurface() }
    }

    /// Installs the exact protected owner before any carrier can be opened.
    ///
    /// - Parameter prepared: The unused owner whose preview is authenticated.
    /// - Returns: Whether this model took the owner and its preview.
    func installColdResume(_ prepared: ColdResumeSession) -> Bool {
        guard coldResume == nil, !prepared.isLocallyDenied, let surface = surfaceForDrawing(), prepared.install(on: surface.drive) else {
            return false
        }
        coldResume = prepared
        return true
    }

    /// Retires the local picture after its protected authorization is denied.
    /// This never clears or closes a host pane. Unlike an ordinary disconnect,
    /// it must not leave the former target's pixels available for reuse.
    ///
    /// - Parameter owner: The exact retired incarnation, never its replacement.
    func retireColdResume(_ owner: ColdResumeSession) {
        guard coldResume === owner else { return }
        disconnect()
        discardRetiredSurface()
    }

    private func discardRetiredSurface() {
        ownedSurface?.isHidden = true
        ownedSurface?.drive.close()
        ownedSurface = nil
        surface = nil
        surfaceControllers.removeAll()
        hasSelection = false
        title = ""
    }

    /// Sends typed bytes toward the shell.
    ///
    /// Through the surface, the way a key press goes: the surface hands the
    /// bytes to the session it holds, which writes them to the SSH carrier
    /// through the handler `openSSHSession` installs or, over QUIC, ships them
    /// as its own Sync input. A write to the carrier alone reaches the shell
    /// on one transport and nothing on the other.
    func send(_ text: String) {
        guard !text.isEmpty else { return }
        surface?.transmitAsUserInput(text)
    }

    private func receive(_ bytes: [UInt8]) {
        guard let surface else {
            pendingInbound.append(contentsOf: bytes)
            return
        }
        surface.feed(Data(bytes))
        surface.serviceIngestEvents()
    }

    /// Records how the connection ended.
    ///
    /// - Parameters:
    ///   - isFailure: Whether an error ended it, rather than the shell.
    ///   - reason: The carrier's description, which goes to the log.
    ///   - reachFailure: Why the host was never reached, when typed.
    ///   - failure: The typed failure, when the caller already has it.
    private func finish(
        isFailure: Bool,
        reason: String,
        reachFailure: SSHReachFailure? = nil,
        classification: SSHCloseClassification? = nil,
        failure typedFailure: ConnectionFailure? = nil
    ) {
        isConnected = false
        hasExited = true
        if isFailure {
            hasFailed = true
            sshFailureSummary = transport == .ssh ? SSHFailurePresentation.directShellSummary(classification) : nil
            connectionLog.note(
                "The connection closed: \(reason.isEmpty ? "no reason given" : reason)"
            )
            statusDetail = Self.sentence(
                for: reason,
                reachFailure: reachFailure,
                host: dialledHost,
                port: dialledPort,
                classification: classification
            )
            let failure =
                typedFailure
                ?? SSHFailurePresentation.failure(
                    reason: reason,
                    reachFailure: reachFailure,
                    classification: classification,
                    host: dialledHost,
                    port: dialledPort
                )
            self.failure = failure
            connectionLog.step(failure.cause, .failed)
        } else if !hasFailed {
            connectionLog.note("The shell exited")
            statusDetail = String(localized: "The shell exited.")
        }
    }

    // MARK: - TerminalSurfaceObserver

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let active = self.surface, ObjectIdentifier(active) == identity else { return }
            self.title = title
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didRingBell reaction: TerminalSurface.BellReaction) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            let isActivePane = self.surface.map { ObjectIdentifier($0) == identity } ?? false
            let isVisibleCompanion =
                visibleCompanionPaneID.flatMap { paneSurfaces[$0] }.map { ObjectIdentifier($0) == identity } ?? false
            let isOnScreen = (isActivePane || isVisibleCompanion) && isScreenVisible
            let isForeground = isOnScreen && UIApplication.shared.applicationState == .active
            if Ubiquitty.Runtime.doesBellMarkUnheard(isForeground) {
                hasUnheardBell = true
            }
        }
    }

    /// A drain changed the screen, and with it possibly the ground: a theme,
    /// an OSC 11 or DECSCNM all reach the snapshot this way.
    nonisolated func terminalSurfaceDidUpdateScreen(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let active = self.surface, ObjectIdentifier(active) == identity else { return }
            refreshGround()
        }
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeScrollback position: TerminalScrollbackPosition) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let active = self.surface, ObjectIdentifier(active) == identity else { return }
            scrollback = position
        }
    }

    /// Returns the focused pane's view to the live output.
    func jumpToBottom() {
        surface?.scrollToTail()
    }

    nonisolated func terminalSurfaceSelectionDidChange(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let active = self.surface, ObjectIdentifier(active) == identity else { return }
            hasSelection = active.hasSelection
        }
    }

    nonisolated func terminalSurfaceDidChangeTabStatus(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let active = self.surface, ObjectIdentifier(active) == identity else { return }
            showProgramStatus(of: active)
        }
    }

    nonisolated func terminalSurfaceDidChangeSearch(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let active = findSurface, ObjectIdentifier(active) == identity, findStatus != nil else { return }
            findStatus = TerminalFindStatus(active.searchStatus)
        }
    }

    /// Shows a surface's program status as the session's.
    private func showProgramStatus(of surface: TerminalSurface) {
        let snapshot = surface.drive.readSnapshot()
        programStatusLabel = String(snapshot.tabStatusLabel())
        // Core resolves it under the pane's theme, as it does on every arm.
        let color = surface.drive.tabStatusColor()
        programStatusColor =
            color.isSet
            ? UIColor(
                red: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1
            ) : nil
    }

    nonisolated func terminalSurface(_ surface: TerminalSurface, didChangeHint text: String) {
        MainActor.assumeIsolated { self.hint = text }
    }

    /// The surface refit its grid to the view. The remote is told the same
    /// numbers the renderer measured, rather than a second count from a font
    /// this shell measured itself.
    nonisolated func terminalSurface(_ surface: TerminalSurface, didResizeGridTo rows: Int, columns: Int) {
        MainActor.assumeIsolated { carrier?.setWindowSize(columns: columns, rows: rows) }
    }

    nonisolated func terminalSurfaceDidRequestKeyboard(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        Task { @MainActor in
            // With two panes on screen the tap may have landed on the one
            // without focus, and the keyboard types into the focused one.
            self.focusPane(showing: identity)
            self.onKeyboardRequested?()
        }
    }

    nonisolated func terminalSurfaceDidRequestSettings(_ surface: TerminalSurface) {
        Task { @MainActor in self.onSettingsRequested?() }
    }

    nonisolated func terminalSurfaceDidRequestNextTab(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        Task { @MainActor in
            guard self.observedSurface(identity) != nil else { return }
            self.switchTab(.next)
        }
    }

    nonisolated func terminalSurfaceDidRequestPreviousTab(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        Task { @MainActor in
            guard self.observedSurface(identity) != nil else { return }
            self.switchTab(.previous)
        }
    }

    nonisolated func terminalSurfaceDidRequestNextConnection(_ surface: TerminalSurface) {
        Task { @MainActor in self.onConnectionSwitchRequested?(.next) }
    }

    nonisolated func terminalSurfaceDidRequestPreviousConnection(_ surface: TerminalSurface) {
        Task { @MainActor in self.onConnectionSwitchRequested?(.previous) }
    }

    /// Focuses the neighbouring workspace pane, crossing tabs and wrapping.
    ///
    /// A workspace with one pane, or none listed — a plain shell, a host not
    /// yet answering — still answers, so the gesture never looks ignored.
    ///
    /// - Parameter step: Which neighbour.
    func switchTab(_ step: SwipeStep) {
        guard let destination = TerminalSwipeNavigation.paneDestination(from: activePaneID, among: panes, step: step) else {
            announce(panes.isEmpty ? TerminalSwipeNavigation.noPanesNotice : TerminalSwipeNavigation.onlyOnePaneNotice)
            return
        }
        selectPane(destination.id)
        if activePaneID == destination.id { announce(destination.title) }
    }

    /// Shows a line over the grid for ``noticeDuration``.
    ///
    /// A later notice replaces an earlier one and gets the whole duration:
    /// each clear is tagged with the notice it was scheduled for, so an older
    /// timer cannot cut a newer notice short.
    ///
    /// - Parameters:
    ///   - text: What to show.
    ///   - duration: How long it stands.
    func announce(_ text: String, for duration: Duration = TerminalSessionModel.noticeDuration) {
        notice = text
        noticeGeneration &+= 1
        let generation = noticeGeneration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = ""
        }
    }

    nonisolated func terminalSurfaceDidExit(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let exiting = observedSurface(identity) else { return }
            if consentRequest?.surface === exiting {
                consentRequest = nil
                presentWaitingConsent()
            }
            if let request = fileDownloadRequest, request.surface === exiting { answerFileDownload(request, download: false) }
            let survivor = paneSurfaces.first { id, candidate in
                guard candidate !== exiting,
                    let pane = Ubiquitty.Session.Layout.PaneID(rawValue: id)
                else { return false }
                return candidate.drive.remoteWorkspaceSession(for: pane) != 0
            }
            if let survivor {
                if exiting === ownedSurface { ownedSurface = survivor.value }
                paneSurfaces = paneSurfaces.filter { $0.value !== exiting }
                if exiting === self.surface { selectPane(survivor.key) }
                refreshPanes()
                return
            }
            finish(isFailure: false, reason: "")
        }
    }

    /// The host answered what sessions it is holding.
    nonisolated func terminalSurfaceDidUpdateHostSessions(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            // Read back through the model's own surface rather than the
            // argument: the two are the same object, and the argument crosses
            // into the actor as a value the compiler cannot prove nobody else
            // still holds.
            settleTheListing(answered: true)
        }
    }

    /// A request to end one of the host's sessions settled.
    ///
    /// The row is dropped on the outcome and never on the ask: a refused,
    /// denied or timed-out terminate leaves the session exactly where it was.
    nonisolated func terminalSurface(
        _ surface: TerminalSurface,
        didSettleHostSessionTerminate sessionID: UInt32,
        outcome: HostSessionTerminateOutcome?
    ) {
        MainActor.assumeIsolated {
            lastTerminateReport = HostSessionTerminateReport(sessionID: sessionID, outcome: outcome)
        }
    }

    /// A change asked of the host's structure ended.
    nonisolated func terminalSurfaceDidSettleHostStructure(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            guard let result = ownedSurface?.drive.lastHostStructureResult, result.outcome != .served else { return }
            lastStructureRefusal = HostStructureRefusal(requestID: result.requestID, reason: result.reason)
        }
    }

    /// The remote connection moved, or the host pinned this session's id.
    ///
    /// The pairing is made from the id the host answered with rather than from
    /// an attach returning true, which says only that the ask went out: a
    /// reattach the host answered with a different session is a session that
    /// had ended, and Core's own memory is what the next connect reads.
    /// What the screen was asked to reach, from the intent alone.
    ///
    /// - Parameter attach: What the picker or the connect rule chose.
    /// - Returns: The sentence the settings sheet shows before a carrier exists.
    private func summary(forIntent attach: HostAttachIntent) -> String {
        switch attach {
        case .session(let id, _, _, _):
            return "Session \(id)"
        case .workspace(let name, _, _, _):
            return "Workspace \(name)"
        case .newSession:
            return "New workspace"
        }
    }

    /// What the screen shows when the carrier the pick needed never arrived.
    ///
    /// - Parameter attach: What was asked for and cannot be reached.
    /// - Returns: A sentence that names the pick and says it was not reached.
    private func summary(forLostPick attach: HostAttachIntent) -> String {
        switch attach {
        case .session(let id, _, _, _):
            return "Session \(id), not reached"
        case .workspace(let name, _, _, _):
            return "Workspace \(name), not reached"
        case .newSession:
            return "New workspace"
        }
    }

    /// What the screen asked the host for, before the host has answered.
    ///
    /// - Parameters:
    ///   - requested: The session id asked for, or zero for a new one.
    ///   - workspaceName: The workspace asked for, empty when none was.
    /// - Returns: The sentence the settings sheet shows while connecting.
    private func summary(forRequested requested: UInt32, workspaceName: String) -> String {
        if requested != 0 {
            return "Session \(requested)"
        }
        if !workspaceName.isEmpty {
            return "Workspace \(workspaceName)"
        }
        return "New workspace"
    }

    /// What the host said this screen is on.
    ///
    /// - Parameters:
    ///   - acknowledged: The session id the host bound this connection to.
    ///   - workspaceName: The workspace it carries, empty when unnamed.
    /// - Returns: The sentence the settings sheet shows once connected.
    private func summary(forAcknowledged acknowledged: UInt32, workspaceName: String) -> String {
        workspaceName.isEmpty
            ? "Session \(acknowledged)"
            : "Session \(acknowledged), workspace \(workspaceName)"
    }

    nonisolated func terminalSurfaceDidChangeInputInDoubt(_: TerminalSurface) {
        MainActor.assumeIsolated { updateInputInDoubt() }
    }

    nonisolated func terminalSurfaceDidChangeRemoteSession(_ surface: TerminalSurface) {
        MainActor.assumeIsolated {
            // A pane whose connection ended has nothing in doubt any more.
            updateInputInDoubt()
            if let request = fileDownloadRequest, request.surface.drive.pendingFileDownloadToken != request.prompt.token {
                fileDownloadRequest = nil
            }
            // The model's own surface, for the reason the list hook reads it:
            // the argument is the same object, arriving as a value the compiler
            // cannot prove nobody else still holds.
            updateRemoteStatus()
            guard !pairingKey.isEmpty, let surface = ownedSurface else { return }
            if surface.wasReattachRefused {
                // Never retried: the host has already said no to this id, and
                // the person is taken back to the list to choose again with the
                // host's own sentence in front of them.
                HostDirectory.forget(host: pairingKey)
                let detail = surface.drive.lastHostRefusal.map { String(Ubiquitty.Session.connectRefusalNotice($0.reason)) } ?? ""
                reattachRefusal =
                    detail.isEmpty
                    ? "The host couldn’t return the workspace this device was last using."
                    : detail
                hasBegunConnecting = false
                isConnected = false
                // The refused attach still holds the surface's remote half, and
                // the next pick skips `disconnect`; an attach over a held half
                // is refused, which fell back to a plain SSH shell.
                surface.drive.detachRemote()
                return
            }
            let sessionID = surface.remoteSessionID
            guard sessionID != 0 else { return }
            summaryState = .settled(summary(forAcknowledged: sessionID, workspaceName: attachedWorkspaceName))
            HostDirectory.remember(
                host: pairingKey,
                sessionID: sessionID,
                workspaceName: attachedWorkspaceName
            )
            refreshAttendance()
        }
    }
}

/// A pane identified by the host's authoritative workspace layout.
///
/// Carries the tab it sits in, because the list is flat — every window's tabs'
/// panes in the host's order — and a tab switch moves between runs of panes
/// that share one.
struct TerminalPane: Identifiable, Equatable {
    let id: UInt32
    let title: String
    /// The host window holding the pane's tab, by position.
    let windowIndex: Int
    /// The pane's tab, by position within its window.
    let tabIndex: Int
    /// The tab's own title, or "Tab N" for a tab the host has not named.
    let tabTitle: String
    /// The host's identity for the pane's tab; zero for a pane listed without one.
    var tabID: UInt32 = 0
}

/// A consent request retains the exact surface that must answer it.
@MainActor
struct TerminalConsentRequest: Identifiable {
    enum Identity: Hashable {
        case consent(ObjectIdentifier, UInt64)
        case structure(ObjectIdentifier, UInt64)
    }

    let id: Identity
    let question: String
    let host: String
    let sessionLabel: String
    let actor: String
    let claimedLabel: String
    /// Set when this device's own program asked: who sent it and the lifetime
    /// a grant keeps, in place of a verified process and a claimed name.
    let ownDeviceDetail: String?
    let isCapabilityGrant: Bool
    let allowsPersistentGrant: Bool
    /// Set when this device asks of its own policy about an effect its remote
    /// host delivered: the answer never reaches the host, which sets no time
    /// limit, and the widest allow lasts as long as the connection.
    let isClientHeld: Bool
    let surface: TerminalSurface

    /// The widest allow a client-held question offers, in Core's words.
    static let connectionScopeTitle = String(Ubiquitty.Security.hostEffectConnectionScopeTitle())
    let structurePrompt: RuntimeDrive.StructureConsentPrompt?

    /// Answers only the exact local presentation retained by this prompt.
    func answer(_ decision: ConsentDecision) {
        switch id {
        case .consent(_, let token):
            surface.drive.respondToConsent(token, decision: decision)
        case .structure(_, let token):
            surface.drive.respondToStructureConsent(token, allow: decision == .allowOnce)
        }
    }
}

extension TerminalSessionModel {
    /// Installs connection metadata and a presentation route, never a URI-selected carrier.
    private func configureFileLinks(on surface: TerminalSurface) {
        surface.remoteFileHost = dialledHost
        surface.remoteFileHostLabel = dialledHostLabel
        surface.fileDownloadPromptHandler = { [weak self, weak surface] prompt in
            guard let self, let surface else { return }
            guard self.consentRequest == nil, self.fileDownloadRequest == nil else {
                surface.answerFileDownload(prompt, download: false)
                return
            }
            self.fileDownloadRequest = TerminalFileDownloadRequest(surface: surface, prompt: prompt)
        }
    }

    /// Downloads only the captured pane's file; the Files view exports its answer.
    func answerFileDownload(_ request: TerminalFileDownloadRequest, download: Bool) {
        if download, fileDownloadRequest?.id != request.id { return }
        if fileDownloadRequest?.id == request.id { fileDownloadRequest = nil }
        guard download else {
            request.surface.answerFileDownload(request.prompt, download: false)
            return
        }
        guard request.surface.drive.pendingFileDownloadToken == request.prompt.token else {
            fileMessage = "This download is no longer available. Tap the link again."
            return
        }
        requestedFileSurface = ObjectIdentifier(request.surface)
        requestedFileID = request.surface.answerFileDownload(request.prompt, download: true)
        receivedFile = nil
        fileMessage = requestedFileID == 0 ? "This download is no longer available. Tap the link again." : "Receiving file…"
    }

    /// Finds a retained surface without carrying a UIKit view across isolation boundaries.
    private func observedSurface(_ identity: ObjectIdentifier) -> TerminalSurface? {
        if let ownedSurface, ObjectIdentifier(ownedSurface) == identity { return ownedSurface }
        return paneSurfaces.values.first { ObjectIdentifier($0) == identity }
    }

    /// What one pane is called in the list: the name Core gives a pane among
    /// several, which is its own program's title and never its tab's name,
    /// else its place in the tab.
    ///
    /// - Parameters:
    ///   - view: The pane's surface, whose program titled it.
    ///   - ordinal: The pane's position in its tab, from one.
    /// - Returns: The pane's name.
    private static func paneName(of view: TerminalSurface, ordinal: Int) -> String {
        let programTitle = view.drive.currentTitle() ?? ""
        let resolved = programTitle.withCString { titleBytes in
            var names = Ubiquitty.Session.TitleNames()
            names.oscTitle = std.string_view(titleBytes)
            let outcome = Ubiquitty.Session.resolveTitleNames(names, .pane)
            return outcome.replacement.empty() ? String(outcome.appTitle) : String(outcome.replacement)
        }
        return resolved.isEmpty ? "Pane \(ordinal)" : resolved
    }

    /// Moves what the model keeps by pane and tab id to the ids a host
    /// restored the workspace under, and lets go of every id the
    /// restoration did not pair.
    ///
    /// A host that took in the record of a daemon that stopped restores the
    /// workspace with ids of its own, and Core carries each pane's session
    /// to the pane restored in its place. A pane's view is still that pane's
    /// under its new id; an id the pairing does not name is the stopped
    /// host's, and the restoring host may have given the same number to
    /// another pane, so no view stays under one.
    ///
    /// - Parameter restored: Core's pairs, from the ids held to the mirror's.
    private func adoptRestoration(_ restored: [Ubiquitty.Session.Layout.RestoredPane]) {
        var paneIDs: [UInt32: UInt32] = [:]
        var tabIDs: [UInt32: UInt32] = [:]
        for pair in restored {
            paneIDs[pair.formerPane.rawValue] = pair.pane.rawValue
            tabIDs[pair.formerTab.rawValue] = pair.tab.rawValue
        }
        paneSurfaces = Dictionary(
            paneSurfaces.compactMap { id, view in paneIDs[id].map { ($0, view) } },
            uniquingKeysWith: { first, _ in first }
        )
        activePaneID = paneIDs[activePaneID] ?? 0
        arrangedPaneIDs = arrangedPaneIDs.compactMap { paneIDs[$0] }
        visibleCompanionPaneID = visibleCompanionPaneID.flatMap { paneIDs[$0] }
        tabProblems = Dictionary(
            tabProblems.compactMap { id, problem in tabIDs[id].map { ($0, problem) } },
            uniquingKeysWith: { first, _ in first }
        )
        pendingTabIDs = Set(pendingTabIDs.compactMap { tabIDs[$0] })
    }

    /// Projects the host's tabs and panes into a compact navigation list.
    func refreshPanes() {
        guard !isRefreshingPanes, let anchor = ownedSurface, anchor.isRemoteAttached else { return }
        isRefreshingPanes = true
        defer { isRefreshingPanes = false }
        let drive = anchor.drive
        if let restored = drive.takeRemoteWorkspaceRestoredPanes() {
            adoptRestoration(restored)
        }
        if drive.remoteWorkspaceSurfaceCount > 0 {
            if drive.isRemoteWorkspaceRestoredAfterHostRestart, !hasAnnouncedHostRestart {
                hasAnnouncedHostRestart = true
                announce(Self.hostRestartNotice, for: Self.hostRestartNoticeDuration)
            }
            attachedWorkspaceName = drive.remoteWorkspaceName
            summaryState = .settled(summary(forAcknowledged: anchor.remoteSessionID, workspaceName: attachedWorkspaceName))
            if !pairingKey.isEmpty {
                HostDirectory.remember(host: pairingKey, sessionID: anchor.remoteSessionID, workspaceName: attachedWorkspaceName)
            }
        }
        var listed: [TerminalPane] = []
        var listedTabs: [TerminalTab] = []
        var retained: [UInt32: TerminalSurface] = [:]
        for windowIndex in 0..<drive.remoteWorkspaceSurfaceCount {
            let window = drive.remoteWorkspaceSurface(at: windowIndex)
            for tabIndex in 0..<drive.remoteWorkspaceTabCount(of: window) {
                let tab = drive.remoteWorkspaceTab(of: window, at: tabIndex)
                let customTitle = drive.remoteWorkspaceTabTitle(of: window, tab: tab)
                let tabTitle = customTitle.isEmpty ? "Tab \(tabIndex + 1)" : customTitle
                let tree = drive.remoteWorkspacePaneTreeSnapshot(of: window, tab: tab)
                var paneNumber = 0
                for id in TerminalSwipeNavigation.paneIDs(in: tree) {
                    guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: id) else { continue }
                    let sessionID = drive.remoteWorkspaceSession(for: pane)
                    guard sessionID != 0 else { continue }
                    let view: TerminalSurface
                    if pane == drive.remoteWorkspacePane {
                        view = anchor
                    } else if let existing = paneSurfaces[id] {
                        view = existing
                    } else {
                        guard let created = makePaneSurface(),
                            created.attachRemoteSibling(to: drive, sessionID: sessionID)
                        else { continue }
                        created.observer = self
                        created.drive.installDefaultClients()
                        view = created
                    }
                    paneNumber += 1
                    retained[id] = view
                    let paneName = Self.paneName(of: view, ordinal: paneNumber)
                    listed.append(
                        TerminalPane(
                            id: id,
                            title: "\(tabTitle) · \(paneName)",
                            windowIndex: windowIndex,
                            tabIndex: tabIndex,
                            tabTitle: tabTitle,
                            tabID: tab.rawValue
                        )
                    )
                }
                let zoomed = drive.remoteWorkspaceActiveTab(of: window) == tab ? drive.remoteWorkspaceZoomedPane(of: window).rawValue : 0
                listedTabs.append(
                    TerminalTab(
                        id: tab.rawValue,
                        windowID: window.rawValue,
                        windowIndex: windowIndex,
                        tabIndex: tabIndex,
                        customTitle: customTitle,
                        focusedPaneID: UInt32(truncatingIfNeeded: tree.focusedPaneID()),
                        zoomedPaneID: zoomed,
                        panes: TerminalTab.layout(of: tree).filter { retained[$0.id] != nil }
                    )
                )
            }
        }
        tabs = listedTabs.filter { !$0.panes.isEmpty }
        let previousPaneIDs = panes.map(\.id)
        paneSurfaces = retained
        panes = listed
        refreshTabTitles()
        let kept = Set(retained.values.map { ObjectIdentifier($0) })
            .union(ownedSurface.map { [ObjectIdentifier($0)] } ?? [])
        if let request = consentRequest, !kept.contains(ObjectIdentifier(request.surface)) {
            consentRequest = nil
            presentWaitingConsent()
        }
        if let request = fileDownloadRequest, !kept.contains(ObjectIdentifier(request.surface)) {
            answerFileDownload(request, download: false)
        }
        surfaceControllers = surfaceControllers.filter { kept.contains($0.key) }
        reconcilePaneFocus(attachmentPaneID: drive.remoteWorkspacePane.rawValue, previousPaneIDs: previousPaneIDs)
        applyRemoteThemeIfNeeded()
        settlePaneChange()
        settleTabRequests()
    }

    /// Starts on the pane admitted for the selected session, then preserves
    /// local focus across topology updates and chooses a neighbor after close.
    func reconcilePaneFocus(attachmentPaneID: UInt32, previousPaneIDs: [UInt32]) {
        if activePaneID == 0, paneSurfaces[attachmentPaneID] != nil {
            focusPane(attachmentPaneID)
        } else if paneSurfaces[activePaneID] == nil,
            let replacement = TerminalPaneArrangement.replacementFocus(
                for: activePaneID,
                previous: previousPaneIDs,
                available: panes.map(\.id)
            )
        {
            focusPane(replacement)
        } else {
            arrangedPaneIDs = TerminalPaneArrangement.arrangement(
                after: arrangedPaneIDs,
                focusing: activePaneID,
                previouslyFocused: nil,
                available: panes.map(\.id)
            )
            if let selected = paneSurfaces[activePaneID] { adopt(selected) }
        }
    }

    /// Lists a workspace and focuses one of its panes with no host behind it.
    ///
    /// Each pane gets a surface of its own, as ``refreshPanes()`` gives it, so a
    /// focus change goes through the same path a listed workspace takes; only
    /// the host's answer is missing.
    ///
    /// - Parameters:
    ///   - listed: The panes, grouped by tab in the host's order.
    ///   - id: The pane to focus.
    func seedWorkspaceForTesting(_ listed: [TerminalPane], focusing id: UInt32) {
        var retained: [UInt32: TerminalSurface] = [:]
        for pane in listed {
            retained[pane.id] = makePaneSurface()
        }
        paneSurfaces = retained
        panes = listed
        focusPane(id)
    }

    /// Lists a workspace as the first refresh after an attach lists it, with
    /// no host behind it.
    ///
    /// The attached pane is drawn by the session's own surface, as
    /// ``refreshPanes()`` gives the anchor its pane, and focus reaches it
    /// through ``reconcilePaneFocus(attachmentPaneID:previousPaneIDs:)`` from
    /// no focus at all; every other pane gets a surface of its own.
    ///
    /// - Parameters:
    ///   - listed: The panes, grouped by tab in the host's order.
    ///   - id: The pane the attach drew.
    func seedAttachedWorkspaceForTesting(_ listed: [TerminalPane], attachedPane id: UInt32) {
        guard let anchor = surfaceForDrawing() else { return }
        var retained: [UInt32: TerminalSurface] = [:]
        for pane in listed {
            retained[pane.id] = pane.id == id ? anchor : makePaneSurface()
        }
        paneSurfaces = retained
        panes = listed
        reconcilePaneFocus(attachmentPaneID: id, previousPaneIDs: [])
    }

    /// Focuses a pane without opening another network connection.
    func selectPane(_ id: UInt32) {
        clearPendingPaneChange()
        workspaceMessage = ""
        focusPane(id)
    }

    private func focusPane(_ id: UInt32) {
        guard let selected = paneSurfaces[id] else { return }
        let previous = activePaneID
        activePaneID = id
        arrangedPaneIDs = TerminalPaneArrangement.arrangement(
            after: arrangedPaneIDs,
            focusing: id,
            previouslyFocused: previous == 0 ? nil : previous,
            available: panes.map(\.id)
        )
        adopt(selected)
        _ = selected.drive.requestPaneVerb(.focus)
    }

    /// Focuses the pane a surface draws, when it is not focused already.
    ///
    /// - Parameter identity: The surface's identity.
    func focusPane(showing identity: ObjectIdentifier) {
        guard let current = surface, ObjectIdentifier(current) != identity,
            let pane = paneSurfaces.first(where: { ObjectIdentifier($0.value) == identity })
        else { return }
        selectPane(pane.key)
    }

    /// Sends a split or close through the pane's authoritative workspace.
    func performPaneAction(_ action: Ubiquitty.Runtime.TerminalSession.PaneVerb) {
        guard let surface else { return }
        beginPaneChange(on: surface, closing: action == .close ? activePaneID : nil) {
            surface.drive.requestPaneVerb(action) == .handled
        }
    }

    /// Closes the pane named by the confirmation, independent of current focus.
    func closePane(_ id: UInt32) {
        guard let pane = paneSurfaces[id] else {
            workspaceMessage = "This pane has already closed."
            return
        }
        beginPaneChange(on: pane, closing: id) { pane.drive.requestPaneVerb(.close) == .handled }
    }

    /// Adds a tab and focuses only the pane named in this request's reply.
    func addTab() {
        guard let surface else { return }
        beginPaneChange(on: surface, shouldOpenCreatedTab: true) { surface.drive.remoteWorkspaceAddTab() }
    }

    private func beginPaneChange(
        on surface: TerminalSurface,
        closing paneID: UInt32? = nil,
        shouldOpenCreatedTab: Bool = false,
        send: () -> Bool
    ) {
        guard canChangePanes else {
            if !isChangingPanes { workspaceMessage = "Wait for the connection before changing panes." }
            return
        }
        clearPendingPaneChange()
        pendingPaneChangeSurface = surface
        pendingClosedPaneID = paneID
        self.shouldOpenCreatedTab = shouldOpenCreatedTab
        workspaceMessage = paneID == nil ? "Creating pane…" : "Closing pane…"
        guard send() else {
            clearPendingPaneChange()
            workspaceMessage = "The pane change could not be sent. Try again when connected."
            return
        }
        paneChangeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            self.clearPendingPaneChange()
            self.workspaceMessage = "The host has not confirmed the change. Check the pane list before trying again."
        }
    }

    private func settlePaneChange() {
        guard let source = pendingPaneChangeSurface else { return }
        let result = source.drive.takeRemoteWorkspacePaneChange()
        switch result.outcome {
        case .Pending, .Idle: break
        case .Accepted:
            hasPaneChangeAcknowledgment = true
            if result.createdPaneID != 0 { pendingCreatedPaneID = result.createdPaneID }
        case .Refused:
            clearPendingPaneChange()
            workspaceMessage = "The host refused this pane change. Its pane limit or permissions may prevent it."
            return
        case .Interrupted:
            clearPendingPaneChange()
            workspaceMessage = "The connection dropped before confirmation. Check the pane list after reconnecting."
            return
        }
        guard hasPaneChangeAcknowledgment else { return }
        if let id = pendingCreatedPaneID, paneSurfaces[id] != nil {
            let shouldOpen = shouldOpenCreatedTab
            clearPendingPaneChange()
            focusPane(id)
            if shouldOpen { isShowingTabOverview = false }
        } else if pendingClosedPaneID != nil {
            clearPendingPaneChange()
        } else {
            return
        }
        workspaceMessage = ""
        completedPaneChanges += 1
    }

    private func clearPendingPaneChange() {
        paneChangeDeadline?.cancel()
        paneChangeDeadline = nil
        pendingPaneChangeSurface = nil
        pendingCreatedPaneID = nil
        pendingClosedPaneID = nil
        shouldOpenCreatedTab = false
        hasPaneChangeAcknowledgment = false
    }

    nonisolated func terminalSurfaceDidChangeRemoteWorkspace(_ surface: TerminalSurface) {
        MainActor.assumeIsolated { refreshPanes() }
    }

    /// A program asked for a banner: the remote host's NOTIFICATION frames,
    /// which the host sends only to this device when its person drives the
    /// session, land in the session's queue and are posted from here.
    nonisolated func terminalSurfaceDidPostNotification(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let surface = observedSurface(identity) else { return }
            while let notification = surface.drive.takeNotification() {
                postBanner(
                    title: notification.title,
                    body: notification.body,
                    name: notification.identifier,
                    occasion: Ubiquitty.NotificationOccasion(rawValue: notification.occasion) ?? .Always,
                    from: surface
                )
            }
        }
    }

    /// Posts one banner a pane's program asked for, as Core composes it.
    ///
    /// What the banner says and in which slot, where it says the session is,
    /// whether a person already looking at the pane gets one and which
    /// earlier banner it replaces are Core's, shared with the desktop shell.
    /// This reports the place and the audience and posts what comes back,
    /// asking for permission the first time; a refusal drops the banner, as
    /// the system would.
    ///
    /// - Parameters:
    ///   - title: The notification's title, already resolved by Core.
    ///   - body: Its body, empty for a body-only message.
    ///   - name: The program's own name for the notification, or empty.
    ///   - occasion: When the program wants it shown.
    ///   - surface: The pane that asked.
    private func postBanner(
        title: String,
        body: String,
        name: String,
        occasion: Ubiquitty.NotificationOccasion,
        from surface: TerminalSurface
    ) {
        if let savedHostID, BackgroundRefreshCoordinator.shared.noteLiveNotification(for: savedHostID) { return }
        let place = Ubiquitty.Session.describeBannerPlace(bannerPlaceFacts(of: surface))
        let banner = Ubiquitty.OSC.composeBanner(std.string(title), std.string(body), place)
        guard banner.shouldPost, Ubiquitty.OSC.isBannerWanted(bannerAudience(for: surface), occasion) else { return }
        // One group per dialled host: a phone shows one host's session at a
        // time, and a pane's id is the host's, unique within what it holds.
        let scope = std.string("\(dialledHost):\(dialledPort)")
        let pane = UInt64(paneID(of: surface) ?? 0)
        let identifier = String(
            Ubiquitty.OSC.bannerRequestIdentifier(.Program, scope, pane, std.string(name))
        )
        let thread = String(Ubiquitty.OSC.bannerThreadIdentifier(scope))
        let heading = String(banner.title)
        let sender = String(banner.subtitle)
        let text = String(banner.body)
        // A banner the app cannot trace back to a producer it still holds is
        // never presented in the foreground, so a pane with no saved host or
        // no attached session posts none.
        guard let savedHostID, surface.remoteSessionID != 0, surface.drive.remoteDaemonInstanceID != 0 else { return }
        let origin = NotificationPresentationOrigin.Live(
            hostID: savedHostID,
            incarnationID: notificationIncarnationID,
            daemonID: surface.drive.remoteDaemonInstanceID,
            sessionID: surface.remoteSessionID,
            occasion: occasion
        )
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]), self?.liveBannerAudience(for: origin) != nil
                else { return }
                let content = UNMutableNotificationContent()
                content.title = heading
                content.subtitle = sender
                content.body = text
                content.threadIdentifier = thread
                content.userInfo = origin.userInfo
                // Adding under an identifier a delivered request holds
                // replaces that one.
                let request = UNNotificationRequest(identifier: origin.prefix + identifier, content: content, trigger: nil)
                try await BackgroundRefreshDelivery.post(
                    identifier: request.identifier,
                    isCurrent: { self?.liveBannerAudience(for: origin) != nil },
                    add: { try await center.add(request) },
                    remove: { name in
                        center.removeDeliveredNotifications(withIdentifiers: [name])
                        center.removePendingNotificationRequests(withIdentifiers: [name])
                    }
                )
            } catch {
                // A refused permission or a retired attachment posts nothing.
            }
        }
    }

    /// The audience of the pane a live banner came from, while this model
    /// still holds the attachment that posted it.
    ///
    /// - Parameter origin: The banner's live attachment.
    /// - Returns: The pane's audience, or nil once the host, incarnation,
    ///   daemon or session has changed.
    func liveBannerAudience(for origin: NotificationPresentationOrigin.Live) -> Ubiquitty.OSC.BannerAudience? {
        guard savedHostID == origin.hostID, notificationIncarnationID == origin.incarnationID else { return nil }
        let surfaces = Array(paneSurfaces.values) + (ownedSurface.map { [$0] } ?? [])
        guard
            let surface = surfaces.first(where: {
                $0.isRemoteAttached && $0.remoteSessionID == origin.sessionID && $0.drive.remoteDaemonInstanceID == origin.daemonID
            })
        else { return nil }
        return bannerAudience(for: surface)
    }

    /// The host's id for the pane a surface draws, or nil for a session the
    /// host lists no panes for.
    private func paneID(of surface: TerminalSurface) -> UInt32? {
        paneSurfaces.first { $0.value === surface }?.key
    }

    /// Where the person's attention is, for a banner one pane asked for.
    ///
    /// Observations and no verdict; whether someone looking there needs a
    /// banner is Core's (`OSC.isBannerWanted`). A phone has no key window:
    /// what stands in for it is this session's screen being the one shown.
    ///
    /// - Parameter surface: The pane that asked.
    /// - Returns: What this session observes.
    private func bannerAudience(for surface: TerminalSurface) -> Ubiquitty.OSC.BannerAudience {
        let isActivePane = self.surface === surface
        let isVisibleCompanion = visibleCompanionPaneID.flatMap { paneSurfaces[$0] } === surface
        var audience = Ubiquitty.OSC.BannerAudience()
        audience.isAppActive = UIApplication.shared.applicationState == .active
        audience.isWindowKey = isScreenVisible
        audience.isPaneFocused = isActivePane
        audience.isPaneVisible = (isActivePane || isVisibleCompanion) && isScreenVisible
        return audience
    }

    /// Reads the existing live pane's audience for a retained host event.
    func backgroundBannerAudience(sessionID: UInt32) -> Ubiquitty.OSC.BannerAudience? {
        guard UIApplication.shared.applicationState == .active, sessionID != 0 else { return nil }
        let surfaces = Array(paneSurfaces.values) + (ownedSurface.map { [$0] } ?? [])
        guard let surface = surfaces.first(where: { $0.isRemoteAttached && $0.remoteSessionID == sessionID }) else { return nil }
        return bannerAudience(for: surface)
    }

    /// What this session holds about where one pane sits, for a banner's
    /// place line.
    ///
    /// Names and counts as the host's layout states them; which of them the
    /// line shows is Core's (`Session.describeBannerPlace`). The host is the
    /// name the person saved it under, the tab is called what the pane list
    /// calls it, and a pane is numbered by its position in its tab, which is
    /// how the list numbers it. A host's windows carry no title here.
    ///
    /// - Parameter surface: The pane that asked.
    /// - Returns: The facts.
    private func bannerPlaceFacts(of surface: TerminalSurface) -> Ubiquitty.Session.BannerPlaceFacts {
        var facts = Ubiquitty.Session.BannerPlaceFacts()
        facts.host = std.string(dialledHostLabel)
        facts.workspace = std.string(attachedWorkspaceName)
        guard let id = paneID(of: surface), let listed = panes.first(where: { $0.id == id }) else { return facts }
        facts.tabTitle = std.string(listed.tabTitle)
        let window = panes.filter { $0.windowIndex == listed.windowIndex }
        let tab = window.filter { $0.tabIndex == listed.tabIndex }
        facts.windowCount = Int32(max(1, Set(panes.map(\.windowIndex)).count))
        facts.tabCount = Int32(max(1, Set(window.map(\.tabIndex)).count))
        facts.paneCount = Int32(max(1, tab.count))
        facts.paneNumber = Int32((tab.firstIndex { $0.id == id } ?? 0) + 1)
        return facts
    }

    nonisolated func terminalSurfaceDidRequestConsent(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let surface = observedSurface(identity) else { return }
            let wasShowing = consentRequest != nil
            showConsent(of: surface)
            if wasShowing && consentRequest == nil { presentWaitingConsent() }
        }
    }

    /// Shows the next question a pane holds once the one shown has closed.
    ///
    /// One sheet shows one question at a time. A question another pane holds
    /// meanwhile waits on that pane rather than being declined: a decline
    /// tells the host this device will never show it.
    private func presentWaitingConsent() {
        guard consentRequest == nil else { return }
        let held = paneSurfaces.sorted { $0.key < $1.key }.map(\.value).filter { $0 !== ownedSurface }
        for surface in (ownedSurface.map { [$0] } ?? []) + held
        where surface.drive.pendingConsentToken != 0 || surface.drive.pendingStructureConsent != nil {
            showConsent(of: surface)
            if consentRequest != nil { return }
        }
    }

    /// Presents the question a pane holds, if the sheet is free.
    ///
    /// - Parameter surface: The pane.
    private func showConsent(of surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        let drive = surface.drive
        let structure = drive.pendingStructureConsent
        if let pending = consentRequest, pending.surface === surface {
            switch pending.id {
            case .consent(_, let token):
                if token != drive.pendingConsentToken { consentRequest = nil }
            case .structure(_, let token):
                if token != structure?.token { consentRequest = nil }
            }
        }
        if drive.pendingConsentAction == .changeStructure {
            guard let request = structure else { return }
            let requestIdentity = TerminalConsentRequest.Identity.structure(identity, request.token)
            guard consentRequest?.id != requestIdentity else { return }
            // Another question is up: this one waits on its pane.
            guard consentRequest == nil else { return }
            consentRequest = TerminalConsentRequest(
                id: requestIdentity,
                question: request.question,
                host: dialledHost,
                sessionLabel: surface.remoteSessionID == 0 ? "Unknown" : String(surface.remoteSessionID),
                actor: "",
                claimedLabel: "",
                ownDeviceDetail: nil,
                isCapabilityGrant: false,
                allowsPersistentGrant: false,
                isClientHeld: false,
                surface: surface,
                structurePrompt: request
            )
            return
        }
        let token = drive.pendingConsentToken
        guard token != 0 else { return }
        let requestIdentity = TerminalConsentRequest.Identity.consent(identity, token)
        guard consentRequest?.id != requestIdentity else { return }
        // Another question is up: this one waits on its pane.
        guard consentRequest == nil else { return }
        guard let action = drive.pendingConsentAction else {
            drive.declineConsent(token)
            return
        }
        let question: String
        var ownDeviceDetail: String?
        let isClientHeld = action == .grantCapability && drive.pendingConsentIsClientHeld
        switch action {
        case .attach: question = "Allow this agent to access the session?"
        case .terminate: question = "Allow this agent to close the session?"
        case .grantCapability:
            let code = drive.pendingConsentCapabilityCode
            guard Ubiquitty.Capability(rawValue: code) != nil else {
                drive.declineConsent(token)
                return
            }
            if isClientHeld {
                // This device asks of its own policy about an effect its
                // remote host delivered; the answer stays here.
                let device = std.string(UIDevice.current.model)
                question = String(Ubiquitty.Security.hostEffectConsentTitle(code))
                ownDeviceDetail = String(Ubiquitty.Security.hostEffectConsentDetail(code, device))
            } else if drive.pendingConsentIsOwnRequest {
                // This device's own program asks: name the device, which
                // has no verified process and claims no agent name.
                let device = std.string(UIDevice.current.model)
                let origin = drive.pendingConsentCapabilityOrigin
                question = String(Ubiquitty.Security.ownDeviceCapabilityConsentTitle(code, origin, device))
                ownDeviceDetail = String(Ubiquitty.Security.ownDeviceCapabilityConsentDetail(code, origin, device))
            } else {
                question = String(Ubiquitty.Security.capabilityConsentTitle(code))
            }
        case .changeStructure:
            return
        }
        consentRequest = TerminalConsentRequest(
            id: requestIdentity,
            question: question,
            host: dialledHost,
            sessionLabel: surface.remoteSessionID == 0 ? "Unknown" : String(surface.remoteSessionID),
            actor: drive.pendingConsentPeerProcess,
            claimedLabel: drive.pendingConsentAgentLabel,
            ownDeviceDetail: ownDeviceDetail,
            isCapabilityGrant: action == .grantCapability,
            allowsPersistentGrant: action != .terminate && !drive.pendingConsentGrantIsPerUse,
            isClientHeld: isClientHeld,
            surface: surface,
            structurePrompt: nil
        )
    }

    /// Answers only the request represented by the presented sheet.
    func answerConsent(_ request: TerminalConsentRequest, decision: ConsentDecision) {
        guard consentRequest?.id == request.id, consentRequest?.surface === request.surface else { return }
        consentRequest = nil
        request.answer(decision)
        presentWaitingConsent()
    }

    /// Pastes text using the terminal's bracketed-paste mode.
    func pasteText(_ text: String) {
        surface?.pasteAsUserInput(text)
    }

    /// Whether a clipboard gesture can send text or a requested MIME notification.
    var canPasteClipboard: Bool {
        UIPasteboard.general.hasStrings
            || (surface?.drive.readSnapshot().modes.shouldReportPasteEvents == true && !UIPasteboard.general.types.isEmpty)
    }

    /// Offers clipboard formats to a paste-event client before reading text.
    func requestClipboardPaste() {
        var names: [String] = []
        for identifier in UIPasteboard.general.types {
            guard let type = UTType(identifier),
                let mime = type.conforms(to: .plainText) ? "text/plain" : type.preferredMIMEType,
                !names.contains(mime)
            else { continue }
            names.append(mime)
        }
        if surface?.sendPasteNotification(names.joined(separator: " ")) == true { return }
        if let text = UIPasteboard.general.string { requestPaste(text) }
    }

    /// Requests a user paste without bypassing the multiline confirmation policy.
    func requestPaste(_ text: String) {
        if let onPasteRequested {
            onPasteRequested(text)
        } else if !requiresPasteConfirmation(text) {
            pasteText(text)
        }
    }

    /// Applies the shared configuration's multiline-paste confirmation rule.
    func requiresPasteConfirmation(_ text: String) -> Bool {
        let configuration = Ubiquitty.Preferences.values().pointee
        guard Ubiquitty.Preferences.Effective.confirmMultilinePaste(configuration) else { return false }
        let lines = text.withCString { Ubiquitty.Input.pasteLineCount(std.string_view($0)) }
        return lines > Ubiquitty.Preferences.Effective.confirmMultilinePasteThreshold(configuration)
    }

    /// Copies the current selection through the system clipboard.
    func copySelection() { if let text = surface?.selectedText { UIPasteboard.general.string = text } }

    /// Selects the terminal's retained text.
    func selectAll() { surface?.selectAll(nil) }

    /// Sends a selected document through the host's bounded file channel.
    func uploadFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let limit = Int(Ubiquitty.Runtime.TerminalSession.pastePushByteLimit())
            guard size > 0 && size <= limit else {
                fileMessage =
                    "Choose a nonempty file smaller than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
                return
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= limit, let surface,
                surface.pushPaste(mime: "application/octet-stream", bytes: Array(data)) != 0
            else {
                fileMessage = "The host could not accept this file."
                return
            }
            fileMessage = "Sending \(url.lastPathComponent)…"
        } catch { fileMessage = error.localizedDescription }
    }

    /// Requests a file within the host session's permitted directory.
    func downloadFile(_ path: String) {
        requestedFileSurface = surface.map(ObjectIdentifier.init)
        requestedFileID = surface?.drive.requestRemoteFile(path) ?? 0
        fileMessage = requestedFileID == 0 ? "The host could not request this file." : "Receiving file…"
    }

    nonisolated func terminalSurfaceDidReceiveHostFile(_ surface: TerminalSurface) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let surface = observedSurface(identity) else { return }
            while let file = surface.drive.takeRemoteFile() {
                guard file.requestID == requestedFileID, requestedFileSurface == identity else { continue }
                requestedFileID = 0
                guard file.isRead else {
                    fileMessage = "The host could not read this file. Check its path and permissions."
                    fileTransferOutcome.record(succeeded: false)
                    continue
                }
                receivedFileName = URL(fileURLWithPath: file.requestedPath).lastPathComponent
                receivedFile = TerminalFileDocument(data: Data(file.bytes))
                fileMessage = "Ready to save \(receivedFileName)."
                fileTransferOutcome.record(succeeded: true)
            }
        }
    }
}

/// Keeps the answer to typing in doubt attached to the pane it was typed
/// into, with Core's words for it.
struct TerminalInputInDoubt: Equatable {
    let surface: ObjectIdentifier
    let notice: RuntimeDrive.InputInDoubtNotice
}

/// Keeps a sheet's answer attached to the pane where the link was clicked.
struct TerminalFileDownloadRequest: Identifiable {
    let id = UUID()
    let surface: TerminalSurface
    let prompt: RuntimeDrive.FileDownloadPrompt
}

extension TerminalSessionModel {
    nonisolated func terminalSurface(_ surface: TerminalSurface, didSettlePastePushWithStatus status: UInt32) {
        let identity = ObjectIdentifier(surface)
        MainActor.assumeIsolated {
            guard let surface = observedSurface(identity) else { return }
            fileMessage = status == 0 ? "Saved on host: \(surface.lastPastePushPath)" : "The host refused the file transfer (\(status))."
            fileTransferOutcome.record(succeeded: status == 0)
        }
    }
}

extension UIColor {
    /// A Core-derived ground as an opaque colour.
    ///
    /// - Parameter tint: The tint Core folded.
    convenience init(ground tint: Ubiquitty.Runtime.ChromeTint) {
        self.init(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue), alpha: 1)
    }
}

extension TerminalSessionModel: HostOutlineSource {
    /// Core's rows over the tree the listed host answered with.
    ///
    /// - Parameter reader: The reader's closed rows and search.
    /// - Returns: The rows; none before an answer.
    func outline(for reader: HostOutlineReader) -> HostOutline {
        guard let drive = ownedSurface?.drive else { return HostOutline.none }
        var contextual = reader
        contextual.namedHost = drive.remoteHostName
        contextual.showsProgramStatusSeparately = true
        return drive.hostOutline(contextual)
    }

    /// Core's word for how current the tree is: a listing's, or one a
    /// watch follows or has lost.
    var freshness: HostOutlineFreshness { hostTreeFreshness }

    /// A listing has no watch to lose.
    var watchError: String { "" }
}
