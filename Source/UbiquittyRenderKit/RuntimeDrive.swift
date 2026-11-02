// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RuntimeDrive.swift — the terminal session, driven from Swift with no
// Objective-C between.
//
// Direct C++ interop makes every crossing a plain call: the bytes cross as a
// Span over the caller's storage, the dimensions are a POD copy, and there is
// nothing to message — no NSData per chunk, no @objc value snapshot per read,
// no objc_msgSend per delegate callback. Two rules hold by discipline rather
// than code: the model is written from one thread, and reads bracket with the
// writer's lock.

import Dispatch
import Foundation
import UbiquittyCore

/// An immutable font application request, paired with its opaque Core receipt.
public struct RuntimeFontRequest: ~Copyable {
    fileprivate let receipt: Ubiquitty.OSC.FontRequestReceipt
    public let isResolved: Bool
    public let family: String
    public let sizePoints: Double
}

/// The human's answer to a permission question.
///
/// At file scope rather than inside ``RuntimeDrive``, because the questions
/// wearing these answers are not all the drive's: a program asking to read the
/// clipboard and an install asking to copy a binary to a remote host collect
/// the same four, and one of them naming a drive to say "deny" would be an
/// accident of where the first case was written.
///
/// The values are `Protocol::Sync::ConsentDecision`'s own, which is what lets
/// the wire, an Objective-C dialog's mapping and this enum cast between each other
/// rather than switch.
public enum ConsentDecision: UInt8, Sendable {
    /// Refuse. The default everywhere, and what a timeout produces.
    case deny = 0
    /// Allow this one request.
    case allowOnce = 1
    /// Allow for as long as this session lives.
    case allowSession = 2
    /// Allow from now on, keyed to the peer executable the daemon
    /// verified — never to the label the agent chose for itself.
    case allowAlways = 3
}

/// The session's coalesced notifications, as a set of Core's own event kinds.
///
/// The flag surface is `1 << EventKind`, and this reads that word through the
/// enum rather than through a second declaration of the same layout: a kind
/// added to Core arrives here with no edit, and one inserted in the middle
/// cannot silently re-point a case at a different event. The spellings are the
/// enum's own, carried across by `UBIQUITTY_SWIFT_NAME`.
public struct RuntimeEvents: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The set holding exactly `kind`.
    ///
    /// - Parameter kind: The Core event kind this bit stands for.
    public init(_ kind: Ubiquitty.Runtime.EventKind) {
        self.rawValue = 1 << UInt32(kind.rawValue)
    }

    /// Whether `kind` is in the set.
    ///
    /// - Parameter kind: The kind to look for.
    /// - Returns: Whether the session raised it.
    public func contains(_ kind: Ubiquitty.Runtime.EventKind) -> Bool {
        contains(RuntimeEvents(kind))
    }

    /// The model changed; a repaint should be scheduled.
    public static let screenDirty = RuntimeEvents(.screenDirty)
    /// The find search published results, progress, or a new active hit.
    public static let searchChanged = RuntimeEvents(.searchChanged)
    /// The child process exited or the stream reached its end.
    public static let exited = RuntimeEvents(.exited)
    /// BEL arrived; the style rides ``RuntimeDrive/lastBellStyle``.
    public static let bell = RuntimeEvents(.bell)
    /// The OSC title or icon changed.
    public static let titleChanged = RuntimeEvents(.titleChanged)
    /// An application asked for a font swap with OSC 50; the request itself is
    /// leased under the model lock through ``RuntimeDrive/beginFontRequest``.
    public static let fontSwapRequested = RuntimeEvents(.fontSwapRequested)
    /// The program's OSC 9;4 progress report moved; the pair rides the
    /// published snapshot rather than this bit.
    public static let progressChanged = RuntimeEvents(.progressChanged)
    /// A file-transfer preamble arrived; the protocol and direction ride
    /// ``RuntimeDrive/detectedFileTransfer``.
    public static let fileTransferDetected = RuntimeEvents(.fileTransferDetected)
    /// A remote host has no `ubiquitty-host` and the user has not approved
    /// installing one there. Ask, then answer with
    /// ``RuntimeDrive/resolveDeployConfirmation(_:)``; nothing is
    /// installed until you do.
    public static let deployConfirmationPending = RuntimeEvents(.deployConfirmationPending)
    /// A pushed paste settled; the status rides ``RuntimeDrive/lastPastePushStatus``.
    public static let pastePushSettled = RuntimeEvents(.pastePushSettled)
    /// A remote connection moved; where it went rides
    /// ``RuntimeDrive/remoteState``, and the reason for a failure rides
    /// ``RuntimeDrive/lastRemoteFailure``.
    public static let remoteStateChanged = RuntimeEvents(.remoteStateChanged)
    /// The attachment phase or its independent stall reasons changed.
    public static let linkStateChanged = RuntimeEvents(.linkStateChanged)
    /// Some of what was typed into a remote pane may not have reached the
    /// host, or the person decided what to do with it; Core's notice rides
    /// ``RuntimeDrive/inputInDoubtNotice``.
    public static let inputInDoubtChanged = RuntimeEvents(.inputInDoubtChanged)
    public static let dragDropPending = RuntimeEvents(.dragDropPending)
    /// The host pinned this connection's session id; it rides
    /// ``RuntimeDrive/remoteSessionID``. Persist it to reattach the same shell
    /// after a restart rather than spawning a fresh one.
    public static let remoteSessionEstablished = RuntimeEvents(.remoteSessionEstablished)
    /// An agent is asking to attach, kill, gain a capability or change this
    /// session. Who is asking rides ``RuntimeDrive/pendingConsentPeerProcess``
    /// and what it wants rides ``RuntimeDrive/pendingConsentAction``; answer
    /// ordinary requests with ``RuntimeDrive/respondToConsent(_:decision:)``.
    /// Structure questions use ``RuntimeDrive/pendingStructureConsent`` and
    /// ``RuntimeDrive/respondToStructureConsent(_:allow:)`` instead. A question
    /// this frontend cannot show the person is declined, never answered, with
    /// ``RuntimeDrive/declineConsent(_:)`` or
    /// ``RuntimeDrive/declineStructureConsent(_:)``. A retired
    /// question also raises this event, so dismiss any presentation whose
    /// token no longer stands. The daemon denies unanswered requests.
    public static let consentRequestPending = RuntimeEvents(.consentRequestPending)
    /// Who is attached to this session changed. Read the roster through
    /// ``RuntimeDrive/attendees``.
    public static let presenceChanged = RuntimeEvents(.presenceChanged)
    /// The reported working directory changed (OSC 7, OSC 633 Cwd, OSC 1337
    /// CurrentDir). Read it through ``RuntimeDrive/currentDirectory()``.
    public static let directoryChanged = RuntimeEvents(.directoryChanged)
    /// A host answered what sessions it holds. Read them through
    /// ``RuntimeDrive/hostOutline(_:)``.
    public static let hostSessionListChanged = RuntimeEvents(.hostSessionListChanged)
    /// A host session asked to terminate settled; how it settled rides
    /// ``RuntimeDrive/lastHostSessionTerminateOutcome``. A refused or denied
    /// terminate is not a session that went away.
    public static let hostSessionTerminateSettled = RuntimeEvents(.hostSessionTerminateSettled)
    /// A change asked of the host's structure ended; how rides
    /// ``RuntimeDrive/lastHostStructureResult``.
    public static let hostStructureSettled = RuntimeEvents(.hostStructureSettled)
    public static let workspaceChanged = RuntimeEvents(.workspaceChanged)
    /// The push of `ubiquitty-host` to a remote host failed; what it printed
    /// rides ``RuntimeDrive/lastDeployFailure``.
    public static let deployFailed = RuntimeEvents(.deployFailed)
    /// A remote host needs `ubiquitty-host` and no automatic install can
    /// supply one; the steps ride ``RuntimeDrive/manualHostInstallCommands``
    /// and the reason rides ``RuntimeDrive/isManualInstallForSetting``.
    public static let deployNeedsManualInstall = RuntimeEvents(.deployNeedsManualInstall)
    /// A host answered a file request; take the answers with
    /// ``RuntimeDrive/takeRemoteFile()`` until it answers nil, because one bit
    /// stands for every answer that arrived in the pass.
    public static let remoteFileArrived = RuntimeEvents(.remoteFileArrived)
    /// The windows this session's program hosts changed, or a hosted pane's
    /// model did: drain ``RuntimeDrive/takeHostedWindowEvent()`` and
    /// ``RuntimeDrive/takeRepaintedHostedPanes()``.
    public static let hostedWindowsChanged = RuntimeEvents(.hostedWindowsChanged)
}

/// Owns one terminal session and feeds it from Swift.
public final class RuntimeDrive {
    private let session: Ubiquitty.Runtime.TerminalSession

    /// The live session identity used to locate its frontend presentation.
    package var sessionIdentity: UInt { session.identityAddress() }

    /// Watches this session's host stream for a file-transfer preamble.
    ///
    /// A remote `sz file` opens with a ZMODEM handshake, and a terminal that
    /// does not notice paints the binary frames instead of receiving the file.
    /// The watch is Core's — the bytes reach it before the parser, on whichever
    /// path drained them — so this only asks for it.
    ///
    /// A hit raises ``RuntimeEvents/fileTransferDetected`` and disarms, so a
    /// continuing preamble cannot fire again while the transfer is set up. Call
    /// again to resume afterwards; that also forgets a partial match.
    public func armFileTransferWatch() {
        session.armFileTransferWatch()
    }

    /// Stops the watch until it is armed again.
    public func disarmFileTransferWatch() {
        session.disarmFileTransferWatch()
    }

    /// The detection the last ``RuntimeEvents/fileTransferDetected`` announced.
    ///
    /// - Returns: What fired — protocol and direction — or a falsy detection
    ///   when nothing has since the watch was last armed.
    public func detectedFileTransfer() -> Ubiquitty.Network.Transfer.Detection {
        session.detectedFileTransfer()
    }

    /// Lifts the ingest hold a detected preamble set, without re-arming.
    ///
    /// ``armFileTransferWatch()`` lifts it too; this is for a caller that
    /// resumes the stream while leaving the watch off.
    public func releaseFileTransferHold() {
        session.releaseFileTransferHold()
    }

    /// The session's stream descriptor, or a negative value without one.
    ///
    /// A transfer agent runs against the PTY master directly: its standard
    /// streams are the terminal's data stream for the length of the transfer,
    /// while ingest is stopped around it.
    public func fileDescriptor() -> Int32 {
        session.fileDescriptor()
    }

    /// Whether the watch would judge the next bytes to arrive.
    public var isFileTransferWatchArmed: Bool {
        session.isFileTransferWatchArmed()
    }

    /// Called after each drain pass that raised events — once per pass, never
    /// once per chunk, which is the bridge's delegate discipline kept as a
    /// closure. Fires on the ingest thread; the owner hops to the main thread
    /// itself, because a hop here would serialize every pass behind the main
    /// run loop.
    var onEvents: ((RuntimeEvents) -> Void)?

    /// Whether the last drain pass completed a synchronized frame.
    ///
    /// Consumed by reading; the drive's owner samples it when deciding to
    /// present.
    public func takeSyncFrameReady() -> Bool {
        session.takeSyncFrameReady()
    }

    /// The style byte of the most recent bell.
    public var lastBellStyle: UInt32 { session.lastBellStyle() }

    /// Everything the most recent bell asked for: the cue, and the two DECSET
    /// escalations and the notification gate Core resolved with it.
    public var lastBellCue: Ubiquitty.BellCue { session.lastBellCue() }

    /// The status of the most recent settled push, meaningful when
    /// ``RuntimeEvents/pastePushSettled`` was delivered.
    public var lastPastePushStatus: UInt32 { session.lastPastePushStatus() }

    /// Where a remote connection is: connecting, connected, dropped, or gone.
    ///
    /// `.Idle` for a session that is not remote at all, so a caller need not
    /// ask ``isRemoteAttached`` first.
    public var remoteState: Ubiquitty.Session.State { session.remoteState() }

    /// Core's status for a silent or stalled attachment; empty when healthy.
    public var paneLinkIndicatorText: String { String(session.paneLinkIndicatorText()) }

    /// What a remote pane says while some of what was typed into it may not
    /// have reached the host, in Core's words, which are the same on every
    /// frontend.
    public struct InputInDoubtNotice: Equatable, Sendable {
        /// The status line: what happened.
        public let message: String
        /// The sentence beneath it: why the choice is the person's.
        public let detail: String
        /// The title of the choice that sends the input again.
        public let resendButton: String
        /// The title of the choice that drops it.
        public let discardButton: String

        public init(message: String, detail: String, resendButton: String, discardButton: String) {
            self.message = message
            self.detail = detail
            self.resendButton = resendButton
            self.discardButton = discardButton
        }
    }

    /// The notice a remote pane shows while its input awaits the person's
    /// decision, or nil while none is awaited. Read beside
    /// ``RuntimeEvents/inputInDoubtChanged``. What the person types waits
    /// behind the input in doubt until they choose, so a frontend shows this
    /// beside the pane without blocking it.
    public var inputInDoubtNotice: InputInDoubtNotice? {
        let notice = session.remoteInputInDoubtNotice()
        let message = String(notice.message)
        guard !message.isEmpty else { return nil }
        return InputInDoubtNotice(
            message: message,
            detail: String(notice.detail),
            resendButton: String(notice.resendButton),
            discardButton: String(notice.discardButton)
        )
    }

    /// Sends the pane's input in doubt again, ahead of what waited behind it.
    /// Called only at the person's word: sending again can run a command
    /// twice.
    public func resendInputInDoubt() { session.resendRemoteInputInDoubt() }

    /// Drops the pane's input in doubt and lets what waited behind it go.
    public func discardInputInDoubt() { session.discardRemoteInputInDoubt() }

    /// Reports the transport selected by the remote Core.
    public var isRemoteUsingQUIC: Bool { session.isRemoteUsingQUIC() }

    /// The physical carrier Core currently owns, including no carrier yet.
    public func remoteCarrierFact() -> Ubiquitty.Session.CarrierFact { session.remoteCarrierFact() }

    /// The Sync Debug report for this session's remote connection: traffic,
    /// protocol and timing, gathered by Core so every frontend shows the same
    /// numbers. An empty report, in state `.Idle`, for a session that is not
    /// remote.
    public func syncTraceReport() -> Ubiquitty.Session.SyncTraceReport { session.remoteSyncTraceReport() }

    /// Clears the remote connection's trace so the Sync Debug window counts
    /// from now.
    public func resetSyncTrace() { session.resetRemoteSyncTrace() }

    /// Why the connection failed, in the host's own words.
    ///
    /// Empty unless ``remoteState`` is `.Failed`. Read beside
    /// ``RuntimeEvents/remoteStateChanged`` — a reason is a string and an
    /// event carries scalars.
    public var lastRemoteFailure: String { String(session.lastRemoteFailure()) }

    /// Why the connection last changed state, in Core's words, for a log.
    public var lastRemoteTransitionDetail: String { String(session.lastRemoteTransitionDetail()) }

    /// Whether the connection failed because the host would not hand back the session it was
    /// asked to reattach.
    ///
    /// The two `.Failed` states a frontend words differently: a host that died is one to retry,
    /// and a session the host will not give back is one to replace — by listing what it does hold,
    /// or by attaching fresh. ``lastRemoteFailure`` says it in words; this is the same fact as a
    /// flag, so a frontend branches on it rather than parsing a sentence. Cleared by any state
    /// that is not `.Failed`, as the reason is.
    public var wasReattachRefused: Bool { session.wasReattachRefused() }

    /// Which session the host would not hand back, or 0 when none was refused.
    public var refusedReattachSessionID: UInt32 { session.refusedReattachSessionID() }

    /// The last refusal the host answered this connection with, nil when it
    /// refused nothing: the reason, which end of a version refusal is older,
    /// and the platform the host named.
    public var lastHostRefusal: Ubiquitty.Session.HostRefusal? {
        let refusal = session.lastHostRefusal()
        return refusal.hasRefusal ? refusal : nil
    }

    /// Makes the next attach install this app's host before it dials.
    ///
    /// Called before the attach. The connection installs first, through the
    /// session's deploy decision, and dials only a host whose install
    /// succeeded; a failed install leaves it Failed with nothing run there.
    ///
    /// - Parameter platform: The host's `uname -sm`, empty when unknown.
    public func requestHostUpdateBeforeAttach(platform: String) {
        session.requestHostUpdateBeforeAttach(std.string(platform))
    }

    /// Sets the access token the next attach and every reconnect present.
    ///
    /// - Parameter token: The token, empty for none.
    public func setRemoteAuthToken(_ token: String) {
        session.setRemoteAuthToken(std.string(token))
    }

    /// The daemon session id this connection holds, or 0 before the host pins
    /// one. Persist it to reattach the same shell after a restart.
    public var remoteSessionID: UInt32 { session.remoteSessionID() }

    /// The daemon socket the session lives on, empty before the host names it.
    /// Persisted beside ``remoteSessionID`` so a restore reaches that daemon.
    package var remoteSocketName: String { String(session.remoteSocketName()) }

    // MARK: - The host's workspace, mirrored

    /// The host's id for the workspace this session belongs to; 0 before the first layout.
    public var remoteWorkspaceID: UInt32 { session.remoteWorkspaceID() }

    /// Identifies the daemon process that owns the session.
    public var remoteDaemonInstanceID: UInt64 { session.remoteDaemonInstanceID() }
    /// The daemon named by an admitted Workspace restore, or zero otherwise.
    public var remoteRestoredFromDaemonInstanceID: UInt64 { session.remoteRestoredFromDaemonInstanceID() }
    /// This session's own pane in the mirror, or `invalidPane` before the first layout.
    public var remoteWorkspacePane: Ubiquitty.Session.Layout.PaneID { session.remoteWorkspacePane() }
    /// The mirror's surface holding this session's pane.
    public var remoteWorkspaceSurface: Ubiquitty.Session.Layout.SurfaceID { session.remoteWorkspaceSurface() }
    /// The mirror's tab holding this session's pane.
    public var remoteWorkspaceTab: Ubiquitty.Session.Layout.TabID { session.remoteWorkspaceTab() }
    /// How many surfaces the mirror holds.
    public var remoteWorkspaceSurfaceCount: Int { Int(session.remoteWorkspaceSurfaceCount()) }
    /// The mirror's active surface.
    public var remoteWorkspaceActiveSurface: Ubiquitty.Session.Layout.SurfaceID { session.remoteWorkspaceActiveSurface() }
    /// The surface at `index` of the mirror, in creation order.
    public func remoteWorkspaceSurface(at index: Int) -> Ubiquitty.Session.Layout.SurfaceID {
        session.remoteWorkspaceSurfaceAt(index)
    }
    /// How many tabs a surface of the mirror holds.
    public func remoteWorkspaceTabCount(of surface: Ubiquitty.Session.Layout.SurfaceID) -> Int {
        Int(session.remoteWorkspaceTabCount(surface))
    }
    /// The tab at `index` of a surface of the mirror.
    public func remoteWorkspaceTab(of surface: Ubiquitty.Session.Layout.SurfaceID, at index: Int) -> Ubiquitty.Session.Layout.TabID {
        session.remoteWorkspaceTabAt(surface, index)
    }

    /// Returns the authoritative workspace name, empty for an unnamed workspace.
    public var remoteWorkspaceName: String { String(session.remoteWorkspaceName()) }

    /// Returns whether the host recreated the workspace after it restarted, so
    /// every pane's shell is fresh and its earlier screen gone.
    public var isRemoteWorkspaceRestoredAfterHostRestart: Bool { session.isRemoteWorkspaceRestoredAfterHostRestart() }

    /// Returns the authoritative custom tab title, empty for automatic naming.
    public func remoteWorkspaceTabTitle(of surface: Ubiquitty.Session.Layout.SurfaceID, tab: Ubiquitty.Session.Layout.TabID) -> String {
        String(session.remoteWorkspaceTabTitle(surface, tab))
    }

    /// Returns the authoritative custom title of a tab wherever the host holds
    /// it, empty for automatic naming or a tab the host does not hold.
    public func remoteWorkspaceTabTitle(of tab: Ubiquitty.Session.Layout.TabID) -> String {
        String(session.remoteWorkspaceCustomTabTitle(tab))
    }

    /// Sends a tab rename request; the mirror changes only after host confirmation.
    public func remoteWorkspaceRenameTab(_ tab: Ubiquitty.Session.Layout.TabID, title: String) -> Bool {
        session.remoteWorkspaceRenameTab(tab, std.string(title))
    }

    /// Sends a workspace rename request; the mirror changes only after host confirmation.
    public func remoteWorkspaceRename(_ name: String) -> Bool {
        session.remoteWorkspaceRename(std.string(name))
    }
    /// The active tab of a surface of the mirror.
    public func remoteWorkspaceActiveTab(of surface: Ubiquitty.Session.Layout.SurfaceID) -> Ubiquitty.Session.Layout.TabID {
        session.remoteWorkspaceActiveTab(surface)
    }
    /// The tab a surface of the mirror shows in front: the one asked for here
    /// while the host has yet to answer, else the host's active tab.
    public func remoteWorkspaceFrontTab(of surface: Ubiquitty.Session.Layout.SurfaceID) -> Ubiquitty.Session.Layout.TabID {
        session.remoteWorkspaceFrontTab(surface)
    }
    /// The pane zoomed on a surface of the mirror, or `invalidPane`.
    public func remoteWorkspaceZoomedPane(of surface: Ubiquitty.Session.Layout.SurfaceID) -> Ubiquitty.Session.Layout.PaneID {
        session.remoteWorkspaceZoomedPane(surface)
    }
    /// The pane tree of one tab of the mirror, copied.
    public func remoteWorkspacePaneTreeSnapshot(
        of surface: Ubiquitty.Session.Layout.SurfaceID,
        tab: Ubiquitty.Session.Layout.TabID
    ) -> Ubiquitty.Panes.Tree {
        session.remoteWorkspacePaneTreeSnapshot(surface, tab)
    }
    /// The host session drawing into a pane of the mirror, or 0.
    public func remoteWorkspaceSession(for pane: Ubiquitty.Session.Layout.PaneID) -> UInt32 {
        session.remoteWorkspaceSessionForPane(pane)
    }
    /// Asks the host to add a tab to this session's surface; the answer is a layout.
    public func remoteWorkspaceAddTab() -> Bool { session.remoteWorkspaceAddTab() }

    /// Consumes the host's settled reply to the latest window/tab creation, split, or pane close.
    public func takeRemoteWorkspacePaneChange() -> Ubiquitty.Runtime.TerminalSession.RemoteWorkspacePaneChange {
        session.takeRemoteWorkspacePaneChange()
    }

    /// Requests another native window in the same hosted workspace.
    ///
    /// - Returns: Whether the host accepted the request for delivery.
    public func remoteWorkspaceAddSurface() -> Bool { session.remoteWorkspaceAddSurface() }
    /// Reports that a person brought this session's tab to the front, which
    /// asks the host to make it its window's active tab.
    ///
    /// - Returns: Whether an ask went out; false when the tab is already in
    ///   front or asked for.
    @discardableResult
    public func remoteWorkspaceBringTabToFront() -> Bool { session.remoteWorkspaceBringTabToFront() }
    /// Asks the host to close a tab of this session's surface.
    public func remoteWorkspaceCloseTab(_ tab: Ubiquitty.Session.Layout.TabID) -> Bool { session.remoteWorkspaceCloseTab(tab) }

    /// One host window's captured close question, invalidated by reconnect or a changed tree.
    public struct RemoteWindowClosePrompt {
        public let token: UInt64
        public let sessionCount: UInt32
    }

    /// Captures the current host window without sending a destructive request.
    public func prepareRemoteWindowClose() -> RemoteWindowClosePrompt? {
        let token = session.prepareRemoteWindowClose()
        guard token != 0 else { return nil }
        return RemoteWindowClosePrompt(token: token, sessionCount: session.pendingRemoteWindowCloseSessionCount())
    }

    /// Zero once the captured host window or its attachment has changed.
    public var pendingRemoteWindowCloseToken: UInt64 { session.pendingRemoteWindowCloseToken() }

    /// Consumes the question once; only an approved current question sends CloseSurface.
    @discardableResult
    public func answerRemoteWindowClose(_ token: UInt64, closeWindow: Bool) -> Bool {
        session.answerRemoteWindowClose(token, closeWindow ? .CloseWindow : .Cancel)
    }
    /// Returns the current host close answer without consuming its event.
    public var remoteWorkspaceCloseOutcome: Ubiquitty.Runtime.TerminalSession.RemoteWorkspaceCloseOutcome {
        session.remoteWorkspaceCloseOutcome()
    }

    /// Consumes a settled host close answer without consuming a pending request.
    public func takeRemoteWorkspaceCloseOutcome() -> Ubiquitty.Runtime.TerminalSession.RemoteWorkspaceCloseOutcome {
        session.takeRemoteWorkspaceCloseOutcome()
    }
    /// Asks the host to move focus one pane over in this session's tab.
    public func remoteWorkspaceMoveFocus(_ direction: Ubiquitty.Panes.Direction) -> Bool { session.remoteWorkspaceMoveFocus(direction) }
    /// Asks the host to set a divider of this session's tab.
    public func remoteWorkspaceSetDividerRatio(splitIndex: Int32, ratio: Float) -> Bool {
        session.remoteWorkspaceSetDividerRatio(splitIndex, ratio)
    }

    /// The current remote topology generation, or zero without a current mirror.
    public var remoteWorkspaceMirrorGeneration: UInt64 { session.remoteWorkspaceMirrorGeneration() }

    /// Takes Core's pairing of the windows, tabs and panes this workspace's
    /// mirror held with the ones its host restored in their places, under
    /// ids of its own, after the daemon that served them stopped.
    ///
    /// Shared by every pane of the workspace and gone once taken: whatever
    /// keeps views by the mirror's ids takes it, moves its keys once, and
    /// lets go of every key a pair does not name, which is the stopped host's.
    ///
    /// - Returns: The pairs, possibly none; `nil` when nothing was restored
    ///   since the last take.
    public func takeRemoteWorkspaceRestoredPanes() -> [Ubiquitty.Session.Layout.RestoredPane]? {
        let restoration = session.takeRemoteWorkspaceRestoration()
        return restoration.isRestored ? Array(restoration.panes) : nil
    }

    /// What an agent wants: attach, terminate, a capability, or one tree change.
    ///
    /// A separate reading from "an agent is asking" because approving a kill
    /// as though it were an attach defeats the gate — the prompt has to say
    /// which.
    public enum ConsentAction: UInt8 {
        /// Attach to the session and observe or drive it.
        case attach = 0
        /// Close the session.
        case terminate = 1
        /// Gain the capability named by ``RuntimeDrive/pendingConsentCapabilityCode``.
        case grantCapability = 2
        /// Make the exact tree change described by ``RuntimeDrive/pendingStructureConsent``.
        case changeStructure = 3
    }

    /// Core's words and local identity for one tree-change question.
    /// The token belongs to this drive and cannot authorize a later question.
    public struct StructureConsentPrompt: Sendable {
        public let token: UInt64
        public let question: String
        public let detail: String
        public let allowTitle: String
        public let denyTitle: String

        package init(token: UInt64, question: String, detail: String, allowTitle: String, denyTitle: String) {
            self.token = token
            self.question = question
            self.detail = detail
            self.allowTitle = allowTitle
            self.denyTitle = denyTitle
        }
    }

    /// Captures the displayed structure question before a native sheet is shown.
    public var pendingStructureConsent: StructureConsentPrompt? {
        let token = session.pendingStructureConsentToken()
        guard token != 0 else { return nil }
        return StructureConsentPrompt(
            token: token,
            question: String(session.pendingStructureConsentQuestion()),
            detail: String(session.pendingStructureConsentDetail()),
            allowTitle: String(session.pendingStructureConsentAllowTitle()),
            denyTitle: String(session.pendingStructureConsentDenyTitle())
        )
    }

    /// Answers only the structure question identified before presentation.
    public func respondToStructureConsent(_ token: UInt64, allow: Bool) {
        session.respondToStructureConsent(token, allow)
    }

    /// Declines the structure question this frontend could not show the
    /// person. It is not an answer: the question stays with the others it was
    /// asked of.
    ///
    /// - Parameter token: The exact local token the question was read with.
    public func declineStructureConsent(_ token: UInt64) {
        session.declineStructureConsent(token)
    }

    #if UBIQUITTY_UI_TESTS || UBIQUITTY_IOS_UI_TESTS
    /// Feeds a question through Core's queue and the ordinary native event drain.
    // swift-only: a UI-test seam the Swift scenarios call, which the generated C++ header drops and no C++ consumer needs
    package func noteStructureConsentForTesting(_ request: Ubiquitty.`Protocol`.Sync.StructureConsent) {
        session.noteStructureConsentForTest(request)
    }

    /// Feeds host retirement through the same observer path as a live host.
    package func noteStructureConsentResolvedForTesting(_ requestID: UInt32) {
        session.noteStructureConsentResolvedForTest(requestID)
    }
    #endif

    /// The consent question waiting on the human, or 0 when there is none.
    public var pendingConsentRequestID: UInt32 { session.pendingConsentRequestID() }

    /// A non-reused local identity for the ordinary question currently shown.
    public var pendingConsentToken: UInt64 { session.pendingConsentToken() }

    /// What the pending request is asking for.
    ///
    /// An action this build does not know reads as ``ConsentAction/attach``
    /// only if it is one; an unknown value answers nil, and a prompt that
    /// cannot say what it is asking must not ask.
    public var pendingConsentAction: ConsentAction? { ConsentAction(rawValue: session.pendingConsentAction()) }

    /// The capability an ``ConsentAction/grantCapability`` request wants, as
    /// the raw enum value. 0 for the other actions.
    public var pendingConsentCapabilityCode: UInt16 { session.pendingConsentCapabilityCode() }

    /// What an application asked the window to do.
    ///
    /// Core's record, read into Swift's own so the rest of the arm names no C++
    /// type. `kind` says which verb, and therefore how to read the rest.
    public struct WindowRequest: Sendable {
        /// Which verb the application used.
        public enum Kind: UInt8, Sendable {
            /// CSI t. ``operation`` is the op; ``first`` and ``second`` its
            /// arguments.
            case windowOp = 1
            /// DECCOLM. ``first`` is non-zero for 132 columns.
            case columnMode = 2
            /// OSC 1337 StealFocus.
            case stealFocus = 3
            /// An attention request; ``first`` is its style.
            case attention = 4
            /// OSC 1337 SetColors=preset. ``text`` names the theme.
            case colorPreset = 5
        }
        /// Which verb.
        public let kind: Kind
        /// The operation for a CSI t, the flag or style otherwise.
        public let first: Int
        /// The operation's first argument.
        public let second: Int
        /// The operation's second argument.
        public let third: Int
        /// The theme name for a colour preset; empty otherwise.
        public let text: String
    }

    /// The oldest window request an application made, removed from the queue.
    ///
    /// Drain until this answers nil. Nil is also the answer before
    /// ``installWindowRequestQueue`` has been called, which is what a frontend
    /// that answers the parser through its own client wants.
    ///
    /// - Returns: The request, or nil when the queue is empty.
    public func takeWindowRequest() -> WindowRequest? {
        let taken = session.takeWindowRequest()
        guard let kind = WindowRequest.Kind(rawValue: taken.kind.rawValue) else {
            return nil
        }
        return WindowRequest(
            kind: kind,
            first: Int(taken.first),
            second: Int(taken.second),
            third: Int(taken.third),
            text: String(taken.text)
        )
    }

    /// Asks Core to queue the window verbs this frontend will answer off the
    /// drain rather than inline.
    ///
    /// - Returns: Whether the queue is the terminal's window client.
    @discardableResult
    public func installWindowRequestQueue() -> Bool { session.installWindowRequestQueue() }

    public struct DragCommand {
        public let kind: Ubiquitty.DragDrop.CommandKind
        public let sessionID: UInt64
        public let requestID: UInt64
        public let type: CChar
        public let x: Int64
        public let y: Int64
        public let pixelX: Int64
        public let pixelY: Int64
        public let operation: UInt32
        public let data: Data
        public let isFinal: Bool
    }

    public func takeDragDropCommand() -> DragCommand? {
        let command = session.takeDragDropCommand()
        guard command.isPresent else { return nil }
        return DragCommand(
            kind: command.kind,
            sessionID: command.sessionID,
            requestID: command.requestID,
            type: command.type(),
            x: command.x(),
            y: command.y(),
            pixelX: command.pixelX(),
            pixelY: command.pixelY(),
            operation: command.operation(),
            data: Data((0..<command.payloadSize()).map { command.payloadByte($0) }),
            isFinal: command.isFinal
        )
    }

    public func nextNativeDragSession() -> UInt64 { session.nextNativeDragSession() }

    @discardableResult
    // swift-only: a Foundation Data parameter has no C++ thunk, and only the Kit's drag-and-drop sends events through it
    public func sendDragEvent(_ event: Ubiquitty.DragDrop.NativeEvent, data: Data = Data()) -> Bool {
        data.withUnsafeBytes { bytes in
            session.sendNativeDragEvent(event, Ubiquitty.Runtime.ByteSpan(bytes.bindMemory(to: CChar.self)))
        }
    }

    public func cancelDragDrop() { session.cancelDragDrop() }

    /// Whether another native data chunk fits without filling the input queue.
    public var canSendNativeDragData: Bool { session.canSendNativeDragData() }

    /// One desktop notification an application asked for with OSC 9, OSC 99 or
    /// OSC 777;notify.
    ///
    /// Core's record, read into Swift's own so the rest of the arm names no C++
    /// type. The pair is already resolved by Core's display policy: a body-only
    /// dialect has its body promoted into ``title``, so a backend posts these
    /// two verbatim.
    public struct Notification: Sendable {
        /// The banner's heading. Never empty.
        public let title: String
        /// The banner's subtitle, empty for a body-only dialect.
        public let body: String
        /// The program's own name for the notification (OSC 99 `i=`), which a
        /// later one under the same name replaces; empty for none.
        public let identifier: String
        /// When the program wants it shown, as Core's `NotificationOccasion`
        /// raw value (OSC 99 `o=`); zero is always.
        public let occasion: UInt8
    }

    /// The oldest notification an application asked for, removed from the queue.
    ///
    /// Drain until this answers nil, on ``Ubiquitty/Runtime/EventKind/notificationPosted``.
    /// Nil is also the answer where a frontend installed its own `ShellClient`.
    ///
    /// - Returns: The notification, or nil when the queue is empty.
    public func takeNotification() -> Notification? {
        let taken = session.takeNotification()
        guard taken.isPresent else {
            return nil
        }
        return Notification(
            title: String(taken.title),
            body: String(taken.body),
            identifier: String(taken.identifier),
            occasion: taken.occasion.rawValue
        )
    }

    /// One act a matched trigger asks this frontend for.
    ///
    /// Core's resolution, read into Swift's own so the rest of the arm names no
    /// C++ type. The two `[triggers]` gates were applied when it was taken:
    /// a `runCommand` or a `webhook` exists here only because the reader opened
    /// the gate, and the match rides in ``arguments`` as one element and in
    /// ``requestBody`` as a JSON value, never in a shell string or the URL.
    public struct TriggerEffect: Sendable {
        /// What to do. The raw values are Core's `TriggerEffectKind`.
        public enum Kind: UInt8, Sendable {
            /// Raise a banner with ``title`` over ``body``.
            case notify = 1
            /// Put ``text`` on the system clipboard.
            case copy = 2
            /// Name the window ``title``.
            case setTitle = 3
            /// Spawn ``arguments``; element 0 is the program.
            case runCommand = 4
            /// POST ``requestBody`` to ``url``.
            case webhook = 5
        }

        /// What to do.
        public let kind: Kind
        /// A banner's heading, or the window's new name.
        public let title: String
        /// A banner's subtitle, empty for a body-only one.
        public let body: String
        /// What a copy puts on the clipboard.
        public let text: String
        /// Where a webhook posts, already checked to be http or https.
        public let url: String
        /// What a webhook posts: `{"match":"…"}`.
        public let requestBody: String
        /// A spawn's explicit argv.
        public let arguments: [String]
    }

    /// The oldest trigger act waiting, removed from the queue.
    ///
    /// Drain until this answers nil, on ``Ubiquitty/Runtime/EventKind/triggerMatched``.
    /// A report the gates refuse is consumed inside and never surfaces, so nil
    /// means the queue is empty rather than that the head was refused.
    ///
    /// - Parameter configuration: The live values the gates are read from.
    /// - Returns: The act, or nil when none is waiting.
    public func takeTriggerEffect(_ configuration: Ubiquitty.Preferences.Values) -> TriggerEffect? {
        let taken = session.takeTriggerEffect(configuration)
        guard let kind = TriggerEffect.Kind(rawValue: taken.kind.rawValue) else {
            return nil
        }
        let arguments = (0..<taken.argumentCount()).map { String(taken.argumentAt($0)) }
        return TriggerEffect(
            kind: kind,
            title: String(taken.title),
            body: String(taken.body),
            text: String(taken.text),
            url: String(taken.url),
            requestBody: String(taken.requestBody),
            arguments: arguments
        )
    }

    /// Names the terminal as its program's OSC 2 would, for a trigger's
    /// `set_title`. Raises no event: read the title back after this returns.
    ///
    /// - Parameter title: The name the trigger resolved to.
    public func applyTriggerTitle(_ title: String) {
        session.applyTriggerTitle(std.string(title))
    }

    /// Compiles the configuration's `[triggers]` and `[characterClass]` rules
    /// into this session's terminal, replacing the ones it carries.
    ///
    /// - Parameter configuration: The live values the rules are read from.
    /// - Returns: What was refused, in words, or empty when nothing was.
    @discardableResult
    public func applyTriggerConfiguration(_ configuration: Ubiquitty.Preferences.Values) -> String {
        String(session.applyTriggerConfiguration(configuration))
    }

    /// Whether the pending request can be granted for longer than one use.
    ///
    /// False for a capability the daemon force-gates to a single use however
    /// the human answers, so a prompt can decline to offer a lifetime that will
    /// not be honoured. Core's, because the tier that decides it is security's
    /// classification and an unmapped code falls through to the strictest one.
    public var pendingConsentGrantIsPerUse: Bool { session.pendingConsentGrantIsPerUse() }

    /// The peer's process as the daemon verified it — the name a prompt may
    /// trust.
    public var pendingConsentPeerProcess: String { String(session.pendingConsentPeerProcess()) }

    /// What the agent calls itself. Spoofable: an agent chooses this string,
    /// so a prompt may show it and may decide nothing on it.
    public var pendingConsentAgentLabel: String { String(session.pendingConsentAgentLabel()) }

    /// The origin a capability request was checked against, as the raw
    /// `CapabilityOrigin` value; it decides which grant lifetimes are kept.
    public var pendingConsentCapabilityOrigin: UInt8 { session.pendingConsentCapabilityOrigin() }

    /// Gives the session's terminal a clipboard that writes the system
    /// clipboard, for a shell that installs no clipboard client of its own:
    /// a remote program's allowed copy then reaches this device's pasteboard.
    ///
    /// - Returns: Whether the terminal now has a clipboard that reaches it.
    @discardableResult
    public func installSystemClipboardWriter() -> Bool { session.installSystemClipboardWriter() }

    /// Gives the session's terminal the clients the shell registered as the
    /// process default, under its model lock.
    ///
    /// For a shell that builds its surfaces itself, so no workspace model's
    /// installer equips them: it registers its installer once at launch and
    /// asks here for each surface before showing it, and again for a terminal
    /// the surface attaches to later.
    package func installDefaultClients() {
        Ubiquitty.Runtime.WorkspaceSession.installDefaultClients(session)
    }

    /// Whether the pending capability request is this device's own: a
    /// program it drives asks about its clipboard or banners. The prompt then
    /// names the device instead of a verified process and a claimed name.
    public var pendingConsentIsOwnRequest: Bool { session.pendingConsentIsOwnRequest() }

    /// Whether the pending question is this client's own, about an effect a
    /// host on another machine delivered. Its answer stays on this device and
    /// an allow lasts at most as long as the connection, so the prompt offers
    /// no "Always" and names no host deadline.
    public var pendingConsentIsClientHeld: Bool { session.pendingConsentIsClientHeld() }

    /// Answers the consent question.
    ///
    /// - Parameters:
    ///   - token: The exact local ``pendingConsentToken`` captured by the prompt.
    ///   - decision: What the human chose.
    public func respondToConsent(_ token: UInt64, decision: ConsentDecision) {
        session.respondToConsent(token, decision.rawValue)
    }

    /// Declines the consent question this frontend could not show the person,
    /// one it cannot present while another is up or cannot word. It is not an
    /// answer: a host's question stays with the others it was asked of.
    ///
    /// - Parameter token: The exact local ``pendingConsentToken`` it was read with.
    public func declineConsent(_ token: UInt64) {
        session.declineConsent(token)
    }

    /// One client attached to this session.
    ///
    /// A value rather than a live view: the roster is rebuilt whole on every
    /// change, so a row read now describes the moment it was read.
    public struct Attendee: Sendable {
        /// How the daemon authorised an attendee, which decides what a revoke
        /// can take away from it.
        public enum Grant: UInt8, Sendable {
            /// A live attach — allowed once, or the session's own client.
            case once = 0
            /// An allow-session grant, which lasts as long as the session.
            case session = 1
            /// A persisted always-allow grant, which outlives it.
            case always = 2
        }

        /// The stable attachment a disconnect names, in canonical ID128 text.
        public let attachmentID: String
        /// A display-only physical connection number, never a revoke selector.
        public let clientID: UInt32
        /// Whether this is a person rather than an agent.
        public let isHuman: Bool
        /// Whether the attendee is attached over QUIC rather than the local
        /// socket — the difference between a peer on this machine and one on
        /// the network.
        public let isQUIC: Bool
        /// Whether this row is this client — the one to leave out of "someone
        /// else is watching".
        public let isSelf: Bool
        /// How the attendee is authorised: 0 once, 1 for the session, 2 always.
        public let grantScope: UInt8
        /// The verified process path; empty when the daemon could not verify it.
        public let process: String
        /// The separately verified daemon grant key, never the process or label.
        public let grantIdentity: String
        /// What the agent calls itself. Chosen by the agent, so it is shown as
        /// a claim and never used as a key.
        public let label: String

        /// The grant this attendee holds, or nil for a scope this build does
        /// not know — which offers no revoke rather than the wrong one.
        public var grant: Grant? { Grant(rawValue: grantScope) }

        /// Builds one row.
        ///
        /// - Parameters:
        ///   - attachmentID: The stable attachment a disconnect names.
        ///   - clientID: A display-only physical connection number.
        ///   - isHuman: Whether this is a person.
        ///   - isQUIC: Whether the attendee is attached over QUIC.
        ///   - isSelf: Whether this row is this client.
        ///   - grantScope: How the attendee is authorised.
        ///   - process: The verified process path.
        ///   - label: The agent's claimed name.
        public init(
            attachmentID: String,
            clientID: UInt32,
            isHuman: Bool,
            isQUIC: Bool,
            isSelf: Bool,
            grantScope: UInt8,
            process: String,
            grantIdentity: String,
            label: String
        ) {
            self.attachmentID = attachmentID
            self.clientID = clientID
            self.isHuman = isHuman
            self.isQUIC = isQUIC
            self.isSelf = isSelf
            self.grantScope = grantScope
            self.process = process
            self.grantIdentity = grantIdentity
            self.label = label
        }
    }

    /// Everyone attached to this session, in the host's order.
    ///
    /// Read when ``RuntimeEvents/presenceChanged`` drains. Built by index
    /// because a vector of structs holding std::string does not cross the
    /// interop seam usefully; the count is read once and every row is bounded
    /// by it.
    public var attendees: [Attendee] {
        (0..<session.presenceAttendeeCount())
            .map { index in
                Attendee(
                    attachmentID: String(session.presenceAttachmentID(index)),
                    clientID: session.presenceClientID(index),
                    isHuman: session.isPresenceAttendeeHuman(index),
                    isQUIC: session.isPresenceAttendeeQUIC(index),
                    isSelf: session.isPresenceAttendeeSelf(index),
                    grantScope: session.presenceGrantScope(index),
                    process: String(session.presenceProcess(index)),
                    grantIdentity: String(session.presenceGrantIdentity(index)),
                    label: String(session.presenceLabel(index))
                )
            }
    }

    /// A host-observed screen read, without the screen's contents.
    public struct ScreenAccess: Sendable {
        public let cursor: UInt64
        public let unixMilliseconds: UInt64
        public let claimedLabel: String
        public let verifiedProcess: String

        public init(cursor: UInt64, unixMilliseconds: UInt64, claimedLabel: String, verifiedProcess: String) {
            self.cursor = cursor
            self.unixMilliseconds = unixMilliseconds
            self.claimedLabel = claimedLabel
            self.verifiedProcess = verifiedProcess
        }
    }

    /// Recent agent reads survive the reader disconnecting.
    public var screenAccesses: [ScreenAccess] {
        (0..<session.screenAccessCount())
            .map { index in
                ScreenAccess(
                    cursor: session.screenAccessCursor(index),
                    unixMilliseconds: session.screenAccessUnixMilliseconds(index),
                    claimedLabel: String(session.screenAccessLabel(index)),
                    verifiedProcess: String(session.screenAccessProcess(index))
                )
            }
    }

    public var hasUnreadScreenAccess: Bool { session.hasUnreadScreenAccess() }

    /// Reviews the list that opened; later captures remain unread.
    public func acknowledgeScreenAccess(through cursor: UInt64) {
        session.acknowledgeScreenAccessThrough(cursor)
    }

    /// Whether anyone other than this client is attached.
    ///
    /// Core's fold, not this file's: every frontend asks the roster the same
    /// question, and one that answered it privately would be a second reading
    /// of who counts as "someone else".
    public var isSharedWithSomeoneElse: Bool { session.isSharedWithOthers() }

    /// How many clients other than this one are attached.
    ///
    /// Core's count, for a badge that distinguishes one other from a crowd.
    public var otherAttendeeCount: Int { Int(session.otherAttendeeCount()) }

    /// A number that moves whenever the tree ``hostOutline(_:)`` reads is
    /// replaced. Read when ``RuntimeEvents/hostSessionListChanged`` drains.
    public var hostSessionTreeRevision: UInt64 { session.hostSessionTreeRevision() }

    /// The daemon socket retained with the current directory answer.
    public var hostSessionDaemonSocketName: String { String(session.hostSessionDaemonSocketName()) }

    /// The daemon process that supplied the current directory answer.
    public var hostSessionDaemonInstanceID: UInt64 { session.hostSessionDaemonInstanceID() }

    /// The machine named by the admitted host, independent of its saved alias.
    public var remoteHostName: String { String(session.remoteHostName()) }

    /// The rows to draw for what the host last said it holds: its
    /// workspaces, their windows, tabs and panes.
    ///
    /// Core decides the rows; this reads them into values. Empty before a
    /// host answered ``listHostSessions(factory:)`` with a tree.
    ///
    /// - Parameter reader: Who is looking, which rows are closed and what is
    ///   searched for.
    /// - Returns: The rows, in the order they are drawn.
    public func hostOutline(_ reader: HostOutlineReader) -> HostOutline {
        HostOutline(session.hostOutlineRows(reader.request))
    }

    /// Whether the host ``listHostSessions(factory:)`` asked answered with
    /// what it holds. Not having answered is never an empty host.
    public var hasHostAnsweredListing: Bool { session.hasHostAnsweredListing() }

    /// How current the tree ``hostOutline(_:)`` reads is, numbered as Core's
    /// `Runtime::HostDirectoryClient::TreeFreshness`: none, listed, followed
    /// by a connected watch, or left by a watch that lost its host.
    public var hostSessionTreeFreshness: UInt8 { session.hostSessionTreeFreshness().rawValue }

    /// The connect to make to the host this drive listed: Core's rule over
    /// the tree the host answered with and the host's remembered pairing.
    ///
    /// - Parameters:
    ///   - hostKey: The embedder's name for the host.
    ///   - predefinedWorkspaceName: The name the saved host carries, empty
    ///     when it names none.
    ///   - chosenSessionID: The listed session the person selected, 0 for
    ///     none.
    /// - Returns: The connect to make.
    package func decideHostAttach(
        host hostKey: String,
        predefinedWorkspaceName: String,
        chosen chosenSessionID: UInt32 = 0
    ) -> HostDirectory.Decision {
        let decision = session.decideHostAttach(std.string(hostKey), std.string(predefinedWorkspaceName), chosenSessionID)
        return HostDirectory.Decision(
            plan: decision.plan,
            sessionID: decision.sessionID,
            workspaceName: String(decision.workspaceName),
            vanishedSessionID: decision.vanishedSessionID,
            isNewSessionOffered: decision.isNewSessionOffered
        )
    }

    #if UBIQUITTY_UI_TESTS || UBIQUITTY_IOS_UI_TESTS
    /// Holds a tree as though the listed host had answered with it, for a
    /// scenario that draws a host without dialling one.
    ///
    /// - Parameter tree: The tree, as a host states it.
    // swift-only: a UI-test seam over a SessionTree parameter the printer cannot represent, and no C++ caller exists
    public func holdHostSessionTreeForTesting(_ tree: Ubiquitty.Session.SessionTree) {
        session.holdHostSessionTreeForUITest(tree)
    }

    /// Holds a tree as though a connected watch had reported it, for a
    /// scenario that draws a followed host without dialling one.
    ///
    /// - Parameter tree: The tree, as a host states it.
    // swift-only: a UI-test seam over a SessionTree parameter the printer cannot represent, and no C++ caller exists
    public func holdWatchedHostSessionTreeForTesting(_ tree: Ubiquitty.Session.SessionTree) {
        session.holdWatchedHostSessionTreeForUITest(tree)
    }
    #endif

    /// Asks a host what sessions it is holding, over a carrier the embedder
    /// builds.
    ///
    /// Separate from an attach and callable before one: a frontend that offers
    /// the human a choice has to know what there is to choose from before it
    /// binds this drive's session to any of it. The answer arrives as
    /// ``RuntimeEvents/hostSessionListChanged``.
    ///
    /// - Parameter factory: The embedder's `Ubiquitty::Session::ChannelFactory`,
    ///   as an address. BORROWED — the directory asks it for a carrier again on
    ///   every refresh, so it must outlive this drive.
    /// - Returns: Whether the question was asked.
    public func listHostSessions(factory: UInt) -> Bool {
        session.listHostSessions(
            factory,
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// Follows a host's tree over a carrier the embedder builds: each change
    /// arrives as ``RuntimeEvents/hostSessionListChanged`` until
    /// ``stopWatchingHostSessions()``. A connection of its own, beside the
    /// listings' and the changes'.
    ///
    /// - Parameter factory: As ``listHostSessions(factory:)``. BORROWED — the
    ///   watch dials it again whenever its carrier drops, so the embedder
    ///   stops the watch before freeing it.
    /// - Returns: Whether a watch is running.
    public func watchHostSessions(factory: UInt) -> Bool {
        session.watchHostSessions(
            factory,
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// Stops following the host and lets go of the factory the watch
    /// borrowed. The tree stays, as one nothing follows.
    public func stopWatchingHostSessions() {
        session.stopWatchingHostSessions()
    }

    /// Asks a host what sessions it is holding, over a carrier this drive's
    /// session SPAWNS.
    ///
    /// ``listHostSessions(factory:)`` in every respect but where the carrier
    /// comes from, which is the split the two attach doors take: a frontend
    /// that reaches a host by spawning `ssh … --attach` has no factory of its
    /// own to hand over, and one built outside Core would be a second spelling
    /// of the transport beside the one `attachRemote` already owns.
    ///
    /// A directory errand always takes the subprocess carrier: it dials in TCP
    /// mode alone, and a QUIC bootstrap is itself an ssh round trip, so dialling
    /// one for a single question would pay a spawn to save none. The QUIC
    /// arguments are still taken, so a caller passes the host's own connection
    /// rather than a trimmed copy of it.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and
    ///     certificate pin; empty likewise offers no QUIC.
    /// - Returns: Whether the question was asked.
    public func listHostSessions(shellCommand: String, quicHost: String, quicBootstrapCommand: String) -> Bool {
        session.listHostSessions(
            std.string(shellCommand),
            std.string(quicHost),
            std.string(quicBootstrapCommand),
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// How a host answered a request to end one of its sessions.
    public enum HostSessionTerminateOutcome: UInt8 {
        /// The session is gone.
        case terminated = 0
        /// The human refused the agent asking.
        case denied = 1
        /// Nobody answered inside the daemon's window.
        case timedOut = 2
        /// The daemon tried and could not.
        case failed = 3
        /// The daemon would not take the request at all.
        case refused = 4
    }

    /// How the last terminate settled.
    ///
    /// Read when ``RuntimeEvents/hostSessionTerminateSettled`` drains. An
    /// outcome this build does not know answers nil, and a frontend that cannot
    /// say what happened must not say the session is gone.
    public var lastHostSessionTerminateOutcome: HostSessionTerminateOutcome? {
        HostSessionTerminateOutcome(rawValue: session.lastHostSessionTerminateOutcome())
    }

    /// Which session the last settled terminate was about.
    ///
    /// Read beside ``lastHostSessionTerminateOutcome``: a picker holding
    /// several rows cannot tell which one an outcome applies to without it.
    public var lastHostSessionTerminateSessionID: UInt32 {
        session.lastHostSessionTerminateSessionID()
    }

    /// Which change of a host's structure was asked, numbered as Core's
    /// `Runtime::StructureOperation`.
    public enum HostStructureOperation: UInt8, Sendable {
        case setLabel = 1
        case setTags = 2
        case renameWorkspace = 3
        case renameTab = 4
        case moveTab = 5
        case closeWindow = 6
    }

    /// How a change ended, numbered as Core's `Runtime::StructureOutcome`.
    public enum HostStructureOutcome: UInt8, Sendable {
        /// The host made the change; the outline's next revision shows it.
        case served = 1
        /// The host refused, for the reason in its own words.
        case refusedByHost = 2
        /// Refused before anything was sent, in Core's words.
        case refusedHere = 3
        /// Sent, and the host's answer never arrived.
        case unanswered = 4
    }

    /// How one change ended.
    public struct HostStructureResult: Sendable {
        /// The number the request was given when it was asked.
        public let requestID: UInt64
        public let operation: HostStructureOperation
        /// What was to be changed.
        public let target: HostOutlineIdentity
        public let outcome: HostStructureOutcome
        /// Why it was not served, as Core or the host worded it; empty when
        /// it was. Shown as it is: a frontend words nothing here.
        public let reason: String
    }

    /// Asks Core for one change, through the one entry that takes scalars.
    private func requestHostStructureChange(
        _ operation: HostStructureOperation,
        _ target: HostOutlineIdentity,
        text: String = "",
        tags: [String] = [],
        window: HostOutlineIdentity? = nil,
        index: UInt32 = 0,
        confirmationToken: UInt64 = 0
    ) -> UInt64 {
        var names = Ubiquitty.Runtime.StructureTags()
        for tag in tags {
            names.append(std.string(tag))
        }
        return session.requestHostStructureChange(
            operation.rawValue,
            target.kind.rawValue,
            target.number,
            std.string(text),
            names,
            window?.number ?? 0,
            index,
            confirmationToken
        )
    }

    /// Sets or clears the label of a workspace, a window, a tab, a pane or a
    /// session of the listed host.
    ///
    /// Every change here is asked the same way. Core checks it against the
    /// outline's tree and either refuses it at once, in its own words, or
    /// makes the host's call. Either way it ends as
    /// ``RuntimeEvents/hostStructureSettled`` with
    /// ``lastHostStructureResult`` carrying the number returned here.
    ///
    /// - Parameters:
    ///   - target: A row's ``HostOutlineRow/id``, or one of its folded
    ///     identities when the inner thing is meant.
    ///   - label: The label; empty clears it.
    /// - Returns: The request's number; zero when no host is listed.
    public func setHostLabel(_ target: HostOutlineIdentity, _ label: String) -> UInt64 {
        requestHostStructureChange(.setLabel, target, text: label)
    }

    /// Replaces the tags of one of those; none clears them.
    ///
    /// - Parameters:
    ///   - target: What is tagged.
    ///   - tags: Its tags, in the order they are drawn.
    /// - Returns: The request's number.
    public func setHostTags(_ target: HostOutlineIdentity, _ tags: [String]) -> UInt64 {
        requestHostStructureChange(.setTags, target, tags: tags)
    }

    /// Gives a workspace its name, or takes it away with an empty one.
    ///
    /// - Parameters:
    ///   - workspace: The workspace's identity.
    ///   - name: The name.
    /// - Returns: The request's number.
    public func renameHostWorkspace(_ workspace: HostOutlineIdentity, _ name: String) -> UInt64 {
        requestHostStructureChange(.renameWorkspace, workspace, text: name)
    }

    /// Gives a tab its name, or takes it away with an empty one.
    ///
    /// - Parameters:
    ///   - tab: The tab's identity.
    ///   - name: The name.
    /// - Returns: The request's number.
    public func renameHostTab(_ tab: HostOutlineIdentity, _ name: String) -> UInt64 {
        requestHostStructureChange(.renameTab, tab, text: name)
    }

    /// Puts a tab at a place among the tabs of a window of its workspace.
    ///
    /// - Parameters:
    ///   - tab: The tab's identity.
    ///   - window: The window it is to stand in.
    ///   - index: The place it takes there, from zero.
    /// - Returns: The request's number.
    public func moveHostTab(_ tab: HostOutlineIdentity, to window: HostOutlineIdentity, at index: UInt32) -> UInt64 {
        requestHostStructureChange(.moveTab, tab, window: window, index: index)
    }

    /// A request that ends sessions on the listed host. Core's
    /// `Runtime::DestructiveRequest`, value for value.
    public enum HostDestructiveRequest: UInt8, Sendable {
        case closeWindow = 1
        case terminateSession = 2
        case terminateWorkspace = 3
    }

    /// The question asked before a request that ends sessions, worded by
    /// Core from the host's tree.
    ///
    /// Shown as it is: the safe button first and the default, the
    /// destructive one second. The token is what the request is sent with.
    public struct HostDestructiveConfirmation: Sendable {
        /// What a button of the question does.
        public enum ButtonRole: Sendable {
            /// Ends nothing. The default: the one Return picks, drawn as
            /// the default button is.
            case safeDefault
            /// Goes through with it. Drawn as a destructive button is, and
            /// never the default.
            case destructive
        }

        /// One button: its title in Core's words and what it does.
        public struct Button: Sendable {
            public let title: String
            public let role: ButtonRole
        }

        public let token: UInt64
        public let title: String
        public let body: String
        public let safeButton: String
        public let destructiveButton: String
        /// The two buttons in the order they are added, each with its role:
        /// the safe default first, the destructive one second.
        public var buttons: [Button] {
            [Button(title: safeButton, role: .safeDefault), Button(title: destructiveButton, role: .destructive)]
        }
        /// How many sessions end.
        public let sessionCount: UInt32
    }

    /// What became of asking for a confirmation or sending a terminate.
    public enum HostDestructiveRefusal: Error, Sendable {
        /// Nothing was asked or sent, for the reason in Core's sentence.
        case refused(String)
    }

    /// Words the question a request that ends sessions is asked with.
    ///
    /// - Parameters:
    ///   - request: What would be asked of the host.
    ///   - target: A window to close; a session, the pane it draws into, or
    ///     a workspace to terminate.
    ///   - hostName: What the host is called in the question.
    /// - Returns: The question with its token, or Core's sentence for why
    ///   there is nothing to ask.
    public func hostDestructiveConfirmation(
        _ request: HostDestructiveRequest,
        target: HostOutlineIdentity,
        hostName: String
    ) -> Result<HostDestructiveConfirmation, HostDestructiveRefusal> {
        let token = session.askHostDestructiveConfirmation(
            request.rawValue,
            target.kind.rawValue,
            target.number,
            std.string(hostName)
        )
        guard token != 0 else {
            return .failure(.refused(String(session.hostDestructiveConfirmationRefusal())))
        }
        return .success(
            HostDestructiveConfirmation(
                token: token,
                title: String(session.hostDestructiveConfirmationTitle()),
                body: String(session.hostDestructiveConfirmationBody()),
                safeButton: String(session.hostDestructiveConfirmationSafeButton()),
                destructiveButton: String(session.hostDestructiveConfirmationDestructiveButton()),
                sessionCount: session.hostDestructiveConfirmationSessionCount()
            )
        )
    }

    /// Closes a window and ends the sessions in its panes.
    ///
    /// Core refuses it unless the confirmation is the one
    /// ``hostDestructiveConfirmation(_:target:hostName:)`` returned for
    /// closing this window.
    ///
    /// - Parameters:
    ///   - window: The window's identity.
    ///   - confirmation: The question that was answered.
    /// - Returns: The request's number.
    public func closeHostWindow(_ window: HostOutlineIdentity, confirmedBy confirmation: HostDestructiveConfirmation) -> UInt64 {
        requestHostStructureChange(.closeWindow, window, confirmationToken: confirmation.token)
    }

    /// Terminates a session, or every session of a workspace.
    ///
    /// Each session settles as its own host-session-terminate event.
    ///
    /// - Parameters:
    ///   - request: ``HostDestructiveRequest/terminateSession`` or
    ///     ``HostDestructiveRequest/terminateWorkspace``.
    ///   - target: The session or its pane, or the workspace.
    ///   - confirmation: The question that was answered.
    /// - Returns: How many sessions the host is asked to end, or Core's
    ///   sentence for why none is.
    public func terminateOnHost(
        _ request: HostDestructiveRequest,
        target: HostOutlineIdentity,
        confirmedBy confirmation: HostDestructiveConfirmation
    ) -> Result<UInt32, HostDestructiveRefusal> {
        let count = session.terminateHostSessions(
            request.rawValue,
            target.kind.rawValue,
            target.number,
            confirmation.token
        )
        guard count != 0 else {
            return .failure(.refused(String(session.lastHostTerminateRefusal())))
        }
        return .success(count)
    }

    /// Shows this session's pane on its host once its layout has arrived:
    /// its window in front, its tab shown, the pane typed into. Called on
    /// the session an attach opened at a pane's row
    /// (``HostOutlineOpen/paneID``): attaching binds the whole workspace and
    /// leaves the host's own focus where it was.
    public func revealRemoteWorkspacePaneWhenAttached() {
        session.revealRemoteWorkspacePaneWhenAttached()
    }

    /// How the change that settled last ended.
    ///
    /// Read when ``RuntimeEvents/hostStructureSettled`` drains. Nil before
    /// any has, and for a result this build cannot read, which a frontend
    /// must not show as a success.
    public var lastHostStructureResult: HostStructureResult? {
        guard session.lastHostStructureRequestID() != 0,
            let operation = HostStructureOperation(rawValue: session.lastHostStructureOperation()),
            let outcome = HostStructureOutcome(rawValue: session.lastHostStructureOutcome()),
            let kind = HostOutlineObjectKind(rawValue: session.lastHostStructureTargetKind())
        else { return nil }
        return HostStructureResult(
            requestID: session.lastHostStructureRequestID(),
            operation: operation,
            target: HostOutlineIdentity(kind: kind, number: session.lastHostStructureTargetNumber()),
            outcome: outcome,
            reason: String(session.lastHostStructureReason())
        )
    }

    /// What a revoke does to an attendee.
    public enum RevokeAction: UInt8 {
        /// Drop the live connection serving the exact stable attachment.
        case disconnectNow = 0
        /// Forget the persisted always-allow grant for a process.
        case stopAlwaysAllowing = 1
        /// Clear this session's allow-session grant for a process.
        case clearSessionGrant = 2
        /// Drop every agent on the session.
        case disconnectAllAgents = 3
    }

    /// Acts on an attendee.
    ///
    /// - Parameters:
    ///   - action: What to do.
    ///   - attachmentID: The exact attachment, for ``RevokeAction/disconnectNow``.
    ///   - identity: The daemon's ``Attendee/grantIdentity`` for grant actions,
    ///     never ``Attendee/process`` or ``Attendee/label``.
    public func revokeConsent(_ action: RevokeAction, attachmentID: String = "", identity: String = "") {
        session.revokeConsent(action.rawValue, std.string(attachmentID), std.string(identity))
    }

    /// Builds a drive whose model is sized to the given grid.
    ///
    /// - Parameters:
    ///   - rows: The grid's rows.
    ///   - columns: The grid's columns.
    public init?(rows: Int, columns: Int) {
        guard let session = Ubiquitty.Runtime.TerminalSession.make() else {
            return nil
        }
        self.session = session
        #if canImport(AppKit)
        session.setNativeDragSupported()
        #endif
        // Metal draws sized blocks and CoreText shapes proportional runs.
        session.start(Int32(rows), Int32(columns), .SizedAndProportional)
    }

    /// Builds a drive over a session the window model owns — a pane whose
    /// launch, close and lifetime Core's `WorkspaceSession` performs; this
    /// drive is the view's route into it.
    ///
    /// - Parameter session: The model-owned session, already started.
    package init(over session: Ubiquitty.Runtime.TerminalSession) {
        self.session = session
        #if canImport(AppKit)
        session.setNativeDragSupported()
        #endif
    }

    /// Builds a drive that renders an externally owned terminal — the tmux
    /// render-only pane, whose model the Session writes and disposes.
    ///
    /// The drive's own session still starts, because its runtime is the
    /// publish anchor the read-snapshot rides; every model accessor then
    /// reads the adopted terminal under the adopted lock, and this drive
    /// never starts ingest.
    ///
    /// - Parameters:
    ///   - terminal: The externally owned terminal to render.
    ///   - lockAddress: The owner's model lock address, from the seam that
    ///     hands a mutex across interop as a number.
    ///   - rows: The grid's rows, for the anchor's initial publish.
    ///   - columns: The grid's columns, likewise.
    public init?(adopting terminal: Ubiquitty.Terminal, lockAddress: UInt, rows: Int, columns: Int) {
        guard let session = Ubiquitty.Runtime.TerminalSession.make() else {
            return nil
        }
        self.session = session
        #if canImport(AppKit)
        session.setNativeDragSupported()
        #endif
        guard session.canClose() else { return nil }
        session.start(Int32(rows), Int32(columns), .SizedAndProportional)
        session.adoptExternalTerminal(terminal, UInt(lockAddress))
        Ubiquitty.Runtime.WorkspaceSession.installDefaultClientsForAdoptedSession(session)
    }

    /// Routes the Stream Debug recorder's byte taps onto this drive's session.
    ///
    /// Must run before ingest starts: the tap slots are read unsynchronized on
    /// the ingest thread, the same contract the drain signal states. The drive
    /// forwards rather than exposing the session — the session's lifetime is
    /// this drive's to manage, and a recorder holding it would outlive that.
    ///
    /// - Parameter recorder: The per-surface recorder taking both taps.
    package func installStreamDebugTaps(_ recorder: StreamDebugRecorder) {
        recorder.install(on: session)
    }

    /// Pumps host bytes into the model.
    ///
    /// The span is borrowed for exactly this call, which is the whole
    /// crossing: no copy, no container, no message. The bridge to the C++
    /// span is one buffer view feeding the imported constructor — the form
    /// that needs no experimental importer feature; the generated Span
    /// overload the noescape annotation describes replaces it when that
    /// feature ships stable.
    ///
    /// - Parameter bytes: The bytes to feed.
    public func feed(_ bytes: Span<CChar>) {
        bytes.withUnsafeBufferPointer { buffer in
            session.feedBytes(Ubiquitty.Runtime.ByteSpan(buffer))
        }
    }

    /// Feeds bytes already held as a raw buffer.
    ///
    /// The `Span` overload above is the one to reach for; this exists for a
    /// caller whose bytes arrive as `Data`, where converting to a `Span` of
    /// `CChar` means a per-byte closure and a second array of the same size.
    /// The buffer is borrowed for exactly this call, as the span is.
    ///
    /// - Parameter bytes: The bytes to feed.
    public func feed(_ bytes: UnsafeBufferPointer<CChar>) {
        session.feedBytes(Ubiquitty.Runtime.ByteSpan(bytes))
    }

    /// Whether the launch is still holding the child's output for the screen
    /// the window opens with.
    public var isOpeningHoldActive: Bool { session.isOpeningHoldActive() }

    /// Writes the screen the window opens with ahead of the child's held
    /// output, and lets that output follow; see
    /// ``Ubiquitty/Runtime/TerminalSession/finishOpeningScreen(_:)``.
    ///
    /// - Parameter bytes: The opening screen; empty releases the hold alone.
    package func finishOpeningScreen(_ bytes: [CChar]) {
        bytes.withUnsafeBufferPointer { buffer in
            session.finishOpeningScreen(Ubiquitty.Runtime.ByteSpan(buffer))
        }
    }

    /// Sends one key press to the host and answers what it encodes to here.
    ///
    /// A local session is written the bytes. A remote session is sent the
    /// press itself, which its host encodes under the modes live when it
    /// writes it; the bytes this terminal's own modes give still land in
    /// `output`, for the echo and for an observer of what was typed.
    ///
    /// - Parameters:
    ///   - press: What the platform reported.
    ///   - output: Where this terminal's encoding lands.
    /// - Returns: Local bytes, echo policy, transition and endpoint admission.
    // swift-only: the generated C++ header drops this package helper, and only Swift callers send keys through it
    package func sendKey(
        _ press: Ubiquitty.Runtime.KeyPress,
        into output: UnsafeMutableBufferPointer<CChar>
    ) -> Ubiquitty.Runtime.KeyEncoding {
        session.sendKey(press, Ubiquitty.Keys.Keymap.EncodedKeyBytes(output))
    }

    /// Sends the formats selected by a user paste gesture when mode 5522 is enabled.
    /// - Parameter mimeTypes: Space-separated clipboard MIME names.
    /// - Returns: Whether the terminal consumed the paste gesture.
    package func sendPasteNotification(_ mimeTypes: String) -> Bool {
        session.sendPasteNotification(std.string(mimeTypes), Ubiquitty.ClipboardBuffer.Clipboard)
    }

    /// Sends pasted text to the host and answers the bytes it comes to here.
    ///
    /// A local session is written the text fenced and normalised. A remote
    /// session is sent the text as one paste, which its host fences and
    /// normalises under the modes live when it writes it.
    ///
    /// - Parameters:
    ///   - text: The clipboard's text.
    /// - Returns: The bytes this terminal's modes give; empty when nothing
    ///   was sent.
    // swift-only: the generated C++ header drops this package helper, and only Swift callers paste through it
    package func sendPaste(_ text: String) -> [CChar] {
        let wrapped = session.sendPaste(std.string(text))
        return Array(wrapped)
    }

    /// Whether bytes the user sends other than keys are also shown locally;
    /// Core's rule, the one the key encoder answers with.
    package func shouldEchoInputLocally() -> Bool {
        session.shouldEchoInputLocally()
    }

    /// Writes input bytes to the host, bypassing the model.
    ///
    /// - Parameter bytes: The bytes to send.
    public func sendInput(_ bytes: Span<CChar>) {
        bytes.withUnsafeBufferPointer { buffer in
            session.sendInput(Ubiquitty.Runtime.ByteSpan(buffer))
        }
    }

    /// Writes input bytes to the host, for the ObjC++ funnel.
    ///
    /// The `Span` overload above serves Swift callers; a Span parameter does
    /// not cross the generated header, so this raw pair is the spelling C++
    /// can call. The span forms inside, over the borrowed bytes, and nothing
    /// is copied.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to send, borrowed for this call.
    ///   - count: How many of them.
    public func sendInput(_ bytes: UnsafePointer<CChar>, count: Int) {
        session.sendInput(Ubiquitty.Runtime.ByteSpan(UnsafeBufferPointer(start: bytes, count: count)))
    }

    /// Whether input sent here reaches a host — a local PTY, a tmux -CC
    /// primary, or a remote core. Core's one answer, which a broadcast reads
    /// to choose its targets and to count them.
    public var hasHostInputSink: Bool {
        session.hasHostInputSink()
    }

    /// Posts a focus change to the thread that owns the model.
    ///
    /// Lock-free on the live path — the command rides the session's ring and
    /// a wake bounds pickup by one loop iteration, so the caller never waits
    /// on the lock a flood holds hot.
    ///
    /// - Parameter focus: The new state.
    public func setDesiredFocus(_ focus: Ubiquitty.Modes.FocusState) {
        session.setDesiredFocus(focus)
    }

    /// Registers the durable knobs the session's boundary capture is steered
    /// by, and arms it.
    ///
    /// The session captures each completed DECSET-2026 frame itself at the
    /// boundary, under the model lock; this hands it the geometry that
    /// capture reads. Call again on every scroll, resize or style edge — the
    /// copy is taken under the lock, so a capture in flight sees the old
    /// registration or the new, never a tear.
    ///
    /// - Parameter geometry: The durable capture knobs; the per-frame
    ///   borrowed tiers are assembled at the boundary.
    public func setSyncFrameCaptureGeometry(_ geometry: Ubiquitty.Runtime.SyncFrameCaptureGeometry) {
        session.setSyncFrameCaptureGeometry(geometry)
    }

    /// Records the run under the pointer for the boundary capture to draw.
    ///
    /// Separate from the geometry above because it changes on a different
    /// occasion — the pointer moving, not the window changing shape — and a
    /// boundary frame with no hover of its own draws the link resting, which
    /// under synchronized output is an emphasis that flickers.
    ///
    /// Called whenever the resolved run changes, the end of a hover included.
    ///
    /// - Parameter hover: The run in absolute rows, or an inactive one.
    public func setSyncFrameHoverLink(_ hover: Ubiquitty.Rendering.FrameHoverLink) {
        session.setSyncFrameHoverLink(hover)
    }

    /// Drains the newest boundary capture, retained, or nil when none waits.
    ///
    /// The single-consumer claim is lock-free and newest-wins like the ready
    /// flag it replaces. The returned capture stays valid until the next
    /// call, because the session reuses its three exchange slots.
    ///
    /// - Returns: The capture, or nil.
    public func takeSyncFrame() -> Ubiquitty.Rendering.FrameCapture? {
        session.takeSyncFrame()
    }

    /// Boundary frames retired before the display promoted them.
    public var syncFrameOverwriteCount: UInt64 { session.syncFrameOverwriteCount() }

    /// Boundary frames promoted toward the display.
    public var syncFramePromoteCount: UInt64 { session.syncFramePromoteCount() }

    /// Boundary captures attempted since the session was armed.
    public var syncFrameCaptureAttemptCount: UInt64 { session.syncFrameCaptureAttemptCount() }

    /// Boundary captures published into the exchange.
    public var syncFramePublicationCount: UInt64 { session.syncFramePublicationCount() }

    /// Boundary captures that found no unheld slot.
    public var syncFrameNoSlotCount: UInt64 { session.syncFrameNoSlotCount() }

    /// Boundaries the drain announced, counted before the armed check.
    public var syncFrameBoundaryAnnounceCount: UInt64 { session.syncFrameBoundaryAnnounceCount() }

    /// Settles that replaced a capture nobody had taken.
    public var staleCaptureReplacedCount: UInt64 { session.staleCaptureReplacedCount() }

    /// Whether the session holds the capture storage a boundary writes into.
    public var isSyncCaptureArmed: Bool { session.isSyncCaptureArmed() }

    /// Boundaries the drain asked to publish, before the host's throttle.
    public var syncFrameBoundaryRequestCount: UInt64 { session.syncFrameBoundaryRequestCount() }

    /// Boundaries the host's publish throttle withheld.
    public var syncFrameBoundaryThrottledCount: UInt64 { session.syncFrameBoundaryThrottledCount() }

    /// Completed DECSET-2026 frames the parser reported to a drain.
    public var syncClearSeenCount: UInt64 { session.syncClearSeenCount() }

    /// Settles that declined to publish for an incoherent frame.
    public var settlePublishRefusedCount: UInt64 { session.settlePublishRefusedCount() }

    /// Whether the coherence rule holds the pane's frame: the live grid may
    /// be a screen the program has not finished drawing, so a live present
    /// waits for the rule to admit it.
    public var isFrameHeld: Bool { session.isFrameHeld() }

    /// Settles the animation schedule against the model, under the model lock.
    ///
    /// - Returns: Whether anything animates, and the delay to its next
    ///   visible change.
    public func nextAnimationDelay() -> Ubiquitty.Runtime.AnimationScheduleVerdict {
        session.nextAnimationDelay()
    }

    /// Resolves the frame-clock facts against the model, under the model lock.
    ///
    /// - Returns: The tick and the cursor's blink weight at it.
    public func frameClockFactsNow() -> Ubiquitty.Runtime.FrameClockFacts {
        session.frameClockFactsNow()
    }

    /// The frame tick every blink curve reads.
    ///
    /// No model lock: the tick is a clock reading and owes the model nothing.
    /// The cursor's weight at that tick is what ``frameClockFactsNow()`` takes
    /// the lock for, so a caller wanting only the tick asks here instead of
    /// paying for an answer it discards.
    ///
    /// - Returns: The tick.
    public func frameTicksNow() -> UInt32 {
        Ubiquitty.Runtime.TerminalSession.frameTicksNow()
    }

    /// The reader's `[cursor] alpha` as the frame's 0..1 multiplier, from the
    /// session's own configuration — the same entry the boundary capture reads.
    public func cursorAlphaUnit() -> Float {
        session.cursorAlphaUnit()
    }

    /// Reports a keypress as the Tektronix graphic-input trigger.
    ///
    /// - Parameters:
    ///   - key: The typed byte, seven bits.
    ///   - pointX: The pointer's x in the view.
    ///   - pointY: Its y, measured from the top of the view.
    ///   - viewWidth: The view's width in the same units.
    ///   - viewHeight: Its height.
    /// - Returns: Whether the press was the trigger and a report was sent.
    public func reportTekGraphicInput(
        key: CChar,
        pointX: Double,
        pointY: Double,
        viewWidth: Double,
        viewHeight: Double
    ) -> Bool {
        session.reportTekGraphicInput(key, pointX, pointY, viewWidth, viewHeight)
    }

    /// Steps the viewport to the neighbouring OSC 133 prompt.
    ///
    /// The scan is the session's, under the model lock: the marks are
    /// parser-owned rows.
    ///
    /// - Parameters:
    ///   - viewOffset: The viewport's current offset into history.
    ///   - anchorRow: The prompt the last step landed on; -1 to re-derive.
    ///   - direction: Negative to step back, positive to step forward.
    /// - Returns: The move to apply, and what to do with it.
    public func stepToPrompt(viewOffset: Int, anchorRow: Int, direction: Int) -> Ubiquitty.Screen.PromptStepResult {
        session.stepToPrompt(Int32(viewOffset), Int32(anchorRow), Int32(direction))
    }

    /// The most font requests one delivery may apply without yielding.
    public static var maxFontRequestsPerDelivery: Int {
        Int(Ubiquitty.Runtime.TerminalSession.maxFontRequestsPerDelivery())
    }

    /// Leases one resolved font operation atomically with its receipt.
    ///
    /// - Parameters:
    ///   - configuredFamily: The family the configuration names.
    ///   - configuredSizePoints: The size it names.
    /// - Returns: The oldest request, or nil when none is ready to apply.
    public func beginFontRequest(
        configuredFamily: String,
        configuredSizePoints: Double
    ) -> RuntimeFontRequest? {
        let delivery = session.beginFontRequest(
            std.string(configuredFamily),
            configuredSizePoints
        )
        guard delivery.receipt.isValid() else { return nil }
        return RuntimeFontRequest(
            receipt: delivery.receipt,
            isResolved: delivery.resolution.isResolved,
            family: String(delivery.resolution.family),
            sizePoints: delivery.resolution.sizePoints
        )
    }

    /// Reports adoption without allowing a stale receipt to consume another request.
    ///
    /// - Parameters:
    ///   - request: The immutable request the frontend attempted.
    ///   - didApply: Whether adoption succeeded.
    ///   - actualFamily: The family actually drawn, including substitution.
    ///   - actualSizePoints: The size actually drawn.
    /// - Returns: Whether Core accepted the acknowledgment.
    public func acknowledgeFontRequest(
        _ request: borrowing RuntimeFontRequest,
        didApply: Bool,
        actualFamily: String,
        actualSizePoints: Double
    ) -> Bool {
        session.acknowledgeFontRequest(
            request.receipt,
            didApply ? .Applied : .Refused,
            std.string(actualFamily),
            actualSizePoints
        )
    }

    /// Publishes both actual font axes after startup, zoom, or configuration.
    ///
    /// - Parameters:
    ///   - family: The family the frontend is drawing.
    ///   - sizePoints: Its actual point size.
    /// - Returns: Whether Core accepted the published state.
    @discardableResult
    public func publishActualFont(family: String, sizePoints: Double) -> Bool {
        session.publishActualFont(std.string(family), sizePoints)
    }

    /// Starts the visual bell's envelope from now, on the session that both
    /// frame routes measure it against.
    public func noteBellFlashStarted() {
        session.noteBellFlashStarted()
    }

    /// The visual bell's strength at `ticks`, from the start the session holds
    /// and the peak its configuration names.
    public func bellFlashAlphaAt(_ ticks: UInt32) -> Float {
        session.bellFlashAlphaAt(ticks)
    }

    /// Applies a named theme through the session's authoritative palette owner.
    ///
    /// - Parameter index: The index in Core's theme catalog.
    /// - Returns: Whether the session accepts the theme.
    public func applyTheme(_ index: Int32) -> Bool {
        session.applyTheme(index)
    }

    /// Whether editor input can be sent to the foreground local shell.
    package var isForegroundLocalShell: Bool {
        let facts = session.processFacts()
        return facts.streamPresent && facts.hasRunningChild && facts.foregroundIsShell
    }

    /// Applies a theme's palette to the model, whole, under the model lock.
    ///
    /// - Parameters:
    ///   - indexedRGB: 768 bytes, red/green/blue per index 0–255.
    ///   - defaultsRGB: 9 bytes — default foreground, default background,
    ///     cursor, three each in that order.
    /// - Returns: Whether both tables held their exact lengths and a model
    ///   existed to apply them to.
    public func applyPalette(
        _ indexedRGB: Ubiquitty.Runtime.AlphaSpan,
        _ defaultsRGB: Ubiquitty.Runtime.AlphaSpan,
        _ indexedAlpha: Ubiquitty.Runtime.AlphaSpan
    ) -> Bool {
        session.applyPalette(indexedRGB, defaultsRGB, indexedAlpha)
    }

    /// Pushes the pane's presentation state to the session's drain gate.
    ///
    /// The fold with the machine throttle is Core's, shared with every ingest
    /// adapter: only a presented, unthrottled pane rides mid-burst gaps, and
    /// anything else parks the ingest thread at the first one.
    ///
    /// - Parameter presentation: The pane's presentation state.
    public func setPresentation(_ presentation: Ubiquitty.Runtime.PanePresentation) {
        session.setPresentation(presentation)
    }

    /// Sets visibility for this renderer's boundary captures.
    ///
    /// - Parameter presentation: Whether the renderer can present frames.
    public func setSyncFramePresentation(_ presentation: Ubiquitty.Runtime.PanePresentation) {
        session.setSyncFramePresentation(presentation)
    }

    public func setProcessStatePresentation(_ presentation: Ubiquitty.Runtime.PanePresentation) {
        session.setProcessStatePresentation(presentation)
    }

    /// Records the rows of history the surface presents above the tail, for
    /// the animation schedule's conservative blink arm.
    ///
    /// - Parameter rows: Rows above the tail; zero at the live tail.
    public func setPresentedViewOffset(_ rows: Int) {
        session.setPresentedViewOffset(Int32(rows))
    }

    /// Runs the mode-1001 hilite deadline check, non-blocking.
    ///
    /// - Parameter nowTicks: The monotonic 60 Hz tick.
    /// - Returns: Whether an await aborted and a repaint must clear its
    ///   highlight.
    public func tickHiliteDeadline(_ nowTicks: UInt32) -> Bool {
        session.tickHiliteDeadline(nowTicks)
    }

    /// Advances animated images by the wall time since the previous call;
    /// the session owns the elapsed clock.
    ///
    /// - Returns: Whether any image advanced and a repaint must show it.
    public func advanceAnimatedImagesNow() -> Bool {
        session.advanceAnimatedImagesNow()
    }

    /// Resets the image-advance clock, so a fresh animation seeds cleanly.
    public func resetImageAdvanceClock() {
        session.resetImageAdvanceClock()
    }

    /// Clears the private 7403 pointer-lock mode, for the break-out chord.
    public func breakOutOfPointerLock() {
        session.breakOutOfPointerLock()
    }

    /// Reports the shell's pointer grab, so the lesson that names the way
    /// out stands for exactly as long as the trap does.
    ///
    /// - Parameter grab: Whether the grab is held.
    public func notePointerLockGrab(_ grab: Ubiquitty.Input.PointerLockGrab) {
        session.notePointerLockGrab(grab)
    }

    /// Whether the shell should hold the pointer grab: the application's ask
    /// and the surface's standing to answer it, decided in Core.
    ///
    /// - Parameter isSurfaceFocused: Whether the surface is the live input target.
    /// - Returns: Whether to hold the grab.
    public func pointerLockVerdict(isSurfaceFocused: Bool) -> Ubiquitty.Input.PointerLockVerdict {
        var facts = Ubiquitty.Input.PointerLockFacts()
        facts.isSurfaceFocused = isSurfaceFocused
        return session.pointerLockVerdict(facts)
    }

    /// Reports the modifier state the shell saw, for the break-out chord.
    ///
    /// - Parameter keys: The modifiers and whether any other key is down.
    public func notePointerLockChord(_ keys: Ubiquitty.Input.PointerLockKeyState) {
        session.notePointerLockChord(keys)
    }

    /// Asks whether the armed chord has been held for its threshold. A
    /// break-out has already cleared the mode by the time this returns.
    ///
    /// - Parameter keysNow: The modifiers as they are now.
    /// - Returns: Whether the shell releases its grab.
    public func tickPointerLockChord(_ keysNow: Ubiquitty.Input.PointerLockKeyState) -> Ubiquitty.Input.PointerLockChordVerdict {
        session.tickPointerLockChord(keysNow)
    }

    /// How long until the armed chord's hold elapses, in 60 Hz ticks, or 0
    /// when it is not armed: the one wake-up the shell books for the chord.
    ///
    /// - Returns: Ticks until the deadline, or 0.
    public func pointerLockChordTicksUntilDeadline() -> UInt32 {
        session.pointerLockChordTicksUntilDeadline()
    }

    /// The hint a shell should be showing now: Core's words, or none.
    ///
    /// - Returns: The text, empty when nothing stands.
    public func hintTextShowing() -> String {
        // Every keyboard this kit ships on prints the Mac glyphs on its keys.
        String(cString: Ubiquitty.Input.hintText(session.hintShowing(), .mac))
    }

    /// How long the standing hint has left, in 60 Hz ticks, or 0 when it will
    /// not withdraw itself.
    ///
    /// - Returns: Ticks until the lesson fades, or 0.
    public func hintTicksUntilExpiry() -> UInt32 {
        session.hintTicksUntilExpiry()
    }

    /// Runs one pointer fact through Core's ladder — report, hilite,
    /// selection — and answers what remains for the view.
    ///
    /// - Parameters:
    ///   - fact: The event's facts.
    ///   - selection: The caller-owned selection session.
    /// - Returns: What to repaint and notify.
    // swift-only: the printer cannot represent the selection pointer, and the only callers are in-package Swift
    package func pointerFact(
        _ fact: Ubiquitty.Runtime.TerminalSession.PointerFact,
        selection: UnsafeMutablePointer<Ubiquitty.Selection.Session>
    ) -> Ubiquitty.Runtime.TerminalSession.PointerOutcome {
        session.pointerFact(fact, selection)
    }

    /// Tells the DEC locator where a pointer that has not moved is, and
    /// sends the report that comes back, if any; Core runs the locator's rung
    /// and nothing else.
    ///
    /// - Parameter fact: Where the pointer is; its kind and button are not read.
    // swift-only: the printer represents no parameter of the fact's type, so this member has no C++ thunk, and the only caller is in-package Swift
    package func seedLocator(_ fact: Ubiquitty.Runtime.TerminalSession.PointerFact) {
        session.seedLocator(fact)
    }

    /// Captures the logical remote-history position after explicit scrolling.
    /// - Parameters:
    ///   - selection: The view-owned selection session.
    ///   - viewOffset: Rows above the tail after the movement.
    // swift-only: selection pointers have no generated C++ thunk; callers are in-package Swift
    package func observeSelectionViewport(_ selection: inout Ubiquitty.Selection.Session, viewOffset: Int) {
        session.observeSelectionViewport(&selection, viewOffset)
    }

    /// Captures the top logical position before the grid moves.
    /// - Parameters:
    ///   - selection: The view-owned anchor and history observation.
    ///   - viewOffset: Rows above the tail before resizing.
    // swift-only: selection pointers have no generated C++ thunk; callers are in-package Swift
    package func noteViewportBeforeResize(_ selection: inout Ubiquitty.Selection.Session, viewOffset: Int) {
        session.noteViewportBeforeResize(&selection, viewOffset)
    }

    /// Resolves the retained viewport after a resize without treating rewrap as output.
    /// - Parameters:
    ///   - selection: The view-owned selection session.
    ///   - viewOffset: Rows above the tail before the resize.
    /// - Returns: The offset in the resized history.
    // swift-only: selection pointers have no generated C++ thunk; callers are in-package Swift
    package func selectionViewportAfterResize(
        _ selection: inout Ubiquitty.Selection.Session,
        viewOffset: Int
    ) -> Int {
        Int(session.selectionViewportAfterResize(&selection, viewOffset))
    }

    /// Applies an output transition to a selection and its viewport in Core.
    ///
    /// - Parameters:
    ///   - selection: The caller-owned selection session.
    ///   - viewOffset: Rows above the tail before the output.
    ///   - history: The drain's published history facts.
    /// - Returns: The viewport decision and whether the selection changed.
    // swift-only: the printer cannot represent the selection pointer, and the only callers are in-package Swift
    package func updateSelectionAfterOutput(
        _ selection: inout Ubiquitty.Selection.Session,
        viewOffset: Int,
        history: Ubiquitty.Screen.HistoryFacts
    ) -> Ubiquitty.Selection.OutputUpdate {
        session.updateSelectionAfterOutput(&selection, viewOffset, history)
    }

    /// Runs one scroll fact through Core's wheel ladder — report,
    /// alternate-scroll fold, or local view — and answers what remains.
    ///
    /// - Parameters:
    ///   - fact: The gesture's facts.
    ///   - tuning: The reader's scroll policy.
    /// - Returns: The view movement left for the caller, and whether the
    ///   gesture was consumed.
    // swift-only: the generated C++ header drops this package helper, and only Swift callers read scroll outcomes through it
    package func scrollFact(
        _ fact: Ubiquitty.Runtime.TerminalSession.ScrollFact,
        tuning: Ubiquitty.Screen.ScrollTuning.Policy
    ) -> Ubiquitty.Runtime.TerminalSession.ScrollOutcome {
        session.scrollFact(fact, tuning)
    }

    /// Selects the whole buffer.
    ///
    /// - Parameter selection: The caller-owned selection session.
    // swift-only: the printer cannot represent the signature, and the only callers are in-package Swift
    package func selectAllText(_ selection: UnsafeMutablePointer<Ubiquitty.Selection.Session>) {
        session.selectAllText(selection)
    }

    /// Starts a sliced search; its publications arrive through searchChanged.
    ///
    /// - Parameters:
    ///   - pattern: The query; empty clears.
    ///   - form: Verbatim text or the search grammar.
    ///   - sensitivity: Whether case distinguishes.
    /// - Returns: Whether a new scan was queued.
    // swift-only: the generated C++ header drops this package helper, and only Swift find bars call it
    package func setSearchQuery(
        _ pattern: String,
        form: Ubiquitty.Runtime.TerminalSession.SearchPatternForm,
        sensitivity: Ubiquitty.CaseSensitivity
    ) -> Bool {
        session.setSearchQuery(std.string(pattern), form, sensitivity)
    }

    /// The search's last publication, read without the model lock.
    package var searchStatus: Ubiquitty.Search.Status { session.searchStatus() }

    /// Starts a search with a bounded palette result list.
    ///
    /// - Parameters:
    ///   - pattern: The query; empty clears.
    ///   - isRegex: Whether the query uses the search grammar.
    ///   - firstRow: The first scoped row, or -1 for the whole buffer.
    ///   - lastRow: The last scoped row, inclusive.
    ///   - labelLimit: The requested number of labels, bounded by Core.
    /// - Returns: Whether a new scan was queued.
    // swift-only: the generated C++ header drops this helper, and only Swift palettes call it
    package func setPaletteSearchQuery(
        _ pattern: String,
        isRegex: Bool,
        firstRow: Int,
        lastRow: Int,
        labelLimit: Int
    ) -> Bool {
        session.setSearchQuery(
            std.string(pattern),
            isRegex ? .regex : .literal,
            .Insensitive,
            Int32(clamping: firstRow),
            Int32(clamping: lastRow),
            max(0, labelLimit)
        )
    }

    /// The current request's bounded labels and durable action destinations.
    // swift-only: the generated C++ header cannot represent the imported vector result
    package var searchLabels: [Ubiquitty.Search.Label] { Array(session.searchLabels()) }

    /// Resolves a palette destination at the moment its action runs.
    ///
    /// - Parameter position: The captured result position.
    /// - Returns: The view offset, or -1 if the text was destroyed.
    // swift-only: only Swift palettes pass logical positions through this seam
    package func searchPositionViewOffset(_ position: Ubiquitty.Screen.LogicalPosition) -> Int {
        Int(session.searchPositionViewOffset(position))
    }

    /// Searches in slices with a bounded wait, for tests and snapshots.
    ///
    /// - Parameters:
    ///   - pattern: The query; empty clears.
    ///   - form: How the pattern is read.
    ///   - sensitivity: Whether case distinguishes.
    ///   - timeoutMilliseconds: The wait bound.
    /// - Returns: The search status; incomplete when the wait expired.
    // swift-only: the printer cannot represent the status result, and only Swift automation calls this helper
    package func searchScrollbackAndWait(
        _ pattern: String,
        form: Ubiquitty.Runtime.TerminalSession.SearchPatternForm,
        sensitivity: Ubiquitty.CaseSensitivity,
        timeoutMilliseconds: UInt32 = 30_000
    ) -> Ubiquitty.Search.Status {
        session.searchScrollbackAndWait(std.string(pattern), form, sensitivity, timeoutMilliseconds)
    }

    /// Steps the active match, both ends wrapping.
    ///
    /// - Parameter step: Which way to move.
    /// - Returns: The same facts a fresh search answers.
    // swift-only: the printer cannot represent the status result, and only Swift find bars call this helper
    package func stepSearchMatch(_ step: Ubiquitty.Runtime.TerminalSession.SearchStep) -> Ubiquitty.Search.Status {
        _ = session.stepSearchMatch(step)
        return session.searchStatus()
    }

    /// Drops the search — the bar closed.
    public func clearScrollbackSearch() {
        session.clearScrollbackSearch()
    }

    /// Routes this session's input through a tmux -CC primary, by address —
    /// the seam's spelling for a caller that cannot name the pointer types.
    /// Zero addresses clear the route.
    ///
    /// - Parameters:
    ///   - clientAddress: The primary's tmux client's address.
    ///   - streamAddress: The control channel stream's address.
    ///   - paneID: The tmux pane the wrapped keys target.
    public func routeInputViaTmux(clientAddress: UInt, streamAddress: UInt, paneID: Int32) {
        guard canClose else { return }
        session.routeInputViaTmuxAddresses(clientAddress, streamAddress, paneID)
    }

    /// Ends an adoption: the session stops reading the owner's terminal and
    /// lock, on the caller's thread, before the owner frees them.
    ///
    /// The ingest loop is stopped first — join here is safe because the loop's
    /// thread never releases the drive — so a surface whose deallocation is
    /// deferred past the owner's retire touches only the session's own model.
    public func endAdoption() {
        guard canClose else { return }
        session.stopIngest()
        session.endExternalAdoption()
    }

    /// Whether the adopted model's window verbs, banners and trigger reports
    /// queue on this drive's session — false when nothing is adopted.
    public var hasAdoptedModelClients: Bool {
        session.hasAdoptedTerminalClients()
    }

    // MARK: - hosted windows

    /// Lets every session made from here on host the windows of a foreground
    /// program that asks to — a typed `tmux -CC` — through the factory named.
    ///
    /// Process-wide and called once, at launch, by a frontend that links a
    /// source: the factory is an address because the language seam cannot name
    /// a function pointer type, and the posts land on the main queue, where
    /// every other use of a source runs.
    ///
    /// - Parameter factoryAddress: The source factory's address.
    public static func enableHostedWindows(factoryAddress: UInt) {
        Ubiquitty.Runtime.TerminalSession.enableHostedWindows(
            factoryAddress,
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// One change the windows this session's program hosts went through.
    ///
    /// Core's record, read into Swift's own so the rest of the arm names no
    /// C++ type.
    public struct HostedWindowEvent: Sendable {
        /// What changed, numbered as Core numbers it.
        public enum Kind: UInt8, Sendable {
            /// A window appeared; ``name`` and ``sessionName`` describe it.
            case windowOpened = 1
            /// A window's panes were laid out anew: ``layout``, ``paneIDs`` in
            /// mount order, and ``activePaneID`` to focus, negative to keep.
            case layoutChanged = 2
            /// A window was renamed to ``name``.
            case windowRenamed = 3
            /// The hosting session was renamed to ``sessionName``.
            case sessionRenamed = 4
            /// A window went; its pane views unbind, then the window is
            /// released back with ``releaseHostedWindow(_:)``.
            case windowClosed = 5
            /// The program stopped hosting: every window goes.
            case ended = 6
        }
        /// What changed.
        public let kind: Kind
        /// The window it changed in.
        public let windowID: Int32
        /// The pane a layout focuses, negative to keep the focus.
        public let activePaneID: Int32
        /// The window's name.
        public let name: String
        /// The hosting session's name.
        public let sessionName: String
        /// The program's own layout string.
        public let layout: String
        /// The layout's panes, in mount order.
        public let paneIDs: [Int32]
    }

    /// The oldest hosted-window change not yet shown, removed from the queue.
    ///
    /// Drain until this answers nil, on ``RuntimeEvents/hostedWindowsChanged``.
    ///
    /// - Returns: The change, or nil when the queue is empty or nothing is
    ///   hosted.
    public func takeHostedWindowEvent() -> HostedWindowEvent? {
        let taken = session.takeHostedWindowEvent()
        guard let kind = HostedWindowEvent.Kind(rawValue: taken.kind.rawValue) else {
            return nil
        }
        return HostedWindowEvent(
            kind: kind,
            windowID: Int32(taken.windowID),
            activePaneID: Int32(taken.activePaneID),
            name: String(taken.name),
            sessionName: String(taken.sessionName),
            layout: String(taken.layout),
            paneIDs: taken.paneIDs.map { Int32($0) }
        )
    }

    /// The hosted panes whose models changed since the last call, each once.
    public func takeRepaintedHostedPanes() -> [Int32] {
        session.takeRepaintedHostedPanes().map { Int32($0) }
    }

    /// What a view binds a hosted pane to.
    public struct HostedPaneFacts {
        /// The pane's model.
        public let terminal: UnsafeMutableRawPointer
        /// The lock that model is read and written under.
        public let lockAddress: UInt
        /// The control client whose options decide how the pane's input wraps.
        public let inputClientAddress: UInt
        /// The channel the pane's input rides.
        public let inputStreamAddress: UInt
        /// The pane's grid.
        public let columns: Int
        /// The pane's grid.
        public let rows: Int
    }

    /// What a view binds a hosted pane to.
    ///
    /// - Parameter paneID: The pane.
    /// - Returns: Its facts, or nil when the pane is not live.
    public func hostedPaneFacts(_ paneID: Int32) -> HostedPaneFacts? {
        let facts = session.hostedPaneFacts(paneID)
        guard let terminal = UnsafeMutableRawPointer(bitPattern: UInt(facts.terminalAddress)) else {
            return nil
        }
        return HostedPaneFacts(
            terminal: terminal,
            lockAddress: UInt(facts.lockAddress),
            inputClientAddress: UInt(facts.inputClientAddress),
            inputStreamAddress: UInt(facts.inputStreamAddress),
            columns: Int(facts.columns),
            rows: Int(facts.rows)
        )
    }

    /// Tells the session a hosted pane's view unbound.
    ///
    /// - Parameter paneID: The pane.
    public func releaseHostedPane(_ paneID: Int32) {
        session.releaseHostedPane(paneID)
    }

    /// Answers a closed hosted window, once its pane views are unbound.
    ///
    /// - Parameter windowID: The window.
    public func releaseHostedWindow(_ windowID: Int32) {
        session.releaseHostedWindow(windowID)
    }

    /// Stops hosting, once every hosted pane view is unbound.
    public func endHostedWindows() {
        session.endHostedWindows()
    }

    /// Whether this session's program hosts windows.
    public var isHostingWindows: Bool {
        session.isHostingWindows()
    }

    /// Captures the backend identity with its verified local reconnect authority.
    package var hostedSessionReference: Ubiquitty.Runtime.HostedSessionReference {
        session.hostedSessionReference()
    }

    /// The hosting source's address: one value for all of a hosting session's
    /// panes, and what an adopted pane routes its resize through.
    public var hostedWindowSourceAddress: UInt {
        UInt(session.hostedWindowSourceAddress())
    }

    /// Routes this adopted pane's resize and client-size report through the
    /// source that hosts it.
    ///
    /// - Parameters:
    ///   - sourceAddress: ``hostedWindowSourceAddress`` of the hosting drive.
    ///   - paneID: The pane this drive renders.
    public func routeResizeThroughHostedSource(_ sourceAddress: UInt, paneID: Int32) {
        guard canClose else { return }
        session.routeResizeThroughHostedSource(sourceAddress, paneID)
    }

    /// Asks the session's backend to perform a pane verb; the caller never
    /// learns what the backend is, only how it answered.
    ///
    /// - Parameter verb: What the user asked of the pane.
    /// - Returns: How the backend answered.
    public func requestPaneVerb(_ verb: Ubiquitty.Runtime.TerminalSession.PaneVerb) -> Ubiquitty.Runtime.TerminalSession.PaneVerbOutcome {
        session.requestPaneVerb(verb)
    }

    public func canTransfer(to target: RuntimeDrive) -> Bool {
        session.canTransferTo(target.session)
    }

    public func requestTransfer(
        to target: RuntimeDrive,
        tree: Ubiquitty.Panes.Tree,
        orientation: Ubiquitty.Panes.Orientation,
        side: Ubiquitty.Panes.InsertSide,
        wholeTab: Bool,
        asTab: Bool,
        insertTarget: Ubiquitty.Panes.InsertTarget = .Pane
    ) -> Ubiquitty.Runtime.TerminalSession.PaneVerbOutcome {
        session.requestTransferTo(target.session, tree, orientation, side, wholeTab ? .Tab : .Pane, asTab ? .Tab : .Split, insertTarget)
    }

    public func requestExtraction(wholeTab: Bool, newWindow: Bool) -> Ubiquitty.Runtime.TerminalSession.PaneVerbOutcome {
        session.requestExtraction(wholeTab ? .Tab : .Pane, newWindow ? .Window : .Tab)
    }

    /// Where a tmux intent aimed at this pane lands: the -CC control channel,
    /// prefix chords into a full-screen `tmux attach`, or nowhere. The session
    /// reads its route and its live process table; this side only asks.
    ///
    /// - Returns: The pane's tmux context.
    public func tmuxPaneContext() -> Ubiquitty.`Protocol`.Tmux.PaneContext {
        session.tmuxPaneContext()
    }

    /// Performs a tmux intent over this pane's own transport, aimed at this
    /// pane rather than its window's first.
    ///
    /// - Parameters:
    ///   - intent: What the reader asked for.
    ///   - value: The new name for a rename; ignored otherwise.
    /// - Returns: Whether bytes went out. False for a native pane, whose
    ///   caller performs its own action instead.
    @discardableResult
    public func performTmuxIntent(_ intent: Ubiquitty.`Protocol`.Tmux.ActionIntent, value: String) -> Bool {
        value.withCString { bytes in
            session.performTmuxIntent(intent, std.string_view(bytes))
        }
    }

    /// The prefix chord a tmux intent takes into a full-screen `tmux attach`,
    /// empty for a pane of any other context.
    ///
    /// A chord is the reader's own typing, so a caller holding a user-input
    /// route types these bytes through it rather than calling
    /// ``performTmuxIntent(_:value:)``: that route is what drops the
    /// selection, echoes under a reset SRM and reaches a broadcast fan-out.
    ///
    /// - Parameters:
    ///   - intent: What the reader asked for.
    ///   - value: The new name for a rename; ignored otherwise.
    /// - Returns: The bytes to type, empty for a pane that takes no chord.
    public func tmuxIntentKeystrokes(_ intent: Ubiquitty.`Protocol`.Tmux.ActionIntent, value: String) -> String {
        value.withCString { bytes in
            String(session.tmuxIntentKeystrokes(intent, std.string_view(bytes)))
        }
    }

    /// Closes the captured tmux window, leaving sibling windows attached.
    @discardableResult
    public func requestTmuxWindowClose(_ windowID: Int32) -> Bool {
        session.requestTmuxWindowClose(windowID)
    }

    /// Ends this pane's tmux session over its control channel.
    ///
    /// - Parameter close: Whether the session survives the close.
    /// - Returns: Whether the command went out; false for a pane no -CC
    ///   primary routes.
    @discardableResult
    public func requestTmuxSessionClose(_ close: Ubiquitty.Runtime.TerminalSession.TmuxSessionClose) -> Bool {
        session.requestTmuxSessionClose(close)
    }

    /// Reports the tmux control client's size: the whole window's grid,
    /// which tmux tiles across the session's panes itself.
    ///
    /// - Parameters:
    ///   - columns: The window content's columns.
    ///   - rows: The window content's rows.
    /// - Returns: Whether the size went out; false for a pane no -CC primary
    ///   routes.
    @discardableResult
    public func reportTmuxClientSize(columns: Int, rows: Int) -> Bool {
        session.reportTmuxClientSize(Int32(columns), Int32(rows))
    }

    /// Attaches as a thin client over a carrier this drive's session spawns.
    ///
    /// The model mirrors the host's screen frames and input ships as Sync
    /// input events. The remote events ride the session's own flag surface,
    /// so the surface's event pump — titles, bells, exit, repaints — needs no
    /// remote awareness at all. This side contributes only the run loop: the
    /// session's posted work runs on the main queue.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and certificate pin; empty
    ///     likewise offers no QUIC.
    ///   - reattachSessionID: The daemon session to re-home to; zero asks for a fresh shell.
    ///   - workspaceName: The workspace to attach under. A name the host already holds a session
    ///     for attaches to that one and a name it does not creates one — one connect, either
    ///     outcome. Empty attaches unnamed, which is the create-or-reattach by session id.
    ///   - endsWhenDetached: Whether a session created under the name ends when its last human
    ///     detaches cleanly, rather than outliving the client.
    ///   - reattachPolicy: What the HELLO asks when `reattachSessionID` has ended: create a
    ///     fresh session in its place, or be refused so the frontend can say so.
    ///   - workspaceID: The stable workspace identifier returned by the directory.
    ///   - daemonSocketName: The daemon socket returned by the directory handshake.
    ///   - daemonInstanceID: The daemon process identity to require, or zero for a new connection.
    /// - Returns: Whether the attach started.
    public func attachRemote(
        shellCommand: String,
        quicHost: String,
        quicBootstrapCommand: String,
        reattachSessionID: UInt32 = 0,
        workspaceName: String = "",
        endsWhenDetached: Bool = false,
        reattachPolicy: Ubiquitty.Session.ReattachPolicy = .AttachOrCreate,
        workspaceID: UInt32 = 0,
        daemonSocketName: String = "",
        daemonInstanceID: UInt64 = 0
    ) -> Bool {
        guard canClose else { return false }
        var request = Self.workspaceAttachRequest(
            shellCommand: shellCommand,
            workspaceID: workspaceID,
            sessionID: reattachSessionID,
            workspaceName: workspaceName,
            daemonSocketName: daemonSocketName,
            daemonInstanceID: daemonInstanceID
        )
        request.reattachPolicy = reattachPolicy
        return session.attachRemote(
            std.string(shellCommand),
            std.string(quicHost),
            std.string(quicBootstrapCommand),
            request,
            std.string(workspaceName),
            endsWhenDetached,
            Ubiquitty.Apple.mainQueueLoop()
        ) == .Started
    }

    /// Reports whether this drive projects the requested authoritative workspace.
    ///
    /// - Parameters:
    ///   - shellCommand: The authenticated transport target, excluding display labels.
    ///   - workspaceID: The directory's stable workspace identifier, or zero when unknown.
    ///   - sessionID: The requested pane session identifier.
    ///   - workspaceName: The explicit named-workspace attach intent.
    ///   - daemonSocketName: The daemon socket returned by the directory handshake.
    ///   - daemonInstanceID: The daemon process identity to require, or zero for a new connection.
    /// - Returns: Whether Core owns a matching established or pending attachment.
    public func matchesRemoteWorkspace(
        shellCommand: String,
        workspaceID: UInt32,
        sessionID: UInt32,
        workspaceName: String,
        daemonSocketName: String,
        daemonInstanceID: UInt64 = 0
    ) -> Bool {
        session.matchesRemoteWorkspace(
            Self.workspaceAttachRequest(
                shellCommand: shellCommand,
                workspaceID: workspaceID,
                sessionID: sessionID,
                workspaceName: workspaceName,
                daemonSocketName: daemonSocketName,
                daemonInstanceID: daemonInstanceID
            )
        )
    }

    private static func workspaceAttachRequest(
        shellCommand: String,
        workspaceID: UInt32,
        sessionID: UInt32,
        workspaceName: String,
        daemonSocketName: String,
        daemonInstanceID: UInt64 = 0
    ) -> Ubiquitty.Session.WorkspaceAttachRequest {
        var request = Ubiquitty.Session.WorkspaceAttachRequest()
        request.authority.endpointIdentity = std.string(shellCommand)
        request.authority.daemonSocket = std.string(daemonSocketName)
        request.authority.daemonInstanceID = daemonInstanceID
        request.workspaceID = workspaceID
        request.sessionID = sessionID
        request.workspaceName = std.string(workspaceName)
        return request
    }

    /// Attaches a pane through the existing workspace connection.
    ///
    /// - Parameters:
    ///   - source: A drive already attached to the workspace.
    ///   - sessionID: An authoritative session identifier in that workspace.
    /// - Returns: Whether Core admitted the pane attachment.
    public func attachRemoteSibling(to source: RuntimeDrive, sessionID: UInt32) -> Bool {
        guard canClose, source.canClose else { return false }
        return session.attachRemoteSibling(source.session, sessionID)
    }

    /// Dresses this session in another's theme before it is attached, and
    /// publishes it, so a pane shows that theme before its host's first frame.
    ///
    /// - Parameter source: The session the pane opens from.
    /// - Returns: Whether the palette was seeded.
    @discardableResult
    public func seedPalette(from source: RuntimeDrive) -> Bool {
        session.seedPaletteFrom(source.session)
    }

    // MARK: - sharing into the local daemon

    /// Whether "Share This Window" can hand this session to the local daemon:
    /// a PTY this process launched, whose child is still running, and which is
    /// not already a thin client, a hosted tmux pane or a window host.
    public var isShareableLocalSession: Bool { session.isShareableLocalSession() }

    /// Whether the local daemon drives this session's PTY on its behalf.
    public var isSharedIntoLocalDaemon: Bool { session.isSharedIntoLocalDaemon() }

    /// The host's id for a locally shared session, or zero before adoption.
    public var sharedSessionID: UInt32 { session.sharedSessionID() }

    /// Other running daemon instances on the machine this directory lists.
    public var hostInstances: [HostDaemonInstance] { HostDaemonInstance.read(session.hostInstances()) }

    /// Whether ``requestReclaim()`` would ask the daemon for the session back.
    public var isReclaimableSharedSession: Bool { session.isReclaimableSharedSession() }

    /// Whether a handoff has enough evidence to permit this view's teardown.
    public var canClose: Bool { session.canClose() }

    /// Whether the inactive local owner awaits the same handoff's final result.
    public var hasUnresolvedLocalAdoption: Bool { session.hasUnresolvedLocalAdoption() }

    /// Counts every unresolved owner, including one retained without a view.
    public static var unresolvedLocalAdoptionCount: UInt32 {
        Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount()
    }

    /// Keeps the bridge owned by the session rather than by a departing view.
    ///
    /// - Parameter command: The ready local daemon's bridge command.
    public func setLocalAdoptionBridgeCommand(_ command: String) {
        session.setLocalAdoptionBridgeCommand(std.string(command))
    }

    /// Attaches a confirmed handoff with this live view's current dispatcher.
    ///
    /// - Returns: Whether the adopted session's thin client started.
    @discardableResult
    public func attachSharedLocalSession() -> Bool {
        session.attachSharedLocalSession(
            0,
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// Explicitly resolves the retained operation without starting a new handoff.
    /// A confirmed daemon owner is attached using current frontend callbacks;
    /// only Core's proven-local result can resume the original local reader.
    ///
    /// - Parameter resolveAddress: The platform's bounded handoff resolver.
    /// - Returns: The same attempt's proven ownership, or unresolved.
    public func resolveLocalAdoption(resolveAddress: UInt) -> Ubiquitty.Session.ShareOwnership {
        let ownership = session.resolveLocalAdoption(resolveAddress)
        if ownership == .Committed, !session.isRemoteAttached() {
            attachSharedLocalSession()
        }
        return ownership
    }

    /// Hands this session's PTY to the local daemon a ubiquitty-host binary
    /// owns, and attaches nothing to it yet.
    ///
    /// Core finds the binary's daemon, starts it when nothing answers, stops
    /// the local reader, and hands the PTY master over through
    /// `handoffAddress`; the shell stays this process's child and its stream
    /// stays open for the reclaim. A proven refusal restores the local reader;
    /// an unresolved Commit keeps it paused and forbids close until an
    /// explicit resolution confirms the owner. A committed pane takes no input
    /// until ``attachSharedLocalWindow()``, ``joinSharedLocalWindow(anchor:)``
    /// or ``attachSharedLocalSession()`` gives it a connection.
    ///
    /// - Parameters:
    ///   - hostBinaryPath: The ubiquitty-host to reach the daemon through.
    ///   - handoffAddress: The platform's descriptor handoff, as an address.
    /// - Returns: How the handoff ended.
    public func commitShareIntoLocalDaemon(hostBinaryPath: String, handoffAddress: UInt) -> Ubiquitty.Session.ShareOutcome {
        session.commitShareIntoLocalDaemon(std.string(hostBinaryPath), handoffAddress)
    }

    /// Attaches a committed pane as the one connection its shared window's
    /// other committed panes ride.
    ///
    /// - Returns: Whether this pane's thin client started.
    @discardableResult
    public func attachSharedLocalWindow() -> Bool {
        session.attachSharedLocalWindow(
            0,
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// Makes an attached pane of a shared window the one whose connection
    /// the window's other panes ride, as ``attachSharedLocalWindow()`` makes
    /// the pane it attaches.
    ///
    /// - Parameter workspaceID: The workspace the host confirmed for the
    ///   window, or zero to take it from the host's answer to a publication
    ///   through this pane.
    /// - Returns: Whether this pane anchors the window.
    @discardableResult
    public func anchorSharedLocalWindow(workspaceID: UInt32) -> Bool {
        session.anchorSharedLocalWindow(workspaceID)
    }

    /// Whether this pane rides the connection this process keeps for its
    /// workspace, the one the workspace's other connections retire into.
    public var isOnIndexedWorkspaceConnection: Bool {
        session.isOnIndexedWorkspaceConnection()
    }

    /// Puts a committed pane on the connection its window's anchor
    /// attached, as one more endpoint of it.
    ///
    /// A pane the host has not yet placed in the anchor's workspace joins, in
    /// Core, inside the topology update that places it. A pane already on a
    /// connection of its own moves onto the anchor's once its input has
    /// settled and its questions have been answered where it is.
    ///
    /// - Parameter anchor: The drive whose connection the window's panes ride
    ///   (``attachSharedLocalWindow()``, ``anchorSharedLocalWindow(workspaceID:)``).
    /// - Returns: Whether the pane rides that connection or will; false when
    ///   it may not, and needs ``attachSharedLocalSession()`` instead.
    public func joinSharedLocalWindow(anchor: RuntimeDrive) -> Bool {
        session.joinSharedLocalWindow(
            anchor.session,
            Ubiquitty.Apple.mainQueueLoop()
        ) != .Refused
    }

    /// Publishes the whole arrangement after the individual PTY adoptions commit.
    public func publishSharedWorkspace(_ workspace: Ubiquitty.Session.SharedWorkspace) -> Bool {
        session.publishSharedWorkspace(workspace)
    }

    /// The host's answer to publishing the shared window.
    public var sharedWorkspaceResult: Ubiquitty.Session.SharedWorkspaceResult {
        session.sharedWorkspaceResult()
    }

    /// Asks the daemon to hand the shared session back.
    ///
    /// The answer arrives as ``RuntimeEvents/remoteStateChanged`` with
    /// ``remoteState`` gone to `.Idle` and ``isSharedIntoLocalDaemon`` false:
    /// the thin client has ended and the kept stream is being read again.
    /// Panes of one shared window are asked for in turn on their connection.
    ///
    /// - Returns: Whether the request was sent or is waiting its turn.
    @discardableResult
    public func requestReclaim() -> Bool {
        session.requestReclaim()
    }

    /// Reports whether both drives use the same Core workspace connection.
    ///
    /// - Parameter other: The drive to compare.
    /// - Returns: True only when both drives belong to the same remote connection.
    public func sharesRemoteWorkspaceConnection(with other: RuntimeDrive) -> Bool {
        session.sharesRemoteWorkspaceConnection(other.session)
    }

    /// Tells a remote session the device's network path moved.
    ///
    /// A no-op on a local session and on one that has not attached, so a caller
    /// may report every path change without asking what the surface holds.
    public func networkPathChanged() {
        session.networkPathChanged()
    }

    /// Tells a remote session what the device's network path costs; Core
    /// states it to the host as the link's cost. Kept for a remote session
    /// this surface starts later.
    public func setNetworkCost(_ cost: Ubiquitty.PAL.NetworkCost) {
        session.setNetworkCost(cost)
    }

    /// Tells a remote session whether its pane is on screen: the host sends a
    /// pane that is not one `PaneDirty` when it changes, and waking it costs
    /// its changed rows.
    ///
    /// A no-op on a local session, so a caller may report every edge.
    ///
    /// - Parameter isShown: Whether the pane is presented.
    public func setRemotePaneShown(_ isShown: Bool) {
        if isShown {
            session.showRemotePane()
        } else {
            session.hideRemotePane()
        }
    }

    /// The stream bytes the host sent this remote pane, 0 for a local one.
    public var remotePaneBytesReceived: UInt64 {
        session.remotePaneBytesReceived()
    }

    /// Dials a reconnecting remote session at once instead of waiting out its
    /// backoff.
    ///
    /// - Returns: Whether a dial began.
    @discardableResult
    public func reconnectRemoteNow() -> Bool {
        session.reconnectRemoteNow()
    }

    /// Reattaches the remote workspace after the platform suspended the process.
    ///
    /// - Parameter secondsSuspended: How long the process was held, as this
    ///   frontend measured it; negative when it cannot say.
    public func resumeAfterSuspension(secondsSuspended: Double) {
        session.resumeAfterSuspension(secondsSuspended)
    }

    /// Tells a remote session's host that this client is about to be
    /// suspended, and lets its carrier go; ``resumeAfterSuspension(secondsSuspended:)``
    /// continues the session.
    ///
    /// A no-op on a local session and on one that is not connected, so a
    /// caller may tell every surface.
    public func suspendRemote() {
        session.suspendRemote()
    }

    /// The instance a remote attach greets its host as, as two halves. A
    /// frontend that keeps a window's identity across launches keeps these
    /// with it and gives them back before attaching, so the relaunched window
    /// is the same client to the host. Zero for a local session.
    public var remoteClientInstance: (low: UInt64, high: UInt64) {
        (session.remoteClientInstanceLow(), session.remoteClientInstanceHigh())
    }

    /// Sets the instance the next remote attach greets its host as.
    ///
    /// - Parameters:
    ///   - low: The instance's low half.
    ///   - high: Its high half.
    public func setRemoteClientInstance(low: UInt64, high: UInt64) {
        session.setRemoteClientInstance(low, high)
    }

    /// Gives the next remote attach the QUIC reach a previous process kept,
    /// so a restored attachment's first carrier is a resume proof and runs no
    /// login.
    ///
    /// - Parameters:
    ///   - address: The numeric address the bootstrap reached.
    ///   - port: The daemon's QUIC port.
    ///   - pin: The daemon certificate's 32-byte SHA-256.
    /// - Returns: Whether the reach was well formed and kept.
    public func seedRemoteResumeReach(address: String, port: UInt16, pin: Data) -> Bool {
        var bytes = std.string()
        for byte in pin { bytes.push_back(CChar(bitPattern: byte)) }
        return session.seedRemoteResumeReach(std.string(address), port, bytes)
    }

    /// The QUIC reach this session's remote connection would resume by, for
    /// a frontend to keep beside its resume record; nil when it has none.
    public var remoteResumeReach: (address: String, port: UInt16, pin: Data)? {
        let port = session.remoteResumeReachPort()
        let bytes = session.remoteResumeReachPin()
        guard port != 0, bytes.size() == 32 else { return nil }
        let pin = Data((0..<bytes.size()).map { UInt8(bitPattern: bytes[$0]) })
        return (String(session.remoteResumeReachAddress()), port, pin)
    }

    /// How many panes the remote connection's last Welcome continued with a
    /// diff: what a restored attachment expects, rather than a new picture.
    public var remoteResumedPanesDiffed: Int { Int(session.remoteResumedPanesDiffed()) }

    /// Consumes the platform's prepared protected owner before attaching.
    /// No network operation occurs while its cached preview is published.
    ///
    /// - Parameters:
    ///   - ownerAddress: Borrowed unique Core owner, consumed only on success.
    ///   - paneLow: The protected preview pane's low identity half.
    ///   - paneHigh: The protected preview pane's high identity half.
    /// - Returns: Whether the owner was installed without starting a carrier.
    public func prepareRemoteResume(ownerAddress: UInt, paneLow: UInt64, paneHigh: UInt64) -> Bool {
        guard canClose else { return false }
        return session.prepareRemoteResume(ownerAddress, paneLow, paneHigh)
    }

    /// Attaches as a thin client over a carrier the embedder builds.
    ///
    /// The same session ``attachRemote(shellCommand:quicHost:quicBootstrapCommand:reattachSessionID:workspaceName:endsWhenDetached:)``
    /// stands up — same Sync client, same reattach id, same clipboard latch — differing only in
    /// where the carrier comes from. `attachRemote` obtains one by spawning: its QUIC arm runs the
    /// bootstrap command as a subprocess and its fallback spawns the transport command. A frontend
    /// that cannot spawn a process supplies the factory instead, which is the only part that was
    /// ever platform-bound; the carriers themselves are portable.
    ///
    /// - Parameters:
    ///   - factory: The embedder's `Ubiquitty::Session::ChannelFactory`, as an address. BORROWED —
    ///     the core calls it again on every reconnect attempt, so it must outlive the session, and
    ///     an embedder that lets it go will crash on the first drop rather than on the first frame.
    ///   - reattachSessionID: The daemon session to re-home to; zero asks for a fresh shell.
    ///   - workspaceName: The workspace to attach under. A name the host already holds a session
    ///     for attaches to that one and a name it does not creates one — one connect, either
    ///     outcome. Empty attaches unnamed, which is the create-or-reattach by session id.
    ///   - endsWhenDetached: Whether a session created under the name ends when its last human
    ///     detaches cleanly, rather than outliving the client.
    ///   - daemonSocketName: The directory-selected daemon socket, or empty for an unbound attach.
    ///   - daemonInstanceID: The directory-selected daemon process, or zero for an unbound attach.
    /// - Returns: Whether the attach started.
    public func attachRemoteOverCarrier(
        factory: UInt,
        reattachSessionID: UInt32 = 0,
        workspaceName: String = "",
        endsWhenDetached: Bool = false,
        daemonSocketName: String = "",
        daemonInstanceID: UInt64 = 0
    ) -> Bool {
        guard canClose else { return false }
        return session.attachRemoteOverCarrier(
            factory,
            reattachSessionID,
            std.string(workspaceName),
            endsWhenDetached,
            std.string(daemonSocketName),
            daemonInstanceID,
            Ubiquitty.Apple.mainQueueLoop()
        )
    }

    /// Offers to install `ubiquitty-host` on the host this session attaches
    /// to, when the host turns out not to have one.
    ///
    /// The confirmation is a sheet, so it crosses as a C function the
    /// session calls and an answer the frontend gives back later — the same
    /// shape the dispatcher's post functions take.
    ///
    /// - Parameters:
    ///   - sshHost: The host a push targets.
    ///   - binaries: Bundled host binaries by remote `uname -sm`.
    ///
    /// Whether the host is already trusted is Core's to read from the trust
    /// list ``HostDirectory/setDeployTrustPersistence(load:store:)`` installed.
    ///
    /// The one question this cannot answer — the first push to a host —
    /// arrives as ``RuntimeEvents/deployConfirmationPending`` on the same
    /// flag surface every other session event rides.
    ///
    public func offerHostDeploy(sshHost: String, binaries: [String: String]) {
        session.offerHostDeploy(std.string(sshHost))
        for (platformArch, path) in binaries {
            session.addDeployBinary(std.string(platformArch), std.string(path))
        }
    }

    /// Approves the install this session asked about; Core records the host
    /// in the trust list.
    ///
    public func approveHostDeploy() {
        session.approveHostDeploy()
    }

    /// Declines the install this session asked about; the connect carries on
    /// without a host binary.
    public func declineHostDeploy() {
        session.declineHostDeploy()
    }

    /// What the last failed push of `ubiquitty-host` printed.
    ///
    /// Read when ``RuntimeEvents`` carries `deployFailed`: the tail of ssh's
    /// and the remote shell's output, or Core's sentence when the push printed
    /// nothing.
    public var lastDeployFailure: String { String(session.lastDeployFailure()) }

    /// Whether the last install waits for sessions to end or handover to succeed.
    public var lastDeployWasDeferred: Bool { session.lastDeployWasDeferred() }

    /// How many sessions the pending update would hand over; 0 when the pending
    /// question is the first-install consent instead.
    ///
    /// Read when ``RuntimeEvents`` carries `deployConfirmationPending`.
    public var hostUpdateLiveSessionCount: Int { Int(session.hostUpdateLiveSessionCount()) }

    /// The question the update with live sessions asks, verbatim.
    ///
    /// - Parameter host: What the person calls the host.
    /// - Returns: The sentence.
    public func hostUpdateSessionsQuestion(host: String) -> String {
        String(session.hostUpdateSessionsQuestion(std.string(host)))
    }

    /// Updates now by handing live sessions to the successor.
    public func updateHostNow() {
        session.updateHostNow()
    }

    /// Installs the update beside the running host; it takes over once the
    /// sessions the daemon holds have ended.
    public func updateHostWhenSessionsEnd() {
        session.updateHostWhenSessionsEnd()
    }

    /// The remote's `uname -sm` for the last install only a person can do.
    ///
    /// Read when ``RuntimeEvents`` carries `deployNeedsManualInstall`; empty
    /// when the host did not say.
    public var manualInstallPlatform: String { String(session.manualInstallPlatform()) }

    /// Whether that install is manual because automatic install is turned off,
    /// rather than because no bundled binary serves the platform.
    public var isManualInstallForSetting: Bool { session.isManualInstallForSetting() }

    /// The commands a person runs on the host to install `ubiquitty-host`,
    /// Core's for the platform ``manualInstallPlatform`` names.
    public var manualHostInstallCommands: String { String(session.manualHostInstallCommands()) }

    /// One answer a host sent back for a file this session asked it for.
    public struct RemoteFile: Sendable {
        /// Which request this answers.
        public let requestID: UInt32
        /// How the host answered: a `Protocol::Sync::FileDataStatus`, zero for
        /// the read that worked.
        public let status: UInt8
        /// The path the host echoed back. The host's own string: what the
        /// answer says it is about, shown and never written under.
        public let path: String
        /// The path this session asked for, matched to the answer by request
        /// id. A landing is named from this — the name carries the extension
        /// deciding whether the bytes reach the default handler, and a host
        /// naming the file would be making that choice for the reader who
        /// clicked.
        public let requestedPath: String
        /// The line the clicked link named, counted from 1; 0 when it named
        /// none. Carried from the ask beside ``requestedPath``.
        public let requestedLine: UInt32
        /// The column the clicked link named, counted from 1; 0 when it named
        /// none.
        public let requestedColumn: UInt32
        /// The bytes, empty unless ``status`` is zero.
        public let bytes: [UInt8]

        /// Whether the host actually read the file.
        public var isRead: Bool { status == 0 }

        /// Builds one answer.
        ///
        /// - Parameters:
        ///   - requestID: Which request this answers.
        ///   - status: How the host answered.
        ///   - path: The path the host echoed back.
        ///   - requestedPath: The path this session asked for.
        ///   - requestedLine: The line the clicked link named, or 0.
        ///   - requestedColumn: The column the clicked link named, or 0.
        ///   - bytes: What it sent.
        public init(
            requestID: UInt32,
            status: UInt8,
            path: String,
            requestedPath: String,
            requestedLine: UInt32 = 0,
            requestedColumn: UInt32 = 0,
            bytes: [UInt8]
        ) {
            self.requestID = requestID
            self.status = status
            self.path = path
            self.requestedPath = requestedPath
            self.requestedLine = requestedLine
            self.requestedColumn = requestedColumn
            self.bytes = bytes
        }
    }

    /// Asks the host for a file on its own filesystem.
    ///
    /// A path a program printed on a host names a file there, not here. The
    /// daemon confines the read to the session's own directory subtree and
    /// answers with ``RuntimeEvents/remoteFileArrived`` whatever the answer is.
    ///
    /// - Parameter path: The absolute path on the host.
    /// - Returns: The request id, or zero when this session cannot ask.
    @discardableResult
    public func requestRemoteFile(_ path: String) -> UInt32 {
        session.requestRemoteFile(std.string(path))
    }

    /// An immutable question for one file on one connected host.
    public struct FileDownloadPrompt: Identifiable {
        public let token: UInt64
        public let host: String
        public let path: String
        public var id: UInt64 { token }
    }

    /// Captures a target without sending a file request.
    public func prepareFileDownload(_ candidate: String, isURI: Bool, host: String, hostLabel: String) -> FileDownloadPrompt? {
        let token = session.prepareRemoteFileDownload(
            std.string(candidate),
            isURI ? .URI : .Path,
            std.string(host),
            std.string(hostLabel)
        )
        guard token != 0 else { return nil }
        return FileDownloadPrompt(
            token: token,
            host: String(session.pendingRemoteFileDownloadHost()),
            path: String(session.pendingRemoteFileDownloadPath())
        )
    }

    /// Identifies the live question, or zero after cancellation or reconnect.
    public var pendingFileDownloadToken: UInt64 { session.pendingRemoteFileDownloadToken() }

    /// Answers the captured question once; stale answers and cancellation send nothing.
    @discardableResult
    public func answerFileDownload(_ token: UInt64, download: Bool) -> UInt32 {
        session.answerRemoteFileDownload(token, download ? .Download : .Cancel)
    }

    /// Takes the oldest answer a host sent, removing it from the queue.
    ///
    /// Read when ``RuntimeEvents`` carries `remoteFileArrived`, until it
    /// answers nil: one event covers however many answers arrived in the pass
    /// that raised it, because the event word is coalesced and the answers are
    /// a queue. Taking rather than peeking, because an answer read twice is a
    /// file written twice.
    ///
    /// - Returns: The answer whole, or nil when none is waiting or the bytes
    ///   could not all be taken. Nil rather than a short answer, because a
    ///   caller writing one to disk would write a file the host never sent and
    ///   have no way to tell it from an empty one.
    public func takeRemoteFile() -> RemoteFile? {
        guard session.hasRemoteFile() else { return nil }
        let count = Int(session.remoteFileByteCount())
        var bytes = [UInt8](repeating: 0, count: count)
        var isWhole = true
        if count > 0 {
            let written = bytes.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress.map { Int(session.copyRemoteFileBytes($0, count)) } ?? 0
            }
            isWhole = written == count
        }
        let line = session.remoteFileRequestedLine()
        let file = RemoteFile(
            requestID: session.remoteFileRequestID(),
            status: session.remoteFileStatus(),
            path: String(session.remoteFilePath()),
            requestedPath: String(session.remoteFileRequestedPath()),
            requestedLine: line.line,
            requestedColumn: line.column,
            bytes: bytes
        )
        session.dropRemoteFile()
        return isWhole ? file : nil
    }

    /// Whether this session mirrors a host rather than a local process.
    public var isRemoteAttached: Bool {
        session.isRemoteAttached()
    }

    /// Whether the authenticated host assigns the pane's geometry to another
    /// attachment. Unknown, disconnected and local sessions return false.
    public var isRemoteGeometryOwnedElsewhere: Bool { session.isRemoteGeometryOwnedElsewhere() }

    /// Whether this session ends when the program it was launched with does.
    ///
    /// Core's answer for this session, not for the process: a window opened
    /// from a `-e` command line and a ⌘N window of the same process hold
    /// different ones.
    public var doesSessionEndWithChild: Bool {
        session.doesSessionEndWithChild()
    }

    /// The foreground process chain a title shows, as Core sampled it.
    public var processChain: String {
        String(session.processChain())
    }

    /// The same chain spelled with each program's arguments.
    public var processChainWithArguments: String {
        String(session.processChainWithArguments())
    }

    /// The foreground process's own name, without its ancestors.
    public var foregroundProcessName: String {
        String(session.foregroundProcessName())
    }

    /// The home directory the host reports for this pane; empty for a local
    /// session and before the host has said.
    public var remoteHomeDirectory: String {
        String(session.remoteHomeDirectory())
    }

    /// The home a title abbreviates this pane's directory against: the host's
    /// for a pane a host serves, the reader's for one on this machine.
    ///
    /// - Parameter localHome: The reader's home.
    /// - Returns: The home; empty for a hosted pane whose host has not said.
    public func titleHomeDirectory(localHome: String) -> String {
        String(session.titleHomeDirectory(std.string(localHome)))
    }

    /// The replica tty's basename, empty for a session with no local PTY.
    public var ttyName: String {
        String(session.ttyName())
    }

    /// The session-leader shell's name, empty before a walk has found one.
    public var shellCommandName: String {
        String(session.shellCommandName())
    }

    /// How many times the sampled process records have moved.
    ///
    /// The key a view over the process table compares against: the chain's own
    /// event fires only when the chain moves, and a reaped background job or a
    /// stopped program leaves the chain standing while the table is stale.
    public var processRecordsGeneration: UInt64 {
        session.processRecordsGeneration()
    }

    /// How this session's process ended, once it has.
    ///
    /// The title weave takes this and drops both process segments, naming the
    /// fact in their place, so a pane kept open after `exit` stops advertising
    /// a shell that has gone.
    public var sessionEnd: Ubiquitty.Title.SessionEnd {
        session.sessionEnd()
    }

    /// Hands Core the status collected after the end.
    ///
    /// Separate from the end itself because the two become knowable at
    /// different moments: end-of-file arrives when the last replica descriptor
    /// closes, and the child is reaped after that.
    public func noteSessionExitStatus(wasSignalled: Bool, code: Int32) {
        session.noteSessionExitStatus(wasSignalled, code)
    }

    /// Collects this session's exit status, for calling once it has ended.
    ///
    /// The reap that produces the number happens after the end-of-file that
    /// raised the end, so this is the step that turns "exited" into "exited 1".
    public func collectSessionExitStatus() {
        session.collectSessionExitStatus()
    }

    /// Whether this connection permits remote programs to read this Mac’s clipboard.
    public var isServingClipboardToHost: Bool {
        session.isServingClipboardToHost()
    }

    /// Whether the clipboard source is awaiting acknowledgement from the host.
    public var isClipboardRoutingPending: Bool {
        session.isClipboardRoutingPending()
    }

    public var canChangeClipboardServing: Bool {
        session.canChangeClipboardServing()
    }

    @discardableResult
    public func setClipboardServing(_ enabled: Bool) -> Bool {
        session.setClipboardServing(enabled)
    }

    /// Sends a pasted payload the host can only receive as a file.
    ///
    /// An image on the clipboard has no spelling as input bytes, so the host
    /// lands it and types the path instead. A local session answers zero:
    /// its clipboard is already on the program's machine.
    ///
    /// - Parameters:
    ///   - mime: The payload's MIME name.
    ///   - bytes: The payload.
    /// - Returns: The push's id, or zero when nothing was sent.
    @discardableResult
    public func pushPaste(mime: String, bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            session.pushPaste(std.string(mime), Ubiquitty.Runtime.PayloadSpan(buffer))
        }
    }

    /// How much of the crossing paste has left, 0 to 1, or negative when
    /// nothing is crossing or the channel cannot say.
    public var pastePushProgress: Double {
        session.pastePushProgress()
    }

    /// Where the host landed the last pushed paste, empty until one does.
    public var lastPastePushPath: String {
        String(session.lastPastePushPath())
    }

    /// The selected text, or empty when nothing is selected.
    ///
    /// - Parameter selection: The caller-owned selection session.
    /// - Returns: The text.
    // swift-only: the printer cannot represent the signature, and the only callers are in-package Swift
    package func selectedText(_ selection: UnsafeMutablePointer<Ubiquitty.Selection.Session>) -> String {
        String(session.selectedText(selection))
    }

    /// The selection as the flavours a copy writes.
    ///
    /// - Parameters:
    ///   - selection: The caller-owned selection session, borrowed for the call.
    ///   - style: The flavour the picked menu item names.
    ///   - pointSize: The em size the view draws at, zoom included.
    /// - Returns: The plain text and, for a styled flavour, the RTF and HTML
    ///   beside it; every one empty when nothing is selected.
    // swift-only: the printer cannot represent the signature, and the only callers are in-package Swift
    package func selectionClipboard(
        of selection: inout Ubiquitty.Selection.Session,
        style: Ubiquitty.Selection.CopyStyle,
        pointSize: Double
    ) -> (plain: String, rtf: String, html: String) {
        let built = session.selectionClipboard(&selection, style, pointSize)
        return (String(built.plain), String(built.rtf), String(built.html))
    }

    /// Captures and publishes the read-snapshot now, for a model written
    /// without a drain pass.
    public func republishSnapshot() {
        session.republishSnapshot()
    }

    /// Pushes the machine-wide load lever to the session's drain gate.
    ///
    /// - Parameter throttle: The machine's throttle state.
    public func setMachineThrottle(_ throttle: Ubiquitty.Runtime.MachineThrottle) {
        session.setMachineThrottle(throttle)
    }

    /// Whether the drain rides the gaps inside a burst rather than parking at
    /// the first one.
    ///
    /// The two levers above meet here and nowhere else, which makes this the
    /// one place a frontend can see what its own pushes came to: a pane that
    /// is presented on an unthrottled machine rides, and everything else
    /// parks and picks the output up on the next poll.
    public var isDrainRidingBurst: Bool {
        session.drainRidesBurst()
    }

    /// Reads the latest parser-state snapshot, lock-free.
    ///
    /// The untorn copy a frontend polls for geometry, modes and animation
    /// inputs without touching the lock a flood holds hot. Value semantics
    /// end to end: the C++ struct is all-scalar and crosses by copy.
    ///
    /// - Returns: The latest published snapshot; default-valued (rows 0)
    ///   before the first drain publishes one.
    public func readSnapshot() -> Ubiquitty.Runtime.RuntimeSnapshot {
        session.readSnapshot()
    }

    /// Passes the frontend's laid-out grid to Core for title composition.
    public func titleGrid(for laidOutGrid: (rows: Int, columns: Int)) -> (rows: Int32, columns: Int32) {
        let grid = session.titleGrid(
            Ubiquitty.Runtime.TitleGrid(rows: Int32(laidOutGrid.rows), columns: Int32(laidOutGrid.columns))
        )
        return (grid.rows, grid.columns)
    }

    /// A link found under a visible cell.
    public struct ResolvedLink {
        package init(
            uri: String,
            isHyperlink: Bool,
            isFilePath: Bool,
            rowFirst: Int32,
            rowLast: Int32,
            columnFirst: Int32,
            columnLast: Int32,
            spanColumnFirst: Int32,
            spanColumnLast: Int32,
            textDigest: UInt64,
            linkID: UInt16
        ) {
            self.uri = uri
            self.isHyperlink = isHyperlink
            self.isFilePath = isFilePath
            self.rowFirst = rowFirst
            self.rowLast = rowLast
            self.columnFirst = columnFirst
            self.columnLast = columnLast
            self.spanColumnFirst = spanColumnFirst
            self.spanColumnLast = spanColumnLast
            self.textDigest = textDigest
            self.linkID = linkID
        }

        /// The link's target, as the program declared it or as the scan read
        /// it out of the text.
        public var uri: String
        /// The program declared this with OSC 8 rather than the text merely
        /// reading like a link. A declaration opens on a plain click; a guess
        /// needs a modifier, so that the terminal never acts on its own
        /// reading of someone's output without being asked.
        public var isHyperlink: Bool
        /// A path candidate — text shaped like a path, not yet confirmed to
        /// name anything.
        public var isFilePath: Bool
        /// The run's first and last rows, in ABSOLUTE buffer rows, so an
        /// underline painted from it stays on its text as the view scrolls.
        public var rowFirst: Int32
        public var rowLast: Int32
        /// The run's first and last columns.
        public var columnFirst: Int32
        public var columnLast: Int32
        /// The columns the run was resolved inside — the pane's, not the
        /// screen's, so a wrapped run's middle rows clip to their own pane.
        public var spanColumnFirst: Int32
        public var spanColumnLast: Int32
        /// The digest of the run's text at the resolve, which a frame checks
        /// against its own cells before it emphasises the run.
        public var textDigest: UInt64
        /// The OSC 8 id the run's cells carry, or zero for a run the text scan
        /// read out of plain characters. A frame gates each cell of the run's
        /// column band on it, so blanks an `id=` reaches across stay unmarked.
        public var linkID: UInt16
    }

    /// Finds the link under a visible cell.
    ///
    /// - Parameters:
    ///   - viewOffset: Rows scrolled back from the live grid.
    ///   - row: A zero-based visible row.
    ///   - column: A zero-based column.
    ///   - scope: How much of the scan to run; a bare hover asks for
    ///     `.declared`, which is one cell read rather than a sweep of the row.
    /// - Returns: The link, or nil when the cell carries none.
    public func resolveLink(
        viewOffset: Int,
        row: Int,
        column: Int,
        scope: Ubiquitty.Screen.LinkScanScope
    ) -> ResolvedLink? {
        guard session.resolveLinkAtVisibleCell(Int32(viewOffset), Int32(row), Int32(column), scope) else {
            return nil
        }
        let uri = String(session.resolvedLinkURI())
        guard !uri.isEmpty else { return nil }
        return ResolvedLink(
            uri: uri,
            isHyperlink: session.resolvedLinkIsHyperlink(),
            isFilePath: session.resolvedLinkIsFilePath(),
            rowFirst: session.resolvedLinkRowFirst(),
            rowLast: session.resolvedLinkRowLast(),
            columnFirst: session.resolvedLinkColumnFirst(),
            columnLast: session.resolvedLinkColumnLast(),
            spanColumnFirst: session.resolvedLinkSpanColumnFirst(),
            spanColumnLast: session.resolvedLinkSpanColumnLast(),
            textDigest: session.resolvedLinkTextDigest(),
            linkID: session.resolvedLinkID()
        )
    }

    /// How many link scans have run at the widening scope; see
    /// ``Ubiquitty/Runtime/TerminalSession/wideLinkScanCount``.
    package var wideLinkScanCount: UInt64 { session.wideLinkScanCount() }

    /// What a [keys] binding asked for, once one matched.
    public struct ResolvedBinding {
        /// The action's kind, as `Input::ActionKind` numbers them.
        public var kind: UInt8
        /// A send-bytes payload, escapes already resolved.
        public var bytes: [UInt8]
        /// A named command's identifier, or a macro's name.
        public var name: String

        /// Resolves an action token through the same Core parser used by key bindings.
        ///
        /// - Parameter token: A configured action name or payload.
        /// - Returns: The parsed action, or nil for an invalid token.
        public static func named(_ token: String) -> ResolvedBinding? {
            let action = Ubiquitty.Input.parseAction(std.string(token))
            guard action.valid() else { return nil }
            return ResolvedBinding(
                kind: UInt8(action.kind.rawValue),
                bytes: (0..<action.bytes.size()).map { UInt8(bitPattern: action.bytes[$0]) },
                name: String(action.name)
            )
        }
    }

    /// Rebuilds the binding table from the live [keys] config.
    public func rebuildKeyBindings() {
        session.rebuildKeyBindings()
    }

    /// Offers a key chord to the user's bindings.
    ///
    /// - Parameters:
    ///   - key: The chord's key, as `Input::resolveChordKey` spells it.
    ///   - modifiers: The chord's modifiers, masked to `bindModMask`.
    /// - Returns: The action when one fired; nil when the key is unbound or
    ///   was swallowed by a chord in progress — which the caller distinguishes
    ///   with ``isChordPending``.
    public func feedKeyChord(key: UInt32, modifiers: UInt32) -> ResolvedBinding? {
        let outcome = session.feedKeyChord(key, modifiers)
        isChordPending = outcome == .pending
        guard outcome == .matched else { return nil }
        let payload = session.resolvedBindingBytes()
        let bytes = (0..<payload.size()).map { UInt8(bitPattern: payload[$0]) }
        return ResolvedBinding(
            kind: session.resolvedBindingKind(),
            bytes: bytes,
            name: String(session.resolvedBindingName())
        )
    }

    /// Whether a `[keys] compose_key` is configured.
    ///
    /// Asked before the chord is built, because building one is a layout query
    /// per keystroke and the configuration with no compose key should not pay
    /// it.
    public var isComposeArmed: Bool {
        session.isComposeArmed()
    }

    /// Offers a key press to the compose path.
    ///
    /// - Parameters:
    ///   - key: The chord's key, as `Input::resolveChordKey` spells it.
    ///   - modifiers: The chord's modifiers, masked to `bindModMask`.
    ///   - typedCodePoint: The character the key produced, zero when it
    ///     produced none.
    /// - Returns: What the frontend should do with the key.
    public func offerKeyToCompose(
        key: UInt32,
        modifiers: UInt32,
        typedCodePoint: UInt32
    ) -> Ubiquitty.Input.ComposeAction {
        session.offerKeyToCompose(key, modifiers, typedCodePoint)
    }

    /// The composed code point, read after `ComposeAction.write`.
    public var composedCharacter: UInt32 {
        session.composedCharacter()
    }

    /// Whether the last chord offered was swallowed by a leader in progress.
    ///
    /// Read straight after ``feedKeyChord(key:modifiers:)``: a pending chord
    /// and an unbound key both answer nil there, and they ask opposite things
    /// of the caller — one spends the key, the other passes it on.
    public private(set) var isChordPending = false

    /// Offers a key chord to the built-in default bindings.
    ///
    /// Asked where the user's table declined: the key-equivalent pass, which
    /// runs while an overlay owns the responder chain. Which defaults still
    /// stand against the user's [keys] table is Core's decision.
    ///
    /// - Parameters:
    ///   - key: The chord's key, as `Input::resolveChordKey` spells it.
    ///   - modifiers: The chord's modifiers, masked to `bindModMask`.
    /// - Returns: The action a default claims the chord for, or nil when none
    ///   does.
    public func feedDefaultKeyChord(key: UInt32, modifiers: UInt32) -> ResolvedBinding? {
        guard session.feedDefaultKeyChord(key, modifiers) else { return nil }
        // A default carries no payload: the catalog holds kinds, and only a
        // user's `send:` spec has bytes.
        return ResolvedBinding(kind: session.resolvedBindingKind(), bytes: [], name: "")
    }

    /// Performs a local soft reset — the manual DECSTR.
    public func softResetTerminal() {
        session.softResetTerminal()
    }

    /// Whether the shell's marks yield a last-command-output region.
    ///
    /// Separate from the selecting call because a menu has to know whether
    /// picking the item would do anything before the user picks it.
    public var hasLastCommandOutput: Bool {
        session.hasLastCommandOutput()
    }

    /// Selects the last command's output.
    ///
    /// - Parameter selection: The view's selection to write.
    /// - Returns: Whether one was found.
    @discardableResult
    public func selectLastCommandOutput(
        into selection: inout Ubiquitty.SelectionState
    ) -> Bool {
        session.selectLastCommandOutput(&selection)
    }

    /// The absolute row a visible row reads from, at one view offset.
    ///
    /// - Parameters:
    ///   - visibleRow: A zero-based row of the visible grid.
    ///   - viewOffset: The offset the view is holding.
    /// - Returns: The absolute row, or -1 with no model to read.
    public func absoluteRow(forVisibleRow visibleRow: Int, viewOffset: Int) -> Int {
        Int(session.absoluteRowForVisibleRow(Int32(visibleRow), Int32(viewOffset)))
    }

    /// Whether the pointer sits where there is nothing to select.
    ///
    /// Tried rather than waited for, so a flood cannot starve the pointer:
    /// a contended read answers `.unknown` and the caller keeps the
    /// affordance it has.
    ///
    /// - Parameters:
    ///   - visibleRow: The pointer's row, zero-based in the viewport.
    ///   - column: The pointer's column.
    ///   - viewOffset: Rows the viewport is scrolled back.
    /// - Returns: What is under the pointer, or that it could not be read.
    public func pointerTextVoid(
        visibleRow: Int,
        column: Int,
        viewOffset: Int
    ) -> Ubiquitty.Runtime.TerminalSession.TextVoidAnswer {
        session.pointerTextVoid(Int32(visibleRow), Int32(column), Int32(viewOffset))
    }

    /// Whether an executed command sits at or above one row.
    ///
    /// Separate from the selecting calls because a menu decides whether its
    /// item is enabled before the user picks it.
    ///
    /// - Parameter absoluteRow: The row, in absolute buffer coordinates.
    /// - Returns: Whether a command was found.
    public func hasCommand(underAbsoluteRow absoluteRow: Int) -> Bool {
        session.hasCommandUnderRow(Int32(absoluteRow))
    }

    /// Selects the command line of the command under one row.
    ///
    /// - Parameters:
    ///   - absoluteRow: The row, in absolute buffer coordinates.
    ///   - selection: The view's selection to write.
    /// - Returns: Whether a command was found.
    @discardableResult
    public func selectCommandLine(
        underAbsoluteRow absoluteRow: Int,
        into selection: inout Ubiquitty.SelectionState
    ) -> Bool {
        session.selectCommandLineUnderRow(Int32(absoluteRow), &selection)
    }

    /// Selects the output of the command under one row.
    ///
    /// - Parameters:
    ///   - absoluteRow: The row, in absolute buffer coordinates.
    ///   - selection: The view's selection to write.
    /// - Returns: Whether a command with output was found.
    @discardableResult
    public func selectCommandOutput(
        underAbsoluteRow absoluteRow: Int,
        into selection: inout Ubiquitty.SelectionState
    ) -> Bool {
        session.selectCommandOutputUnderRow(Int32(absoluteRow), &selection)
    }

    /// Hands the focused search match over as a real text selection.
    ///
    /// - Parameter selection: The view's selection to write.
    /// - Returns: Whether a match was handed over.
    @discardableResult
    public func handOffActiveSearchMatch(
        into selection: inout Ubiquitty.SelectionState
    ) -> Bool {
        session.handOffActiveSearchMatch(&selection)
    }

    /// Records a user-initiated input event for the cursor's activity freeze.
    ///
    /// The caret holds solid for a moment after each keystroke rather than
    /// blinking through the text being typed. Core owns the hold and its
    /// duration; a frontend owes it only the fact that input happened, from
    /// its keyboard and pointer handlers.
    public func noteUserActivity() {
        session.noteUserActivity()
    }

    /// Runs a clear command against this session's model.
    ///
    /// The command is named by Core's own enum rather than one restated here:
    /// which gesture destroys what is a product decision, and a frontend that
    /// keeps its own copy of it is a frontend that can disagree with the
    /// others about what Cmd-K means.
    ///
    /// - Parameters:
    ///   - command: Which clear the user asked for.
    ///   - selection: The view's selection, dropped when the rows it names go.
    /// - Returns: Whether the viewport must return to the live tail. False
    ///   when the command handed off to a program that owns the layout.
    @discardableResult
    public func runClearCommand(
        _ command: Ubiquitty.Screen.ClearCommand,
        droppingSelection selection: inout Ubiquitty.SelectionState
    ) -> Bool {
        session.runClearCommand(command, &selection)
    }

    /// The session's Terminal, for the renderer's capture.
    ///
    /// A `Ubiquitty.Terminal` rather than any pointer shape: Core imports the
    /// Terminal as a reference Swift does not manage, so the borrow crosses as
    /// the type itself and no caller ever sees an address. Safety is the
    /// caller's lock bracket: a single-threaded caller has a trivial one, and
    /// a live drive brackets with the same lock its feed thread holds.
    ///
    /// - Returns: The Terminal, or nil before the model exists.
    public func borrowTerminal() -> Ubiquitty.Terminal? {
        session.terminal()
    }

    /// The cells a proportional run needs, as a `q=1` query would be
    /// answered: through the installed measurer, else the grid face.
    ///
    /// Under the read lock, which the caller holds.
    ///
    /// - Parameter codePoints: The run's text.
    /// - Returns: The cell count, or -1 without a terminal.
    public func measureProportionalRunCells(_ codePoints: [UInt32]) -> Int {
        codePoints.withUnsafeBufferPointer { buffer in
            Int(session.proportionalRunCells(Ubiquitty.Runtime.TerminalSession.CodePointSpan(buffer)))
        }
    }

    /// Installs a proportional-text measurer on the model, or removes it.
    ///
    /// - Parameters:
    ///   - measure: The measurer, or nil to uninstall.
    ///   - context: What the measurer reads; it must outlive the installation.
    // swift-only: the printer cannot represent the C function pointer alias, and the surface is the one caller
    package func setTextMeasurer(
        _ measure: Ubiquitty.Runtime.TerminalSession.TextMeasureFunction?,
        richText: Ubiquitty.RichText.Shaper.Function?,
        fontCatalog: Ubiquitty.RichText.FontCatalogProvider.Function?,
        context: UnsafeMutableRawPointer?
    ) {
        session.setTextMeasurer(measure, context)
        session.setRichTextShaper(richText, context)
        session.setFontCatalogProvider(fontCatalog, context)
    }

    /// Publishes the renderer's typography table to the model terminal
    /// (Docs/rich-text.md), and to the host of a remote pane.
    ///
    /// - Parameter builder: The table, filled face by face.
    // swift-only: the generated C++ header drops this package helper, and only Swift callers publish through it
    package func publishTypography(_ builder: Ubiquitty.RichText.TypographyFactsBuilder) {
        _ = session.publishTypographyFrom(builder)
    }

    /// Publishes the frontend's ready inventory fact and asks Core whether a frame changed.
    package func fontCatalogBecameReady(_ generation: UInt64, _ rendererRevision: UInt64) -> Bool {
        session.fontCatalogBecameReady(generation, rendererRevision)
    }

    /// Applies the config's `[security]` switches to the model, under the
    /// model lock; see ``Ubiquitty/Runtime/TerminalSession/applyTerminalPreferences``.
    ///
    /// - Parameter config: The config fold as it stands.
    public func applyTerminalPreferences(_ config: Ubiquitty.Preferences.Values) {
        session.applyTerminalPreferences(config)
    }

    /// Applies the cursor preferences after the reader picked a shape, handing
    /// the style back to them; see
    /// ``Ubiquitty/Runtime/TerminalSession/applyPickedCursorPreferences``.
    ///
    /// - Parameter config: The config fold as it stands, the pick already in it.
    public func applyPickedCursorPreferences(_ config: Ubiquitty.Preferences.Values) {
        session.applyPickedCursorPreferences(config)
    }

    /// Re-derives the palette from the launch theme under the current
    /// adaptation; see ``Ubiquitty/Runtime/TerminalSession/reseedLaunchTheme``.
    ///
    /// - Parameter config: The resolved config the theme ladder reads.
    /// - Returns: Whether a model existed to re-seed.
    @discardableResult
    public func reseedLaunchTheme(_ config: Ubiquitty.Preferences.Values) -> Bool {
        session.reseedLaunchTheme(config)
    }

    /// Captures the portable facts displayed by a session inspector.
    // swift-only: the inspector consumes this snapshot in Swift; no C++ caller needs a generated thunk.
    package func inspectorInfo() -> Ubiquitty.Session.SessionInfo {
        session.inspectorInfo()
    }

    /// The local session's answerback label, with concealment applied by Core.
    package var inspectorAnswerbackDisplay: String { String(session.inspectorAnswerbackDisplay()) }

    /// Replaces the local session's answerback from the inspector.
    /// - Parameter value: The user-entered message.
    /// - Returns: Whether the owning session accepted the replacement.
    package func setInspectorAnswerback(_ value: String) -> Bool {
        session.setInspectorAnswerback(std.string(value))
    }

    /// Finds the theme matching the session's authoritative reset baseline.
    ///
    /// - Returns: The catalog index, or -1 for a custom palette.
    package func currentThemeIndex() -> Int32 {
        session.currentThemeIndex()
    }

    /// The status colours of this session's theme, with the ones its file names.
    public func statusColors() -> Ubiquitty.Themes.StatusColors {
        session.statusColors()
    }

    /// The colour of the tab status this session publishes, under its theme;
    /// `isSet` is false for none.
    public func tabStatusColor() -> Ubiquitty.Runtime.TabStatusColor {
        session.tabStatusColor()
    }

    /// Reports whether the session owns directory metadata that can be reset.
    package var canClearReportedDirectory: Bool {
        session.canClearReportedDirectory()
    }

    /// Resets the shell's reported directory while retaining process cwd fallback.
    ///
    /// - Returns: Whether the session cleared a report.
    package func clearReportedDirectory() -> Bool {
        session.clearReportedDirectory()
    }

    /// Routes an inspector signal to the session backend.
    ///
    /// - Parameters:
    ///   - processID: The process selected from the snapshot.
    ///   - signal: The native signal number.
    /// - Returns: Whether the backend delivered the signal.
    package func signalInspectedProcess(_ processID: UInt32, signal: Int32) -> Bool {
        session.signalInspectedProcess(processID, signal)
    }

    /// Reports whether the session's background has a custom override.
    package var canResetBackground: Bool {
        session.canResetBackground()
    }

    /// Restores the exact background held by the session's reset baseline.
    ///
    /// - Returns: Whether the session accepts the reset.
    package func resetBackground() -> Bool {
        session.resetBackground()
    }

    /// Applies an inspector's background color to the session.
    ///
    /// - Parameters:
    ///   - red: The red component.
    ///   - green: The green component.
    ///   - blue: The blue component.
    /// - Returns: Whether the session accepts the background change.
    @discardableResult
    package func setInspectorBackground(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        session.setInspectorBackground(red, green, blue)
    }

    /// Reads the model's current OSC title.
    ///
    /// The title arrives as an event flag carrying no payload, so a host told
    /// the title changed still has to come and get it. Read under the model
    /// lock: the ingest thread rewrites its owned UTF-8 storage, and copying
    /// it unlocked races a resize that reallocates it.
    ///
    /// - Returns: The title, or nil before the model exists.
    public func currentTitle() -> String? {
        lockForRead()
        defer { unlockForRead() }
        guard let term = borrowTerminal() else { return nil }
        return String(term.titleUTF8.copyToString())
    }

    /// Reads the working directory the session reported (OSC 7, OSC 633 Cwd,
    /// OSC 1337 CurrentDir).
    ///
    /// Under the model lock, for the reason ``currentTitle()`` is: the string
    /// is rewritten in place by the ingest thread.
    ///
    /// - Returns: The directory, empty when none was reported, or nil before
    ///   the model exists.
    public func currentDirectory() -> String? {
        lockForRead()
        defer { unlockForRead() }
        guard borrowTerminal() != nil else { return nil }
        return String(session.currentDirectory())
    }

    /// Reads the directory a title names: where the session is, which while a
    /// connection holds the terminal is only what its far side reported
    /// (Core's `Title::titleDirectory`). A new tab and a link's base read
    /// ``currentDirectory()``.
    ///
    /// Under the model lock, for the reason ``currentDirectory()`` is.
    ///
    /// - Returns: The directory, empty when the title names none, or nil
    ///   before the model exists.
    public func titleDirectory() -> String? {
        lockForRead()
        defer { unlockForRead() }
        guard borrowTerminal() != nil else { return nil }
        return String(session.titleDirectory())
    }

    /// The whole of what the pane's status says, as Core composes, bounds and
    /// cleans it: a tab's hover text. The published snapshot's
    /// `statusHelpDigest` moves when this does.
    ///
    /// - Returns: The text, empty when the pane reports no status.
    public func statusHelpText() -> String {
        lockForRead()
        defer { unlockForRead() }
        guard borrowTerminal() != nil else { return "" }
        return String(session.statusHelpText())
    }

    /// What the pane's program says it is doing, whole, as Core cleans it:
    /// the record's title and message, without the name, state or percent its
    /// status symbol carries. The published snapshot's `statusHelpDigest`
    /// moves when this does.
    ///
    /// - Returns: The text, empty when the pane reports no status or its
    ///   record says nothing.
    public func programActivityText() -> String {
        lockForRead()
        defer { unlockForRead() }
        guard borrowTerminal() != nil else { return "" }
        return String(session.programActivityText())
    }

    /// The program the pane runs, for the icon a title draws before its name:
    /// the one its status record names, and failing that its foreground
    /// process. Takes no lock, as `processChain` takes none, so the title
    /// weave can read it on every screen update.
    ///
    /// - Parameter published: The pane's published snapshot.
    /// - Returns: The program's catalog key, empty for a pane running none.
    public func processIconKey(_ published: Ubiquitty.Runtime.RuntimeSnapshot) -> String {
        String(session.processIconKey(published.reportedProcessIcon))
    }

    /// Every source on this side that can say where the session is — the
    /// transport stamp, the process walk and the far side's report — for
    /// Core's `Session::resolvePaneHost` to rank.
    ///
    /// - Returns: The sources.
    public func locationInputs() -> Ubiquitty.Session.LocationInputs {
        session.locationInputs()
    }

    /// The number of window-size deliveries to this session's local stream.
    package var windowSizeDeliveryCount: UInt64 { session.windowSizeDeliveryCount() }

    /// Returns the session's local folder, or an empty string for remote locations.
    public func representedLocalDirectory() -> String {
        lockForRead()
        defer { unlockForRead() }
        return String(session.representedLocalDirectory())
    }

    /// Reads the focused document the session reported (OSC 6).
    ///
    /// Under the model lock, for the reason ``currentDirectory()`` is: the
    /// string is rewritten in place by the ingest thread.
    ///
    /// - Returns: The URL verbatim, empty when none was reported, or nil
    ///   before the model exists.
    public func currentFileURL() -> String? {
        lockForRead()
        defer { unlockForRead() }
        guard let term = borrowTerminal() else { return nil }
        return String(term.currentFileURL.copyToString())
    }

    /// Resizes the model's grid.
    ///
    /// Forwards to the session, which decides whether history rewraps —
    /// that turns on what the foreground process is — so a frontend never
    /// spells a reflow decision of its own. What it does say is which
    /// gesture the resize belongs to, because only the frontend knows
    /// whether a drag is still in progress.
    ///
    /// - Parameters:
    ///   - rows: The new row count.
    ///   - columns: The new column count.
    ///   - gesture: Whether this is one step of a live drag.
    ///   - anchor: Which edge of the grid stays put; the top unless the
    ///     drag's stationary edge is the bottom one.
    ///   - widthInPixels: The text area's width in pixels, carried into the
    ///     same winsize as the grid so the child sees one resize; zero when
    ///     the caller reports no extent.
    ///   - heightInPixels: The text area's height in pixels, likewise.
    public func resize(
        rows: Int,
        columns: Int,
        gesture: Ubiquitty.Runtime.TerminalSession.ResizeGesture = .settled,
        anchor: Ubiquitty.Modes.AnchorMode = .top,
        widthInPixels: Int = 0,
        heightInPixels: Int = 0
    ) {
        session.resize(Int32(rows), Int32(columns), gesture, anchor, Int32(widthInPixels), Int32(heightInPixels))
    }

    /// Stamps host-output activity for the pacing policy.
    ///
    /// The drains stamp themselves; this is for a frontend's own reason to keep
    /// painting, where output is not what changed.
    public func notePresentationActivity() {
        session.notePresentationActivity()
    }

    /// Whether frames are being driven on a clock right now.
    ///
    /// A caller seeing output while this is false takes the idle-to-active edge
    /// and resumes: the stamp that would have returned that edge happens on the
    /// ingest thread, where no frontend is listening.
    public var isPresentationContinuous: Bool {
        session.isPresentationContinuous()
    }

    /// Whether host output has been idle past the driver's timeout.
    public var isPresentationIdleExpired: Bool {
        session.isPresentationIdleExpired()
    }

    /// Publishes how frames are being driven.
    ///
    /// - Parameter mode: What the frontend is doing now.
    public func setPresentationMode(_ mode: Ubiquitty.Runtime.FrameMode) {
        session.setPresentationMode(mode)
    }

    /// Enables the screen-change-rate recommendation. Off,
    /// isPresentationRecommendedContinuous is always true.
    public func setAdaptivePresentation(_ drive: Ubiquitty.Runtime.AdaptiveDrive) {
        session.setAdaptivePresentation(drive)
    }

    /// Whether adaptive presentation is enabled.
    public var isAdaptivePresentation: Bool {
        session.isAdaptivePresentation()
    }

    /// Feeds the presentation driver the resolved panel frame interval (1/rate).
    public func setPresentationFrameIntervalSeconds(_ seconds: Double) {
        session.setPresentationFrameIntervalSeconds(seconds)
    }

    /// Whether the screen-change rate warrants continuous drive as of now.
    public var isPresentationRecommendedContinuous: Bool {
        session.isPresentationRecommendedContinuous()
    }

    /// Whether the drain's last pass filled its capacity, so the writer is
    /// ahead and each pass publishes its own frame into the sync slot.
    public var isDrainSaturated: Bool {
        session.isDrainSaturated()
    }

    /// The adaptive drain streak, for a debug readout.
    public var presentationFastDrainStreak: Int {
        Int(session.presentationFastDrainStreak())
    }

    /// The frame interval the adaptive estimate measures against; 0 until sourced.
    public var presentationFrameIntervalSeconds: Double {
        session.presentationFrameIntervalSeconds()
    }

    /// Stamps a rendered frame that changed pixels, for the adaptive rate estimate.
    public func notePresentationNetChange() {
        session.notePresentationNetChange()
    }

    /// Whether this present should wait: a synchronized-output block is
    /// open, or a whole-screen erase's redraw is still arriving.
    public func shouldWithholdFrame(nowTicks: UInt32) -> Bool {
        session.shouldWithholdFrame(Ubiquitty.Ticks(nowTicks))
    }

    /// The capture's recheck under the model lock it holds: a block the
    /// parser opened, or a screen it erased, since the published check.
    public func shouldWithholdCapture(_ terminal: Ubiquitty.Terminal, nowTicks: UInt32) -> Bool {
        session.shouldWithholdCapture(terminal, Ubiquitty.Ticks(nowTicks))
    }

    /// The live-resize capture's check under the model lock it holds: the
    /// redraw behind the newest whole-screen erase has not been parsed whole.
    ///
    /// - Parameter terminal: The model, borrowed under the caller's lock.
    /// - Returns: True while the capture would show the erased screen.
    public func isEraseRedrawArriving(_ terminal: Ubiquitty.Terminal) -> Bool {
        session.isEraseRedrawArriving(terminal)
    }

    /// Tells the drain whether a live resize is in progress, so that it takes
    /// no frame of a redraw still arriving behind a whole-screen erase while
    /// the resize's capture holds that redraw back.
    ///
    /// - Parameter resize: Whether a live resize is in progress.
    public func setLiveResize(_ resize: Ubiquitty.Runtime.LiveResize) {
        session.setLiveResize(resize)
    }

    /// Ticks until a withheld present may release on its own; 0 when none is held.
    public func presentationHoldTicksRemaining(nowTicks: UInt32) -> UInt32 {
        session.presentationHoldTicksRemaining(Ubiquitty.Ticks(nowTicks))
    }

    /// Plans a live frame against the baseline the boundary captures share.
    /// Caller holds the model lock (inside `withTerminal`).
    public func planRetainedFrame(
        _ terminal: Ubiquitty.Terminal,
        _ request: Ubiquitty.Rendering.RetainedFrameRequest,
        _ rowDirty: Ubiquitty.Rendering.RowDirtySpan
    ) -> Ubiquitty.Rendering.RetainedFramePlan {
        session.planRetainedFrame(terminal, request, rowDirty)
    }

    /// Plans a skipped grid frame against the baseline the boundary captures
    /// share -- the frame-skip gate's path. Caller holds the model lock.
    public func planSkippedGridFrame(
        _ terminal: Ubiquitty.Terminal,
        _ request: Ubiquitty.Rendering.RetainedFrameRequest,
        _ rowDirty: Ubiquitty.Rendering.RowDirtySpan
    ) -> Ubiquitty.Rendering.RetainedFramePlan {
        session.planSkippedGridFrame(terminal, request, rowDirty)
    }

    /// Invalidates the shared baseline; the next frame on either route is Full.
    public func invalidateRetainedFrame(_ terminal: Ubiquitty.Terminal) {
        session.invalidateRetainedFrame(terminal)
    }

    /// Retunes the sync-publish throttle to the presentation refresh interval.
    public func setSyncPublishRefreshSeconds(_ seconds: Double) {
        session.setSyncPublishRefreshSeconds(seconds)
    }

    /// Whether a history rewrap is owed at the current width.
    ///
    /// True between a drag step that changed the width and the settle that
    /// pays for it.
    public var hasDeferredHistoryRewrap: Bool {
        session.hasDeferredHistoryRewrap()
    }

    /// Pays for the history rewrap a live drag deferred.
    ///
    /// Called once when the drag settles: the rewrap is proportional to the
    /// scrollback, and the widths in between are ones nobody asked to read
    /// at.
    public func settleResize() {
        session.settleResize()
    }

    /// Takes the model lock, for a read whose bracket spans call boundaries.
    ///
    /// ``withRenderLock(_:)`` is the shape to prefer; this pair exists for a
    /// caller whose lock and unlock live in different methods — the ObjC++
    /// view's imperative lock discipline — and carries the same rule: every
    /// take is matched by exactly one ``unlockForRead()``.
    public func lockForRead() {
        session.lockForRead()
    }

    /// Releases the model lock taken by ``lockForRead()``.
    public func unlockForRead() {
        session.unlockForRead()
    }

    /// The model lock's address, for the ObjC++ adoption seam.
    ///
    /// A render adapter over this session's Terminal brackets with the same
    /// mutex the drain bites; the address crosses as a number because Swift
    /// has no business dereferencing or retyping it — the one consumer is
    /// the bridge's adopt call, which casts it back on the side where the
    /// type lives. Valid as long as the drive.
    public func modelLockAddress() -> UInt {
        UInt(session.modelLockAddressForAdoption())
    }

    /// Tries the model lock without waiting.
    ///
    /// For the per-drain and per-move paths where blocking starves the main
    /// thread under a flood; the session states the discipline. A true
    /// return pairs with ``unlockForRead()``.
    ///
    /// - Returns: Whether the lock was taken.
    public func tryLockForRead() -> Bool {
        session.tryLockForRead()
    }

    /// Launches the user's login shell.
    ///
    /// The ingest loop is Core's, not started here: the poll-and-drain loop
    /// the Metal arm tuned — the spin-before-poll bands, the self-pipe in the
    /// poll set, the burst ride — is measured work this drive consumes rather
    /// than re-derives.
    ///
    /// - Returns: Whether the PTY opened.
    public func launchLoginShell() -> Bool {
        session.launchLoginShell()
    }

    /// Launches the user's login shell in a chosen working directory.
    ///
    /// The directory is how a split inherits the focused pane's cwd; empty
    /// falls back to the shell's own default.
    ///
    /// - Parameter initialDirectory: The working directory, or empty.
    /// - Returns: Whether the PTY opened.
    public func launchLoginShell(initialDirectory: String) -> Bool {
        session.launchLoginShell(std.string(initialDirectory))
    }

    /// Publishes the window's cell and pixel extent to the host.
    ///
    /// For the moments the pixel extent is the news — right after launch and
    /// on a backing-scale change; ``resize(rows:columns:)`` covers the
    /// steady-state pair. Applications read the pixel fields for image
    /// geometry.
    ///
    /// - Parameters:
    ///   - columns: The grid's columns.
    ///   - rows: The grid's rows.
    ///   - widthInPixels: The text area's width in pixels.
    ///   - heightInPixels: The text area's height in pixels.
    public func setWindowSize(columns: Int, rows: Int, widthInPixels: Int, heightInPixels: Int) {
        session.setWindowSize(Int32(columns), Int32(rows), Int32(widthInPixels), Int32(heightInPixels))
    }

    /// Publishes the cell's and the text area's device-pixel sizes to the
    /// model; see ``Ubiquitty/Runtime/TerminalSession/publishCellPixelSize``.
    ///
    /// - Parameters:
    ///   - cellWidthInPixels: One cell's width in device pixels.
    ///   - cellHeightInPixels: One cell's height in device pixels.
    ///   - textAreaWidthInPixels: The grid's width in device pixels.
    ///   - textAreaHeightInPixels: The grid's height in device pixels.
    ///   - drawableWidthInPixels: The whole drawable's width, padding included;
    ///     what a program measures under DECSET 7402.
    ///   - drawableHeightInPixels: The whole drawable's height.
    public func publishCellPixelSize(
        cellWidthInPixels: Int,
        cellHeightInPixels: Int,
        textAreaWidthInPixels: Int,
        textAreaHeightInPixels: Int,
        drawableWidthInPixels: Int,
        drawableHeightInPixels: Int
    ) {
        session.publishCellPixelSize(
            Int32(cellWidthInPixels),
            Int32(cellHeightInPixels),
            Int32(textAreaWidthInPixels),
            Int32(textAreaHeightInPixels),
            Int32(drawableWidthInPixels),
            Int32(drawableHeightInPixels)
        )
    }

    /// Launches one shell command.
    ///
    /// - Parameter command: The command line, run under the shell.
    /// - Returns: Whether the PTY opened.
    public func launchShellCommand(_ command: String) -> Bool {
        session.launchShellCommand(std.string(command))
    }

    /// Starts the session's ingest thread over its transport.
    ///
    /// The loop is Core's extracted one; the session owns the thread. Events
    /// arrive as flags this drive reads once per interest, and the sync-frame
    /// signal through ``takeSyncFrameReady()``.
    ///
    /// - Returns: Whether the loop started; false with no pollable transport.
    public func startIngest() -> Bool {
        session.startIngest()
    }

    /// Stops the ingest thread and joins it. Idempotent.
    public func stopIngest() {
        session.stopIngest()
    }

    /// Returns and clears the session's coalesced event flags.
    ///
    /// Each event is seen once and none twice, which is the one-pass-per-drain
    /// delegate discipline kept as a read.
    public func takeEvents() -> RuntimeEvents {
        RuntimeEvents(rawValue: session.takeEventFlags())
    }

    /// Returns and clears the coalesced event bits, raw, for the ObjC++
    /// funnel — the bit layout is Core's `EventKind`, the same one
    /// ``takeEvents()`` types for Swift callers.
    public func takeEventBits() -> UInt32 {
        session.takeEventFlags()
    }

    /// Installs the coalesced signal called by event producers. Clearing it
    /// waits for active calls before the caller releases their context.
    ///
    /// Both addresses cross as integers because a function-pointer parameter
    /// is dropped from the generated C++ surface entirely; the session casts
    /// them back on the side where the types live, and this file never
    /// interprets either.
    ///
    /// - Parameters:
    ///   - context: The context's address, handed back to every call.
    ///   - function: The signal function's address, or zero to leave quiet.
    public func setDrainSignal(context: UInt, function: UInt) {
        session.setDrainSignalRaw(context, function)
    }

    /// Returns and clears the total bytes the ingest loop has drained.
    ///
    /// A monotonic tap for a smoke or a bench; the per-pass outcome stays on
    /// the loop's thread.
    public func takeDrainedBytes() -> UInt64 {
        session.takeDrainedBytes()
    }

    /// Starts tallying ingest deliveries for the perf log; see
    /// ``takePerfDrainTally()``.
    package func startTallyingPerfDrains() {
        session.startTallyingPerfDrains()
    }

    /// Returns and clears the deliveries tallied since the last take: their
    /// bytes, their count, and their parse time summed and at its longest.
    // swift-only: the nested tally is read only by in-package Swift frame diagnostics
    package func takePerfDrainTally() -> Ubiquitty.Runtime.TerminalSession.PerfDrainTally {
        session.takePerfDrainTally()
    }

    /// Brackets a render capture with the same lock the drain bites.
    ///
    /// - Parameter body: The read to run under the model lock.
    /// - Returns: Whatever the read returns.
    public func withRenderLock<Result>(_ body: () -> Result) -> Result {
        session.lockForRead()
        defer { session.unlockForRead() }
        return body()
    }

    /// Borrows the terminal for exactly one scoped read, under the model
    /// lock.
    ///
    /// The structural form of lock–borrow–unlock: the lock cannot leak past
    /// the borrow, and the borrow cannot escape the lock — the two mistakes
    /// the manual bracket invites. Rethrows and stays generic so a caller's
    /// error and result types pass through untouched.
    ///
    /// - Parameter body: The read to run against the borrowed terminal.
    /// - Returns: The body's result, or nil when the session lends no
    ///   terminal.
    @discardableResult
    // swift-only: the printer cannot represent the signature, and the only callers are in-package Swift
    package func withTerminal<Result>(_ body: (Ubiquitty.Terminal) throws -> Result) rethrows -> Result? {
        session.lockForRead()
        defer { session.unlockForRead() }
        guard let terminal = session.terminal() else {
            return nil
        }
        return try body(terminal)
    }

    /// The non-blocking twin of ``withTerminal(_:)``: a busy lock answers
    /// absent rather than waiting, which is what a read racing a flood wants.
    ///
    /// - Parameter body: The read to run against the borrowed terminal.
    /// - Returns: The body's result, or nil when the lock is busy or the
    ///   session lends no terminal.
    @discardableResult
    // swift-only: the printer cannot represent the signature, and the only callers are in-package Swift
    package func withTerminalIfIdle<Result>(_ body: (Ubiquitty.Terminal) throws -> Result) rethrows -> Result? {
        guard session.tryLockForRead() else {
            return nil
        }
        defer { session.unlockForRead() }
        guard let terminal = session.terminal() else {
            return nil
        }
        return try body(terminal)
    }

    /// Starts or stops appending every byte this session ingests to a file.
    ///
    /// Taken under the model lock. The ingest thread writes the open log from
    /// inside its locked parse, so an open or a close outside that lock could
    /// close the file under a write in flight — a write into a closed stream,
    /// or a log torn mid-chunk.
    ///
    /// - Parameter path: The file to append to, or nil to close the log.
    /// - Returns: Whether the file opened or the log closed; false when the
    ///   file cannot be opened or the session lends no terminal.
    @discardableResult
    public func setSessionLogPath(_ path: String?) -> Bool {
        withTerminal { terminal in
            guard let path else {
                return Ubiquitty.setSessionLogPath(terminal, nil)
            }
            return path.withCString { Ubiquitty.setSessionLogPath(terminal, $0) }
        } ?? false
    }

    /// Disposes the model and closes any owned stream. Idempotent.
    public func close() {
        session.close()
    }

    /// Ends the remote half and keeps the terminal, so the surface can attach
    /// again. Idempotent.
    public func detachRemote() {
        session.detachRemote()
    }

    /// Sends everything this session writes to the host to `handler` while it
    /// has no stream of its own.
    ///
    /// An embedder that feeds the host's bytes in with ``feed(_:)`` owns the
    /// way back: the DA, cursor-position and colour reports those bytes
    /// provoke reach `handler` on the feeding thread before `feed` returns,
    /// and input — keys, pastes, and the button and wheel reports the pointer
    /// ladder encodes — reaches it on the thread that sends it. A session with
    /// a stream writes both there instead.
    ///
    /// - Parameter handler: Receives each chunk of bytes for the host, or nil
    ///   to stop.
    public func setReplyHandler(_ handler: ((Data) -> Void)?) {
        guard let handler else {
            session.setReplySink(nil, nil)
            replyHandler = nil
            return
        }
        let box = ReplyHandler(handler)
        session.setReplySink(
            { context, bytes in
                guard let context, bytes.size() > 0, let base = bytes.__dataUnsafe() else { return }
                Unmanaged<ReplyHandler>.fromOpaque(context).takeUnretainedValue()
                    .handler(Data(bytes: base, count: Int(bytes.size())))
            },
            Unmanaged.passUnretained(box).toOpaque()
        )
        replyHandler = box
    }

    /// Holds the reply handler the session's sink calls through, for as long
    /// as the sink names it.
    private final class ReplyHandler {
        let handler: (Data) -> Void
        init(_ handler: @escaping (Data) -> Void) { self.handler = handler }
    }

    private var replyHandler: ReplyHandler?
}

/// What a row of a host's outline is.
///
/// Numbered as Core's `App::ListedLevel`, which `HostOutline.h` pins.
public enum HostOutlineLevel: UInt8, Sendable {
    case workspace = 0
    case window = 1
    case tab = 2
    case pane = 3
}

/// The kind of thing an identity names, numbered as Core's
/// `Session::Identity::ObjectKind`.
public enum HostOutlineObjectKind: UInt8, Sendable {
    case workspace = 0
    case session = 1
    case window = 2
    case tab = 3
    case pane = 4
    case client = 5
}

/// What a row is addressed, opened and closed by.
public struct HostOutlineIdentity: Hashable, Sendable {
    /// What kind of thing it names.
    public let kind: HostOutlineObjectKind
    /// Its number, never reused by the host.
    public let number: UInt64

    /// Names a thing by its kind and number.
    public init(kind: HostOutlineObjectKind, number: UInt64) {
        self.kind = kind
        self.number = number
    }
}

/// An independently owned session directory on one machine.
public struct HostDaemonInstance: Hashable, Codable, Sendable, Identifiable {
    public let socketName: String
    public let executable: String
    public let startedUnixSeconds: UInt64
    public var appVersion: String? = nil
    public var id: String { socketName }

    public var title: String {
        let date = Date(timeIntervalSince1970: TimeInterval(startedUnixSeconds))
        return "Sessions started \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    package var coreValue: Ubiquitty.Session.HostInstanceInfo {
        var value = Ubiquitty.Session.HostInstanceInfo()
        value.socketName = std.string(socketName)
        value.executable = std.string(executable)
        value.startedUnixSeconds = startedUnixSeconds
        value.appVersion = std.string(appVersion ?? "")
        return value
    }

    /// Changes only the attach executable; Core's current socket pin stays intact.
    package func bootstrap(_ command: String, pinInitialOwner: Bool) -> String {
        let redirected = command.withCString { Ubiquitty.Session.hostInstanceBootstrap(std.string_view($0), coreValue) }
        guard pinInitialOwner else { return String(redirected) }
        return String(redirected)
            .withCString { commandBytes in
                socketName.withCString {
                    String(Ubiquitty.Session.substituteReattachSocket(std.string_view(commandBytes), std.string_view($0)))
                }
            }
    }

    package static func read(_ list: Ubiquitty.Session.HostInstanceList) -> [Self] {
        (0..<Int(list.count()))
            .map {
                let value = list.instanceAt($0)
                return Self(
                    socketName: String(value.socketName),
                    executable: String(value.executable),
                    startedUnixSeconds: value.startedUnixSeconds,
                    appVersion: value.appVersion.empty() ? nil : String(value.appVersion)
                )
            }
    }
}

/// A status, least urgent first, numbered as Core's `App::StatusKind`.
public enum HostOutlineStatus: UInt8, Sendable {
    case none = 0
    case idle = 1
    case running = 2
    case working = 3
    case done = 4
    case attention = 5
    case blocked = 6
    case failed = 7

    /// The program-status symbol shared by the Apple session lists and native tabs.
    public var symbolName: String {
        switch self {
        case .failed: "xmark.octagon.fill"
        case .blocked: "questionmark.bubble.fill"
        case .attention: "bell.badge.fill"
        case .working: "circle.dotted"
        case .done: "checkmark.circle.fill"
        case .running: "play.circle.fill"
        case .idle: "moon.zzz"
        case .none: "circle"
        }
    }

    /// The symbol, a blocked program's telling what it waits for: an answer,
    /// a permission, or a sign-in.
    ///
    /// - Parameter blockKind: What a blocked program waits for.
    /// - Returns: The symbol's name.
    public func symbolName(blockKind: HostOutlineBlockKind) -> String {
        guard self == .blocked else { return symbolName }
        switch blockKind {
        case .permission: return "hand.raised.fill"
        case .auth: return "key.fill"
        case .question, .none: return "questionmark.bubble.fill"
        }
    }
}

/// The theme slot a status mark is drawn in, numbered as Core's
/// `Themes::StatusColorSlot`.
public enum HostOutlineStatusSlot: UInt8, Sendable {
    case failed = 0
    case blocked = 1
    case attention = 2
    case done = 3
    case working = 4
    case neutral = 5
    case progress = 6
}

/// What a blocked program waits for, numbered as Core's
/// `OSC::ProgramBlockKind`.
public enum HostOutlineBlockKind: UInt8, Sendable {
    case none = 0
    case permission = 1
    case question = 2
    case auth = 3
}

/// Whether anything runs in a workspace, numbered as Core's
/// `Session::TreeWorkspaceState`.
public enum HostOutlineWorkspaceState: UInt8, Sendable {
    case live = 0
    case restoredAfterHostRestart = 1
    case restorable = 2
}

/// A colour Core resolved for a row.
public struct HostOutlineColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    /// Reads a colour Core packed as 0xRRGGBBAA.
    init(packed: UInt32) {
        red = UInt8(truncatingIfNeeded: packed >> 24)
        green = UInt8(truncatingIfNeeded: packed >> 16)
        blue = UInt8(truncatingIfNeeded: packed >> 8)
        alpha = UInt8(truncatingIfNeeded: packed)
    }
}

/// What one mark on a row is drawn in, as Core resolved it
/// (`App::statusMarkInk`).
public enum HostOutlineInk: Hashable, Sendable {
    /// The reader's theme's colour for the mark.
    case theme(HostOutlineColor)
    /// The platform's own colour for the mark: the reader said it has one and
    /// the theme names none.
    case platform

    /// Reads an ink Core handed out as a flag and a packed colour.
    init(isPlatform: Bool, packed: UInt32) {
        self = isPlatform ? .platform : .theme(HostOutlineColor(packed: packed))
    }
}

/// Which mark a row's progress is drawn as, numbered as the progress values
/// of Core's `App::StatusMark`. It says which of a platform's own colours a
/// progress ink of ``HostOutlineInk/platform`` means.
public enum HostOutlineProgressMark: UInt8, Sendable {
    /// Carrying the accent.
    case accent = 0
    /// Dimmed.
    case inactive = 1
    /// Reporting an error.
    case error = 2
}

/// The status marks a platform has a colour of its own for, as Core's
/// `App::PlatformStatusColors` names them. A fact a frontend reports once;
/// Core decides, per row, where that colour is the one to draw.
public struct HostOutlinePlatformMarks: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// A progress mark carrying the accent.
    public static let progress = HostOutlinePlatformMarks(rawValue: 1 << 0)
    /// A progress mark dimmed.
    public static let progressInactive = HostOutlinePlatformMarks(rawValue: 1 << 1)
    /// A progress mark reporting an error.
    public static let progressError = HostOutlinePlatformMarks(rawValue: 1 << 2)
    /// The mark a notification nobody has seen leaves.
    public static let notification = HostOutlinePlatformMarks(rawValue: 1 << 3)
}

/// A tag a row wears.
public struct HostOutlineTag: Hashable, Sendable {
    /// The tag's name; empty for an untitled rule tag, drawn as a dot.
    public let name: String
    /// What a screen reader speaks for the tag: its name, or for an untitled
    /// tag its colour's name or its rule's pattern.
    public let spokenName: String
    /// The colour the reader's `[[tags]]` rules give the name, if any.
    public let color: HostOutlineColor?
    /// Whether its rule made it prominent.
    public let isLoud: Bool
    /// Whether the chip draws the name: false for an untitled tag, and for
    /// one whose rule hides its name, each drawn as a dot and spoken by
    /// ``spokenName`` (Core's `Session::ResolvedTag::drawsName`).
    public let isNameShown: Bool
}

/// What names a row that has no identity: a window or a tab of a workspace
/// nothing runs in, by its place in that workspace's record.
public struct HostOutlineRecordedKey: Hashable, Sendable {
    /// The restorable workspace.
    public let workspaceID: UInt32
    /// Whether the row is a window's or a tab's.
    public let level: HostOutlineLevel
    /// The window's index in the record.
    public let window: Int
    /// The tab's index in that window; zero on a window's row.
    public let tab: Int
}

/// How long ago something happened by the host's clock, as a fact a frontend
/// words itself.
public struct HostOutlineAge: Hashable, Sendable {
    /// Whole seconds since.
    public let seconds: UInt64
}

/// What a closed row hides.
public struct HostOutlineSummary: Hashable, Sendable {
    public let windows: Int
    public let tabs: Int
    public let panes: Int
    /// The most urgent status under the row and how many panes share it.
    public let worstStatus: HostOutlineStatus
    public let worstStatusCount: Int
    /// The newest output and input under the row, by the host's clock in
    /// milliseconds since the Unix epoch; zero for never.
    public let newestOutputUnixMilliseconds: UInt64
    public let newestInputUnixMilliseconds: UInt64
}

/// One row of a host's outline, with every decision already made by Core
/// (`App::OutlineRow`): what it is called, what folded into it, its status
/// and colour, and how long ago anything under it wrote.
public struct HostOutlineRow: Sendable {
    /// What the row is.
    public let level: HostOutlineLevel
    /// The identity the row is addressed, opened and closed by; nil for a
    /// window's or a tab's row in a workspace nothing runs in.
    public let id: HostOutlineIdentity?
    /// What such a row is closed by instead.
    public let recordedKey: HostOutlineRecordedKey?
    /// The window, the tab and the pane the row also stands for, where a
    /// level with one child folded them into it.
    public let foldedWindow: HostOutlineIdentity?
    public let foldedTab: HostOutlineIdentity?
    public let foldedPane: HostOutlineIdentity?
    /// Whether anything runs in the workspace the row is in.
    public let workspaceState: HostOutlineWorkspaceState
    /// The labels drawn beside the title, outermost first.
    public let labelChips: [String]
    /// The tags the row wears, each name once.
    public let tags: [HostOutlineTag]
    /// The row's status rolled up from the panes under it.
    public let status: HostOutlineStatus
    /// What a blocked program under the row waits for.
    public let blockKind: HostOutlineBlockKind
    /// The colours programs under the row set, if any.
    public let indicatorColor: HostOutlineColor?
    public let tabColor: HostOutlineColor?
    /// The theme slot the status mark is drawn in, and its colour in the
    /// reader's theme.
    public let statusSlot: HostOutlineStatusSlot
    public let statusColor: HostOutlineColor
    /// What each mark on the row is drawn in. The progress, bell and
    /// notification inks are read only on a row that has that mark.
    public let statusInk: HostOutlineInk
    public let progressInk: HostOutlineInk
    public let progressMark: HostOutlineProgressMark
    public let bellInk: HostOutlineInk
    public let notificationInk: HostOutlineInk
    /// The row's status as Core words it, "blocked 1/3: permission"; empty
    /// for a row of no status.
    public let statusWords: String
    /// What a blocked program under the row waits for, as Core's word; empty
    /// when nothing is blocked or it did not say.
    public let blockKindWord: String
    /// The row's progress as Core words it, "40%" or "paused 40%"; empty with
    /// no report.
    public let progressWords: String
    /// Who is attached under the row as Core words it, "2 people, 1 agent";
    /// empty for nobody.
    public let attendanceWords: String
    /// What a closed row hides as Core words it, "2 windows, 5 panes"; empty
    /// on a row that hides nothing.
    public let collapsedWords: String
    /// What a workspace's row says of its state as Core words it, "restored"
    /// or "restorable"; empty for a live workspace and on every other row.
    public let stateWords: String
    /// What a workspace's row says of how long it lasts as Core words it,
    /// "ends when detached"; empty otherwise.
    public let lifetimeWords: String
    /// How long ago anything under the row wrote and was typed into; nil for
    /// never.
    public let sinceOutput: HostOutlineAge?
    public let sinceInput: HostOutlineAge?
    /// How long ago anything last happened under the row, for a place that
    /// shows one age: the newer of the two, as Core picked it; nil for never.
    public let sinceActivity: HostOutlineAge?
    /// What the row hides, when it is a parent that is not open.
    public let collapsedSummary: HostOutlineSummary?
    /// How far the row is indented.
    public let depth: Int
    /// The workspace's index in the tree.
    public let pathWorkspace: Int
    /// The window's index in its workspace.
    public let pathWindow: Int
    /// The tab's index in its window.
    public let pathTab: Int
    /// The pane's index in its tab.
    public let pathPane: Int
    /// On a workspace's row, whether it ends when the last person detaches.
    public let endsWhenDetached: Bool
    /// What the row is called.
    public let title: String
    /// What is running in what the row stands for; empty when the title says it.
    public let secondaryTitle: String
    /// How many panes under the row share its status.
    public let statusCount: Int
    /// How many panes are under the row.
    public let paneCount: Int
    /// The progress state, as OSC 9;4 numbers it; zero for none.
    public let progressState: UInt8
    /// The progress, in percent.
    public let progressValue: UInt8
    /// Whether a bell rang under the row that nobody has seen.
    public let hasUnseenBell: Bool
    /// Whether a notification under the row is unseen.
    public let hasUnseenNotification: Bool
    /// How many panes under the row wear a badge.
    public let badgeCount: Int
    /// The badge text of the pane the row is or stands for.
    public let badge: String
    /// When anything under the row last wrote, by the host's clock; zero for never.
    public let lastOutputUnixMilliseconds: UInt64
    /// When anything under the row was last typed into; zero for never.
    public let lastInputUnixMilliseconds: UInt64
    /// How many people are attached under the row.
    public let attachedPeople: Int
    /// How many agents are attached under the row.
    public let attachedAgents: Int
    /// The program of the pane the row is or stands for.
    public let program: String
    /// The program's own status string, empty when none was reported.
    public let programStatus: String
    /// The directory of the pane the row is or stands for.
    public let directory: String
    /// The width in cells of the pane the row is or stands for.
    public let columns: Int
    /// The height in cells of the pane the row is or stands for.
    public let rows: Int
    /// Whether the row is the host's current one at its level.
    public let isHostCurrent: Bool
    /// What the mark for that means, in Core's words, for a tooltip and for
    /// accessibility; empty on a row that is not current.
    public let hostCurrentWords: String
    /// Whether the row has rows under it to open.
    public let isExpandable: Bool
    /// Whether the rows under it are shown.
    public let isExpanded: Bool
    /// Whether the row itself matches the search.
    public let isMatch: Bool

    // What a row's actions read: facts Core states, so nothing here is
    // derived from neighbouring rows, a name or a title.

    /// What opening the row attaches to.
    public let open: HostOutlineOpen
    /// Every level the row is or stands for, outermost first, each with its
    /// own label and its own hand-put tags: what an editor shows and what a
    /// label or tags change replaces.
    public let own: [HostOutlineOwn]
    /// Where the tab the row is or stands for sits and may go; nil on a row
    /// that is no tab's.
    public let tabPlace: HostOutlineTabPlace?
    /// The words of the newest notification nobody has seen under the row;
    /// empty when there is none.
    public let attentionTitle: String
    public let attentionBody: String
    /// The one mark the row shows for what runs under it, by the rule a
    /// tab's accessory slot is ranked by.
    public let accessory: HostOutlineAccessory
    /// The ink the program chose for that mark; nil for the theme's own.
    public let accessoryInk: HostOutlineColor?
    /// What the row is to the place the reader's own window shows. One row
    /// at most is here or holds it.
    public let here: HostOutlineHere
    /// The second line a compact reader gives the row, in Core's words,
    /// when the row needs a person: what its notification says, else its
    /// status when that is failed, blocked or asking for attention. Empty
    /// for a row that is drawn on one line.
    public let secondLine: String
    /// The lines a hover or a detail popover shows, worded and ordered by
    /// Core.
    public let details: [HostOutlineDetail]

    /// Reads one row out of Core's rows.
    ///
    /// Every closed enumeration is checked before the value exists: a number
    /// this build has no case for yields no row, never a row with a case it
    /// was not sent.
    ///
    /// - Parameters:
    ///   - rows: Core's rows.
    ///   - index: The row.
    init?(rows: Ubiquitty.Runtime.HostOutlineRows, index: Int) {
        guard let level = HostOutlineLevel(rawValue: rows.level(index)),
            let workspaceState = HostOutlineWorkspaceState(rawValue: rows.workspaceState(index)),
            let status = HostOutlineStatus(rawValue: rows.statusKind(index)),
            let blockKind = HostOutlineBlockKind(rawValue: rows.blockKind(index)),
            let statusSlot = HostOutlineStatusSlot(rawValue: rows.statusSlot(index)),
            let opening = HostOutlineOpen.How(rawValue: rows.openOpening(index)),
            let accessory = HostOutlineAccessory(rawValue: rows.accessory(index)),
            let here = HostOutlineHere(rawValue: rows.here(index)),
            let progressMark = HostOutlineProgressMark(rawValue: rows.progressMark(index))
        else { return nil }
        self.here = here
        secondLine = String(rows.secondLine(index))
        details = (0..<Int(rows.detailCount(index)))
            .map {
                HostOutlineDetail(label: String(rows.detailLabel(index, $0)), value: String(rows.detailValue(index, $0)))
            }
        open = HostOutlineOpen(
            how: opening,
            sessionID: rows.openSessionID(index),
            workspaceID: rows.openWorkspaceID(index),
            workspaceName: String(rows.openWorkspaceName(index)),
            paneID: rows.openPaneID(index),
            obstacle: String(rows.openObstacle(index))
        )
        var levels: [HostOutlineOwn] = []
        for level in 0..<Int(rows.ownCount(index)) {
            guard let kind = HostOutlineObjectKind(rawValue: rows.ownKind(index, level)) else { return nil }
            levels.append(
                HostOutlineOwn(
                    id: HostOutlineIdentity(kind: kind, number: rows.ownNumber(index, level)),
                    label: String(rows.ownLabel(index, level)),
                    tags: (0..<Int(rows.ownTagCount(index, level))).map { String(rows.ownTag(index, level, $0)) },
                    name: String(rows.ownName(index, level))
                )
            )
        }
        own = levels
        if rows.hasTabPlace(index) {
            tabPlace = HostOutlineTabPlace(
                tab: HostOutlineIdentity(kind: .tab, number: rows.tabPlaceTab(index)),
                window: HostOutlineIdentity(kind: .window, number: rows.tabPlaceWindow(index)),
                index: rows.tabPlaceIndex(index),
                tabCount: rows.tabPlaceTabCount(index),
                canMoveEarlier: rows.canTabMoveEarlier(index),
                canMoveLater: rows.canTabMoveLater(index),
                acceptedIndices: (0..<Int(rows.tabPlaceAcceptedIndexCount(index))).map { rows.tabPlaceAcceptedIndex(index, $0) },
                destinations: (0..<Int(rows.tabPlaceOtherWindowCount(index)))
                    .map {
                        HostOutlineTabDestination(
                            window: HostOutlineIdentity(kind: .window, number: rows.tabPlaceOtherWindow(index, $0)),
                            title: String(rows.tabPlaceOtherWindowTitle(index, $0)),
                            index: rows.tabPlaceOtherWindowIndex(index, $0)
                        )
                    }
            )
        } else {
            tabPlace = nil
        }
        attentionTitle = String(rows.attentionTitle(index))
        attentionBody = String(rows.attentionBody(index))
        self.accessory = accessory
        accessoryInk = rows.hasAccessoryInk(index) ? HostOutlineColor(packed: rows.accessoryInk(index)) : nil
        self.progressMark = progressMark
        self.level = level
        self.workspaceState = workspaceState
        self.status = status
        self.blockKind = blockKind
        self.statusSlot = statusSlot
        let number = rows.idNumber(index)
        if number != 0 {
            guard let kind = HostOutlineObjectKind(rawValue: rows.idKind(index)) else { return nil }
            id = HostOutlineIdentity(kind: kind, number: number)
        } else {
            id = nil
        }
        if rows.hasRecordedKey(index) {
            guard let recordedLevel = HostOutlineLevel(rawValue: rows.recordedLevel(index)) else { return nil }
            recordedKey = HostOutlineRecordedKey(
                workspaceID: rows.recordedWorkspaceID(index),
                level: recordedLevel,
                window: Int(rows.recordedWindow(index)),
                tab: Int(rows.recordedTab(index))
            )
        } else {
            recordedKey = nil
        }
        let window = rows.foldedWindowNumber(index)
        foldedWindow = window != 0 ? HostOutlineIdentity(kind: .window, number: window) : nil
        let tab = rows.foldedTabNumber(index)
        foldedTab = tab != 0 ? HostOutlineIdentity(kind: .tab, number: tab) : nil
        let pane = rows.foldedPaneNumber(index)
        foldedPane = pane != 0 ? HostOutlineIdentity(kind: .pane, number: pane) : nil
        labelChips = (0..<Int(rows.labelChipCount(index))).map { String(rows.labelChip(index, $0)) }
        tags = (0..<Int(rows.tagCount(index)))
            .map { tag in
                HostOutlineTag(
                    name: String(rows.tagName(index, tag)),
                    spokenName: String(rows.tagSpokenName(index, tag)),
                    color: rows.hasTagColor(index, tag) ? HostOutlineColor(packed: rows.tagColor(index, tag)) : nil,
                    isLoud: rows.isTagLoud(index, tag),
                    isNameShown: rows.isTagNameShown(index, tag)
                )
            }
        indicatorColor = rows.hasIndicatorColor(index) ? HostOutlineColor(packed: rows.indicatorColor(index)) : nil
        tabColor = rows.hasTabColor(index) ? HostOutlineColor(packed: rows.tabColor(index)) : nil
        statusColor = HostOutlineColor(packed: rows.statusColor(index))
        statusInk = HostOutlineInk(isPlatform: rows.isStatusInkPlatform(index), packed: rows.statusInkColor(index))
        progressInk = HostOutlineInk(isPlatform: rows.isProgressInkPlatform(index), packed: rows.progressInkColor(index))
        bellInk = HostOutlineInk(isPlatform: rows.isBellInkPlatform(index), packed: rows.bellInkColor(index))
        notificationInk = HostOutlineInk(
            isPlatform: rows.isNotificationInkPlatform(index),
            packed: rows.notificationInkColor(index)
        )
        statusWords = String(rows.statusWords(index))
        blockKindWord = String(rows.blockKindWord(index))
        progressWords = String(rows.progressWords(index))
        attendanceWords = String(rows.attendanceWords(index))
        collapsedWords = String(rows.collapsedWords(index))
        stateWords = String(rows.stateWords(index))
        lifetimeWords = String(rows.lifetimeWords(index))
        sinceOutput = rows.isOutputAgeKnown(index) ? HostOutlineAge(seconds: rows.secondsSinceOutput(index)) : nil
        sinceInput = rows.isInputAgeKnown(index) ? HostOutlineAge(seconds: rows.secondsSinceInput(index)) : nil
        sinceActivity = rows.isActivityAgeKnown(index) ? HostOutlineAge(seconds: rows.secondsSinceActivity(index)) : nil
        if rows.hasCollapsedSummary(index) {
            guard let worst = HostOutlineStatus(rawValue: rows.collapsedWorstStatus(index)) else { return nil }
            collapsedSummary = HostOutlineSummary(
                windows: Int(rows.collapsedWindows(index)),
                tabs: Int(rows.collapsedTabs(index)),
                panes: Int(rows.collapsedPanes(index)),
                worstStatus: worst,
                worstStatusCount: Int(rows.collapsedWorstStatusCount(index)),
                newestOutputUnixMilliseconds: rows.collapsedNewestOutputUnixMilliseconds(index),
                newestInputUnixMilliseconds: rows.collapsedNewestInputUnixMilliseconds(index)
            )
        } else {
            collapsedSummary = nil
        }
        depth = Int(rows.depth(index))
        pathWorkspace = Int(rows.pathWorkspace(index))
        pathWindow = Int(rows.pathWindow(index))
        pathTab = Int(rows.pathTab(index))
        pathPane = Int(rows.pathPane(index))
        endsWhenDetached = rows.doesEndWhenDetached(index)
        title = String(rows.title(index))
        secondaryTitle = String(rows.secondaryTitle(index))
        statusCount = Int(rows.statusCount(index))
        paneCount = Int(rows.statusPaneCount(index))
        progressState = rows.progressState(index)
        progressValue = rows.progressValue(index)
        hasUnseenBell = rows.hasUnseenBell(index)
        hasUnseenNotification = rows.hasUnseenNotification(index)
        badgeCount = Int(rows.badgeCount(index))
        badge = String(rows.badge(index))
        lastOutputUnixMilliseconds = rows.lastOutputUnixMilliseconds(index)
        lastInputUnixMilliseconds = rows.lastInputUnixMilliseconds(index)
        attachedPeople = Int(rows.attachedPeople(index))
        attachedAgents = Int(rows.attachedAgents(index))
        program = String(rows.program(index))
        programStatus = String(rows.programStatus(index))
        directory = String(rows.directory(index))
        columns = Int(rows.columns(index))
        self.rows = Int(rows.rows(index))
        isHostCurrent = rows.isHostCurrent(index)
        hostCurrentWords = String(rows.hostCurrentWords(index))
        isExpandable = rows.isExpandable(index)
        isExpanded = rows.isExpanded(index)
        isMatch = rows.isMatch(index)
    }
}

/// What opening a row, or picking a workspace a connect asks about, attaches
/// to. Handed back to the attach as it is: no caller looks up a session or a
/// name.
public struct HostOutlineOpen: Hashable, Sendable {
    /// How it is opened, numbered as Core's `Session::AttachOpening`.
    public enum How: UInt8, Sendable {
        /// It cannot be; ``HostOutlineOpen/obstacle`` says why.
        case cannot = 0
        /// By attaching to ``HostOutlineOpen/sessionID``.
        case bySession = 1
        /// By asking the host for ``HostOutlineOpen/workspaceName``, which
        /// recreates the workspace from its record.
        case byRestoring = 2
        /// By showing what this app already has open:
        /// ``HostOutlineOpen/sessionID`` is the session the reader said it
        /// holds the workspace open with, and nothing is attached.
        case byRevealing = 3
    }

    public let how: How
    /// The session to attach to; zero unless it opens by one.
    public let sessionID: UInt32
    /// The workspace it lands in, and that workspace's name.
    public let workspaceID: UInt32
    public let workspaceName: String
    /// The pane to show once attached, as the host's layout numbers it; zero
    /// for wherever the host's own focus is.
    public let paneID: UInt32
    /// Why it cannot be opened, as Core words it; empty when it can.
    public let obstacle: String

    /// Reads the value a row's accessors hand out field by field.
    init(how: How, sessionID: UInt32, workspaceID: UInt32, workspaceName: String, paneID: UInt32, obstacle: String) {
        self.how = how
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.paneID = paneID
        self.obstacle = obstacle
    }

    /// Reads the value Core hands out whole, as a candidate of the question
    /// a connect asks carries it.
    ///
    /// - Parameter target: Core's target.
    public init(_ target: Ubiquitty.Session.AttachTarget) {
        how = How(rawValue: target.opening.rawValue) ?? .cannot
        sessionID = target.sessionID
        workspaceID = target.workspaceID
        workspaceName = String(target.workspaceName)
        paneID = target.paneID
        obstacle = String(Ubiquitty.Session.attachObstacleSentence(target.obstacle))
    }
}

/// One level a row is or stands for, with what that node itself holds.
public struct HostOutlineOwn: Hashable, Sendable {
    /// The node: a workspace, a window, a tab, a pane, or the session behind
    /// a pane.
    public let id: HostOutlineIdentity
    /// Its own label, empty when it has none.
    public let label: String
    /// Its own hand-put tags, in the order they are drawn.
    public let tags: [String]
    /// The name a person gave it, which a rename replaces: a workspace's or
    /// a tab's. Empty for one with none and on a level that takes no name.
    public let name: String
}

/// Where a tab stands among its window's tabs, and where the host would let
/// it go.
public struct HostOutlineTabPlace: Hashable, Sendable {
    public let tab: HostOutlineIdentity
    public let window: HostOutlineIdentity
    /// Its place among that window's tabs, from zero, and how many there are.
    public let index: UInt32
    public let tabCount: UInt32
    public let canMoveEarlier: Bool
    public let canMoveLater: Bool
    /// The places in its own window the host would accept it at, lowest
    /// first: a drop is offered at these and nowhere else. In another
    /// window every place from zero to that destination's index is
    /// accepted.
    public let acceptedIndices: [UInt32]
    /// The other windows of its workspace that have room for it, each with
    /// what Core calls it and the place to ask for there.
    public let destinations: [HostOutlineTabDestination]
    /// Those windows' identities.
    public var otherWindows: [HostOutlineIdentity] { destinations.map(\.window) }
}

/// One line a hover or a detail popover shows for a row.
public struct HostOutlineDetail: Hashable, Sendable {
    /// What the fact is: "Program", "Directory", "Last output".
    public let label: String
    /// The fact.
    public let value: String
}

/// A window a tab could be moved to.
public struct HostOutlineTabDestination: Hashable, Sendable {
    public let window: HostOutlineIdentity
    /// What the outline calls that window.
    public let title: String
    /// The place to ask for there: after its last tab.
    public let index: UInt32
}

/// What a row is to the place the reader's own window shows, numbered as
/// Core's `App::OutlineHere`.
public enum HostOutlineHere: UInt8, Sendable {
    case elsewhere = 0
    /// The row is, or stands for, the pane the window types into.
    case here = 1
    /// The place is under the row and no row drawn beneath says so.
    case holdsHere = 2
}

/// How much room a reader gives a row, numbered as Core's
/// `App::OutlineDensity`.
public enum HostOutlineDensity: UInt8, Sendable {
    /// A list with room for everything: every parent starts open.
    case regular = 0
    /// A sidebar: workspaces start closed, but the one that holds what the
    /// reader's window shows.
    case compact = 1
}

/// What a reader's own window shows of a host.
public struct HostOutlineWindowPlace: Hashable, Sendable {
    /// The host its session is attached to, as the reader names hosts.
    public var host: String
    /// The workspace, as the host numbers it.
    public var workspaceID: UInt32
    /// The pane it types into, as the host's layout numbers it; zero when
    /// only its session is known.
    public var paneID: UInt32
    /// The session that draws into that pane.
    public var sessionID: UInt32

    /// Names a place.
    public init(host: String, workspaceID: UInt32, paneID: UInt32, sessionID: UInt32) {
        self.host = host
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.sessionID = sessionID
    }
}

/// A workspace of a host this app already has open.
public struct HostOutlineOpenWorkspace: Hashable, Sendable {
    /// The host it is on, as the reader names hosts.
    public var host: String
    /// The workspace, as the host numbers it; zero when only the session is
    /// known.
    public var workspaceID: UInt32
    /// The session this app attached with: a row that reveals hands it back.
    public var sessionID: UInt32

    /// Names an open workspace.
    public init(host: String, workspaceID: UInt32, sessionID: UInt32) {
        self.host = host
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

/// The one mark a row shows, numbered as Core's `App::TabAccessory`.
public enum HostOutlineAccessory: UInt8, Sendable {
    case none = 0
    case progressRing = 1
    case bell = 2
    /// A bell drawn in the colour the program chose.
    case colouredBell = 3
    /// The colour the program chose, as a dot.
    case statusDot = 4
    case notificationDot = 5
    /// Never on a row: a list has no reader's unread output to mark.
    case activityDots = 6
    /// Never on a row.
    case shortcutHint = 7
}

/// The rows of a host's outline, in the order they are drawn.
public struct HostOutline: Sendable {
    /// The tree revision the rows describe.
    public let revision: UInt64
    /// How many rows match the search; zero without one.
    public let matchCount: Int
    /// Whether the rows are a search's: the reader's query held a term, so
    /// Core kept only what matches and opened the way to it.
    public let isSearching: Bool
    public let rows: [HostOutlineRow]

    /// Reads Core's rows into values.
    ///
    /// - Parameter rows: What `Runtime::HostDirectoryClient::outlineRows` or
    ///   a session's `hostOutlineRows` returned.
    public init(_ rows: Ubiquitty.Runtime.HostOutlineRows) {
        revision = rows.revision()
        matchCount = Int(rows.matchCount())
        isSearching = rows.isSearching()
        self.rows = (0..<Int(rows.count())).compactMap { HostOutlineRow(rows: rows, index: $0) }
    }

    /// No rows: what a reader draws before any host answered.
    public static var none: HostOutline { HostOutline(Ubiquitty.Runtime.HostOutlineRows()) }
}

/// What a frontend brings to an outline of a host: who is looking, which
/// rows the person has closed and what the person is searching for. Core
/// supplies the rest from the preferences and the theme.
public struct HostOutlineReader: Sendable {
    /// The applied profile's name, for a title part that shows it.
    public var profileName = ""
    /// What names a surface when no title part produced text.
    public var fallbackName = ""
    /// The machine already named by the outline's surrounding screen.
    public var namedHost = ""
    /// Whether the program's status has its own line below the title.
    public var showsProgramStatusSeparately = false
    /// The rows the person has closed. Every other parent is open.
    public var collapsed: Set<HostOutlineIdentity> = []
    /// The rows with no identity the person has closed.
    public var collapsedRecordedRows: Set<HostOutlineRecordedKey> = []
    /// What the person is searching for; empty for no search.
    public var query = ""
    /// The catalog index of the theme the outline is drawn in; nil for the
    /// session's own, or for no theme where there is no session.
    public var themeIndex: Int?
    /// What the reader calls the host this outline lists; empty for this
    /// machine. Core compares it with the hosts named in ``here`` and
    /// ``alreadyOpen``, so those are stated the same to every host's
    /// outline.
    public var host = ""
    /// How much room the reader gives a row.
    public var density: HostOutlineDensity = .regular
    /// The workspaces the person opened by hand, which a compact reader's
    /// need to be open. Kept by ``open(_:)`` and ``close(_:)``.
    public var opened: Set<HostOutlineIdentity> = []
    /// What the reader's own window shows, on whichever host.
    public var here: HostOutlineWindowPlace?
    /// What this app has open, on every host.
    public var alreadyOpen: [HostOutlineOpenWorkspace] = []
    /// The status marks the reader's platform has a colour of its own for.
    public var platformMarks: HostOutlinePlatformMarks = []

    /// A reader with nothing closed and no search.
    public init() {}

    /// Opens a row the person opened: its rows are listed.
    ///
    /// - Parameter row: The row's identity.
    public mutating func open(_ row: HostOutlineIdentity) {
        collapsed.remove(row)
        if row.kind == .workspace {
            opened.insert(row)
        }
    }

    /// Closes a row the person closed: its rows are not listed.
    ///
    /// - Parameter row: The row's identity.
    public mutating func close(_ row: HostOutlineIdentity) {
        collapsed.insert(row)
        opened.remove(row)
    }

    /// The request as Core takes it.
    public var request: Ubiquitty.Runtime.HostOutlineRequest {
        var request = Ubiquitty.Runtime.HostOutlineRequest()
        request.viewer.profileName = std.string(profileName)
        request.viewer.fallbackName = std.string(fallbackName)
        request.viewer.windowHostName = std.string(namedHost)
        request.showsProgramStatusSeparately = showsProgramStatusSeparately
        request.query = std.string(query)
        request.themeIndex = Int32(clamping: themeIndex ?? -1)
        request.host = std.string(host)
        request.density = density == .compact ? .compact : .regular
        // Opened first: closing a row afterwards is what the person did last.
        for row in opened {
            _ = request.open(row.kind.rawValue, row.number)
        }
        request.platformStatusColors.hasProgress = platformMarks.contains(.progress)
        request.platformStatusColors.hasProgressInactive = platformMarks.contains(.progressInactive)
        request.platformStatusColors.hasProgressError = platformMarks.contains(.progressError)
        request.platformStatusColors.hasNotification = platformMarks.contains(.notification)
        for row in collapsed {
            _ = request.close(row.kind.rawValue, row.number)
        }
        for row in collapsedRecordedRows {
            _ = request.closeRecorded(row.workspaceID, row.level.rawValue, row.window, row.tab)
        }
        if let here {
            request.setHere(std.string(here.host), here.workspaceID, here.paneID, here.sessionID)
        }
        for held in alreadyOpen {
            request.addAlreadyOpen(std.string(held.host), held.workspaceID, held.sessionID)
        }
        return request
    }
}

/// The words a list of a host's sessions is drawn with, in Core's wording
/// (`Runtime/SessionListWords.h`). A frontend draws them and words none.
public enum HostWords {
    /// A phrase that never varies, numbered as Core's
    /// `Runtime::SessionListPhrase`.
    public enum Phrase: UInt8, Sendable, CaseIterable {
        case connect = 0
        case open = 1
        case newSession = 2
        case showWindow = 3
        case tryAgain = 4
        case askAgain = 5
        case cancel = 6
        case save = 7
        case create = 8
        case attach = 9
        case copySessionLink = 10
        case label = 11
        case tags = 12
        case renameSession = 13
        case renameTab = 14
        case moveTabEarlier = 15
        case moveTabLater = 16
        case moveTabToWindow = 17
        case closeWindow = 18
        case terminate = 19
        case terminateSession = 20
        case newNamedSession = 21
        case expandAll = 22
        case noLabel = 23
        case tagsSeparatedByCommas = 24
        case sessionName = 25
        case tabName = 26
        case noName = 27
        case lastUsed = 28
        case alwaysOpens = 29
        case ended = 30
        case lastSession = 31
        case thisMachine = 32
        case ubiquittyHost = 33
        case shownInAWindowHere = 34
        case aWindowShowsThisHost = 35
        case tabColour = 36
        case badges = 37
        case bell = 38
        case notification = 39
        case indicator = 40
        case lastActive = 41
        case here = 42
        case holdsHere = 43
        case continueOnAnotherDevice = 44
    }

    /// A phrase's words.
    ///
    /// - Parameter phrase: Which.
    /// - Returns: The words, as they are shown.
    public static func text(_ phrase: Phrase) -> String {
        String(Ubiquitty.Runtime.sessionListPhrase(phrase.rawValue))
    }

    /// The menu item that edits one level's label or tags, by what a person
    /// calls that level.
    ///
    /// - Parameter kind: The level.
    /// - Returns: "Session…" for a workspace, "Pane’s Session…" for the
    ///   session behind a pane, and so on.
    public static func levelMenuTitle(_ kind: HostOutlineObjectKind) -> String {
        String(Ubiquitty.Runtime.levelMenuTitleWords(kind.rawValue))
    }

    /// How many sessions a host holds: "no sessions", "1 session".
    ///
    /// - Parameter count: How many workspaces its tree holds.
    /// - Returns: The words.
    public static func sessionCount(_ count: Int) -> String {
        String(Ubiquitty.Runtime.sessionCountWords(UInt64(max(0, count))))
    }

    /// What the control that closes or opens a row is, for accessibility.
    ///
    /// - Parameter row: The row.
    /// - Returns: "Collapse build" for an open row, "Expand build" for a
    ///   closed one.
    public static func foldControl(for row: HostOutlineRow) -> String {
        let title = std.string(row.title)
        return String(row.isExpanded ? Ubiquitty.Runtime.collapseControlWords(title) : Ubiquitty.Runtime.expandControlWords(title))
    }

    /// A label chip, for accessibility: "Label nightly".
    ///
    /// - Parameter label: The label.
    /// - Returns: The words.
    public static func labelChip(_ label: String) -> String {
        String(Ubiquitty.Runtime.labelChipWords(std.string(label)))
    }

    /// A tag chip, for accessibility: "Tag production".
    ///
    /// - Parameter name: The tag.
    /// - Returns: The words.
    public static func tagChip(_ name: String) -> String {
        String(Ubiquitty.Runtime.tagChipWords(std.string(name)))
    }

    /// A pane's grid: "132×43"; empty when either is not positive.
    ///
    /// - Parameters:
    ///   - columns: Its width in cells.
    ///   - rows: Its height in cells.
    /// - Returns: The words.
    public static func grid(columns: Int, rows: Int) -> String {
        String(Ubiquitty.Runtime.gridWords(Int32(clamping: columns), Int32(clamping: rows)))
    }

    /// When anything under a row last wrote: "Last output 3m ago".
    ///
    /// - Parameter seconds: How long ago, by the host's clock.
    /// - Returns: The words.
    public static func lastOutput(secondsAgo seconds: UInt64) -> String {
        String(Ubiquitty.Runtime.lastOutputWords(seconds))
    }

    /// When anything under a row was last typed into: "Last input 3m ago".
    ///
    /// - Parameter seconds: How long ago, by the host's clock.
    /// - Returns: The words.
    public static func lastInput(secondsAgo seconds: UInt64) -> String {
        String(Ubiquitty.Runtime.lastInputWords(seconds))
    }

    /// When anything under a row last moved either way: "Last active 3m
    /// ago".
    ///
    /// - Parameter seconds: How long ago, by the host's clock.
    /// - Returns: The words.
    public static func lastActive(secondsAgo seconds: UInt64) -> String {
        String(Ubiquitty.Runtime.lastActiveWords(seconds))
    }

    /// A row's compact trailing age, without its accessibility label.
    ///
    /// - Parameter seconds: How long ago, by the host's clock.
    /// - Returns: "just now" or the largest whole unit, such as "3m ago".
    public static func compactAge(secondsAgo seconds: UInt64) -> String {
        String(Ubiquitty.Runtime.compactAgeWords(seconds))
    }

    /// A notice: what happened and what it means for the person.
    public struct Notice: Sendable {
        public let title: String
        public let message: String
        /// Whether asking again is the action beside it.
        public let doesOfferAskingAgain: Bool

        /// Reads Core's notice.
        init(_ notice: Ubiquitty.Runtime.SessionListNotice) {
            title = String(notice.title)
            message = String(notice.message)
            doesOfferAskingAgain = notice.doesOfferAskingAgain
        }
    }

    /// The notice for how a terminate settled; nil for a session that was
    /// terminated, which the list shows by losing its row.
    ///
    /// - Parameters:
    ///   - outcome: The host's answer as Core numbers it; a number this
    ///     build has no outcome for is worded as one it does not know.
    ///   - name: What the session is called; empty for none kept.
    ///   - sessionID: The session.
    /// - Returns: The notice.
    public static func terminateOutcome(_ outcome: UInt8, name: String, sessionID: UInt32) -> Notice? {
        let notice = Notice(Ubiquitty.Runtime.terminateOutcomeNotice(outcome, std.string(name), sessionID))
        return notice.title.isEmpty ? nil : notice
    }

    /// The notice for a connect that was waiting for a listing that failed.
    ///
    /// - Parameters:
    ///   - hostName: What the host is called.
    ///   - reason: Why the listing failed, standing alone; empty for none.
    /// - Returns: The notice.
    public static func listingFailedWhileConnecting(hostName: String, reason: String) -> Notice {
        Notice(Ubiquitty.Runtime.listingFailedWhileConnectingNotice(std.string(hostName), std.string(reason)))
    }

    /// The notice for a connect that produced no window on this machine.
    ///
    /// - Parameter hostName: What the host is called.
    /// - Returns: The notice.
    public static func windowNotOpened(hostName: String) -> Notice {
        Notice(Ubiquitty.Runtime.windowNotOpenedNotice(std.string(hostName)))
    }

    /// Why a session name is refused before anything is asked.
    public static var sessionNameTooLong: String {
        String(Ubiquitty.Runtime.sessionNameTooLongSentence())
    }

    /// What naming a new session a name the host already holds does.
    ///
    /// - Parameter name: The name.
    /// - Returns: The sentence.
    public static func sessionNameTaken(_ name: String) -> String {
        String(Ubiquitty.Runtime.sessionNameTakenSentence(std.string(name)))
    }

    /// The button that opens the session a new one would have been named
    /// as: "Open Existing “ci”".
    ///
    /// - Parameter name: The name.
    /// - Returns: The title.
    public static func openExisting(_ name: String) -> String {
        String(Ubiquitty.Runtime.openExistingTitle(std.string(name)))
    }
}

/// What a host was last attached on, and the one rule that turns that memory, a
/// saved host's predefined workspace name and the host's own answer into a
/// connect.
///
/// Core's `Ubiquitty::Runtime::HostDirectory` with the crossing spelled in
/// Swift: the embedder's store arrives as two closures instead of two C
/// function pointers over a byte buffer, and a listing arrives whole instead of
/// staged row by row. The rule itself is never restated here — a frontend that
/// spelled it would answer the same three inputs differently from every other
/// frontend, which is the one thing the Core seam exists to prevent.
///
/// Static, because Core's directory is the process's: an app has one saved-host
/// list, so a second one would be a second answer to what a host was last
/// attached on.
public enum HostDirectory {
    /// Reads a host's stored record.
    ///
    /// The bytes are opaque to the embedder: what they mean is Core's, and a
    /// store that parsed them would be a second reader to keep in step with the
    /// one that wrote them.
    public typealias Load = (String) -> [UInt8]?

    /// Writes a host's record, replacing whatever was there. Empty bytes are
    /// how Core spells a host to forget.
    public typealias Store = (String, [UInt8]) -> Void

    /// The connect one ``decideBeforeListing(host:predefinedWorkspaceName:)``
    /// describes.
    ///
    /// The plan and the values it chose in one answer, so a caller that took
    /// the plan never attaches under another decision's target.
    public struct Decision {
        /// What to do.
        public let plan: Ubiquitty.Session.AttachPlan
        /// The session the plan lands on: the one to re-home to for the by-id
        /// plan, the listed session bearing the name for the attach-named
        /// plan; 0 otherwise.
        public let sessionID: UInt32
        /// The name to attach under or create under, for the named plans; empty
        /// otherwise.
        public let workspaceName: String
        /// The remembered session the host answered without, 0 when there is
        /// none.
        public let vanishedSessionID: UInt32
        /// Whether a new unnamed session is a second action beside the plan;
        /// false when the plan is that new session.
        public let isNewSessionOffered: Bool
    }

    /// Installs the embedder's storage.
    ///
    /// Until this is called every recall answers nothing and every remember is
    /// dropped, which is right for an embedder with nowhere to keep a record: it
    /// connects as though it had never been to the host.
    ///
    /// - Parameters:
    ///   - load: Reads a host's bytes.
    ///   - store: Writes them.
    public static func setPersistence(load: @escaping Load, store: @escaping Store) {
        let installed = Persistence(load: load, store: store)
        // Published under the box lock before it crosses: Core borrows the
        // context, so whatever Core may still invoke must be the box this
        // lock currently holds — never a box a replacement already dropped.
        // Replacing first and crossing second also keeps the two in step when
        // two threads install at once: the crossing always names the newest.
        persistenceBox.setCurrent(installed)
        // The relay's address, not the install's: the relay is immortal, so
        // the unretained context Core keeps is always valid. Through-closures
        // still resolve the live box per call (latest install wins) rather
        // than trusting this address.
        Ubiquitty.Runtime.HostDirectory.setPersistence(
            loadThroughClosure,
            storeThroughClosure,
            Unmanaged.passUnretained(persistenceBox).toOpaque()
        )
    }

    /// The session a host was last attached on.
    ///
    /// - Parameter hostKey: The embedder's name for the host.
    /// - Returns: The daemon session id, or 0 when the host is unknown.
    public static func rememberedSessionID(host hostKey: String) -> UInt32 {
        Ubiquitty.Runtime.HostDirectory.rememberedSessionID(std.string(hostKey))
    }

    /// The workspace a host was last attached under.
    ///
    /// - Parameter hostKey: The embedder's name for the host.
    /// - Returns: The name, empty for an unnamed session or an unknown host.
    public static func rememberedWorkspaceName(host hostKey: String) -> String {
        String(Ubiquitty.Runtime.HostDirectory.rememberedWorkspaceName(std.string(hostKey)))
    }

    /// Pairs a host with the session it is attached on.
    ///
    /// - Parameters:
    ///   - hostKey: The embedder's name for the host.
    ///   - sessionID: The session now attached, as the host pinned it.
    ///   - workspaceName: The workspace it is attached under, empty for an
    ///     unnamed session.
    public static func remember(host hostKey: String, sessionID: UInt32, workspaceName: String) {
        Ubiquitty.Runtime.HostDirectory.remember(std.string(hostKey), sessionID, std.string(workspaceName))
    }

    /// Drops a host's pairing, so the next connect decides as a first one.
    ///
    /// - Parameter hostKey: The embedder's name for the host.
    public static func forget(host hostKey: String) {
        Ubiquitty.Runtime.HostDirectory.forget(std.string(hostKey))
    }

    /// Installs the embedder's storage for the hosts trusted to receive a
    /// `ubiquitty-host` push.
    ///
    /// The list is one opaque record under a key Core names, handed to `load`
    /// and `store` in place of a host key; its bytes are Core's to read.
    ///
    /// - Parameters:
    ///   - load: Reads the record under the key, nil when there is none.
    ///   - store: Writes it; empty bytes trust nobody.
    public static func setDeployTrustPersistence(load: @escaping Load, store: @escaping Store) {
        deployTrustBox.setCurrent(Persistence(load: load, store: store))
        Ubiquitty.Runtime.HostDirectory.setDeployTrustPersistence(
            loadThroughClosure,
            storeThroughClosure,
            Unmanaged.passUnretained(deployTrustBox).toOpaque()
        )
    }

    /// Whether the person has trusted a host to receive a push.
    ///
    /// - Parameter sshHost: The ssh destination a push targets.
    /// - Returns: Whether Core's trust list holds it.
    public static func isDeployTrusted(host sshHost: String) -> Bool {
        Ubiquitty.Runtime.HostDirectory.isDeployTrusted(std.string(sshHost))
    }

    /// Records the person's consent to push to a host.
    ///
    /// - Parameter sshHost: The ssh destination.
    public static func trustDeploy(host sshHost: String) {
        Ubiquitty.Runtime.HostDirectory.trustDeploy(std.string(sshHost))
    }

    /// Withdraws the consent to push to a host, so the next push asks again.
    ///
    /// - Parameter sshHost: The ssh destination.
    public static func revokeDeployTrust(host sshHost: String) {
        Ubiquitty.Runtime.HostDirectory.revokeDeployTrust(std.string(sshHost))
    }

    /// Every host trusted to receive a push, in the order trusted.
    public static var deployTrustedHosts: [String] {
        Ubiquitty.Runtime.HostDirectory.deployTrustedHosts().map { String($0) }
    }

    /// The connect to make before the host has answered, over its own
    /// record alone: a predefined name is created under, a remembered
    /// session is returned to, and otherwise the listing is waited for.
    ///
    /// Once a host has answered, the connect is decided on its tree through
    /// ``RuntimeDrive/decideHostAttach(host:predefinedWorkspaceName:chosen:)``.
    ///
    /// - Parameters:
    ///   - hostKey: The embedder's name for the host.
    ///   - predefinedWorkspaceName: The name the saved host carries, empty when
    ///     it names none.
    /// - Returns: The connect to make.
    public static func decideBeforeListing(host hostKey: String, predefinedWorkspaceName: String) -> Decision {
        let decision = Ubiquitty.Runtime.HostDirectory.decideBeforeListing(std.string(hostKey), std.string(predefinedWorkspaceName))
        return Decision(
            plan: decision.plan,
            sessionID: decision.sessionID,
            workspaceName: String(decision.workspaceName),
            vanishedSessionID: decision.vanishedSessionID,
            isNewSessionOffered: decision.isNewSessionOffered
        )
    }

    /// The installed closures, as one object the C seam's context points at.
    ///
    /// Reentrancy contract, read before touching: the lock guards the POINTER
    /// only — resolving which box is current. The embedder's closures always
    /// run after the lock is released, so a closure that re-enters
    /// `HostDirectory` (recall, remember, or a further `setPersistence`) takes
    /// a free lock and cannot deadlock. Resolving per call (rather than
    /// trusting the context Core passes back) is what keeps every invocation
    /// on the newest box: a replacement that lands mid-flight changes what the
    /// next call resolves, never what an entered one invokes.
    private final class Persistence: @unchecked Sendable {
        let load: Load
        let store: Store

        init(load: @escaping Load, store: @escaping Store) {
            self.load = load
            self.store = store
        }
    }

    /// The box Core may currently invoke, behind a lock.
    ///
    /// Process-immortal: this object is held by the `static let` below, so its
    /// address is a context Core may keep forever. That is what makes the
    /// unretained crossing sound — the referent of an unretained pointer must
    /// outlive every use, and this one outlives the process. Per-install
    /// `Persistence` objects stay retained by this relay (while current) and
    /// by the strong locals of entered closures (while running), so a
    /// replacement destroys nothing Core may still invoke.
    ///
    /// `NSLock` (never held across an embedder call, per the contract on
    /// `Persistence`) rather than an actor, because the `@convention(c)`
    /// closures cannot await.
    private final class PersistenceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Persistence?

        func setCurrent(_ persistence: Persistence) {
            lock.withLock {
                current = persistence
            }
        }

        func resolveCurrent() -> Persistence? {
            lock.withLock {
                current
            }
        }
    }

    /// What ``setPersistence(load:store:)`` last installed, held so the context
    /// Core borrows stays alive exactly while Core may invoke it.
    private static let persistenceBox = PersistenceBox()

    /// What ``setDeployTrustPersistence(load:store:)`` last installed, held
    /// on the same terms as ``persistenceBox``.
    private static let deployTrustBox = PersistenceBox()

    /// Core's `Load`, over the Swift closure.
    ///
    /// The full length is answered whichever buffer arrived, so Core learns
    /// when its own was too small rather than reading a truncated record as a
    /// whole one.
    ///
    /// The raw pointers are the C function-pointer type Core declares, which is
    /// the only shape a `@convention(c)` closure can carry: a Swift-side span or
    /// array would have no representation on the other side of that ABI. They
    /// are read once each, inside this closure, and never stored.
    ///
    /// The box runs resolved, not received: the context Core passes back names
    /// the immortal relay, not any one install. Resolving the live box under
    /// the relay lock keeps every invocation on a box that is alive for the
    /// whole call (the strong local outlives it) and on the newest install
    /// (latest persistence wins). The unretained read of the relay is sound
    /// because nothing ever releases it; per-install boxes are never read
    /// unretained.
    private static let loadThroughClosure:
        @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?, Int) -> Int = {
            context,
            hostKey,
            buffer,
            capacity in
            guard let context, let hostKey else {
                return 0
            }
            let relay = Unmanaged<PersistenceBox>.fromOpaque(context).takeUnretainedValue()
            guard let persistence = relay.resolveCurrent() else {
                return 0
            }
            guard let bytes = persistence.load(String(cString: hostKey)), !bytes.isEmpty else {
                return 0
            }
            if let buffer, capacity > 0 {
                bytes.withUnsafeBufferPointer { source in
                    buffer.update(from: source.baseAddress!, count: min(capacity, bytes.count))
                }
            }
            return bytes.count
        }

    /// Core's `Store`, over the Swift closure.
    ///
    /// Resolved like ``loadThroughClosure``: the live box, held strongly for
    /// the call, so a replacement mid-flight neither destroys what this
    /// invocation runs nor diverts it onto the wrong store.
    private static let storeThroughClosure:
        @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int) ->
            Void = {
                context,
                hostKey,
                bytes,
                byteCount in
                guard let context, let hostKey else {
                    return
                }
                let relay = Unmanaged<PersistenceBox>.fromOpaque(context).takeUnretainedValue()
                guard let persistence = relay.resolveCurrent() else {
                    return
                }
                var record: [UInt8] = []
                if let bytes, byteCount > 0 {
                    record = [UInt8](UnsafeBufferPointer(start: bytes, count: byteCount))
                }
                persistence.store(String(cString: hostKey), record)
            }
}
