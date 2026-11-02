// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CoreText
import Foundation
internal import UbiquittyCore
package import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// How a host answered a request to end one of its sessions.
public enum HostSessionTerminateOutcome: UInt8, Sendable {
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

/// What connecting to a host should do about its sessions.
///
/// `Ubiquitty::Session::AttachPlan`'s cases, re-declared here because this
/// module's public vocabulary is its own, and the Core module it would
/// otherwise name crosses as an internal import. The numbers
/// are pinned to Core's, which pins its own for this side to match.
public enum HostAttachPlan: UInt8, Sendable {
    /// Re-home to the remembered session, which the host still lists or has
    /// not answered about.
    case attachByID = 0
    /// Create a session and name it, because nothing listed bears the name.
    case createNamed = 1
    /// Attach to the listed session bearing the name.
    case attachNamed = 2
    /// Ask the human, because the host has sessions and nothing picks one.
    case chooseFromList = 3
    /// Create a fresh unnamed session, because the host has answered that it
    /// holds none.
    case createNew = 4
    /// Connect nothing yet, because the host has not answered and nothing
    /// remembered names a session; decide again once the listing lands.
    case awaitListing = 5
}

/// What an attach naming a session asks the host when that session has ended.
///
/// `Ubiquitty::Session::ReattachPolicy`'s cases, re-declared here for the reason
/// ``HostAttachPlan`` is, with the same pinned numbers.
public enum RemoteReattachPolicy: UInt8, Sendable {
    /// Reattach, or create a fresh session in place of one that ended.
    case attachOrCreate = 0
    /// Reattach, or be refused; never create. What returning to a remembered
    /// session asks, so a session that ended is reported rather than replaced
    /// by a shell the person would take for their own.
    case attachOnly = 1
}

/// The connect one ``TerminalSurface/decideHostAttach(host:predefinedWorkspaceName:chosen:)``
/// or ``HostDirectory/decideBeforeListing(host:predefinedWorkspaceName:)`` describes.
///
/// The plan and the two values it chose in one answer, so a caller cannot read
/// a session id against a plan that named none.
public struct HostAttachDecision: Sendable {
    /// What to do.
    public let plan: HostAttachPlan
    /// The session the plan lands on: the one to re-home to for
    /// ``HostAttachPlan/attachByID``, and the listed session bearing the name
    /// for ``HostAttachPlan/attachNamed``; 0 otherwise. Only the by-id plan
    /// passes it as `reattachSessionID`; the named plan attaches by name and
    /// carries the id so a picker can mark the row the name resolves to.
    public let sessionID: UInt32
    /// The name to attach under or create under, for the named plans; empty
    /// otherwise. Passed as `workspaceName` to either attach door.
    public let workspaceName: String
    /// The remembered session the host answered without, 0 when the host has
    /// not answered or still lists it. A picker shows it as the session that
    /// ended; it is never attached to.
    public let vanishedSessionID: UInt32
    /// Whether a new unnamed session is offered beside the plan as a second,
    /// different action: false when the plan is that new session, so a
    /// window never shows two buttons doing one thing.
    public let isNewSessionOffered: Bool

    /// The session id an attach door is handed for this plan: the by-id plan's
    /// target, 0 for every other plan.
    public var reattachSessionID: UInt32 { plan == .attachByID ? sessionID : 0 }
}

/// What a host was last attached on, and the one rule that turns that memory, a
/// saved host's predefined workspace name and the host's own answer into a
/// connect.
///
/// The rule is Core's and is never restated by a frontend: two frontends
/// spelling it would answer the same three inputs differently, one reattaching
/// where the other opens a second shell on the same host. Where a record is
/// kept stays the embedder's, so persistence crosses as a pair of closures over
/// bytes whose meaning is Core's alone.
///
/// Static, because the directory is the process's: an app has one saved-host
/// list, so a second one would be a second answer to what a host was last
/// attached on.
public enum HostDirectory {
    /// Reads a host's stored record, or nil when it has none.
    public typealias Load = (String) -> [UInt8]?

    /// Writes a host's record. Empty bytes are how Core spells a host to
    /// forget, so they are stored rather than skipped.
    public typealias Store = (String, [UInt8]) -> Void

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
        UbiquittyRenderKit.HostDirectory.setPersistence(load: load, store: store)
    }

    /// The session a host was last attached on.
    ///
    /// - Parameter hostKey: The embedder's name for the host.
    /// - Returns: The daemon session id, or 0 when the host is unknown.
    public static func rememberedSessionID(host hostKey: String) -> UInt32 {
        UbiquittyRenderKit.HostDirectory.rememberedSessionID(host: hostKey)
    }

    /// The workspace a host was last attached under.
    ///
    /// - Parameter hostKey: The embedder's name for the host.
    /// - Returns: The name, empty for an unnamed session or an unknown host.
    public static func rememberedWorkspaceName(host hostKey: String) -> String {
        UbiquittyRenderKit.HostDirectory.rememberedWorkspaceName(host: hostKey)
    }

    /// Pairs a host with the session it is attached on.
    ///
    /// Made from ``TerminalSurface/remoteSessionID`` rather than from an attach
    /// returning true, which says only that the ask went out.
    ///
    /// - Parameters:
    ///   - hostKey: The embedder's name for the host.
    ///   - sessionID: The session now attached, as the host pinned it.
    ///   - workspaceName: The workspace it is attached under, empty for an
    ///     unnamed session.
    public static func remember(host hostKey: String, sessionID: UInt32, workspaceName: String) {
        UbiquittyRenderKit.HostDirectory.remember(host: hostKey, sessionID: sessionID, workspaceName: workspaceName)
    }

    /// Drops a host's pairing, so the next connect decides as a first one.
    ///
    /// What a refused reattach calls, named by
    /// ``TerminalSurface/refusedReattachSessionID``.
    ///
    /// - Parameter hostKey: The embedder's name for the host.
    public static func forget(host hostKey: String) {
        UbiquittyRenderKit.HostDirectory.forget(host: hostKey)
    }

    /// Installs the embedder's storage for the hosts trusted to receive a
    /// `ubiquitty-host` push: one opaque record under a key Core names.
    ///
    /// - Parameters:
    ///   - load: Reads the record under the key, nil when there is none.
    ///   - store: Writes it; empty bytes trust nobody.
    public static func setDeployTrustPersistence(load: @escaping Load, store: @escaping Store) {
        UbiquittyRenderKit.HostDirectory.setDeployTrustPersistence(load: load, store: store)
    }

    /// Whether the person has trusted a host to receive a push.
    ///
    /// - Parameter sshHost: The ssh destination a push targets.
    /// - Returns: Whether Core's trust list holds it.
    public static func isDeployTrusted(host sshHost: String) -> Bool {
        UbiquittyRenderKit.HostDirectory.isDeployTrusted(host: sshHost)
    }

    /// Records the person's consent to push to a host.
    ///
    /// - Parameter sshHost: The ssh destination.
    public static func trustDeploy(host sshHost: String) {
        UbiquittyRenderKit.HostDirectory.trustDeploy(host: sshHost)
    }

    /// Withdraws the consent to push to a host, so the next push asks again.
    ///
    /// - Parameter sshHost: The ssh destination.
    public static func revokeDeployTrust(host sshHost: String) {
        UbiquittyRenderKit.HostDirectory.revokeDeployTrust(host: sshHost)
    }

    /// Every host trusted to receive a push, in the order trusted.
    public static var deployTrustedHosts: [String] {
        UbiquittyRenderKit.HostDirectory.deployTrustedHosts
    }

    /// The connect to make before the host has answered, over its own record alone: a
    /// predefined name is created under, a remembered session is returned to, and otherwise the
    /// listing is waited for.
    ///
    /// Once the host has answered, decide on its tree through
    /// ``TerminalSurface/decideHostAttach(host:predefinedWorkspaceName:chosen:)``.
    ///
    /// - Parameters:
    ///   - hostKey: The embedder's name for the host.
    ///   - predefinedWorkspaceName: The name the saved host carries, empty when
    ///     it names none.
    /// - Returns: The connect to make.
    public static func decideBeforeListing(host hostKey: String, predefinedWorkspaceName: String) -> HostAttachDecision {
        let decision = UbiquittyRenderKit.HostDirectory.decideBeforeListing(host: hostKey, predefinedWorkspaceName: predefinedWorkspaceName)
        return HostAttachDecision(
            plan: HostAttachPlan(rawValue: decision.plan.rawValue) ?? .chooseFromList,
            sessionID: decision.sessionID,
            workspaceName: decision.workspaceName,
            vanishedSessionID: decision.vanishedSessionID,
            isNewSessionOffered: decision.isNewSessionOffered
        )
    }
}

/// What a host learns about a terminal without reaching inside it.
///
/// One method per ``RuntimeEvents`` flag, because Core already decides what is
/// worth telling a host and a second opinion here would drift from it. A host
/// that wants less implements less: every method is optional through the
/// extension below.
extension TerminalSurface {
    /// What one bell asks of the host, as Core resolved it.
    ///
    /// A Kit value mirroring `PAL::BellCue` field for field. It exists because
    /// the observer protocol is public and its requirements are written into
    /// the module interface, which cannot name a C++ type; the decision behind
    /// each field stays Core's, and this only carries it across.
    public struct BellReaction: Sendable, Equatable {
        /// Which of the two cues the bell rings as.
        public enum Voice: Sendable, Equatable {
            /// Nothing: the reader turned the bell off.
            case silent
            /// The beep alone.
            case audible
            /// The inverse-colour flash alone.
            case visual
            /// Both.
            case audibleAndVisual
        }

        /// The cue to execute.
        public var voice: Voice
        /// DECSET 1043: the window asks to be brought forward.
        public var shouldPopWindow: Bool
        /// DECSET 1042: the window asks to be marked urgent.
        public var shouldRaiseUrgency: Bool
        /// Whether the bell rang where nobody was looking, so it is worth a
        /// desktop notification. Core decides; the host posts.
        public var shouldNotify: Bool

        /// Whether the cue includes the beep.
        public var isAudible: Bool { voice == .audible || voice == .audibleAndVisual }

        /// Carries Core's cue across the module wall.
        ///
        /// - Parameter cue: The cue the session resolved for this bell.
        internal init(_ cue: Ubiquitty.BellCue) {
            // Compared rather than switched: a closed C++ enum traps on a raw
            // value Swift cannot name, and `silent` is the answer for one.
            if cue.mode == .Both {
                voice = .audibleAndVisual
            } else if cue.mode == .Audio {
                voice = .audible
            } else if cue.mode == .Visual {
                voice = .visual
            } else {
                voice = .silent
            }
            shouldPopWindow = cue.shouldPopWindow
            shouldRaiseUrgency = cue.shouldRaiseUrgency
            shouldNotify = cue.shouldNotify
        }
    }
}

public protocol TerminalSurfaceObserver: AnyObject {
    /// Resolves the pane displaying the surface in its current host arrangement.
    ///
    /// - Parameter surface: The originating surface.
    /// - Returns: Its pane identifier, or nil when it is no longer displayed.
    func terminalSurfacePaneIdentifier(_ surface: TerminalSurface) -> Int?

    /// Reports whether a displayed title consumes sampled process facts.
    ///
    /// - Parameter surface: The pane whose metadata would be sampled.
    /// - Returns: Whether any displayed title needs process facts.
    func terminalSurfaceNeedsProcessState(_ surface: TerminalSurface) -> Bool

    /// The terminal's OSC title changed.
    ///
    /// Delivered as a value rather than drawn, so one surface serves a pane
    /// header, a tab and a window title without knowing which exist.
    ///
    /// - Parameters:
    ///   - surface: The surface whose title changed.
    ///   - title: The new title.
    func terminalSurface(_ surface: TerminalSurface, didChangeTitle title: String)

    /// The session reported a working directory (OSC 7, OSC 633 Cwd, OSC
    /// 1337 CurrentDir).
    ///
    /// A value, as the title is: the window title, the proxy icon and a pane
    /// header all read the same directory, and none of them owns it.
    ///
    /// - Parameters:
    ///   - surface: The surface whose directory changed.
    ///   - directory: The reported directory, as an absolute path.
    func terminalSurface(_ surface: TerminalSurface, didChangeCurrentDirectory directory: String)

    /// The sampled process facts moved — a different foreground chain, or a
    /// session-leader shell resolved for the first time.
    ///
    /// The facts are read beside this rather than carried in it, the shape
    /// every list-valued report takes here: ``RuntimeDrive/processChain`` and
    /// the properties next to it. A title woven from those segments has no
    /// other edge to redraw on.
    ///
    /// - Parameter surface: The surface whose process sample moved.
    func terminalSurfaceDidChangeProcessState(_ surface: TerminalSurface)

    /// The child process exited or the stream ended.
    ///
    /// - Parameter surface: The surface whose session ended.
    func terminalSurfaceDidExit(_ surface: TerminalSurface)

    /// The reader asked for a keyboard.
    ///
    /// Raised by a tap while no keyboard is up. The surface reports the ask
    /// rather than raising one itself: on a phone the first responder that
    /// carries keys is the host's, and which view holds it is the host's
    /// arrangement, not the terminal's.
    ///
    /// - Parameter surface: The surface whose reader asked to type.
    func terminalSurfaceDidRequestKeyboard(_ surface: TerminalSurface)

    /// Where the view stands in the scrollback changed, or output arrived
    /// below a view held back in it.
    ///
    /// Raised by the touch shell, which draws no scroll bar of its own: how a
    /// phone shows the position, and how a reader gets back to the live
    /// output, is the host's arrangement.
    ///
    /// - Parameters:
    ///   - surface: The surface whose view moved.
    ///   - position: Where the view now stands.
    func terminalSurface(_ surface: TerminalSurface, didChangeScrollback position: TerminalScrollbackPosition)

    /// The reader asked for the host's own settings, with two fingers.
    ///
    /// Raised rather than acted on, for the same reason the keyboard is: what
    /// settings are and where they appear is the host's arrangement. The
    /// terminal owns only the fact that a gesture it does not otherwise use
    /// asked for them.
    ///
    /// - Parameter surface: The surface whose reader asked.
    func terminalSurfaceDidRequestSettings(_ surface: TerminalSurface)

    /// The reader swiped one finger leftward, asking for the next tab.
    ///
    /// Raised rather than acted on: which tabs exist and in what order is the
    /// host's workspace, and a surface draws one pane of it.
    ///
    /// - Parameter surface: The surface the reader swiped.
    func terminalSurfaceDidRequestNextTab(_ surface: TerminalSurface)

    /// The reader swiped one finger rightward, asking for the previous tab.
    ///
    /// - Parameter surface: The surface the reader swiped.
    func terminalSurfaceDidRequestPreviousTab(_ surface: TerminalSurface)

    /// The reader swiped two fingers leftward, asking for the next connection.
    ///
    /// What a connection is, and which ones are open, is the host
    /// application's: the surface knows only the session it draws.
    ///
    /// - Parameter surface: The surface the reader swiped.
    func terminalSurfaceDidRequestNextConnection(_ surface: TerminalSurface)

    /// The reader swiped two fingers rightward, asking for the previous connection.
    ///
    /// - Parameter surface: The surface the reader swiped.
    func terminalSurfaceDidRequestPreviousConnection(_ surface: TerminalSurface)

    /// BEL arrived, and the surface has already drawn its half of the answer.
    ///
    /// What is left is the host's: the sound, the Dock, a banner. Core
    /// resolved all of it into one cue; this carries that cue as a Kit value
    /// rather than as Core's own struct, because a public requirement is part
    /// of the module's interface and the interface cannot name a C++ type —
    /// the same wall `UInt32` once stood in for here.
    ///
    /// - Parameters:
    ///   - surface: The surface that received it.
    ///   - reaction: What the bell asked of the host, as Core decided it.
    func terminalSurface(_ surface: TerminalSurface, didRingBell reaction: TerminalSurface.BellReaction)

    /// The surface's remote host has no `ubiquitty-host` and the user has
    /// not approved installing one there.
    ///
    /// Ask, then answer with
    /// ``RuntimeDrive/resolveDeployConfirmation(_:)``. Nothing is
    /// installed until you do, and the session holds the attempt open.
    ///
    /// - Parameter surface: The surface whose session asked.
    func terminalSurfaceRequestsDeployConfirmation(_ surface: TerminalSurface)

    /// The push of `ubiquitty-host` to the surface's remote host failed.
    ///
    /// The connection has already gone Failed and says so; this is the
    /// install's own account, read through ``RuntimeDrive/lastDeployFailure``,
    /// which names what the person has to fix on the host.
    ///
    /// - Parameter surface: The surface whose session pushed.
    func terminalSurfaceDidFailHostDeploy(_ surface: TerminalSurface)

    /// Who is attached to the surface's session changed — someone joined,
    /// left, or had a grant altered.
    ///
    /// The roster is read beside this through ``RuntimeDrive/attendees``, the
    /// shape every list-valued report takes here. A host shows it and offers
    /// what can be done about it; the surface only knows that it moved.
    ///
    /// - Parameter surface: The surface whose roster changed.
    func terminalSurfaceDidChangePresence(_ surface: TerminalSurface)

    /// A consent question is about to go up on this surface's window.
    ///
    /// Raised before the sheet, so a host whose window is a background tab,
    /// occluded, or behind another app can surface the question without taking
    /// focus — the sheet is otherwise never seen and the daemon holds the agent
    /// until its timeout, which reads to the person as nothing having happened.
    ///
    /// - Parameters:
    ///   - surface: The surface whose session was asked about.
    ///   - question: What the agent wants, in the words the sheet asks it.
    ///   - actor: The verified name of who is asking.
    func terminalSurface(_ surface: TerminalSurface, willAskForConsent question: String, from actor: String)

    /// Notifies an embedder that Core is waiting for a consent decision.
    func terminalSurfaceDidRequestConsent(_ surface: TerminalSurface)

    /// The surface's remote host has no `ubiquitty-host` and no automatic
    /// install can supply one.
    ///
    /// The commands a person runs by hand ride
    /// ``RuntimeDrive/manualHostInstallCommands``, and why they are needed
    /// rides ``RuntimeDrive/isManualInstallForSetting``.
    ///
    /// - Parameter surface: The surface whose session asked.
    func terminalSurfaceNeedsManualHostInstall(_ surface: TerminalSurface)

    /// The host answered a file this surface asked it for.
    ///
    /// Take the answers with ``RuntimeDrive/takeRemoteFile()`` until it
    /// answers nil: it is a queue, one call drains one answer, and this is
    /// raised once for however many arrived in the pass. What a host sent is
    /// not what this machine produced, so a host writing it to disk lands it
    /// the way a browser download lands.
    ///
    /// - Parameter surface: The surface whose session asked.
    func terminalSurfaceDidReceiveHostFile(_ surface: TerminalSurface)

    /// The model changed and a repaint is due.
    ///
    /// The surface schedules its own redraw before this arrives; a host needs it
    /// only for chrome that tracks activity, such as a tab's unread dot.
    ///
    /// - Parameter surface: The surface whose screen changed.
    func terminalSurfaceDidUpdateScreen(_ surface: TerminalSurface)

    /// The palette moved while the surface draws no frame.
    ///
    /// A pane nothing composites holds its screen updates for the reveal, but
    /// what a host draws from the pane's colours outside it, a background
    /// tab's label among it, is on screen and follows them now: a theme
    /// change reaches a hidden remote pane only as its host applies it, after
    /// every window was told of the change itself.
    ///
    /// - Parameter surface: The surface whose palette moved.
    func terminalSurfaceDidChangeWithheldPalette(_ surface: TerminalSurface)

    /// The link under the pointer changed, or there is none.
    ///
    /// Its own callback rather than a flag the host polls: the preview is
    /// chrome outside the pane, and the surface is what knows when the pointer
    /// moved onto a different run.
    ///
    /// - Parameters:
    ///   - surface: The surface the pointer is over.
    ///   - target: What a click would open, or nil where no link is hovered.
    func terminalSurface(_ surface: TerminalSurface, didChangeLinkPreview target: String?)

    /// The program's OSC 9;4 progress report moved.
    ///
    /// Its own callback rather than a screen update: a report changes no cell,
    /// so a host watching the screen never hears about the one thing this
    /// escape exists to say.
    ///
    /// - Parameter surface: The surface whose report moved.
    func terminalSurfaceDidChangeProgress(_ surface: TerminalSurface)

    /// The find search published counts, progress, or focus.
    ///
    /// - Parameter surface: The surface whose search status changed.
    func terminalSurfaceDidChangeSearch(_ surface: TerminalSurface)

    /// The session's own tab status colour moved (OSC 21337).
    ///
    /// Its own callback for the reason the progress report has one, and one
    /// sharper: the escape exists to speak for a session nobody is looking at,
    /// so a host that heard about it only on the next screen update would show
    /// "waiting" at the moment the waiting ended.
    ///
    /// - Parameter surface: The surface whose colour moved.
    func terminalSurfaceDidChangeTabStatus(_ surface: TerminalSurface)

    /// The selection changed — began, grew, cleared or was replaced.
    ///
    /// - Parameter surface: The surface whose selection changed.
    func terminalSurfaceSelectionDidChange(_ surface: TerminalSurface)

    /// The model's belief that a password prompt is on screen changed —
    /// private mode 7401, or the `[security] password_detect` heuristic.
    ///
    /// The surface shows its lock and masks local echo itself; a host hears
    /// this to hold Secure Keyboard Entry for the prompt, or to mark a tab.
    ///
    /// - Parameters:
    ///   - surface: The surface whose prompt state changed.
    ///   - isActive: Whether a password prompt is on screen now.
    func terminalSurface(_ surface: TerminalSurface, didChangePasswordPrompt isActive: Bool)

    /// Bytes this surface just encoded and wrote to its host.
    ///
    /// The wire bytes rather than the event, which is what a host broadcasting
    /// one keystroke to several panes needs: re-encoding per pane would read
    /// each pane's own modes and send a different sequence to each.
    ///
    /// - Parameters:
    ///   - surface: The surface that encoded them.
    ///   - bytes: The buffer, whose first `count` entries are the sequence.
    ///   - count: How many bytes the encoder wrote.
    func terminalSurface(_ surface: TerminalSurface, didTransmit bytes: [CChar], count: Int)

    /// The view's size crossed a cell boundary and the grid was republished.
    ///
    /// Delivered after the session hears the new size, so a host reading the
    /// grid off the surface sees the dimensions the shell was just told. A
    /// resize that moves only pixels — a backing-scale change — fires nothing.
    ///
    /// - Parameters:
    ///   - surface: The surface whose grid changed.
    ///   - rows: The new row count.
    ///   - columns: The new column count.
    func terminalSurface(_ surface: TerminalSurface, didResizeGridTo rows: Int, columns: Int)

    /// Reports whether the host's resize should preserve the visible top row when growing.
    ///
    /// - Parameter surface: The surface being resized.
    /// - Returns: Whether the host is expanding from the visible content's top.
    func terminalSurfacePreservesVisibleTopOnResize(_ surface: TerminalSurface) -> Bool

    /// The surface gained or lost first-responder status.
    ///
    /// - Parameters:
    ///   - surface: The surface whose focus changed.
    ///   - isFocused: Whether it holds focus.
    func terminalSurface(_ surface: TerminalSurface, didChangeFocus isFocused: Bool)

    /// A file-transfer handshake was detected in the stream.
    ///
    /// The detector disarms on firing; call
    /// ``RuntimeDrive/armFileTransferWatch()`` again after the transfer
    /// completes (or is dismissed) to resume monitoring.
    ///
    /// - Parameter surface: The surface whose session detected the preamble.
    func terminalSurfaceDidDetectFileTransfer(_ surface: TerminalSurface)

    /// A pushed paste settled: the host either landed it or refused it.
    ///
    /// The landed path is on the surface — the event carries scalars only —
    /// and it is already typed into the program by the time this arrives.
    ///
    /// - Parameters:
    ///   - surface: The surface the push crossed on.
    ///   - status: The wire's paste-push status value.
    func terminalSurface(_ surface: TerminalSurface, didSettlePastePushWithStatus status: UInt32)

    /// A host answered what sessions it is holding.
    ///
    /// The host's tree is held on the surface — an event carries scalars only —
    /// and a connect is decided on it through
    /// ``TerminalSurface/decideHostAttach(host:predefinedWorkspaceName:chosen:)``.
    /// An answer that could not be got holds no tree rather than the previous
    /// one, so a picker never offers a row the host may no longer have.
    ///
    /// - Parameter surface: The surface that asked.
    func terminalSurfaceDidUpdateHostSessions(_ surface: TerminalSurface)

    /// A request to end one of a host's sessions settled.
    ///
    /// A refused, denied or timed-out terminate is not a session that went
    /// away, so a host removes the row on the outcome rather than on the ask.
    ///
    /// - Parameters:
    ///   - surface: The surface that asked.
    ///   - sessionID: The session the request named.
    ///   - outcome: What the daemon did, or nil for an outcome this build does
    ///     not know — which a host must not read as the session being gone.
    func terminalSurface(_ surface: TerminalSurface, didSettleHostSessionTerminate sessionID: UInt32, outcome: HostSessionTerminateOutcome?)

    /// A change asked of a listed host's structure — a rename, a label —
    /// ended; how rides ``RuntimeDrive/lastHostStructureResult``. A served
    /// change is followed by a listing, which reports itself.
    ///
    /// - Parameter surface: The surface that asked.
    func terminalSurfaceDidSettleHostStructure(_ surface: TerminalSurface)

    /// The remote connection moved, or the host pinned this session's id.
    ///
    /// One hook for both because a frontend reads the same three properties either way:
    /// ``TerminalSurface/remoteSessionID`` is what a pairing is made from,
    /// ``TerminalSurface/wasReattachRefused`` says a remembered session must be replaced rather
    /// than retried, and ``TerminalSurface/remoteFailureDetail`` is the host's own sentence for
    /// why. An event carries scalars, so all three are read from the surface.
    ///
    /// - Parameter surface: The surface whose remote connection moved.
    func terminalSurfaceDidChangeRemoteSession(_ surface: TerminalSurface)

    /// Some of what was typed into this surface's remote pane may not have
    /// reached the host, or the person decided what to do with it.
    ///
    /// Core decides which input is in doubt and words the notice: read
    /// ``RuntimeDrive/inputInDoubtNotice``, nil once no decision is awaited.
    /// Show it beside the pane without blocking it, and answer with
    /// ``RuntimeDrive/resendInputInDoubt()`` or
    /// ``RuntimeDrive/discardInputInDoubt()`` only at the person's word:
    /// sending again can run a command twice. Until then what the person
    /// types waits behind the input in doubt.
    ///
    /// - Parameter surface: The surface whose pane's input is in doubt.
    func terminalSurfaceDidChangeInputInDoubt(_ surface: TerminalSurface)

    /// The host's workspace was mirrored anew: on attach, and after every verb the host
    /// performed, whichever client sent it.
    ///
    /// A topology is not a scalar, so it is read from the drive beside this —
    /// ``RuntimeDrive/remoteWorkspacePane`` names this surface's pane, and the surface, tab and
    /// tree getters after it describe what the host holds around it, with the host's ids.
    ///
    /// - Parameter surface: The surface whose host workspace changed.
    func terminalSurfaceDidChangeRemoteWorkspace(_ surface: TerminalSurface)

    /// An application asked for a font swap with OSC 50.
    ///
    /// Reported rather than applied here because what answers the request is
    /// the HOST's: it knows the configuration the reset falls back to and it
    /// owns the window the new metrics resize. The surface's part is noticing
    /// that a request arrived, which only it can do — it is the thing that
    /// drains.
    ///
    /// - Parameter surface: The surface whose session carries the request.
    func terminalSurfaceDidRequestFontSwap(_ surface: TerminalSurface)

    /// An application asked for something only a window can do.
    ///
    /// A CSI t window operation, a DECCOLM column change, OSC 1337 StealFocus,
    /// an attention request or an OSC 1337 colour preset — the whole
    /// `WindowClient` surface, which this arm cannot install because Swift
    /// cannot subclass a C++ class with virtual methods. Core queues them
    /// instead and the surface reports that the queue is not empty.
    ///
    /// Carries no request, on the same terms as the font swap above: the
    /// answerer drains ``RuntimeDrive/takeWindowRequest()`` until it is empty,
    /// which is also what keeps a shell that ignores this from leaving a queue
    /// filling behind it — nothing arrives that nobody asked for.
    ///
    /// - Parameter surface: The surface whose session carries the requests.
    func terminalSurfaceDidRequestWindowOperation(_ surface: TerminalSurface)

    /// An application asked for a desktop notification.
    ///
    /// OSC 9 (iTerm), OSC 99 (kitty) or OSC 777;notify (urxvt) — the
    /// `ShellClient` notification hook, which this arm cannot install for the
    /// reason the window verbs above give. Core queues the resolved title and
    /// body instead and the surface reports that the queue is not empty.
    ///
    /// Carries no banner, on the same terms: the host drains
    /// ``RuntimeDrive/takeNotification()`` until it is empty, which is also
    /// what keeps a host that ignores this from leaving a queue filling behind
    /// it. Whether a banner is posted at all stays the host's — Core has
    /// already applied the `DesktopNotification` capability gate, and the
    /// reader's `[notifications]` preference is read where the post is made.
    ///
    /// - Parameter surface: The surface whose session carries the banners.
    func terminalSurfaceDidPostNotification(_ surface: TerminalSurface)

    /// A configured trigger matched a line and has an act for the host.
    ///
    /// The `TriggerClient` hook, which this arm cannot install for the reason
    /// the window verbs above give. Core queues the engine's reports and the
    /// surface reports that the queue is not empty.
    ///
    /// Carries no act, on the same terms: the host drains
    /// ``RuntimeDrive/takeTriggerEffect(_:)`` until it is empty. What each act
    /// is, and whether `[triggers]` lets a spawn or a POST through at all, is
    /// Core's answer on that call; the host performs it.
    ///
    /// - Parameter surface: The surface whose session carries the reports.
    func terminalSurfaceDidMatchTrigger(_ surface: TerminalSurface)

    /// The windows the surface's program hosts changed.
    ///
    /// A program speaking for windows of its own — a typed `tmux -CC` — had
    /// one open, laid out, renamed or closed, or a hosted pane's model moved.
    /// Carries nothing: the host drains
    /// ``RuntimeDrive/takeHostedWindowEvent()`` and
    /// ``RuntimeDrive/takeRepaintedHostedPanes()`` until each is empty.
    ///
    /// - Parameter surface: The surface whose session hosts the windows.
    func terminalSurfaceDidChangeHostedWindows(_ surface: TerminalSurface)

    /// The words Core wants shown for a gesture nobody can see changed.
    ///
    /// Core decides the words and for how long they stand -- a swallowed
    /// drag's lesson fades on Core's clock, the pointer-lock lesson stands
    /// while the grab does -- and this fires only when the answer changes. A
    /// shell shows the text, hides its chrome when the text is empty, and
    /// keeps no clock of its own.
    ///
    /// - Parameters:
    ///   - surface: The surface whose hint changed.
    ///   - text: What to show, empty when nothing stands.
    func terminalSurface(_ surface: TerminalSurface, didChangeHint text: String)
}

extension TerminalSurfaceObserver {
    public func terminalSurfaceNeedsProcessState(_ surface: TerminalSurface) -> Bool { true }

    public func terminalSurfaceDidChangeHostedWindows(_: TerminalSurface) {}
    public func terminalSurface(_: TerminalSurface, didChangeTitle _: String) {}
    public func terminalSurface(_: TerminalSurface, didChangeCurrentDirectory _: String) {}
    public func terminalSurfaceDidChangeProcessState(_: TerminalSurface) {}
    public func terminalSurfaceDidExit(_: TerminalSurface) {}
    public func terminalSurface(_: TerminalSurface, didRingBell _: TerminalSurface.BellReaction) {}

    /// A host that never offers an install never asks, so the default is to
    /// decline nothing and answer nothing.
    ///
    /// - Parameter surface: The surface whose session asked.
    public func terminalSurfaceRequestsDeployConfirmation(_: TerminalSurface) {}
    /// A host that never offers an install has no failure to report.
    public func terminalSurfaceDidFailHostDeploy(_: TerminalSurface) {}
    /// A host that never attaches remotely has no install to explain.
    public func terminalSurfaceNeedsManualHostInstall(_: TerminalSurface) {}
    /// A host that asks for no files is answered with none.
    public func terminalSurfaceDidReceiveHostFile(_: TerminalSurface) {}
    /// A host with no roster to show hears the changes and does nothing.
    public func terminalSurfaceDidChangePresence(_: TerminalSurface) {}
    /// A host with one window in front of the reader has nothing to surface.
    public func terminalSurface(_: TerminalSurface, willAskForConsent _: String, from _: String) {}

    /// Leaves the pane unnamed when the embedder has no arrangement.
    public func terminalSurfacePaneIdentifier(_: TerminalSurface) -> Int? { nil }

    /// Leaves consent presentation to an interested embedder.
    public func terminalSurfaceDidRequestConsent(_: TerminalSurface) {}
    public func terminalSurfaceDidUpdateScreen(_: TerminalSurface) {}
    public func terminalSurfaceDidChangeWithheldPalette(_: TerminalSurface) {}
    public func terminalSurfaceDidChangeProgress(_: TerminalSurface) {}
    public func terminalSurfaceDidChangeSearch(_: TerminalSurface) {}
    public func terminalSurfaceDidChangeTabStatus(_: TerminalSurface) {}
    public func terminalSurface(_: TerminalSurface, didChangeLinkPreview _: String?) {}
    public func terminalSurfaceSelectionDidChange(_: TerminalSurface) {}

    /// A host with no keyboard to raise has none to answer with.
    ///
    /// - Parameter surface: The surface whose reader asked to type.
    public func terminalSurfaceDidRequestKeyboard(_: TerminalSurface) {}
    /// A host with no settings to show has none to answer with.
    public func terminalSurfaceDidRequestSettings(_: TerminalSurface) {}
    /// A host that draws no scroll position has nothing to update.
    public func terminalSurface(_: TerminalSurface, didChangeScrollback _: TerminalScrollbackPosition) {}
    /// A host with one tab has nowhere to switch to.
    public func terminalSurfaceDidRequestNextTab(_: TerminalSurface) {}
    /// A host with one tab has nowhere to switch to.
    public func terminalSurfaceDidRequestPreviousTab(_: TerminalSurface) {}
    /// A host with one connection has nowhere to switch to.
    public func terminalSurfaceDidRequestNextConnection(_: TerminalSurface) {}
    /// A host with one connection has nowhere to switch to.
    public func terminalSurfaceDidRequestPreviousConnection(_: TerminalSurface) {}
    public func terminalSurface(_: TerminalSurface, didChangePasswordPrompt _: Bool) {}
    public func terminalSurface(_: TerminalSurface, didTransmit _: [CChar], count _: Int) {}
    public func terminalSurface(_: TerminalSurface, didResizeGridTo _: Int, columns _: Int) {}

    /// Retains ordinary resize anchoring when the host supplies no expansion intent.
    public func terminalSurfacePreservesVisibleTopOnResize(_: TerminalSurface) -> Bool { false }
    public func terminalSurface(_: TerminalSurface, didChangeFocus _: Bool) {}

    /// A host with no chrome to teach in stays quiet.
    ///
    /// Silence is the safe default: a hint is a courtesy, and an embedder that
    /// drops it loses discoverability rather than function. A shell without
    /// chrome that still wants to teach draws Core's own in-grid toast
    /// (``Rendering/layoutHintToast``) instead of implementing this.
    public func terminalSurface(_: TerminalSurface, didChangeHint _: String) {}
    /// Re-arms the watch, which also lifts the ingest hold the detection set.
    ///
    /// The default answers for an observer that offers no transfer UI, and it
    /// must resume the stream: a detection parks ingest until something
    /// answers, so a no-op default would freeze the session of every embedder
    /// that never heard of file transfer.
    public func terminalSurfaceDidDetectFileTransfer(_ surface: TerminalSurface) {
        // Observer calls arrive on the main thread — the surface's delivery
        // contract — so the hop asserts rather than re-dispatches.
        MainActor.assumeIsolated { surface.drive.armFileTransferWatch() }
    }

    /// An embedder that never pushes a paste never sees one settle.
    public func terminalSurface(_: TerminalSurface, didSettlePastePushWithStatus _: UInt32) {}
    /// A host that never asks what sessions a host holds never hears an answer.
    public func terminalSurfaceDidUpdateHostSessions(_: TerminalSurface) {}
    /// A host that never asks to end a session never sees one settle.
    public func terminalSurface(_: TerminalSurface, didSettleHostSessionTerminate _: UInt32, outcome _: HostSessionTerminateOutcome?) {}
    /// A host that never asks for a structure change never sees one settle.
    public func terminalSurfaceDidSettleHostStructure(_: TerminalSurface) {}
    /// A host that does not resize windows has no font swap to apply.
    public func terminalSurfaceDidRequestFontSwap(_: TerminalSurface) {}
    /// A host with no window to move ignores what a program asks of one.
    public func terminalSurfaceDidRequestWindowOperation(_: TerminalSurface) {}
    /// A host with no desktop to banner on drops what a program asks for.
    public func terminalSurfaceDidPostNotification(_: TerminalSurface) {}
    public func terminalSurfaceDidMatchTrigger(_: TerminalSurface) {}
    /// A host with nothing to pair a session against has nothing to hear.
    public func terminalSurfaceDidChangeRemoteSession(_: TerminalSurface) {}
    /// A host that never attaches remotely never has input in doubt.
    public func terminalSurfaceDidChangeInputInDoubt(_: TerminalSurface) {}
    public func terminalSurfaceDidChangeRemoteWorkspace(_: TerminalSurface) {}
}

/// The immutable geometry of one submitted grid frame, in view points.
/// Queries keep this value while model snapshots, style, or view bounds change.
public struct TerminalSurfaceFrameGeometry {
    public let rows: Int32
    public let columns: Int32
    public let cellSize: CGSize
    public let insets: PlatformEdgeInsets
    public let clip: CGRect?
    public let deviceScale: Double
    public let isFullscreenContentActive: Bool

    /// Stores the geometry used by one submitted frame.
    ///
    /// - Parameters:
    ///   - rows: The captured grid height.
    ///   - columns: The captured grid width.
    ///   - cellSize: The drawn cell size in view points.
    ///   - insets: The drawn grid origin and padding in view points.
    ///   - clip: The content viewport in view points, or nil when unclipped.
    ///   - deviceScale: The submitted frame's backing pixels per point.
    ///   - isFullscreenContentActive: Whether pixel reports use the drawable origin.
    public init(
        rows: Int32,
        columns: Int32,
        cellSize: CGSize,
        insets: PlatformEdgeInsets,
        clip: CGRect?,
        deviceScale: Double,
        isFullscreenContentActive: Bool
    ) {
        self.rows = rows
        self.columns = columns
        self.cellSize = cellSize
        self.insets = insets
        self.clip = clip
        self.deviceScale = deviceScale
        self.isFullscreenContentActive = isFullscreenContentActive
    }
}

/// Draws a surface's content, supplied rather than owned.
///
/// Injected for the same reason chrome is, and for one more: a renderer holds
/// the glyph atlases, which are cut for a font at a scale and cost real memory
/// and rasterisation to fill. Every pane in a window shares one, so a surface
/// that built its own would rasterise the same glyphs once per pane and hold a
/// texture set per pane.
///
/// The surface still owns its layer and its geometry — the renderer is told
/// where to draw and what to draw from, never asked for either.
@MainActor
public protocol TerminalSurfaceRenderer: AnyObject {
    /// Returns the last submitted frame's geometry.
    ///
    /// A declined or detached render preserves the previous value.
    /// - Parameter surface: The surface whose frame is queried.
    /// - Returns: The submitted geometry, or nil before a grid frame.
    func presentedGeometry(for surface: TerminalSurface) -> TerminalSurfaceFrameGeometry?

    /// The font's em size in points, including the renderer's current zoom.
    var pointSize: Double { get }

    /// One cell's size in points, which is what turns a view size into a grid.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The cell size; a non-positive dimension suspends resizing.
    func cellSize(for surface: TerminalSurface) -> CGSize

    /// The cell as the frame draws it, in points — the natural one, or the
    /// advance DECCOLM compressed so 132 columns fit the width.
    ///
    /// The pointer and every piece of chrome placed on a cell map through
    /// this one; the grid fit, the window sizing and the published cell
    /// pixel size keep ``cellSize(for:)``, the natural advance.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The drawn cell size.
    func drawnCellSize(for surface: TerminalSurface) -> CGSize

    /// Draws one frame of this surface's terminal into its layer.
    ///
    /// - Parameters:
    ///   - surface: The surface to draw. Its ``TerminalSurface/drive`` carries
    ///     the model, and bracketing the read is the renderer's to do — it knows
    ///     which of its passes touch the model and for how long.
    ///   - layer: The layer to present into.
    /// - Returns: Whether a frame was drawn. False leaves the previous frame on
    ///   screen, which is the right outcome when nothing changed.
    @discardableResult
    func encodeFrame(for surface: TerminalSurface, into layer: CAMetalLayer) -> Bool

    /// Whether `surface`'s last drawn frame captured any row differing from the
    /// shadow baseline. Valid only after `encodeFrame(for:into:)` returned true.
    func lastFrameHadNetChange(for surface: TerminalSurface) -> Bool

    /// Readies whatever the renderer measures per backing scale.
    ///
    /// Called when a surface's scale changes, ahead of the grid it publishes:
    /// a renderer whose cell is measured off faces built at the scale reports
    /// the previous display's cell until it has remeasured.
    ///
    /// - Parameter scale: Backing pixels per point, from the surface's layer.
    func prepare(forDeviceScale scale: Double)

    /// The insets the frame draws inside, in points.
    ///
    /// The surface subtracts these when it maps a pointer to a cell and when
    /// it places chrome on one, so a renderer that letterboxes must answer the
    /// same insets its frame draws with, or the pointer lands one padding-width
    /// off every cell it names. Not what the grid is FITTED inside: DECSET
    /// 7402 draws the frame edge to edge without moving a column, so the two
    /// differ exactly while it holds — see ``gridFitInsets(for:)``.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The insets, top carrying any extra reserved band.
    func gridInsets(for surface: TerminalSurface) -> PlatformEdgeInsets

    /// The visible content clip for a translated host grid, in view points.
    /// - Parameter surface: The independently sized view.
    /// - Returns: Nil when the grid has no additional viewport clip.
    func contentClip(for surface: TerminalSurface) -> CGRect?

    /// The column under a point along a row the last frame laid out as
    /// proportional runs (Docs/proportional-text.md), or nil for a row on the
    /// grid, where the surface's own arithmetic answers.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row under the point.
    ///   - xInCells: The point along the row, in drawn cells from the grid's left edge.
    /// - Returns: The column, or nil.
    func letterColumn(for surface: TerminalSurface, row: Int32, xInCells: Double) -> Int32?

    /// Where a point is along such a row in cells — the column plus the
    /// fraction of its letter crossed — or nil for a row on the grid.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row under the point.
    ///   - xInCells: The point along the row, in drawn cells from the grid's left edge.
    /// - Returns: The position, or nil.
    func letterXInCells(for surface: TerminalSurface, row: Int32, xInCells: Double) -> Double?

    /// The insets the grid is fitted inside — window padding plus any
    /// reserved band — in points.
    ///
    /// The surface subtracts these when it fits a grid to its bounds and when
    /// it sizes a window to a grid. They stand whatever the frame draws, so an
    /// application that takes the frame edge to edge is not resized for it.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The insets, top carrying any extra reserved band.
    func gridFitInsets(for surface: TerminalSurface) -> PlatformEdgeInsets

    /// Readies a layer this renderer will draw into.
    ///
    /// A `CAMetalLayer` hands out no drawable until it carries the device and
    /// pixel format its frames are built for; without them `nextDrawable`
    /// answers nil forever and every encode refuses, which reaches a viewer as
    /// a window that never paints rather than as an error.
    ///
    /// The renderer sets them because the renderer owns both — a surface
    /// naming a device would be a second opinion about which one draws.
    ///
    /// - Parameter layer: The layer to ready.
    func prepare(_ layer: CAMetalLayer)

    /// Redraws at a new em size.
    ///
    /// The surface asks; the renderer keeps the rest of its font configuration,
    /// because the size is the only part a zoom moves and a caller restating
    /// the family and features would be a second opinion about them.
    ///
    /// Changing this changes the cell size, so the surface re-fits its grid
    /// afterwards — a renderer that answers a new size without the grid
    /// following draws the old row count at the new scale.
    ///
    /// - Parameter pointSize: The em size to draw at.
    func adopt(pointSize: Double)
}

extension TerminalSurfaceRenderer {
    /// Does nothing, for a renderer that measures nothing per scale.
    ///
    /// - Parameter scale: Backing pixels per point.
    public func prepare(forDeviceScale scale: Double) {}

    /// Does nothing, for a renderer whose size is not the surface's to move.
    ///
    /// Defaulted rather than required so a zoom gesture is inert on such a
    /// renderer instead of a compile error for the embedder that wrote it.
    ///
    /// - Parameter pointSize: The em size that would be adopted.
    public func adopt(pointSize: Double) {}

    /// The cell size committed with the submitted grid frame.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The drawn cell size, or zero before a grid frame.
    public func drawnCellSize(for surface: TerminalSurface) -> CGSize {
        presentedGeometry(for: surface)?.cellSize ?? .zero
    }

    /// The insets committed with the submitted grid frame.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: The drawn insets, or zero before a grid frame.
    public func gridInsets(for surface: TerminalSurface) -> PlatformEdgeInsets {
        presentedGeometry(for: surface)?.insets ?? PlatformEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// The clip committed with the submitted grid frame.
    /// - Parameter surface: The surface asking.
    /// - Returns: The drawn clip, or nil for an unclipped or absent frame.
    public func contentClip(for surface: TerminalSurface) -> CGRect? { presentedGeometry(for: surface)?.clip }

    /// Every row on the grid, for a renderer that keeps no letter layout.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row.
    ///   - xInCells: The point along the row.
    /// - Returns: Nil.
    public func letterColumn(for surface: TerminalSurface, row: Int32, xInCells: Double) -> Int32? { nil }

    /// Every row on the grid, for a renderer that keeps no letter layout.
    ///
    /// - Parameters:
    ///   - surface: The surface asking.
    ///   - row: The visible row.
    ///   - xInCells: The point along the row.
    /// - Returns: Nil.
    public func letterXInCells(for surface: TerminalSurface, row: Int32, xInCells: Double) -> Double? { nil }

    /// Zero on every side: a renderer with no padding fits where it draws.
    ///
    /// - Parameter surface: The surface asking.
    /// - Returns: Zero insets.
    public func gridFitInsets(for surface: TerminalSurface) -> PlatformEdgeInsets {
        PlatformEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

/// Chrome a host draws around a terminal, supplied rather than subclassed.
///
/// Injected because the same surface appears in a split pane, a lone window, an
/// agent pane and a Beam view, and each wants different furniture around
/// identical content. A subclass per host would fork the terminal to vary the
/// frame around it.
public protocol TerminalSurfaceChrome: AnyObject {
    /// A header view for this surface, or nil for none.
    ///
    /// - Parameter surface: The surface to build a header for.
    /// - Returns: The header, sized by the host, or nil.
    func titleView(for surface: TerminalSurface) -> PlatformView?

    /// Views the host wants beside the title, in leading-to-trailing order.
    ///
    /// - Parameter surface: The surface to build accessories for.
    /// - Returns: The accessories, or an empty array.
    func accessoryViews(for surface: TerminalSurface) -> [PlatformView]
}

extension TerminalSurfaceChrome {
    public func titleView(for _: TerminalSurface) -> PlatformView? { nil }
    public func accessoryViews(for _: TerminalSurface) -> [PlatformView] { [] }
}

/// What the ingest thread holds instead of the surface's address.
///
/// The signal fires on the ingest thread, and deinit runs on main once the
/// last reference has already dropped — so between those two moments an
/// eventful pass can arrive for a surface that is going away. Holding the
/// address alone gave no way to notice: the trampoline would rebuild a
/// reference to memory whose deinit had begun, and the main hop it queued
/// would call into it after the memory was gone. Closing a pane while its
/// child floods output is exactly when passes are densest.
///
/// A weak reference under a lock answers instead, and the box itself is what
/// crosses to main: the trampoline enqueues the box, and the main-queue block
/// does the weak load, so the strong reference that keeps a live surface
/// alive is created and destroyed on the thread its deinit asserts. Swift
/// clears a weak reference when deinit begins, so a load that succeeds is a
/// surface still alive, and a load after that returns nothing — the pass is
/// dropped, which is what a surface on its way out wants anyway.
///
/// Unchecked because every access to the one mutable field goes through
/// `lock`, and the field is weak, which the runtime clears on its own
/// schedule; the box carries no other state.
private final class SurfaceDrainSignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var surface: TerminalSurface?

    init(_ surface: TerminalSurface) {
        self.surface = surface
    }

    /// The surface, while it is still alive.
    ///
    /// Called on the main queue only. A weak load materialises a strong
    /// reference, and dropping a strong reference is where the surface's
    /// deinit can run — deinit asserts main-actor isolation, so a load on any
    /// other thread is a trap waiting for teardown. The ingest thread never
    /// calls this; it hands the whole box to a main-queue block and the load
    /// and the release both happen there.
    ///
    /// - Returns: A strong reference that outlives the call, or nil.
    func liveSurface() -> TerminalSurface? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }

    /// Drops the reference, so every later signal is a no-op.
    func clear() {
        lock.lock()
        surface = nil
        lock.unlock()
    }
}

/// The ingest thread's side of the drain signal: one hop to main per
/// eventful pass.
///
/// The box crosses the hop, never the surface. Resolving the weak reference
/// here would hand this thread a strong reference whose release can be the
/// last one — ARC destroys the local on the calling thread after the async call
/// returns, and if main's block released its copy first, the surface's
/// main-actor deinit runs on the ingest thread and traps. Reproduced in an
/// optimised build before being designed out, so the dead-box case costs one
/// enqueued no-op rather than an early return here.
///
/// - Parameter context: The signal box's address, as registered.
private func surfaceDrainSignal(_ context: UInt) {
    guard let raw = UnsafeRawPointer(bitPattern: context) else {
        return
    }
    let box = Unmanaged<SurfaceDrainSignalBox>.fromOpaque(raw).takeUnretainedValue()
    DispatchQueue.main.async {
        box.liveSurface()?.serviceIngestEvents()
    }
}

/// A terminal that owns its session and reports what a host needs to draw around it.
///
/// The unit a host embeds: one object carrying the Core session, the render
/// surface and the event fan-out, so placing a terminal is an `addSubview` and a
/// launch rather than an assembly of three lifetimes a host has to keep in step.
///
/// Ownership runs one way. The surface owns the session; a host owns the
/// surface. Nothing above holds the terminal, so tearing down a pane cannot
/// leave a stream running, and two hosts cannot reach the same session.
///
/// The surface draws content and never chrome. Titles leave as values through
/// ``TerminalSurfaceObserver`` and furniture arrives through
/// ``TerminalSurfaceChrome``, which is what lets a pane, a tab and a window take
/// the same title without the terminal knowing any of them exist.
public final class TerminalSurface: PlatformView {
    /// Receives what the session reports. Held weakly: a host owns the surface.
    public weak var observer: TerminalSurfaceObserver?
    var lastSearchRevealGeneration: UInt64 = 0
    var lastSearchRevealEpoch: UInt32 = 0

    /// Supplies the furniture drawn around the content. Held weakly for the same reason.
    public weak var chrome: TerminalSurfaceChrome? {
        didSet { rebuildChrome() }
    }

    /// The terminal's current OSC title, empty until one arrives.
    ///
    /// Readable at any time so a host attaching late does not wait for the next
    /// change to populate a tab.
    public private(set) var title: String = ""

    /// The working directory the session last reported, or empty until a
    /// shell with integration installed says where it is.
    ///
    /// Readable at any time, as ``title`` is, so a host attaching late does
    /// not wait for the next `cd` to learn where the shell already is.
    public private(set) var currentDirectory: String = ""

    /// The session this surface owns.
    ///
    /// Package-scoped rather than public: the drive's own surface carries
    /// Core-typed API, and one Core type in a public signature makes every
    /// consumer enable C++ interoperability. Hosts drive the session through
    /// the pure methods below; in-package callers reach the drive directly.
    package let drive: RuntimeDrive

    /// Recorder for the Stream Debug window — captures the raw PTY byte stream.
    /// Installed before ingest starts; records only when the debug window is watching.
    package let streamDebugRecorder = StreamDebugRecorder()

    /// Draws the content.
    ///
    /// Held strongly, so a surface keeps what it draws with. Sharing is by
    /// assignment and unaffected: several surfaces given one renderer still
    /// share its glyph sheets, and it lives until the last of them is gone.
    ///
    /// This reference was weak, on the reasoning that a renderer belongs to a
    /// window rather than to a pane. It made the front door a trap — the
    /// factory hands back a fresh renderer, and `surface.renderer =
    /// makeRenderer(...)` dropped it before the next line unless the caller
    /// happened to keep a second reference of its own. Nothing said so, and
    /// the surface then drew every frame through a nil renderer: a black
    /// terminal with a correct grid behind it.
    public var renderer: TerminalSurfaceRenderer? {
        didSet {
            // The layer takes its device from whichever renderer draws it, so
            // it is readied on every assignment rather than once at build: a
            // surface adopted by a second renderer would otherwise keep the
            // first one's device and hand out drawables it cannot draw into.
            renderer?.prepare(metalLayer)
            installTextMeasurer()
            if let actualRenderer = renderer as? SurfaceRenderer {
                drive.publishActualFont(family: actualRenderer.familyName, sizePoints: actualRenderer.pointSize)
            }
            needsDisplay = true
        }
    }

    /// Points the model's proportional-text measurement at this surface's
    /// renderer (Docs/proportional-text.md), or removes it when there is none.
    ///
    /// The context is the surface itself, unretained: the session the
    /// measurer is installed on is the surface's own, so it never outlives it.
    private func installTextMeasurer() {
        guard renderer != nil else {
            drive.setTextMeasurer(nil, richText: nil, fontCatalog: nil, context: nil)
            return
        }
        let measure: Ubiquitty.Runtime.TerminalSession.TextMeasureFunction = {
            context,
            codePoints,
            count,
            faceBits,
            weight,
            glyphsOut,
            capacity,
            cellAdvanceOut in
            guard let context, let codePoints, let glyphsOut, capacity > 0 else {
                return 0
            }
            let surface = Unmanaged<TerminalSurface>.fromOpaque(context).takeUnretainedValue()
            let text = UnsafeBufferPointer(start: codePoints, count: Int(count))
            let shaped = surface.proportionalMeasure.shape(
                Ubiquitty.Rendering.ClusterSpan(text),
                face: Ubiquitty.Rendering.FontFace(rawValue: faceBits) ?? Ubiquitty.Rendering.FontFace.Regular,
                weight: weight
            )
            guard !shaped.isEmpty, shaped.count <= Int(capacity) else {
                return 0
            }
            for index in 0..<shaped.count {
                glyphsOut[index] = shaped[index]
            }
            cellAdvanceOut?.pointee = surface.proportionalMeasure.cellAdvanceInPixels
            return Int32(shaped.count)
        }
        drive.setTextMeasurer(
            measure,
            richText: { context, document, request, facts, result in
                guard let context, let document, let request, let facts, let result else { return false }
                let surface = Unmanaged<TerminalSurface>.fromOpaque(context).takeUnretainedValue()
                return surface.proportionalMeasure.shapeRichText(
                    document.pointee,
                    request: request.pointee,
                    facts: facts.pointee,
                    into: &result.pointee
                )
            },
            fontCatalog: { context, query, facts, result in
                guard let context, let query, let facts, let result else { return false }
                let surface = Unmanaged<TerminalSurface>.fromOpaque(context).takeUnretainedValue()
                return surface.proportionalMeasure.queryFonts(
                    query.pointee,
                    facts: facts.pointee,
                    into: &result.pointee
                )
            },
            context: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// The selection over this surface's terminal, driven by Core's rules.
    internal let selectionModel = SurfaceSelectionModel()

    #if !canImport(AppKit) && !canImport(UIKit)
    /// Reconciles the OS pointer grab with what the terminal asked for.
    ///
    /// Nothing to reconcile here. Neither toolkit this fallback compiles
    /// for offers a pointer to confine, so the mode is still tracked by
    /// Core, and still reported, but no grab exists to take or release.
    internal func updatePointerLock() {}
    #endif

    /// The layer frames are presented into.
    ///
    /// Owned here rather than by the renderer: a layer belongs to a view, and a
    /// renderer shared by several panes would otherwise hold one of them.
    public let metalLayer = CAMetalLayer()
    #if canImport(AppKit)
    private var dragDropStorage: TerminalDragDrop?
    internal var dragDrop: TerminalDragDrop {
        if let dragDropStorage { return dragDropStorage }
        let controller = TerminalDragDrop(surface: self)
        dragDropStorage = controller
        return controller
    }
    internal var secondaryTextPlane: SecondaryTextPlane?
    internal var backgroundVibrancyPlane: SecondaryTextPlane?
    #endif
    /// The content's visual displacement; terminal rows remain inside the scrollback extent.
    package private(set) var verticalOverscroll: CGFloat = 0
    #if canImport(AppKit)
    private let contentClipLayer = CALayer()
    private let overscrollBackgroundLayer = CALayer()
    /// The stationary background exposed by elastic scrolling.
    public var overscrollBackgroundColor: CGColor? {
        didSet {
            // Assigning an equal colour is not free: Core Animation takes a new
            // CGColor and marks the layer for display, so a quiet screen would
            // repaint the band to arrive at the pixels already there.
            if let oldValue, let colour = overscrollBackgroundColor, oldValue == colour {
                return
            }
            if oldValue == nil, overscrollBackgroundColor == nil {
                return
            }
            overscrollBackgroundLayer.backgroundColor = overscrollBackgroundColor
            overscrollLayerWritesForTesting += 1
        }
    }

    /// Writes that reached the overscroll layer.
    package private(set) var overscrollLayerWritesForTesting = 0
    #endif

    /// The grid the last resize published, so an unchanged size does no work.
    package private(set) var publishedGrid = (rows: 0, columns: 0)

    /// This view's native-size remote viewport; never shared with sibling panes.
    internal var remotePanOffsetInPoints = CGPoint.zero
    internal var presentedFrameGeometry: TerminalSurfaceFrameGeometry?

    /// The pixel extent last sent as the winsize, so a scale change with
    /// the grid unchanged still re-sends it.
    private var publishedWindowPixels = (width: 0, height: 0)

    /// The composition in flight, empty when none is.
    ///
    /// Stored because AppKit queries it between keystrokes and the model holds
    /// no record of text that has not been committed.
    internal var markedText: String = ""

    /// The caret or selection the input method placed inside ``markedText``,
    /// in UTF-16 units, as it reported it; Core holds it to the composition's
    /// bounds when it is answered back.
    internal var markedSelection = NSRange(location: 0, length: 0)

    /// Bumped whenever the input method produced text.
    ///
    /// How the key router tells a consumed key from an ignored one: an input
    /// method that neither commits nor composes leaves this alone, and the key
    /// has to reach the encoder instead.
    internal var textInputGeneration: UInt64 = 0

    private var headerView: PlatformView?
    private var accessories: [PlatformView] = []

    /// Paces this surface's animation repaints — the same clock the Metal
    /// arm's view uses, consumed through the same delegate. The surface has
    /// no display link, so only the tick half of the clock is live here; the
    /// link half's facts answer inert values below.
    internal var frameClock: FrameClock!
    private var clockBridge: SurfaceClockBridge!

    /// How many rows of history sit above the tail in this surface's view.
    ///
    /// Zero at the tail. Every frame request and the sync-frame geometry carry
    /// it, and the animation schedule reads it through the drive so a blink
    /// cell in scrolled-back history keeps its clock conservatively armed.
    package internal(set) var viewOffset = 0

    /// The scrollback row count at the last follow-tail decision, so a held
    /// viewport compensates its offset by exactly the tail's growth.
    internal var lastScrollbackCount = 0

    /// Banks sub-line wheel and trackpad deltas between events, so a slow pan
    /// still advances a line over several ticks.
    /// The em size this surface was configured with, before any zoom.
    ///
    /// Held because a zoom is an OFFSET over the configured size, not a size of
    /// its own: zooming in and back out has to land on the size the reader
    /// configured, and a surface that only remembered the current size would
    /// drift by whatever rounding each step carried.
    ///
    /// The convenience initialiser sets this. An embedder that builds its own
    /// renderer and assigns it sets this too, or the zoom has no size to be an
    /// offset over and does nothing.
    public var configuredPointSize: Double = 0

    /// The window's own offset over ``configuredPointSize``, in points.
    ///
    /// Per surface rather than per application, which is what "the window's
    /// font zoom" means: two windows on one configuration zoom independently.
    public internal(set) var fontZoomOffset: Double = 0

    /// The configured background picture this surface decoded, with the path
    /// and colour space it was decoded for, so a configuration that moved
    /// something else does not decode the file again.
    var configuredBackdrop: (path: String, usesDisplayP3: Bool, image: BackdropImage?) = ("", false, nil)

    internal var wheelAccumulator = Ubiquitty.FractionalAccumulator()

    #if canImport(UIKit)
    /// Whether the host is showing a keyboard, which decides what a tap means.
    /// See ``TerminalSurface/installPointerGestures()``.
    public var isKeyboardPresented = false
    /// The pan's cumulative translation at the last callback, so each one
    /// reports the change rather than the total.
    internal var lastScrollTranslation = CGPoint.zero
    /// The pan's source survives the final callback, after UIKit lifts the touches.
    internal var scrollIsDirectTouch = false
    /// The axis the current one-finger pan settled on, nil until it has travelled
    /// far enough to say. See ``TouchPanRule``.
    internal var scrollPanAxis: TouchPanAxis?
    /// Whether a one-finger pan has begun and not yet ended, so a finger that lands
    /// meanwhile is known to be a second one.
    internal var scrollPanIsActive = false
    /// Whether another finger touched down while the current one-finger pan was under way.
    /// The pan takes one touch and ignores the rest, so it cannot report this itself.
    internal var scrollPanSawAnotherFinger = false
    /// The installed one-finger scroll pan, the pinch and the two-finger connection pan,
    /// which the arbiter tells apart and whose handlers read each other's facts.
    /// The hold below is the fourth recogniser the arbiter delegates.
    internal weak var scrollPan: UIPanGestureRecognizer?
    internal weak var fontZoomPinch: UIPinchGestureRecognizer?
    internal weak var connectionPan: UIPanGestureRecognizer?
    /// The installed hold: the selection gesture, or the edit menu over a selection.
    internal weak var holdPress: UILongPressGestureRecognizer?
    /// Whether the hold's touch is on the glass, a finger's or the Pencil's, as
    /// the arbiter last saw it offered. A pointer has Shift to hold, so only a
    /// touch on the glass makes the hold the platform's selection gesture.
    internal var holdPressIsOnTheGlass = true
    /// Whether the current hold opened the edit menu, so its drag and release
    /// select nothing.
    internal var holdPressOffersEditMenu = false
    /// The delegate of those four recognisers. Held here because a recogniser's
    /// delegate is weak.
    internal var touchGestureArbiter: TouchGestureArbiter?
    /// Whether the touch gestures are on this view yet.
    internal var pointerGesturesInstalled = false
    /// The zoom offset the current pinch began at, so each callback resolves
    /// against the gesture's start rather than the previous callback.
    internal var zoomOffsetAtPinchStart: Double = 0
    /// Only the latest size requested between display refreshes needs measurement.
    internal var pendingPinchPointSize: Double?
    internal var isPinchingFont = false
    /// The edit-menu interaction, once one has been installed.
    internal var editMenuInteraction: UIEditMenuInteraction?
    /// What the edit menu offers beyond the responder chain's entries.
    internal var editMenuDelegate: SurfaceEditMenuDelegate?
    /// The lollipops at the ends of the selection, once one has been drawn.
    internal var selectionHandles: SelectionHandles?
    /// The system loupe over the selection end a finger is moving, while one
    /// is moving it.
    internal var selectionLoupe: UITextLoupeSession?
    #if UBIQUITTY_IOS_UI_TESTS
    /// What the loupe has done over this surface, for the UI suite.
    internal var selectionLoupeRecord: SelectionLoupeRecord?
    #endif
    /// Whether the current hold made the selection it is dragging, so its
    /// release offers the edit menu over what it made.
    internal var holdPressMadeSelection = false
    /// When and where the last double-tap selection ended, so a third tap
    /// close behind it grows the word to its line.
    internal var lastWordSelection: (time: TimeInterval, point: CGPoint)?
    /// Rows of output that arrived below a view held back in the scrollback,
    /// since it last stood at the live tail.
    internal var rowsArrivedWhileScrolledBack = 0
    /// The position last reported, so a repaint that moved nothing raises
    /// nothing.
    public internal(set) var reportedScrollbackPosition: TerminalScrollbackPosition?
    #endif

    /// An embedder's tuning, when one was supplied. Nil means the config
    /// decides — see ``wheelPolicy``.
    internal var injectedWheelPolicy: Ubiquitty.Screen.ScrollTuning.Policy?

    /// Whether typing has hidden the pointer. Cleared by a real move or a
    /// click: either means the pointer is visible again, and a hover has
    /// something to anchor on.
    ///
    /// Package-visible because a scenario cannot see the OS cursor: AppKit
    /// hides it globally and answers no question about why, so this is the
    /// only witness that typing asked.
    package internal(set) var pointerIsHiddenForTyping = false

    /// The link run under the pointer, for the frame to underline in the hover
    /// accent. Nil when nothing is hovered, which is what stops the accent.
    ///
    /// Declared for both arms because the RENDERER reads it, and the renderer
    /// is shared: a member behind `canImport(AppKit)` that shared code names is
    /// a member the phone cannot compile. Only the pointer tracking that fills
    /// it is desktop-shaped, and that stays guarded where it lives.
    package internal(set) var hoveredLinkRun: RuntimeDrive.ResolvedLink?

    /// What a click on ``hoveredLinkRun`` would actually open.
    ///
    /// The same string for a URL, and the `file://` URL a bare path resolved
    /// to for a path candidate — which is what the preview has to say, since a
    /// reader shown the raw text would be told less than the click will do.
    package internal(set) var hoveredLinkTarget: String?

    /// How many frames this surface has encoded.
    ///
    /// An encode is a frame built, not one seen: a scenario about what reached
    /// the glass, and when, reads ``beginRecordingPresentsForTesting(capacity:)``
    /// instead.
    package internal(set) var framesEncodedForTesting = 0

    /// Called on the main thread after each frame this surface encodes into
    /// its layer, with the retained grid already holding that frame: the one
    /// seam a scenario reads every presented frame through, rather than
    /// sampling the surface between frames and missing the one that blinked.
    package var frameEncodedObserverForTesting: (@MainActor (TerminalSurface) -> Void)?

    /// Seconds spent inside those encodes.
    ///
    /// Beside the count because the count alone cannot tell a slow frame from
    /// a rare one, and the two ask for opposite fixes: a driver presents more
    /// often, and does nothing for an arm already spending its whole budget
    /// inside one frame.
    package internal(set) var frameEncodeSecondsForTesting = 0.0

    /// Whether this surface's frames feed the paint heatmap.
    ///
    /// The renderer reads it every frame, so a frame renderer made while the
    /// heatmap is open joins it from a fresh baseline. Inert in a build without
    /// UBIQUITTY_PERF_DIAG, where Core compiles the capture's heat pass out.
    package private(set) var isPaintHeatmapEnabled = false

    /// Starts feeding this surface's frames to the paint heatmap.
    ///
    /// Every frame renderer drops whatever shadow it held, so the next frame
    /// is a baseline even when the heatmap closed and reopened between two
    /// frames.
    package func enablePaintHeatmap() {
        disablePaintHeatmap()
        isPaintHeatmapEnabled = true
        needsDisplay = true
    }

    /// Stops feeding this surface's frames to the paint heatmap and releases
    /// every frame renderer's shadow.
    package func disablePaintHeatmap() {
        isPaintHeatmapEnabled = false
        for renderer in frameRenderers.values {
            renderer.isPaintHeatmapEnabled = false
        }
    }

    /// Whether the session's deliveries are being tallied for the perf log.
    var isTallyingPerfDrains = false

    /// The bytes the last perf-log tally carried, for the handler's spike line.
    var lastPerfDrainBytes: UInt64 = 0

    /// The hovered run the LAST FRAME was built with, in the visible rows it
    /// was converted to. Row-last below row-first means no hover.
    ///
    /// Distinct from ``hoveredLinkRun``, which is what the pointer resolved:
    /// this is what the frame did with it, and only the second says the
    /// underline was drawn.
    /// How many image quads the LAST BUILT FRAME carried. -1 until a frame has
    /// been built. A scenario reads this rather than the model: the chafa bugs
    /// were invisible to every model-level probe, because the model was right
    /// and the frame was not.
    package private(set) var lastFrameImageQuadCount: Int32 = -1

    /// How many image uploads this surface's store has run off the model
    /// lock, for a caller checking that a pixel transfer does not hold the
    /// lock the parser is waiting for.
    package var offLockImageUploadCount: Int {
        frameRenderers.values.reduce(0) { $0 + $1.imageStore.offLockUploadCount }
    }

    /// The underline rules this surface's last build cut around descender
    /// ink, and the widest clearance any of them keeps, in device pixels.
    ///
    /// The cut itself is drawn by the fragment stage from these rules, so a
    /// probe that cannot read the drawable reads what the shader was handed.
    package var lastBuiltSkipInkRules: (count: Int, widestPadInPixels: Float) {
        frameRenderers.values.reduce((count: 0, widestPadInPixels: Float(0))) { sum, renderer in
            let rules = renderer.skipInkRules
            return (sum.count + rules.count, max(sum.widestPadInPixels, rules.widestPadInPixels))
        }
    }

    /// Whether this surface's renderer carries the configured background
    /// image, for a caller checking that a preference reached the window.
    package var isShowingBackdrop: Bool {
        (renderer as? SurfaceRenderer)?.isShowingBackdrop ?? false
    }

    package private(set) var lastFrameHoverRowFirst: Int32 = 0
    package private(set) var lastFrameHoverRowLast: Int32 = -1
    package private(set) var lastFrameHoverColumnFirst: Int32 = 0
    package private(set) var lastFrameHoverColumnLast: Int32 = -1

    /// The emphasis colour the last frame was assembled with, straight sRGB.
    ///
    /// Read back off the frame's own options rather than from the style, for
    /// the reason the run beside it is: what the style holds and what the frame
    /// drew with are the same only while the fallback in between is right, and
    /// it was not — the components defaulted to zero under an alpha of one, so
    /// a hovered link drew black.
    package private(set) var lastFrameHoverColor: (red: Float, green: Float, blue: Float) = (0, 0, 0)

    /// Records what a frame did with the hovered run.
    ///
    /// - Parameters:
    ///   - isActive: Whether the frame carried a hover at all.
    ///   - rowFirst: The run's first visible row.
    ///   - rowLast: Its last.
    ///   - columnFirst: Its first column.
    ///   - columnLast: Its last.
    ///   - color: The emphasis colour the frame drew the run in.
    /// Records the built frame's image-quad count; the renderer calls it once
    /// per frame beside the layer resolve, with 0 when the frame has no layer.
    package func noteFrameImageQuads(_ count: Int32) {
        lastFrameImageQuadCount = count
    }

    package func noteFrameHoverRun(
        isActive: Bool,
        rowFirst: Int32,
        rowLast: Int32,
        columnFirst: Int32,
        columnLast: Int32,
        color: (red: Float, green: Float, blue: Float)
    ) {
        lastFrameHoverRowFirst = isActive ? rowFirst : 0
        lastFrameHoverRowLast = isActive ? rowLast : -1
        lastFrameHoverColumnFirst = isActive ? columnFirst : 0
        lastFrameHoverColumnLast = isActive ? columnLast : -1
        lastFrameHoverColor = color
    }

    /// What one frame's cursor presentation was assembled from, and what it
    /// resolved to.
    ///
    /// The fill is read back off the frame's own options rather than derived
    /// again here, so it stands for what the applier wrote and not for what
    /// a reader would compute from the two facts beside it.
    package struct FrameCursorPresentation: Equatable {
        /// Whether the cursor paints filled rather than as a hollow outline.
        package var isCursorFilled: Bool
        /// Whether the pane's window was a tab behind its group's front one.
        package var isWindowBackgroundedTab: Bool
        /// Whether the pane held focus.
        package var isPaneFocused: Bool
    }

    /// The cursor presentation the last frame was assembled with; nil before
    /// the first frame.
    package private(set) var lastFrameCursorPresentation: FrameCursorPresentation?

    /// How many frames this surface ASSEMBLED: built its options and resolved
    /// the cursor presentation above, whether or not a drawable then let it
    /// commit. A backgrounded, occluded tab assembles the frame a probe asks
    /// for but finds no drawable to present it, so the assembled count is the
    /// signal that a fresh presentation was resolved; the committed-encode
    /// count stays where it was.
    package internal(set) var framesAssembledForTesting = 0

    /// Records what a frame did with the cursor's presentation.
    ///
    /// - Parameter presentation: The fill the frame's options carried and the
    ///   two facts it was resolved from.
    package func noteFrameCursorPresentation(_ presentation: FrameCursorPresentation) {
        lastFrameCursorPresentation = presentation
        framesAssembledForTesting += 1
    }

    /// The configured connection host, never a title or OSC-reported hostname.
    package var remoteFileHost = ""
    /// A configured display name, shown alongside the connection host.
    package var remoteFileHostLabel = ""
    /// Presents a captured download question; UIKit installs its native model route.
    package var fileDownloadPromptHandler: ((RuntimeDrive.FileDownloadPrompt) -> Void)?

    #if canImport(AppKit)
    /// What a shell does with a link the terminal decided to open.
    ///
    /// The shell's, because only it knows what a URL means on its platform —
    /// and a closure rather than a call so a scenario can watch the decision
    /// without launching anything. A surface with none opens nothing, which is
    /// the right answer for an embedder that has not said what opening means.
    package var linkOpener: ((String) -> Void)?
    internal var fileDownloadAlert: NSAlert?

    /// Whether the pointer is currently showing the link affordance. Held so
    /// the cursor is set on the edge only: setting one per motion event fights
    /// AppKit's cursor rects and flickers.
    package internal(set) var isShowingLinkAffordance = false

    /// Every URI this surface has opened, in order.
    ///
    /// A scenario cannot watch NSWorkspace, and must not launch a browser to
    /// find out whether a click worked.
    package internal(set) var openedLinksForTesting: [String] = []

    /// Every path this surface has asked its host for, in order.
    ///
    /// The ask crosses to a daemon, so a scenario with no daemon has no other
    /// way to see which path a click named — and which path it named is the
    /// whole of the behaviour, since the host answers whatever it is given.
    package internal(set) var requestedHostFilesForTesting: [String] = []
    #endif

    /// How many times input has been reported to the cursor's activity
    /// freeze.
    ///
    /// The freeze itself is Core's and is tested there. What a scenario needs
    /// to know is whether this arm reports at all — it did not, and every key
    /// still typed, so no typing-level assertion could see the difference.
    package internal(set) var userActivityNotesForTesting = 0

    /// A drag owns the pointer: it is driving a selection rather than asking
    /// what is under it. Written by the shared pointer route from Core's answer
    /// about the press, and read by the AppKit affordances — the pointer's
    /// shape over the void, the hover re-resolve — which stand off until the
    /// button comes up. Declared outside their block because the writer is
    /// shared: a touch shell sets a latch nothing reads, which costs nothing.
    internal var isSelectionDragInFlight = false

    #if canImport(AppKit)
    /// Repeats while a selection drag is held outside the grid; nil otherwise.
    /// Whether the left button is down on the grid.
    ///

    #if canImport(AppKit)
    /// The clock that drives frames while host output flows; nil while the
    /// surface presents on demand.
    internal var frameLink: SurfaceFrameLink?

    /// The rate the clock last asked for, applied when the link starts.
    ///
    /// Core's rate ladder decides it — the screen's maximum, the reader's
    /// cap, the reduced background cadence — and this is where the answer
    /// waits between a pause and the resume that follows it.
    internal var requestedFramesPerSecond = 60

    /// Whether frames are being driven on a clock rather than asked for one
    /// mark at a time.
    ///
    /// The state the pacing policy decides: true while host output flows,
    /// false again once it has been idle past the driver's timeout.
    package var isDrivingFramesForTesting: Bool { frameLink?.isRunning ?? false }

    /// How many times the frame drive has been started from a stop.
    package var frameDriveStartsForTesting: Int { frameLink?.startCount ?? 0 }

    /// The link, built on first use.
    ///
    /// Built late because most surfaces never flood: a terminal watching a
    /// prompt has nothing to drive, and one that never sees a burst never
    /// pays for the object.
    ///
    /// - Returns: This surface's link.
    internal func ensureFrameLink() -> SurfaceFrameLink {
        if let frameLink {
            return frameLink
        }
        let link = SurfaceFrameLink(layer: metalLayer, view: self) { [weak self] in
            self?.driveOneFrame()
        }
        link.diagnosticSnapshot = { [weak self] in
            guard let self else { return "surface released" }
            return
                "draws=\(drawnFrameCount) attempts=\(encodeAttemptCount) unowed=\(skippedAsUnowedCount) sync=\(withheldForSyncOutputCount) "
                + "occluded=\(withheldForOcclusionCount) "
                + ((renderer as? SurfaceRenderer)?.frameDeliverySummary ?? "")
        }
        frameLink = link
        return link
    }

    /// Draws the frame a tick asked for, and stops the clock once the
    /// output that started it has stopped.
    ///
    /// The idle test rides the tick rather than a timer of its own: the
    /// clock is already firing, and a second schedule to decide when the
    /// first should end is one more thing to keep in step.
    internal func driveOneFrame() {
        // A display-link callback can precede the queued ingest notification.
        // Consume the session's pending events before deciding no frame is owed.
        serviceIngestEvents()
        drawSurfaceFrame()
        frameClock.maybePause()
    }
    #endif

    /// Whether the pointer is past the end of its row's text.
    ///
    /// Held rather than asked per draw: the read is a tried lock on the
    /// model, and a contended one keeps this value rather than flickering
    /// the pointer between shapes under a flood.
    internal var isPointerOverTextVoid = false

    /// Where a window move was grabbed, in the window's coordinates; nil
    /// when no window move is running.
    internal var windowDragGrabInWindow: CGPoint?

    /// Whether the drag in flight is a column block.
    ///
    /// Sampled at the press and held for the gesture, because the modifier
    /// that armed it is often let go mid-drag and the selection stays
    /// rectangular either way — the pointer must say so for as long as it is.
    internal var isRectangularDragInFlight = false

    internal var dragAutoScrollTimer: Timer?

    /// Where that drag was last seen, in view coordinates. Re-sampled each
    /// tick because a held pointer sends no further events.
    internal var dragAutoScrollPoint: CGPoint = .zero
    #endif

    /// The cell height in points, for the wheel policy's points-per-line
    /// conversion; the renderer stamps it when metrics resolve.
    internal var scrollbackCellHeightPoints: CGFloat = 0

    #if canImport(AppKit)
    /// The shape an application asked for with OSC 22, or nil when it has asked
    /// for none.
    ///
    /// Read off the published snapshot on each drain rather than reported: this
    /// shell installs no `WindowClient`, and the pointer is resolved on the main
    /// thread between drains where the model lock is the wrong thing to take.
    /// Nil is not `.default` — a program that pushed "default" asked for the
    /// arrow, and a program that pushed nothing gets the terminal's own I-beam.
    package internal(set) var appPointerShape: Ubiquitty.PAL.MousePointerShape?

    /// The shape the cursor rect was last built for, so a drain that changes
    /// nothing about the pointer rebuilds nothing. Package-visible as the
    /// witness of what was applied, which the resolved shape alone is not.
    package internal(set) var installedPointerShape: Ubiquitty.PAL.MousePointerShape?

    /// The native scroll bar mirroring the scrollback extent; revealed on
    /// scroll movement and while scrolled-back history grows.
    ///
    /// AppKit chrome, and the shell's rather than the terminal's: a phone
    /// shows scrollback position its own way, and neither shell should carry
    /// the other's furniture.
    internal let terminalScroller = TerminalScroller(frame: .zero)

    /// The lock shown while the model believes a password prompt is on screen.
    internal let passwordBadge = PasswordPromptBadge(frame: .zero)

    /// The window's frame when the current live resize began, or `.zero`
    /// outside one — which edges of it are moving is what the layer anchors
    /// against for the drag's duration.
    internal var liveResizeStartWindowFrame = CGRect.zero

    /// Whether the tab bar was present at the last resize.
    ///
    /// A tab appearing or disappearing (the group's window count crossing two)
    /// relays out every pane; that pass must not take the synchronous present,
    /// and only a change tells it apart from an ordinary resize.
    internal var wasTabBarPresent = false
    #endif

    /// What the badge last showed, so a quiet screen update costs no work.
    package private(set) var isPasswordPromptShown = false

    /// The black layer standing over the whole view while the program has the
    /// display blanked, made on the first blank and kept for the next.
    internal var displayBlankCover: CALayer?

    #if canImport(AppKit)
    /// The scroller's delegate bridge, keeping RenderKit out of the surface's
    /// public conformance surface.
    private var scrollerBridge: SurfaceScrollerBridge!
    #endif

    /// The VoiceOver projection cache: the flat visible text, its per-row
    /// UTF-16 ranges, the Core projection they were converted from — kept
    /// whole because Core's caret and selection mapping index it directly —
    /// and whether a screen delivery has staled them.
    internal var accessibilityCachedText: NSString?
    internal var accessibilityLineRanges: [NSRange] = []
    internal var accessibilityCachedProjection: Ubiquitty.Accessibility.TextProjection?
    internal var isAccessibilityTextDirty = true

    /// The value-changed post coalescer — the ceiling and the trailing-post
    /// decision are Core's; this side holds the state and the timer.
    internal var accessibilityNotifyThrottle = Ubiquitty.Accessibility.NotifyThrottle()

    /// The window-edge observers — miniaturize, deminiaturize, occlusion —
    /// re-registered whenever the surface changes windows.
    /// The ingest thread's handle on this surface, retained for as long as a
    /// signal can arrive through it and released once one cannot.
    private var drainSignalBox: Unmanaged<SurfaceDrainSignalBox>?

    // Internal rather than private: each shell's lifecycle extension installs
    // and clears these, and an extension in another file is not the same access
    // scope. The list is still the surface's — nothing outside this module sees it.
    internal var windowObservers: [NSObjectProtocol] = []
    private var registeredFontsObserver: NSObjectProtocol?
    private var richTextCatalogObserver: NSObjectProtocol?

    /// The same, for the edges NSWorkspace posts on its own notification
    /// centre. Held apart because an observer is removed from the centre it
    /// was added to, and one taken off the wrong centre stays registered.
    internal var workspaceObservers: [NSObjectProtocol] = []

    /// Whether this surface holds the OS cursor grab — the single source of
    /// truth every pointer-lock enable and teardown routes through.
    internal var isPointerLocked = false

    /// The cursor's CG-global position at lock, warped back to on release.
    internal var pointerLockRestorePoint = CGPoint.zero

    /// The break-out chord's hold state: armed, since when, and the one-shot
    /// timer polling the hold — modifiers do not auto-repeat.
    internal var pointerLockChordTimer: Timer?
    /// Whether the chord's one-shot wake-up is already booked. UIKit has no
    /// timer object to test for nil the way ``pointerLockChordTimer`` lets
    /// AppKit do, so the dispatched ask carries this flag instead.
    internal var isPointerLockChordTickBooked = false
    /// The token observing a GameController mouse arriving after this
    /// surface is already on screen, so a mouse paired mid-session still
    /// reaches relative pointer lock.
    internal var pointerLockMouseConnectObserver: NSObjectProtocol?
    /// How many non-modifier keys are down, counted on the presses edges so
    /// the chord can tell ⌃⌘ alone from a ⌃⌘X held for as long.
    internal var heldNonModifierPressCount = 0
    /// The chord's keys as a run with no keyboard supplies them, or nil to
    /// read GameController.
    internal var pointerLockChordKeyStateOverride: (() -> Ubiquitty.Input.PointerLockKeyState)?
    /// Whether the DEC locator (DECELR) was armed at the last delivery — the
    /// published bit, mirrored once per delivery so the off-to-on edge is seen.
    internal var isLocatorArmed = false
    /// Where a scenario says the pointer stands, in view coordinates, in
    /// place of the window server's answer; nil reads the window server. Only
    /// the locator's arm edge reads it — a scenario cannot put the real
    /// pointer over a window without moving the reader's.
    package var locatorPointerOverrideForTesting: CGPoint?
    /// The hint text last handed to the observer, so a re-ask that answers
    /// the same words is silent.
    internal var shownHintText = ""
    /// Whether the one wake-up at Core's hint expiry is already booked.
    internal var isHintRecheckScheduled = false

    /// This surface's frame renderers, keyed by the scale their sheets were cut
    /// at; empty until the first frame.
    ///
    /// Held here rather than on the shared ``TerminalSurfaceRenderer`` because a
    /// `TerminalRenderer` is one per view by its own declaration, and eleven of
    /// its stored properties are this view's: the retained grid and its scroll
    /// partner, the instance streams, the capture, the Tek streams, and the
    /// cursor animator. The animator is the one that misbehaves without a lock
    /// or a size mismatch to hide behind — it holds the in-flight slide, so two
    /// surfaces sharing one would each tick it toward their own cursor and the
    /// glide would chase whichever drew last, across two terminals.
    ///
    /// The glyph sheets stay shared regardless: `GlyphAtlas.shared(key:)` keys
    /// them by configuration, so per-view renderers on one font rasterise each
    /// glyph once between them. The split is per-view CONTENT, shared PIXELS.
    package var frameRenderers: [Int: TerminalRenderer] = [:]

    /// The renderer build the entries above were cut from; the renderer
    /// drops them when its build moved, so an adopted font reaches the
    /// glyphs and not only the grid.
    package var frameRendererGeneration = -1

    /// The atlas a proportional-text measurement shapes with, handed over by
    /// the renderer as it cuts this surface's frame renderer.
    package let proportionalMeasure = ProportionalMeasureBox()

    /// Where a cell-metric change of this surface's own — the pinch zoom — is
    /// answered: the window that shows the surface, which decides whether it
    /// follows the font or holds and reflows. Absent, the surface refits its
    /// grid into the bounds it has. Set by the host that owns the window.
    package var cellMetricChangeHost: ((() -> Void) -> Void)?

    /// Declares the painted frame gone, so the next capture reports every row.
    ///
    /// The dirty set is filled from this baseline and from nothing else, while
    /// whether the retained texture is loaded is decided separately. A caller
    /// that drops the target without dropping the baseline gets the one
    /// combination that draws nothing: the frame clears, and the capture — the
    /// cells being unchanged — names no row to paint over the clear. Anything
    /// that invalidates painted pixels rather than cell contents has to come
    /// through here, which is every rebuild of the faces or the sheets.
    /// Takes a restyled renderer: the grid is refit under the new insets,
    /// the retained baseline dropped, and a frame asked for.
    ///
    /// A style change repaints every pixel while writing no cell — the stamp
    /// refuses the retained target, and without the refit the grid would keep
    /// the column count the old padding left room for.
    package func restyle() {
        refitGridToBounds()
        invalidateRetainedBaseline()
        needsDisplay = true
        frameClock.noteAnimationActivity()
    }

    /// Fits the grid to the bounds afresh, whatever grid stands published.
    ///
    /// For a caller whose grid may already hold the row count the bounds
    /// give and still needs Core's fit run: a drag's settle, which lays out
    /// top-anchored what its steps laid out bottom-anchored.
    internal func refitGridToBounds() {
        publishedGrid = (0, 0)
        resizeGridToBounds()
    }

    package func invalidateRetainedBaseline() {
        drive.withTerminal { terminal in
            drive.invalidateRetainedFrame(terminal)
        }
    }

    /// Lets every retained frame go: the per-scale renderers with the grids
    /// they retain, and the session's damage baseline with them.
    ///
    /// The answer to a font change. A retained target is a picture of one
    /// face laid out on one cell, and a change to either leaves it certifying
    /// pixels the next frame lays out differently: a frame that trusts it
    /// reuses rows drawn at the old metrics and the frame after repaints
    /// them, which reads as a flicker on every surface the change reached
    /// through something other than its own renderer. Dropped here, whole,
    /// rather than left for the next frame to notice.
    package func discardRetainedFrames() {
        for renderer in frameRenderers.values {
            renderer.releaseRetainedGrid()
        }
        frameRenderers.removeAll()
        invalidateRetainedBaseline()
        needsDisplay = true
    }

    /// One byte per visible row, written by the plan and read by the capture.
    ///
    /// Held rather than allocated per frame for the reason the capture holds its
    /// own storage: this is a steady-state path, and a per-frame allocation on it
    /// is a per-frame allocation. Its length is the row count the plan checks, so
    /// a resize between frames demotes that frame to a full rebuild by itself.
    package var rowDirtyScratch: [UInt8] = []

    /// Plans a frame whose grid nobody reads: no drain, no row copy.
    ///
    /// DECSET 7402 with an opaque letterbox paints every cell the letterbox
    /// colour and no glyph. Core clears the dirty set, keeps every captured
    /// row and declares the baseline gone, so the first plan after the mode
    /// clears re-reads every row. Called under the model lock, as the plan
    /// it stands in for is.
    ///
    /// - Parameters:
    ///   - terminal: The borrowed terminal, under the lock.
    ///   - rows: The visible row count.
    ///   - columns: The column count.
    /// - Returns: The plan.
    package func planSkippedGridFrame(
        _ terminal: Ubiquitty.Terminal,
        rows: Int,
        columns: Int
    ) -> Ubiquitty.Rendering.RetainedFramePlan {
        guard rows > 0, columns > 0 else {
            return Ubiquitty.Rendering.makeFullRebuildPlan()
        }
        if rowDirtyScratch.count != rows {
            rowDirtyScratch = [UInt8](repeating: 0, count: rows)
        }
        var request = Ubiquitty.Rendering.makeRetainedFrameRequest()
        request.rows = Int32(rows)
        request.columns = Int32(columns)
        request.viewOffset = Int32(viewOffset)
        return rowDirtyScratch.withUnsafeMutableBufferPointer { dirty in
            drive.planSkippedGridFrame(
                terminal,
                request,
                Ubiquitty.Rendering.RowDirtySpan(dirty)
            )
        }
    }

    /// Plans this frame's retained-target reuse, draining the damage.
    ///
    /// Called with the model lock held, because the drain mutates the grid's
    /// damage state — a plan taken off the lock reads a generation the parser is
    /// still advancing, and the rows it calls clean are the ones it raced.
    ///
    /// The dirty buffer is resized to the row count here. Core refuses a span
    /// whose length is not the row count, so a resize between frames demotes that
    /// frame to a full rebuild without anything else having to notice.
    ///
    /// - Parameters:
    ///   - terminal: The borrowed terminal, under the lock.
    ///   - rows: This frame's row count.
    ///   - columns: This frame's column count.
    ///   - target: Whether the retained texture survived at this frame's size —
    ///     a render-side fact Core cannot read for itself.
    ///   - hasBackdrop: Whether the frame composites the window's backdrop
    ///     under the grid, the other one.
    ///   - cellHeightInPixels: The resolved cell height, for the scroll bands.
    ///   - originYInPixels: The grid's top edge in the target.
    ///   - textureHeightInPixels: The target's height.
    /// - Returns: The plan, whose verdict and refresh the frame reads.
    package func planRetainedFrame(
        _ terminal: Ubiquitty.Terminal,
        rows: Int,
        columns: Int,
        target: Bool,
        hasBackdrop: Bool,
        cellHeightInPixels: Int,
        originYInPixels: Int,
        textureHeightInPixels: Int
    ) -> Ubiquitty.Rendering.RetainedFramePlan {
        guard rows > 0, columns > 0 else {
            return Ubiquitty.Rendering.makeFullRebuildPlan()
        }
        if rowDirtyScratch.count != rows {
            rowDirtyScratch = [UInt8](repeating: 0, count: rows)
        }
        var request = Ubiquitty.Rendering.makeRetainedFrameRequest()
        request.rows = Int32(rows)
        request.columns = Int32(columns)
        request.viewOffset = Int32(viewOffset)
        request.isTargetMatching = target
        request.hasBackdrop = hasBackdrop
        request.cellHeightInPixels = Int32(cellHeightInPixels)
        request.originYInPixels = Int32(originYInPixels)
        request.textureHeightInPixels = Int32(textureHeightInPixels)
        return rowDirtyScratch.withUnsafeMutableBufferPointer { dirty in
            drive.planRetainedFrame(
                terminal,
                request,
                Ubiquitty.Rendering.RowDirtySpan(dirty)
            )
        }
    }

    /// The pixel origin used by the registered boundary capture.
    package var registeredSyncGeometryOrigin: CGPoint?

    /// The drawable size the session's boundary-capture geometry was last
    /// registered for; nil before the first registration. The renderer keys
    /// re-registration on it so the model lock is taken on placement edges,
    /// not per frame.
    package var registeredSyncGeometrySize: CGSize?

    /// The atlas scale of the build that registration was assembled from; nil
    /// before the first registration. Part of the same key because the
    /// registration carries the build's metrics and slot geometry, which a
    /// scale change replaces while the drawable size can stay put.
    package var registeredSyncGeometryScale: Double?

    /// The cursor fill the boundary-capture geometry was last registered
    /// with; nil before the first registration. Part of the key because the
    /// fill moves neither the drawable size nor the style, and a registration
    /// left standing would draw every boundary frame's cursor against the
    /// fill the live route has already left behind. Keyed on the fill and not
    /// on focus alone because a tab going behind moves the fill with no focus
    /// change; the price is one re-registration, one model-lock take, per
    /// tab switch.
    package var isRegisteredSyncCursorFilled: Bool?

    /// The frame styling the boundary-capture geometry was last registered
    /// with; nil before the first registration. Part of the same key because
    /// the registration stores the assembled style whole, and a style change
    /// alone moves neither the drawable size nor the scale.
    package var registeredSyncStyle: SurfaceStyle?
    internal var registeredSyncBackground: SIMD4<Float>?
    internal var registeredSyncBackgroundOpacity: Double?

    /// The view offset the boundary-capture geometry was last registered
    /// with; nil before the first registration. Part of the key because a
    /// scroll edge moves nothing else in it, and a registration left standing
    /// would freeze every boundary frame on the rows of the offset it was
    /// assembled at.
    package var registeredSyncViewOffset: Int?

    /// The atlas's raster facts the boundary-capture geometry was last
    /// registered with; nil before the first registration.
    ///
    /// Part of the re-registration key because the boundary route derives its
    /// glyph phases from the registration while the live route derives them
    /// from the atlas it is drawing with: a face swap that keeps the drawable
    /// size and the style would otherwise leave the two routes phasing glyphs
    /// on different grids for the rest of the session.
    package var registeredSyncRaster: FrameRasterInputs?

    /// The cell advance the boundary-capture geometry was last registered
    /// with, in atlas pixels; nil before the first registration. Part of the
    /// key because DECCOLM compresses the advance without moving the drawable
    /// size, the scale or the style, and a registration left standing would
    /// lay every boundary frame out on the advance the live route no longer
    /// draws.
    package var registeredSyncCellWidth: Float?

    /// The atlas key used by boundary captures, including font metrics and slot geometry.
    package var registeredSyncSheetKey: String?

    #if canImport(AppKit)
    /// The ordinary question on this surface, retired when Core's token changes.
    package var consentPresentation: ConsentPresentation?
    /// The operation question on this surface, retired when Core's token changes.
    package var structureConsentPresentation: StructureConsentPresentation?
    #endif

    /// Bumped by a surface-owned recolour that writes no cell, so the
    /// renderer's retained-target stamp goes stale and the next frame
    /// rebuilds in full instead of Loading pixels wearing the replaced
    /// colours. The per-index alpha table was the one such recolour; with
    /// the alpha in Core's palette every recolour is model-side (OSC 4, a
    /// palette apply) and moves the terminal's own ``paletteEpoch``, which
    /// the stamp also folds in, so today only the scenario hook below moves
    /// this.
    package private(set) var retainedContentEpoch = 0

    /// Stales the retained target's stamp without writing a cell or moving
    /// the model, for a scenario. Nothing else stales the stamp this way,
    /// since the palette's alpha is Core's and a surface never recolours its
    /// own target; this keeps the case reachable so the frame that clears its
    /// target is still shown a stale stamp beside a partial dirty set, which
    /// is the pair it must not trust.
    package func staleRetainedContentForTesting() {
        retainedContentEpoch += 1
    }

    /// The theme foreground chrome tints to, by Core's one derivation, as an
    /// AppKit colour read under the model lock.
    ///
    /// - Parameter alpha: The colour's opacity.
    /// - Returns: The colour.
    public func chromeForegroundColor(alpha: Double = 1) -> PlatformColor {
        chromeColor(alpha: alpha, Ubiquitty.chromeForegroundColor)
    }

    /// The theme background, the chrome twin of the foreground.
    ///
    /// - Returns: The colour, opaque.
    public func chromeBackgroundColor() -> PlatformColor {
        chromeColor(alpha: 1, Ubiquitty.chromeBackgroundColor)
    }

    /// The theme's accent, by Core's one derivation, as an AppKit colour read
    /// under the model lock.
    ///
    /// - Returns: The colour, opaque.
    public func chromeAccentColor() -> PlatformColor {
        chromeColor(alpha: 1, Ubiquitty.chromeAccentColor)
    }

    /// The theme's cursor colour, the chrome twin of the accent.
    ///
    /// - Returns: The colour, opaque.
    public func chromeCursorColor() -> PlatformColor {
        chromeColor(alpha: 1, Ubiquitty.chromeCursorColor)
    }

    private func chromeColor(alpha: Double, _ resolve: (Ubiquitty.Terminal?) -> Ubiquitty.ColorRGBA) -> PlatformColor {
        let color = drive.withTerminal { resolve($0) } ?? resolve(nil)
        return PlatformColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: alpha
        )
    }

    /// Applies a theme's palette to the model, whole, under the model lock.
    ///
    /// The overwrite is the designed theme operation — the palette's own
    /// header says the frontend overwrites on theme apply — and OSC 4/10/11
    /// edits land on the applied table afterwards, which is the ordering a
    /// live theme switch wants. The special-colour slots (OSC 5) are left
    /// alone: they are the application's, not the theme's.
    ///
    /// The alpha goes into the palette beside the colour: Core's frame
    /// capture reads the per-index opacity off the palette it copies, so a
    /// theme that dims an index by alpha is drawn dimmed by every arm, and an
    /// OSC 4 write that replaces the colour draws opaque from the next frame.
    ///
    /// - Parameters:
    ///   - indexedRGB: 768 bytes — red, green, blue for each index 0–255.
    ///   - defaultsRGB: 9 bytes — the default foreground, the default
    ///     background, and the cursor colour, three each in that order.
    ///   - indexedAlpha: 256 bytes — one foreground opacity per index — or
    ///     empty for opaque throughout.
    /// - Returns: Whether the tables held their exact lengths and were
    ///   applied.
    @discardableResult
    public func applyPalette(indexedRGB: [UInt8], defaultsRGB: [UInt8], indexedAlpha: [UInt8] = []) -> Bool {
        let applied = indexedRGB.withUnsafeBufferPointer { indexed in
            defaultsRGB.withUnsafeBufferPointer { defaults in
                indexedAlpha.withUnsafeBufferPointer { alpha in
                    drive.applyPalette(
                        Ubiquitty.Runtime.AlphaSpan(indexed),
                        Ubiquitty.Runtime.AlphaSpan(defaults),
                        Ubiquitty.Runtime.AlphaSpan(alpha)
                    )
                }
            }
        }
        return applied
    }

    /// The live capture's status-row scratch, explicitly allocated rather
    /// than an array: the options borrow these cells for the capture call,
    /// and copy-on-write storage moves under exactly that borrow.
    private var statusRowStorage: UnsafeMutableBufferPointer<Ubiquitty.Cell>?

    /// The status-row scratch, grown to at least the given capacity.
    ///
    /// - Parameter capacity: Cells the caller is about to fill.
    /// - Returns: Stable storage of at least that capacity.
    package func statusRowScratch(capacity: Int) -> UnsafeMutableBufferPointer<Ubiquitty.Cell> {
        if let storage = statusRowStorage, storage.count >= capacity {
            return storage
        }
        statusRowStorage?.deallocate()
        let storage = UnsafeMutableBufferPointer<Ubiquitty.Cell>.allocate(capacity: max(capacity, 1))
        statusRowStorage = storage
        return storage
    }

    /// The foreground opacity the last frame drew a cell with, or nil when
    /// no frame has an instance at that cell. Read off the built cell
    /// instances rather than the palette, so it answers for what reached
    /// the screen: the palette's alpha as the capture carried it into the
    /// frame, or opaque where the frame drew it so.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - column: The column.
    /// - Returns: The drawn foreground alpha, 0...1.
    package func drawnForegroundAlphaForTesting(row: Int, column: Int) -> Float? {
        (renderer as? SurfaceRenderer)?.drawnForegroundAlphaForTesting(for: self, row: row, column: column)
    }

    /// Reads the live native background without invalidating its retained frame.
    package func nativeBackgroundPixelsForTesting() -> Data? {
        (renderer as? SurfaceRenderer)?.nativeBackgroundPixelsForTesting(for: self)
    }

    /// Reads ordinary pixels without changing the live frame's native color routing.
    package func retainedGridPixelsForTesting() -> Data? {
        (renderer as? SurfaceRenderer)?.retainedGridPixelsForTesting(for: self)
    }

    /// Selects a real renderer policy without overriding authenticated ownership.
    /// - Parameter presentation: The non-owner presentation under test.
    package func setRemoteViewportPresentationForTesting(_ presentation: RemoteViewportPresentation) {
        guard let painter = renderer as? SurfaceRenderer else { return }
        painter.style.nonOwnerPresentation = presentation
        askForAnotherFrame()
    }

    #if UBIQUITTY_UI_TESTS
    /// Changes real renderer padding and returns the previous value for restoration.
    ///
    /// - Parameter points: Left padding in native view points.
    /// - Returns: The previous padding, or nil without a native renderer.
    @discardableResult
    package func setLeftPaddingForTesting(_ points: Double) -> Double? {
        guard let painter = renderer as? SurfaceRenderer else { return nil }
        let previous = painter.style.paddingLeftPoints
        painter.style.paddingLeftPoints = points
        askForAnotherFrame()
        return previous
    }
    #endif

    /// Returns the live frame's native terminal mark ink.
    package func nativeTerminalMarkInkForTesting() -> SIMD4<Float>? {
        (renderer as? SurfaceRenderer)?.nativeTerminalMarkInkForTesting(for: self)
    }

    /// How many overlay quads the last frame drew in the padding gutters,
    /// where OSC 133 prompt marks are the only thing that draws; nil before
    /// a frame built any overlays.
    ///
    /// - Returns: The gutter quad count of the last frame.
    package func gutterOverlayCountForTesting() -> Int? {
        (renderer as? SurfaceRenderer)?.gutterOverlayCountForTesting(for: self)
    }

    /// Creates a surface owning a fresh session.
    ///
    /// - Parameters:
    ///   - rows: Initial row count.
    ///   - columns: Initial column count.
    /// - Returns: Nil when Core declines to make a session.
    public convenience init?(rows: Int, columns: Int) {
        guard let drive = RuntimeDrive(rows: rows, columns: columns) else { return nil }
        self.init(drive: drive, rows: rows, columns: columns)
    }

    /// Creates a surface adopting an externally owned terminal — the tmux
    /// render-only pane, whose model the Session writes and disposes.
    ///
    /// The Objective-C spelling, because the owner lives on that side of the
    /// seam: the terminal crosses as the untyped pointer the reference type
    /// is, and the lock as the number the adoption seam already hands out.
    ///
    /// - Parameters:
    ///   - terminal: The externally owned terminal, as a raw pointer.
    ///   - lockAddress: The owner's model lock address.
    ///   - rows: The grid's rows.
    ///   - columns: The grid's columns.
    /// - Returns: The surface, or nil when Core declines a session.
    /// Creates a surface adopting an externally owned terminal.
    ///
    /// The typed spelling, and the one to reach for. A terminal crosses as
    /// itself: Swift imports it as a reference because Core deletes its copy and
    /// move constructors, so no pointer and no bitcast are involved, and the
    /// compiler checks the call.
    ///
    /// - Parameters:
    ///   - terminal: The externally owned terminal.
    ///   - lockAddress: The owner's model lock address.
    ///   - rows: The grid's rows.
    ///   - columns: The grid's columns.
    /// - Returns: The surface, or nil when Core declines a session.
    ///
    /// Package-scoped, not public: its signature names a Core type this module
    /// imports internally, and a framework's textual interface cannot describe
    /// one — the emitted `.swiftinterface` spells it `__ObjC.Ubiquitty.Terminal`
    /// and then fails to verify against itself. An embedder outside the package
    /// reaches the same constructor through the `UnsafeMutableRawPointer`
    /// overload below, which is what the ObjC selector already binds to. Both
    /// callers of this one are in-package.
    package static func makeAdopting(terminal: Ubiquitty.Terminal, lockAddress: UInt, rows: Int, columns: Int) -> TerminalSurface? {
        guard let drive = RuntimeDrive(adopting: terminal, lockAddress: lockAddress, rows: rows, columns: columns) else {
            return nil
        }
        return TerminalSurface(drive: drive, rows: rows, columns: columns)
    }

    #if canImport(AppKit)
    /// The Objective-C spelling, for the AppKit shell's owner.
    ///
    /// It takes a raw pointer for one reason only: Objective-C cannot carry
    /// a C++ type, so a typed reference degrades at this boundary and the
    /// bitcast puts it back. Nothing else should use it — a Swift caller has
    /// the typed overload above, and a Swift-only shell has no reason to
    /// route a model through a pointer.
    @objc(surfaceAdoptingTerminal:lockAddress:rows:columns:)
    public static func makeAdopting(terminal: UnsafeMutableRawPointer, lockAddress: UInt, rows: Int, columns: Int) -> TerminalSurface? {
        makeAdopting(
            terminal: unsafeBitCast(terminal, to: Ubiquitty.Terminal.self),
            lockAddress: lockAddress,
            rows: rows,
            columns: columns
        )
    }
    #endif

    /// Creates a surface over a caller-built drive — a pane that spawned the
    /// session itself, or one adopting an externally owned terminal.
    ///
    /// - Parameters:
    ///   - drive: The drive whose model this surface presents.
    ///   - rows: The grid's rows, matching the drive's.
    ///   - columns: The grid's columns, likewise.
    package init(drive: RuntimeDrive, rows: Int, columns: Int) {
        self.drive = drive
        publishedGrid = (rows, columns)
        super.init(frame: .zero)
        registeredFontsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.proportionalMeasure.invalidateRichText()
                self.frameRenderers.removeAll()
                self.needsDisplay = true
            }
        }
        richTextCatalogObserver = NotificationCenter.default.addObserver(
            forName: RichTextFontCatalogCache.readyNotification,
            object: RichTextFontCatalogCache.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, RichTextFontCatalogCache.shared.hasBuiltSnapshot else { return }
                let generation = RichTextFontCatalogCache.shared.generation
                let revision = self.proportionalMeasure.refreshRichTextRevision()
                let shouldRedraw = self.drive.fontCatalogBecameReady(generation, revision)
                guard shouldRedraw else { return }
                self.needsDisplay = true
            }
        }
        // The configured caret, before anything can present. A terminal built
        // without this carries the construction defaults — a blinking block —
        // whatever `[cursor]` asks for, and the blink alone repaints eight
        // times a second forever. Core owns which fields the group covers, so
        // shape, linger, rate, alpha and inversion arrive with it.
        drive.withTerminal { terminal in
            Ubiquitty.Preferences.Effective.applyCursorPreferences(terminal, Ubiquitty.Preferences.values().pointee)
        }
        // Before any ingest starts: the signal pair is read unsynchronized on
        // the loop's thread, and the setter's contract is the session's —
        // install against a parked loop. Without this hop the surface draws
        // its first frame and then never again: the ingest thread has no way
        // to say the model changed, and every observer event stays queued in
        // the session for a reader that never comes.
        // The box outlives this surface by one release, performed in deinit
        // after the loop is parked — so the address the ingest thread holds is
        // valid for as long as anything can signal through it, whatever order
        // the surface's own teardown takes.
        // Same before-ingest contract as the drain signal below: the tap
        // slots are plain function pointers the ingest thread reads without
        // synchronization, so they are set while nothing can be ingesting.
        // The recorder records only while the Stream Debug window watches;
        // an installed tap on an unwatched surface is two null-guarded calls.
        drive.installStreamDebugTaps(streamDebugRecorder)
        // The perf log's tally, from the surface's first delivery on: the
        // session may already be ingesting, and the tally is an atomic flag
        // the loop reads, so it is safe to raise here either way.
        if SurfaceRenderer.framePerfLog.isActive() {
            isTallyingPerfDrains = true
            drive.startTallyingPerfDrains()
        }
        #if canImport(AppKit)
        // A path dropped on the grid is a path the reader wants to type.
        registerForDraggedTypes(Self.fileDropTypes)
        #endif
        let box = SurfaceDrainSignalBox(self)
        drainSignalBox = Unmanaged.passRetained(box)
        drive.setDrainSignal(
            context: UInt(bitPattern: Int(bitPattern: drainSignalBox!.toOpaque())),
            function: unsafeBitCast(surfaceDrainSignal as @convention(c) (UInt) -> Void, to: UInt.self)
        )
        // The Metal layer is a SUBLAYER of AppKit's own backing layer, never the
        // backing layer itself. A CAMetalLayer does not take part in the view
        // display cycle: made the backing layer, `updateLayer` is never called,
        // every `needsDisplay` this view sets is dropped, and the window stays
        // on whatever the compositor had — which is nothing, so it is white.
        wantsLayer = true
        // NSView's layer is optional and UIView's is not, so the two spell the
        // same attach differently. Nothing else about it differs.
        #if canImport(AppKit)
        contentClipLayer.masksToBounds = true
        contentClipLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        contentClipLayer.frame = bounds
        layer?.addSublayer(contentClipLayer)
        overscrollBackgroundLayer.actions = [
            "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
        ]
        contentClipLayer.addSublayer(overscrollBackgroundLayer)
        contentClipLayer.addSublayer(metalLayer)
        #else
        layer.addSublayer(metalLayer)
        #endif
        // A sublayer's geometry changes are implicitly animated by Core
        // Animation, where a view's own backing layer's are not: left alone the
        // grid slides and fades toward every new size for a quarter second,
        // which reads as the terminal lagging the window edge. The actions are
        // refused once here rather than suppressed per change, so a resize path
        // that forgets a transaction cannot reintroduce it.
        metalLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
            "contentsGravity": NSNull(),
            "backgroundColor": NSNull(),
        ]
        metalLayer.frame = bounds
        // The drawable is shown at its native size pinned to the top-left,
        // never scaled to fill the layer. Core Animation's default gravity is
        // `resize`, which stretches whatever drawable is current across the
        // layer's bounds: any moment the two disagree — a bounds change before
        // the next frame lands, a drawable rounded to integer pixels against
        // fractional bounds — draws the glyphs at the wrong pitch rather than
        // leaving an edge the next frame fills. In steady state the drawable
        // matches the bounds and the gravity does nothing. It stays top-left
        // through a live resize too, whichever edge is dragged: the grid is
        // laid out from the top inset on every step, so a stale frame in the
        // new bounds loses its bottom edge and never part of its first row.
        metalLayer.contentsGravity = .topLeft
        // Frames are presented on demand rather than on a clock: the session
        // signals when the model changed, and a terminal showing a still screen
        // should cost nothing.
        metalLayer.isOpaque = true
        metalLayer.needsDisplayOnBoundsChange = true
        metalLayer.presentsWithTransaction = false
        // The pool's ceiling, stated rather than inherited: with each frame's
        // drawable released when the frame ends (`drawSurfaceFrame`), this is
        // the most drawables of one size the layer holds, whatever a program
        // makes the window do.
        metalLayer.maximumDrawableCount = 3
        clockBridge = SurfaceClockBridge(surface: self)
        frameClock = FrameClock(delegate: clockBridge)
        // [render] max_fps and vsync, from the configuration in force: the
        // clock keeps the cap and re-clamps a live link on a change, and the
        // vsync choice is asserted on the layer here and again on every
        // resume, since the layer comes back with the default after a screen
        // or backing change.
        applyRenderPreferences(Ubiquitty.Preferences.Effective.liveRenderConfiguration())
        // The screen-change-rate drive is the default; UBIQUITTY_ADAPTIVE_FPS=0
        // holds the link continuous, which is what the bench's fixed arms measure.
        if ProcessInfo.processInfo.environment["UBIQUITTY_ADAPTIVE_FPS"] != "0" {
            drive.setAdaptivePresentation(.on)
        }
        // The user's [keys] section, parsed into a table this surface resolves
        // chords against. Built here rather than lazily because a binding that
        // works only after the first unbound keystroke is a binding that looks
        // broken.
        drive.rebuildKeyBindings()
        // The scroll bar spans the surface and stays hidden until
        // history exists; drags on it drive the view offset back through the
        // bridge, the same space the wheel moves.
        #if canImport(AppKit)
        terminalScroller.frame = bounds
        terminalScroller.autoresizingMask = [.width, .height]
        scrollerBridge = SurfaceScrollerBridge(surface: self)
        terminalScroller.scrollerDelegate = scrollerBridge
        terminalScroller.onOverscrollChange = { [weak self] offset in self?.applyVerticalOverscroll(offset) }
        addSubview(terminalScroller)
        addSubview(passwordBadge)
        // The OS cursor grab is process-global, so the app's own transitions
        // have to reach every surface that could be holding one — including a
        // pane behind the frontmost window, which sees no edge of its own.
        PointerLockRegistry.shared.add(self)
        #endif
    }

    deinit {
        // The last release lands on the main thread: every owner of a live
        // surface is a host view tree, and the ingest thread takes no strong
        // reference at all — the drain trampoline hands its box to a
        // main-queue block, and the weak load that materialises the strong
        // reference happens inside that block, on main. The
        // teardown asserts that confinement rather than hopping to it — a hop
        // would defer these deallocations past the release and leave the weak
        // in the signal box resolving to a surface whose teardown is ordered.
        MainActor.assumeIsolated {
            #if canImport(AppKit)
            // Creating the controller here would register a weak reference to a deallocating surface.
            dragDropStorage?.cancel()
            #endif
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            if let registeredFontsObserver {
                NotificationCenter.default.removeObserver(registeredFontsObserver)
            }
            if let richTextCatalogObserver {
                NotificationCenter.default.removeObserver(richTextCatalogObserver)
            }
            #if canImport(AppKit)
            // Off the centre they were added to; see `workspaceObservers`.
            for observer in workspaceObservers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            revealSettle?.cancel()
            if isPasswordPromptShown {
                PasswordPromptRegistry.shared.forget(self)
            }
            // A grab is process-global, so a surface torn down still holding
            // one leaves a hidden, dissociated cursor with nothing left to
            // release it. The window and focus edges cover the ordinary
            // paths; this covers a teardown that reached none of them.
            applyPointerLock(false)
            #endif
            statusRowStorage?.deallocate()
            frameClock.stop()
            // Clear the box first: a pass already inside the trampoline is holding
            // its lock, and this waits for it; every pass after it finds nothing
            // and returns. Park ingest and unregister, which waits for every
            // event producer's active callback, before releasing its context.
            if let box = drainSignalBox {
                box.takeUnretainedValue().clear()
            }
            drive.stopIngest()
            drive.setDrainSignal(context: 0, function: 0)
            if let box = drainSignalBox {
                box.release()
                drainSignalBox = nil
            }
            drive.close()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TerminalSurface is created in code, never from a nib")
    }

    /// Launches the user's login shell in this surface's session.
    ///
    /// - Parameter initialDirectory: The working directory to start in, or
    ///   nil for the user's home.
    /// - Returns: Whether the shell launched and its output is being read.
    @discardableResult
    public func launchShell(initialDirectory: String? = nil) -> Bool {
        let hasLaunched: Bool =
            if let initialDirectory {
                drive.launchLoginShell(initialDirectory: initialDirectory)
            } else {
                drive.launchLoginShell()
            }
        guard hasLaunched else {
            return false
        }
        guard drive.startIngest() else {
            return false
        }
        // The watch reads every byte the host sends, looking for a handshake most
        // sessions never see. A reader who does not transfer files this way can
        // decline the reading; one who does gets the download rather than a
        // screen of binary frame, which is why it is on unless asked otherwise.
        if Ubiquitty.Preferences.Effective.shouldWatchForZModem(Ubiquitty.Preferences.values().pointee) {
            drive.armFileTransferWatch()
        }
        return true
    }

    /// Attaches this surface's session as a thin client to a remote host.
    ///
    /// The model mirrors the host's screen frames, input ships as Sync
    /// input events, and the titles, bells, exit and repaints arrive through the
    /// same observer events a local shell raises — a host calls this where
    /// it would have called ``launchShell(initialDirectory:)`` and changes
    /// nothing else.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and
    ///     certificate pin; empty likewise offers no QUIC.
    ///   - reattachSessionID: The daemon session to re-home to, or zero for a
    ///     fresh one.
    ///   - workspaceName: The workspace to attach under. A name the host
    ///     already holds a session for attaches to that one and a name it does
    ///     not creates one — one connect, either outcome. Empty attaches
    ///     unnamed, which is the create-or-reattach by session id.
    ///   - endsWhenDetached: Whether a session created under the name ends when
    ///     its last human detaches cleanly, rather than outliving the client.
    ///   - reattachPolicy: What the attach asks when `reattachSessionID` has
    ///     ended. Attach-only is refused with
    ///     ``TerminalSurface/refusedReattachSessionID`` set rather than handed a
    ///     fresh session.
    ///   - workspaceID: The stable workspace identifier returned by the directory.
    ///   - daemonSocketName: The daemon socket returned by the directory handshake.
    ///   - daemonInstanceID: The daemon process identity to require, or zero for a new connection.
    /// - Returns: Whether the attach started.
    @discardableResult
    public func attachRemote(
        shellCommand: String,
        quicHost: String = "",
        quicBootstrapCommand: String = "",
        reattachSessionID: UInt32 = 0,
        workspaceName: String = "",
        endsWhenDetached: Bool = false,
        reattachPolicy: RemoteReattachPolicy = .attachOrCreate,
        workspaceID: UInt32 = 0,
        daemonSocketName: String = "",
        daemonInstanceID: UInt64 = 0
    ) -> Bool {
        drive.attachRemote(
            shellCommand: shellCommand,
            quicHost: quicHost,
            quicBootstrapCommand: quicBootstrapCommand,
            reattachSessionID: reattachSessionID,
            workspaceName: workspaceName,
            endsWhenDetached: endsWhenDetached,
            reattachPolicy: reattachPolicy == .attachOnly ? .AttachOnly : .AttachOrCreate,
            workspaceID: workspaceID,
            daemonSocketName: daemonSocketName,
            daemonInstanceID: daemonInstanceID
        )
    }

    /// Attaches a pane through the existing workspace connection.
    ///
    /// - Parameters:
    ///   - source: A drive already attached to the workspace.
    ///   - sessionID: An authoritative session identifier in that workspace.
    /// - Returns: Whether Core admitted the pane attachment.
    @discardableResult
    package func attachRemoteSibling(to source: RuntimeDrive, sessionID: UInt32) -> Bool {
        drive.attachRemoteSibling(to: source, sessionID: sessionID)
    }

    /// Attaches this surface's session over a carrier the embedder builds.
    ///
    /// The same thin-client session ``attachRemote(shellCommand:quicHost:quicBootstrapCommand:reattachSessionID:workspaceName:endsWhenDetached:)``
    /// stands up, differing only in where the carrier comes from. That one obtains carriers by
    /// spawning — a subprocess for the QUIC bootstrap, `ssh` for the fallback — which a frontend
    /// that cannot spawn a process has no way to use, even though the carriers themselves are
    /// portable and a QUIC connection dials directly.
    ///
    /// - Parameters:
    ///   - carrierFactory: The embedder's `Ubiquitty::Session::ChannelFactory`, as an address.
    ///     BORROWED, and it must outlive this surface's session: the session asks it for a fresh
    ///     carrier on every reconnect attempt, not once at attach.
    ///   - reattachSessionID: The daemon session to re-home to, or zero for a fresh one.
    ///   - workspaceName: The workspace to attach under. A name the host already holds a session
    ///     for attaches to that one and a name it does not creates one — one connect, either
    ///     outcome. Empty attaches unnamed, which is the create-or-reattach by session id.
    ///   - endsWhenDetached: Whether a session created under the name ends when its last human
    ///     detaches cleanly, rather than outliving the client.
    ///   - daemonSocketName: The directory-selected daemon socket, or empty for an unbound attach.
    ///   - daemonInstanceID: The directory-selected daemon process, or zero for an unbound attach.
    /// - Returns: Whether the attach started.
    @discardableResult
    public func attachRemoteOverCarrier(
        carrierFactory: UInt,
        reattachSessionID: UInt32 = 0,
        workspaceName: String = "",
        endsWhenDetached: Bool = false,
        daemonSocketName: String = "",
        daemonInstanceID: UInt64 = 0
    ) -> Bool {
        drive.attachRemoteOverCarrier(
            factory: carrierFactory,
            reattachSessionID: reattachSessionID,
            workspaceName: workspaceName,
            endsWhenDetached: endsWhenDetached,
            daemonSocketName: daemonSocketName,
            daemonInstanceID: daemonInstanceID
        )
    }

    /// Whether the attach failed because the host would not hand back the session it was asked
    /// to reattach.
    ///
    /// The two failures a frontend words differently: a host that died is one to retry, and a
    /// session the host will not give back is one to replace — by offering the host's sessions, or by
    /// attaching fresh. A frontend that read only "failed" would retry a reattach the host has
    /// already refused, forever. Cleared as soon as the connection reaches any other state.
    public var wasReattachRefused: Bool { drive.wasReattachRefused }

    /// Which session the host would not hand back, or 0 when none was refused.
    ///
    /// Read beside ``wasReattachRefused``: a frontend holding several remembered sessions cannot
    /// tell which one to forget without it.
    public var refusedReattachSessionID: UInt32 { drive.refusedReattachSessionID }

    /// The daemon session id this connection holds, or 0 before the host pins one.
    ///
    /// Pinned at HELLO_ACK and announced as
    /// ``TerminalSurfaceObserver/terminalSurfaceDidChangeRemoteSession(_:)``. A pairing a frontend
    /// persists is made from this and never from an attach returning true, which says only that
    /// the ask went out: a reattach the host answered with a different session is a session that
    /// had ended, and the two are told apart by comparing this against what was asked for.
    public var remoteSessionID: UInt32 { drive.remoteSessionID }

    /// Why the remote connection failed, in the host's own words. Empty unless it failed.
    ///
    /// A refusal is shown rather than retried, so the sentence the daemon sent is the one a
    /// frontend puts on screen.
    public var remoteFailureDetail: String { drive.lastRemoteFailure }

    /// How many clients other than this one are attached to this session.
    ///
    /// Core's count, so that every frontend answers "is somebody else on this" the same way.
    public var otherAttendeeCount: Int { drive.otherAttendeeCount }

    /// Asks a host what sessions it is holding, over a carrier the embedder builds.
    ///
    /// Separate from an attach and callable before one: a frontend that offers the human a choice
    /// has to know what there is to choose from before it binds this surface to any of it. The
    /// answer arrives as ``TerminalSurfaceObserver/terminalSurfaceDidUpdateHostSessions(_:)``.
    ///
    /// - Parameter carrierFactory: The embedder's `Ubiquitty::Session::ChannelFactory`, as an
    ///   address. BORROWED, and it must outlive this surface's session: the directory asks it for a
    ///   fresh carrier on every refresh.
    /// - Returns: Whether the question was asked.
    @discardableResult
    public func listHostSessions(carrierFactory: UInt) -> Bool {
        drive.listHostSessions(factory: carrierFactory)
    }

    /// Follows a host's tree over a carrier the embedder builds, on a connection of its own; each
    /// change arrives as ``TerminalSurfaceObserver/terminalSurfaceDidUpdateHostSessions(_:)``.
    ///
    /// - Parameter carrierFactory: As ``listHostSessions(carrierFactory:)``. BORROWED: call
    ///   ``stopWatchingHostSessions()`` before freeing it.
    /// - Returns: Whether a watch is running.
    @discardableResult
    public func watchHostSessions(carrierFactory: UInt) -> Bool {
        drive.watchHostSessions(factory: carrierFactory)
    }

    /// Stops following the host and lets go of the factory the watch borrowed.
    public func stopWatchingHostSessions() {
        drive.stopWatchingHostSessions()
    }

    /// Asks a host what sessions it is holding, over a carrier this surface's session SPAWNS.
    ///
    /// ``listHostSessions(carrierFactory:)`` in every respect but where the carrier comes from,
    /// which is the split the two attach doors take: a frontend that reaches a host by spawning
    /// `ssh … --attach` has no factory of its own to hand over. The answer arrives the same way, as
    /// ``TerminalSurfaceObserver/terminalSurfaceDidUpdateHostSessions(_:)``.
    ///
    /// The errand takes the subprocess carrier whatever the QUIC arguments say: it dials in TCP
    /// mode alone, and a bootstrap is itself an ssh round trip, so dialling QUIC for one question
    /// would pay a spawn to save none.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and certificate pin; empty
    ///     likewise offers no QUIC.
    /// - Returns: Whether the question was asked.
    @discardableResult
    public func listHostSessions(
        shellCommand: String,
        quicHost: String = "",
        quicBootstrapCommand: String = ""
    ) -> Bool {
        drive.listHostSessions(
            shellCommand: shellCommand,
            quicHost: quicHost,
            quicBootstrapCommand: quicBootstrapCommand
        )
    }

    /// The connect to make to the host this surface listed: Core's rule over the tree the host
    /// answered with and the host's remembered pairing.
    ///
    /// - Parameters:
    ///   - hostKey: The embedder's name for the host.
    ///   - predefinedWorkspaceName: The name the saved host carries, empty when it names none.
    ///   - chosenSessionID: The listed session the person selected, 0 for none.
    /// - Returns: The connect to make; the rule waits for the listing, or returns to the
    ///   remembered session, while the host has not answered.
    public func decideHostAttach(
        host hostKey: String,
        predefinedWorkspaceName: String,
        chosen chosenSessionID: UInt32 = 0
    ) -> HostAttachDecision {
        let decision = drive.decideHostAttach(host: hostKey, predefinedWorkspaceName: predefinedWorkspaceName, chosen: chosenSessionID)
        return HostAttachDecision(
            plan: HostAttachPlan(rawValue: decision.plan.rawValue) ?? .chooseFromList,
            sessionID: decision.sessionID,
            workspaceName: decision.workspaceName,
            vanishedSessionID: decision.vanishedSessionID,
            isNewSessionOffered: decision.isNewSessionOffered
        )
    }

    /// Tells a remote session the device's network path moved.
    ///
    /// Only the shell can see this — Core has no reachability API — so the
    /// frontend that owns an NWPathMonitor reports it here. A QUIC carrier
    /// migrates and is left alone; anything else is redialled at once rather
    /// than sitting out a backoff on a path that is already gone.
    public func networkPathChanged() {
        drive.networkPathChanged()
    }

    /// Tells a remote session what the device's network path costs.
    ///
    /// The shell's report, as a move is. Core tells the host, which pushes a
    /// metered or constrained link no history beyond one screen and sends the
    /// rest only as the person scrolls to it. Kept for a session this surface
    /// attaches later.
    public func setNetworkCost(_ cost: NetworkPathWatch.Cost) {
        switch cost {
        case .unmetered:
            drive.setNetworkCost(.unmetered)
        case .expensive:
            drive.setNetworkCost(.expensive)
        case .constrained:
            drive.setNetworkCost(.constrained)
        }
    }

    /// Whether this surface mirrors a host rather than a local process.
    public var isRemoteAttached: Bool {
        drive.isRemoteAttached
    }

    /// Whether this surface offered this Mac's clipboard to programs on the host.
    public var isServingClipboardToHost: Bool {
        drive.isServingClipboardToHost
    }

    /// Whether the clipboard source is awaiting acknowledgement from the host.
    public var isClipboardRoutingPending: Bool {
        drive.isClipboardRoutingPending
    }

    public var canChangeClipboardServing: Bool {
        drive.canChangeClipboardServing
    }

    @discardableResult
    public func setClipboardServing(_ enabled: Bool) -> Bool {
        drive.setClipboardServing(enabled)
    }

    /// Whether the program asked for bracketed paste (DECSET 2004).
    ///
    /// Read from the published snapshot rather than the model, so a paste
    /// arriving while a flood holds the model lock still answers.
    public var isBracketedPasteEnabled: Bool {
        drive.readSnapshot().modes.bracketedPaste
    }

    /// Sends a pasted payload the host can only receive as a file.
    ///
    /// - Parameters:
    ///   - mime: The payload's MIME name.
    ///   - bytes: The payload.
    /// - Returns: The push's id, or zero when nothing was sent.
    @discardableResult
    public func pushPaste(mime: String, bytes: [UInt8]) -> UInt32 {
        drive.pushPaste(mime: mime, bytes: bytes)
    }

    /// How much of the crossing paste has left, 0 to 1, or negative when
    /// nothing is crossing or the sender cannot say.
    public var pastePushProgress: Double {
        drive.pastePushProgress
    }

    /// Where the host landed the last pushed paste, empty until one does.
    public var lastPastePushPath: String {
        drive.lastPastePushPath
    }

    /// Sends text the user produced, and reports it as transmitted.
    ///
    /// ``send(_:)`` writes to the host and tells nobody, which is right for a
    /// host driving its own surface. A paste is the user typing: whatever
    /// watches typed input — a broadcast fan-out, a recorder — must see it, or
    /// the same keystrokes reach different panes depending on how they arrived.
    ///
    /// - Parameter text: The bytes to transmit, already fenced and normalised.
    package func transmitAsUserInput(_ text: String) {
        transmitAsUserInput(Array(text.utf8CString.dropLast()))
    }

    /// Sends user input without interpreting its encoding.
    ///
    /// - Parameter bytes: The complete payload, including embedded null bytes.
    package func transmitAsUserInput(_ bytes: consuming [CChar]) {
        guard !bytes.isEmpty else {
            return
        }
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            drive.sendInput(base, count: buffer.count)
        }
        noteUserInputTransmitted(bytes)
    }

    /// Offers the clipboard formats to an application using paste-event mode.
    /// - Parameter mimeTypes: Space-separated MIME names captured by the gesture.
    /// - Returns: Whether the terminal consumed the gesture.
    package func sendPasteNotification(_ mimeTypes: String) -> Bool {
        drive.sendPasteNotification(mimeTypes)
    }

    /// Pastes text as the user's input.
    ///
    /// The terminal sends it: fenced and normalised bytes to a local program,
    /// the text itself to a remote host, which fences it under the modes live
    /// there. What follows is what any of the user's text does to the view.
    ///
    /// - Parameter text: The clipboard's text.
    package func pasteAsUserInput(_ text: String) {
        let wrapped = drive.sendPaste(text)
        guard !wrapped.isEmpty else {
            return
        }
        noteUserInputTransmitted(wrapped)
    }

    /// What the user's own text does once it has been sent: the echo SRM
    /// leaves to the frontend, the observer, and the view's return to the
    /// live screen.
    ///
    /// - Parameter bytes: The bytes as this terminal's modes give them.
    private func noteUserInputTransmitted(_ bytes: [CChar]) {
        // Core's echo rule, the one the key path answers with: SRM reset
        // shows the bytes locally, a password prompt never does.
        if drive.shouldEchoInputLocally() {
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                drive.feed(Span(_unsafeStart: base, count: buffer.count))
            }
        }
        observer?.terminalSurface(self, didTransmit: bytes, count: bytes.count)
        // User text acts on the live screen the way a key press does, so the
        // view leaves history to show it — the Metal arm's writeStringToHost
        // records the same reason. ``send(_:)`` stays free of this: a host
        // driving its own surface is not the user, and it holds what it holds.
        snapToTailOnKeypress()
        noteUserActivity()
        hidePointerForTyping()
        // Every route the user's own text takes ends here — a keystroke, a
        // paste, an input method's commit — and each of them drops the
        // selection, because text arriving is the moment the highlight stops
        // describing anything the reader is looking at.
        clearSelectionForUserInput()
    }

    /// The user-input route, for a scenario that asks what it costs the
    /// selection.
    ///
    /// - Parameter text: The text to send as though the reader typed it.
    package func transmitAsUserInputForTesting(_ text: String) {
        transmitAsUserInput(text)
    }

    /// Sends text to the running process as user input.
    ///
    /// - Parameter text: The text, encoded as the terminal's input bytes.
    public func send(_ text: String) {
        let bytes = Array(text.utf8CString.dropLast())
        guard !bytes.isEmpty else {
            return
        }
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            drive.sendInput(base, count: buffer.count)
        }
    }

    /// Feeds bytes into the terminal as if the session produced them.
    ///
    /// For hosts that embed a surface without a live process — previews,
    /// replays, tests — and the reason the surface can draw before anything
    /// launches.
    ///
    /// - Parameter data: The bytes, exactly as a process would emit them.
    public func feed(_ data: Data) {
        // Borrowed where it already is, rather than copied into a second array
        // a byte at a time. This is the path previews, replays and tests feed,
        // so a multi-megabyte replay would pay a closure per byte and an
        // allocation the size of the input for bytes the call only reads.
        data.withUnsafeBytes { raw in
            drive.feed(raw.bindMemory(to: CChar.self))
        }
    }

    /// The layer the surface draws into, for a test that drives the scale.
    var metalLayerForTesting: CAMetalLayer { metalLayer }

    /// The delay the frame clock would schedule right now, in seconds.
    ///
    /// The clock's own answer, taken through the same bridge it uses, so a
    /// test reads the cadence a quiet terminal actually runs at rather than
    /// one recomputed beside it.
    ///
    /// - Returns: The seconds until the next repaint this surface asks for.
    func animationDelayForTesting() -> Double {
        clockBridge.frameClock(frameClock, nextAnimationDelayAt: drive.frameClockFactsNow().blinkTicks)
    }

    #if canImport(AppKit)
    // Both are NSView's own contract: draw by updating the layer rather than
    // through drawRect, and be eligible for first responder. UIKit asks
    // neither question — a UIView is layer-backed and its responder
    // eligibility comes from canBecomeFirstResponder, which the shell
    // answers.
    override public var wantsUpdateLayer: Bool { true }

    override public var acceptsFirstResponder: Bool { true }
    #endif

    /// The facts an animation decision reads, gathered from one snapshot.
    ///
    /// One snapshot for the whole answer: the terminal-side facts are captured
    /// together and must be read together, or the clock can arm on a cursor
    /// from one instant and a blink reading from another. What they mean is
    /// Core's to say — both arms call the same predicate, so a cursor cannot
    /// blink under one renderer and freeze under the other.
    ///
    /// - Returns: The demand this surface currently places on its clock.
    func animationDemand() -> Ubiquitty.Rendering.AnimationDemand {
        let snapshot = drive.readSnapshot()
        var demand = Ubiquitty.Rendering.AnimationDemand()
        // The flash's live strength, so the schedule picks the smooth cadence
        // while one is running: the envelope is a fade, and a clock stepping
        // at the blink rate would draw it in two frames.
        //
        // The tick alone, which needs no model lock. Every other fact here comes
        // off the published snapshot, and this is asked on every animation edge
        // and every ingest event: routing it through the facts that resolve the
        // cursor's weight blocks the main thread on the lock the parser holds,
        // for a weight the demand does not read.
        demand.bellFlashAlpha = bellFlashDemand(atTicks: drive.frameTicksNow())
        demand.hasBlinkCellOnScreen = snapshot.hasBlinkCellOnScreen
        demand.hasBlinkHint = snapshot.hasBlinkHint
        demand.presentedViewOffset = Int32(viewOffset)
        demand.isImageAnimating = snapshot.imagesAnimating
        demand.isFocusedMatchBouncing = (renderer as? SurfaceRenderer)?.isFocusedMatchBouncing ?? false
        demand.isCursorSliding = frameRenderers.values.contains { $0.isCursorSliding }
        demand.isHiliteAwaiting = snapshot.hiliteAwaiting
        demand.isCursorVisible = snapshot.isCursorVisible
        demand.isCursorBlinkEnabled = snapshot.cursorBlinkEnabled
        demand.cursorStyle = Ubiquitty.Cursor.Style(rawValue: snapshot.cursorStyle) ?? .FollowUserPreference
        demand.isCursorFocused = isSurfaceFocused
        // Core drops every animating reason but the hilite deadline for a pane
        // whose frames are withheld, so a covered window's blink schedules no
        // fires at all.
        demand.isFrameDeliveryWithheld = frameDelivery == .Withhold
        return demand
    }

    /// Whether the last frame drawn for this surface drew a selection.
    ///
    /// Read by the frame assembly, which routes the frame after a selection
    /// ends through the live capture rather than a boundary one.
    package var didLastFrameDrawSelection = false

    /// Whether the last frame drawn for this surface drew a search tier: the
    /// focused match or any other match on the visible rows.
    ///
    /// Read by the frame assembly, which keeps such a surface on the live
    /// capture: a boundary capture is built without the search tiers.
    package var didLastFrameDrawSearch = false

    /// Whether the keyboard is on this surface, by Core's rule.
    ///
    /// The frame assembly reads it into the capture's options, which is what
    /// separates the focused block cursor from the unfocused hollow outline;
    /// a surface that never joins a window keeps the focused default, so a
    /// headless host draws the cursor a lone terminal would. Always what was
    /// last published to the session, never a value computed at the read.
    package private(set) var isSurfaceFocused = true

    /// Whether the responder chain last handed this surface the keyboard.
    ///
    /// Remembered rather than read back from the window: the responder
    /// callbacks run before AppKit installs the new responder, and a surface
    /// drawing offscreen has no window whose chain could be read at all. It
    /// is not the focus fact. It says which pane the reader means, which
    /// stays true of a pane in a window the system has not made key, and it
    /// is what moves the model's focused pane. A touch shell's focus does not
    /// read it at all; see ``touchKeyboardHolder``.
    private var isResponderTarget = true

    #if canImport(UIKit)
    /// The text input outside the terminal that last began editing.
    ///
    /// Weak, and re-read at every derivation rather than trusted: what the
    /// touch rule asks is whether it still holds the keyboard in this
    /// surface's window, and an input that ended editing or left has let it
    /// go whether or not its end edge was seen.
    internal weak var editingOtherTextInput: UIView?
    #endif

    /// Sets focus without a window, for a caller that draws offscreen.
    ///
    /// A window's surface learns this from its edges, the responder callbacks
    /// and on a touch shell another input's editing, and a surface that never
    /// joins one keeps the focused default. A frame drawn
    /// for an unfocused pane has to be able to say so, or the hollow outline
    /// the focus alone produces cannot be drawn at all. In a window the next
    /// edge re-derives the answer from the window's facts.
    ///
    /// - Parameter isFocused: Whether the frame draws as the focused pane.
    package func setSurfaceFocused(_ isFocused: Bool) {
        isResponderTarget = isFocused
        publishSurfaceFocus(isFocused ? .Focused : .Unfocused)
    }

    /// Publishes one focus state to the session, on the edge only.
    ///
    /// Lock-free: the session posts the change to the thread that owns the
    /// model, so a focus edge arriving under an output flood cannot block
    /// main on the lock the ingest holds hot.
    ///
    /// - Parameter focus: The state Core decided.
    private func publishSurfaceFocus(_ focus: Ubiquitty.Modes.FocusState) {
        let isFocused = focus == .Focused
        guard isFocused != isSurfaceFocused else { return }
        isSurfaceFocused = isFocused
        drive.setDesiredFocus(focus)
        needsDisplay = true
    }

    /// Re-derives this surface's focus from the facts around it.
    ///
    /// Core's rules, so both macOS shells unfocus a pane on the same edges,
    /// the window losing key status and the application losing the keyboard
    /// included, neither of which a responder edge reports; and a touch shell
    /// unfocuses one only while another text input holds its keyboard.
    package func refreshSurfaceFocus() {
        let published: Ubiquitty.Modes.FocusState = isSurfaceFocused ? .Focused : .Unfocused
        #if canImport(AppKit)
        // The window facts are AppKit's. A surface drawing offscreen has no
        // window to read, so for it the responder callbacks carry the whole
        // fact.
        var facts = Ubiquitty.Runtime.SurfaceFocusFacts()
        facts.isWindowKey = true
        facts.isApplicationActive = true
        facts.isFirstResponder = isResponderTarget
        if window != nil {
            facts = SurfaceFocus.facts(for: self)
        }
        let verdict = Ubiquitty.Runtime.surfaceFocus(facts, published)
        #else
        let verdict = Ubiquitty.Runtime.touchSurfaceFocus(touchKeyboardHolder, published)
        #endif
        publishSurfaceFocus(verdict.focus)
        if verdict.wantsActivityNote {
            noteUserActivity()
        }
        // The lock's desire reads the same three facts, so it reconciles with
        // them: a lock held by a surface the focus left would trap a pointer
        // nothing reads.
        updatePointerLock()
    }

    /// Re-derives across AppKit's settling, for an edge that announces a
    /// responder change before making it.
    package func refreshSurfaceFocusAcrossSettling() {
        #if canImport(AppKit)
        SurfaceFocus.applyAcrossSettling { [weak self] in
            MainActor.assumeIsolated { self?.refreshSurfaceFocus() }
        }
        #else
        // A touch shell reads who holds its keyboard, and another input's
        // taking it is reported by that input's own editing edge once it has,
        // so a settled pass would answer what this one already did.
        refreshSurfaceFocus()
        #endif
    }

    /// Whether this pane's window is a native tab behind its group's front one.
    ///
    /// Beside the focus fact because the two answer different questions about
    /// the same frame: focus is what Core freezes the blink and gates the
    /// unfocused bell on, and this is only what the cursor paints as. A
    /// backgrounded pane is still unfocused as far as the model is concerned,
    /// which is why this never reaches ``setSurfaceFocused(_:)``.
    package private(set) var isWindowBackgroundedTab = false

    /// Re-reads the tab-group fact and asks for a frame when it moved.
    ///
    /// The flip between the filled cursor and the hollow outline changes no
    /// cell, so nothing in the drain dirties a row for it: without a frame
    /// asked for on this edge, a tab leaving the front keeps the outline it
    /// was last drawn with until its terminal writes something. Called on
    /// every edge a tab switch produces, the key-window edges and the
    /// occlusion flip that follows them, and on arriving in a window.
    package func refreshWindowTabBackgrounding() {
        #if canImport(AppKit)
        let isBackgroundedTab = WindowTabSelection.isBackgroundedTab(window)
        guard isBackgroundedTab != isWindowBackgroundedTab else { return }
        isWindowBackgroundedTab = isBackgroundedTab
        // A tab reaching the front is a reveal: the group's selection moves
        // now and the window system's occlusion report follows a frame later,
        // so the tab draws its current content rather than the layer it
        // stopped at. Noted before the recompute, which reads it.
        if !isBackgroundedTab {
            noteRevealEdge(recomputing: false)
        }
        // A tab reaching or leaving the front is a presentation edge as much
        // as a repaint one: the pane behind stops earning the tick.
        recomputePresentation()
        needsDisplay = true
        frameClock.noteAnimationActivity()
        #endif
    }

    override public func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if !isResponderTarget {
            isResponderTarget = true
            // The pane the reader means, which is a different question from
            // whether the keyboard is on it: a click in a window the system
            // has not made key still names the pane every later verb
            // addresses, so this stays synchronous and is not gated on the
            // window's key status.
            observer?.terminalSurface(self, didChangeFocus: true)
        }
        refreshSurfaceFocusAcrossSettling()
        #if canImport(AppKit)
        // A pane reached by keyboard produces no mouse move, so nothing else
        // would ask what the pointer is over — and it may be resting on a link
        // in the pane that just arrived.
        updateLinkAffordanceAtLivePointer()
        #endif
        return true
    }

    override public func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if isResponderTarget {
            isResponderTarget = false
            observer?.terminalSurface(self, didChangeFocus: false)
        }
        refreshSurfaceFocusAcrossSettling()
        #if canImport(AppKit)
        // `mouseExited` does not fire on a pane or tab switch, so an
        // affordance left standing here is a hand and an underline lit over
        // the NEW pane's content, explained by nothing on screen.
        clearLinkAffordance()
        #endif
        return true
    }

    #if canImport(AppKit)
    // UIKit needs no answer: its origin is already top-left, which is what
    // this asks AppKit for.
    override public var isFlipped: Bool { true }
    #endif

    /// Whether a sync-output recheck is already on the queue, so held frames
    /// arm one timer rather than one per draw attempt.
    private var isSyncOutputRecheckScheduled = false

    /// A 60 Hz monotonic count, cyclic like the tick domain it stands in
    /// for. The surface's schedule runs the smooth cadence while anything
    /// animates, so blink-phase alignment with Core's curve is the
    /// renderer's affair, not this count's. One derivation, because the
    /// sync-output hold ages on the same clock the frame schedule reads.
    ///
    /// Nonisolated because it reads a system clock and no surface state, so a
    /// caller off the main thread needs no hop to ask.
    ///
    /// - Returns: The current tick.
    nonisolated static func monotonicTicksNow() -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(CACurrentMediaTime() * 60.0))
    }

    // The draw entry point, under each shell's name for it. Both are reached
    // by setting needsDisplay, which is the surface's whole repaint
    // vocabulary.
    #if canImport(AppKit)
    override public func updateLayer() {
        drawSurfaceFrame()
    }
    #else
    /// The display link that answers a dirty mark, paused between frames.
    ///
    /// UIKit runs no display step for a view that overrides no drawRect, so
    /// setNeedsDisplay reaches nothing on its own: the surface presents
    /// through its own CAMetalLayer and has no backing store for UIKit to
    /// fill. The link is what AppKit's display cycle is here — one draw per
    /// refresh, however many marks arrived between them.
    internal var frameDisplayLink: CADisplayLink?

    override public func setNeedsDisplay() {
        super.setNeedsDisplay()
        armFrameDisplayLink()
    }

    /// The live registration for display-scale changes, held so it is made
    /// once.
    internal var displayScaleRegistration: (any UITraitChangeRegistration)?
    #endif

    /// Editor commands the input method delivered and the surface swallowed.
    ///
    /// The seam an oracle reads: the swallow's whole effect is a beep that does
    /// not happen, which no assertion can hear. The count says the command took
    /// the surface's own `doCommand(by:)` rather than `NSResponder`'s beeping
    /// default — lose the override and this stays at zero while every key still
    /// types, which is exactly the regression it exists to catch.
    package internal(set) var editorCommandsSwallowedForTesting = 0

    /// Which way the last tab-cycling chord asked to move: 1 for the next tab,
    /// -1 for the previous, 0 before either.
    ///
    /// The seam an oracle reads, for the same reason the swallow above has one:
    /// the whole effect of the request is `NSWindow.selectNextTab`, which the
    /// platform refuses for a window that is not key — and no window in the UI
    /// harness is, the application being an accessory. Without this a scenario
    /// could only assert that the chord was claimed, which any action would
    /// satisfy.
    package internal(set) var lastTabSelectionDirectionForTesting = 0

    /// The phase inputs the renderer's last live frame drew under.
    ///
    /// Every glyph's subpixel phase is a function of its pen x, and the pen is
    /// origin plus columns times advance — with the quads pinned to the pixel
    /// grid, these are the only numbers that can move ink inside them. Read by
    /// the live-typing scenario, which asserts they hold still while a real
    /// shell echoes keystrokes; nil while no frame has been encoded or the
    /// renderer is not the surface's own.
    package var lastFramePhaseInputsForTesting: FramePhaseInputs? {
        guard let renderer = renderer as? SurfaceRenderer else { return nil }
        return FramePhaseInputs(
            originX: renderer.lastFrameOriginXInPixels,
            originY: renderer.lastFrameOriginYInPixels,
            cellWidth: renderer.lastFrameCellWidthInAtlasPixels,
            didReuseLastFrame: renderer.didReuseLastFrame,
            didTrustDirtySet: renderer.didTrustDirtySetLastFrame,
            cellRefusalsAfterTrust: renderer.cellRefusalsAfterTrust,
            drawnCells: renderer.lastFrameDrawnCells,
            dirtyRows: renderer.lastFrameDirtyRows,
            plannedRows: renderer.lastFramePlannedRows
        )
    }

    /// What the renderer's last live frame drew under.
    ///
    /// A name rather than a tuple because its readers hold one across a loop,
    /// and a six-field tuple written out at each of them is a declaration that
    /// has to be found and edited every time a field joins.
    package struct FramePhaseInputs {
        /// The pen's x at the row's start, in device pixels.
        package let originX: Float
        /// The pen's y, in device pixels.
        package let originY: Float
        /// One cell's advance, in the atlas's pixels.
        package let cellWidth: Float
        /// Whether the frame Loaded the retained target.
        package let didReuseLastFrame: Bool
        /// Whether its builder was allowed to re-read only the dirty rows.
        package let didTrustDirtySet: Bool
        /// Frames so far whose encode refused a target the plan had trusted.
        package let cellRefusalsAfterTrust: Int
        /// Cell instances the frame's builder emitted.
        package let drawnCells: Int
        /// Rows the plan marked dirty.
        package let dirtyRows: Int
        /// Rows the plan walked.
        package let plannedRows: Int
    }

    /// Frames drawn through the shell's draw entry point.
    ///
    /// The seam an oracle reads: a surface can be correct in every other
    /// respect and never be asked to draw, which no renderer-side assertion
    /// can see.
    package private(set) var drawnFrameCount = 0

    /// Passes that reached the renderer, rather than turning back at a guard.
    ///
    /// `drawnFrameCount` counts every pass the toolkit or the link asked for,
    /// including the ones withheld for an open synchronized-output block or
    /// skipped because nothing owed a frame. Only the passes counted here can
    /// present, or ask again for having presented nothing, so a reader
    /// diagnosing a pane that never paints needs the two apart.
    package private(set) var encodeAttemptCount = 0

    /// Passes withheld for an open synchronized-output block or a settling erase.
    package private(set) var withheldForSyncOutputCount = 0

    /// Live-resize passes that kept the previous frame because the redraw
    /// behind a whole-screen erase was still arriving.
    package private(set) var deferredForArrivingRedrawCount = 0

    /// Passes that turned back because nothing owed a frame.
    package private(set) var skippedAsUnowedCount = 0

    private static let tracesFrames = ProcessInfo.processInfo.environment["UBIQUITTY_FRAME_TRACE"] == "1"

    /// Records the repaint handoff for an opt-in diagnosis of stale glass.
    private func traceFrame(_ stage: String) {
        guard Self.tracesFrames else { return }
        let frame = renderer as? SurfaceRenderer
        #if canImport(AppKit)
        let route = isToolkitDisplayRouteEnabled ? "toolkit" : "link"
        let linkActivity = frameLink?.isRunning == true ? 1 : 0
        #else
        let route = "toolkit"
        let linkActivity = 0
        #endif
        let line = String(
            format:
                "[frame-trace] %.6f pane=%ld %@ owed=%d delivery=%@ route=%@ link=%d draws=%ld attempts=%ld presents=%ld dirty=%ld/%ld cells=%ld skips=%ld sync=%ld occluded=%ld %@\n",
            CACurrentMediaTime(),
            ObjectIdentifier(self).hashValue,
            stage,
            isFrameOwed ? 1 : 0,
            frameDelivery == .Draw ? "draw" : "withhold",
            route,
            linkActivity,
            drawnFrameCount,
            encodeAttemptCount,
            frame?.presentedFrameCount ?? 0,
            frame?.lastFrameDirtyRows ?? 0,
            frame?.lastFramePlannedRows ?? 0,
            frame?.lastFrameDrawnCells ?? 0,
            skippedAsUnowedCount,
            withheldForSyncOutputCount,
            withheldForOcclusionCount,
            frame?.frameDeliverySummary ?? ""
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The adaptive drive readout for the debug window.
    package func adaptiveDriveFacts() -> AdaptiveDriveFacts {
        AdaptiveDriveFacts(
            arm: "modern",
            surfaceIdentity: ObjectIdentifier(self).hashValue,
            isAdaptive: drive.isAdaptivePresentation,
            isLinkContinuous: drive.isPresentationContinuous,
            isRecommendedContinuous: drive.isPresentationRecommendedContinuous,
            fastDrainStreak: drive.presentationFastDrainStreak,
            frameIntervalSeconds: drive.presentationFrameIntervalSeconds,
            framesDrawn: drawnFrameCount,
            framesPresented: (renderer as? SurfaceRenderer)?.presentedFrameCount ?? 0
        )
    }

    /// Draws one frame. Each shell calls it from its own draw entry point.
    /// Whether anything has asked for the next frame.
    ///
    /// Continuous drive presents on the display link rather than on a mark, so a
    /// repaint request schedules nothing and this is the only record that one was
    /// made. A link callback finding it false would encode the pixels already on
    /// the glass. Starts true because the first frame is owed unconditionally:
    /// nothing has been drawn, so there is no unchanged state to be right about.
    private var isFrameOwed = true

    /// Whether no frame of this surface has been encoded into its layer yet.
    private var isAwaitingFirstFrame = true

    /// Whether a frame drawn now would reach the glass.
    ///
    /// Core's verdict (`Runtime::paneFrameDelivery`) over this shell's facts,
    /// re-derived on every presentation edge. Withheld is a window nothing
    /// composites: the pass turns back at the draw entry, the mark it would
    /// have consumed stays owed, and the reveal draws it.
    internal private(set) var frameDelivery: Ubiquitty.Runtime.PaneFrameDelivery = .Draw

    /// The palette epoch of the newest screen change the observer was told
    /// of, so a withheld pane reports a palette that moved and nothing else.
    private var reportedPaletteEpoch: UInt64 = 0

    private var deferredPresentationEvents: RuntimeEvents = []
    private var isMetadataPresented = true
    private var processInspectors: Set<ObjectIdentifier> = []
    package var hasProcessInspector: Bool { !processInspectors.isEmpty }

    /// Registers whether an inspector consumes this pane's metadata.
    ///
    /// - Parameters:
    ///   - inspector: The observing model's identity.
    ///   - isActive: Whether its inspector is open.
    package func setProcessInspector(_ inspector: ObjectIdentifier, isActive: Bool) {
        if isActive {
            processInspectors.insert(inspector)
        } else {
            processInspectors.remove(inspector)
        }
        recomputePresentation()
    }

    /// The reveal edge this pane is drawing through, if any.
    ///
    /// The window system reports occlusion a frame or more after the edge that
    /// ended it, so an edge that brings a window forward draws at once and the
    /// report settles it. The lifecycle is Core's; this is where it stands.
    private var reveal = Ubiquitty.Runtime.PaneReveal()

    /// The booked recompute that ends a reveal no report answered.
    private var revealSettle: DispatchWorkItem?

    /// Whether a frame is owed, for a scenario that covers a window and
    /// checks the change it could not show is still waiting for the reveal.
    package var isFrameOwedForTesting: Bool { isFrameOwed }

    /// Whether this pane's frames are being withheld, for a diagnostic.
    package var isFrameDeliveryWithheldForTesting: Bool { frameDelivery == .Withhold }

    /// Reveal edges this pane has taken.
    package private(set) var revealEdgesForTesting = 0

    /// Repaint requests recorded without a display pass because the pane's
    /// frames are withheld.
    package private(set) var repaintsOwedWhileWithheldForTesting = 0

    /// Passes that turned back because the pane's frames are withheld.
    package private(set) var withheldForOcclusionCount = 0

    /// Whether the frame being drawn is a resize step's, drawn synchronously
    /// with its bounds change.
    internal var isDrawingResizeStep = false

    /// The booked release of the transactional present a resize step turned on.
    internal var transactionalPresentRelease: DispatchWorkItem?

    /// The size the surface last re-gridded for; a repeat of it owes nothing.
    private var lastResizedSize = CGSize.zero

    /// Whether frames nobody asked for are skipped.
    ///
    /// `UBIQUITTY_SKIP_UNCHANGED_FRAMES=0` presents on every link callback, so the
    /// two policies can be measured against each other in one binary: two builds
    /// differ by their whole optimisation regime, and that gap has been read as a
    /// real difference in this codebase before.
    ///
    /// AppKit only, because `isFrameOwed` is what the skip consumes and the
    /// `needsDisplay` override is what records it. UIKit has no such override,
    /// so a skip there would consume a mark nothing sets again and the surface
    /// would draw once and stop — which is what the draw-entry smoke reports
    /// when this is not scoped: every pass turning back as unowed.
    private static let skipsUnchangedFrames: Bool = {
        #if canImport(AppKit)
        return ProcessInfo.processInfo.environment["UBIQUITTY_SKIP_UNCHANGED_FRAMES"] != "0"
        #else
        return false
        #endif
    }()

    #if canImport(AppKit)
    /// Records every repaint request, however it was spelled.
    ///
    /// Overriding the property rather than editing its call sites is what keeps a
    /// site added later covered: the animation tick, the search pill, hover, the
    /// scroller and a resize all reach a frame through here, and a skip that
    /// missed one would drop that repaint entirely.
    override public var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                isFrameOwed = true
                traceFrame("mark")
                // A pane nothing composites is marked and left marked: the
                // request is recorded above, and handing it to AppKit would
                // commit a transaction and run a display cycle to encode a
                // frame into a drawable the window server throws away. The
                // reveal is what spends the mark.
                if frameDelivery == .Withhold {
                    repaintsOwedWhileWithheldForTesting += 1
                    return
                }
            }
            // The mark is recorded above whatever happens here, because it is
            // what the next pass consumes. Scheduling a toolkit display pass is
            // separate, and a link already presenting at the resolved rate does
            // not want one: a surface asked for frames by both routes draws on
            // the toolkit's cadence as well as the link's, which is the rate no
            // ceiling governs.
            if isToolkitDisplayRouteEnabled || !newValue {
                super.needsDisplay = newValue
            }
        }
    }

    /// Whether a repaint request also schedules a toolkit display pass.
    ///
    /// Cleared while a link drives, so the resolved rate — the screen's maximum
    /// clamped by `[render] max_fps` — is the only thing asking for frames.
    internal var isToolkitDisplayRouteEnabled = true
    #endif

    internal func drawSurfaceFrame() {
        #if canImport(AppKit)
        // An already-scheduled AppKit repaint leaves its demand for the Metal callback.
        if frameLink?.ownsDrawableDelivery == true, frameLink?.currentDrawable == nil { return }
        #endif
        drawnFrameCount += 1
        traceFrame("draw-start")
        // Nothing of this window is on screen, so whatever this pass would
        // encode reaches a drawable nobody composites. Every route lands here
        // — an AppKit display cycle, a link tick, a live-resize step, a direct
        // call — which is why the guard is at the entry rather than at each of
        // them. The owed mark is not consumed: the reveal draws it.
        guard frameDelivery == .Draw else {
            withheldForOcclusionCount += 1
            traceFrame("draw-withheld")
            frameClock.maybePause()
            isAnimationClockArmed = frameClock.isTicking
            return
        }
        // Nothing asked for this frame, so encoding it would reproduce what the
        // glass already shows. The pause check still runs, or the link would
        // never stand down and idle would never be reached.
        guard isFrameOwed || !Self.skipsUnchangedFrames else {
            skippedAsUnowedCount += 1
            traceFrame("draw-unowed")
            frameClock.maybePause()
            // The readout is kept current on this path too. A pass that draws
            // nothing is the quiet screen's steady state, and the schedule's own
            // fire is what stands the tick down — so a reader told once that the
            // clock was armed would never be told it stopped, because the only
            // other writer sits past this return. Nothing owes a frame here, so
            // the tick alone is the answer.
            isAnimationClockArmed = frameClock.isTicking
            return
        }
        isFrameOwed = false
        guard let renderer else {
            reportMissingRenderer()
            return
        }
        // A pass the layer could hand no drawable for drew nothing, and the
        // model change that asked for it goes with the request unless the
        // request is made again: a surface that has never presented then stays
        // blank for as long as it lives, over a live session whose keystrokes
        // run and whose title updates. A new tab reaches this whenever its
        // first pass beats the layer to a drawable, and no later edge owes it
        // a repaint.
        cursorPresentationDeadline = nil
        encodeAttemptCount += 1
        // Drained per frame: the drawable and its texture are autoreleased by
        // the acquire, and a caller that draws several frames inside one
        // run-loop callout — a burst of window resizes, each drawing its step
        // synchronously at a new size — would otherwise hold every one of
        // them, each a fresh allocation, until that callout's pool pops.
        let didEncode = autoreleasepool { renderer.encodeFrame(for: self, into: metalLayer) }
        if didEncode, isAwaitingFirstFrame {
            isAwaitingFirstFrame = false
            #if canImport(UIKit)
            metalLayer.backgroundColor = nil
            #endif
        }
        if didEncode {
            frameEncodedObserverForTesting?(self)
            // The presentation rate is fed by net change against the shadow
            // baseline; a frame that captured no dirty row stamps nothing.
            if renderer.lastFrameHadNetChange(for: self) {
                drive.notePresentationNetChange()
            }
        } else if !isFrameOwed {
            askForAnotherFrame()
        } else {
            // An open output block owns the retry through its watchdog or next delivery.
            cursorPresentationDeadline = nil
        }
        traceFrame(didEncode ? "draw-encoded" : "draw-refused")
        scheduleAnimationIfNeeded()
    }

    /// Asks for a frame again, after one that could not be drawn.
    ///
    /// On the next turn rather than here, so the request cannot be folded into
    /// the pass it repairs, and only while the surface is somewhere a retry can
    /// succeed: a view with no window, or one behind an occluded one, is handed
    /// no drawable at all and repaints from the edge that brings it back.
    package func askForAnotherFrame() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A surface with no window is the same refusal the occlusion guard
            // makes, and is counted as one: nothing of it is on screen to
            // repaint. Returning silently instead leaves neither count moved,
            // and a reader asking whether the surface is still being asked
            // cannot tell that from a retry that never ran.
            guard let window = self.window else {
                self.repaintRetriesRefused += 1
                return
            }
            #if canImport(AppKit)
            // Core's verdict first, so a retry inside an unconfirmed reveal is
            // asked rather than refused: the report still says covered there,
            // and the frame the reveal owes is exactly the one this repairs.
            guard self.frameDelivery == .Draw,
                window.occlusionState.contains(.visible)
                    || Ubiquitty.Runtime.isPaneRevealUnconfirmed(self.reveal, TerminalSurface.monotonicTicksNow())
            else {
                self.repaintRetriesRefused += 1
                return
            }
            #endif
            self.repaintRetriesAsked += 1
            self.needsDisplay = true
        }
    }

    /// Repaints asked again after a pass that drew nothing.
    package private(set) var repaintRetriesAsked = 0

    /// Repaints not asked again because nothing of this surface is on screen —
    /// it has no window, or the window it has does not read as visible.
    package private(set) var repaintRetriesRefused = 0

    /// Whether the missing renderer has already been reported.
    private var hasReportedMissingRenderer = false

    /// Says once that this surface is drawing nothing, and why.
    ///
    /// A surface in a window with no renderer produces exactly the symptom
    /// that carries no information: black. Everything else can be correct —
    /// the session connected, the grid full, the geometry right — and there
    /// is nothing on screen and nothing in any log. An embedder gets a
    /// sentence instead.
    private func reportMissingRenderer() {
        guard window != nil, !hasReportedMissingRenderer else { return }
        hasReportedMissingRenderer = true
        FileHandle.standardError.write(
            Data(
                ("ubiquitty: a TerminalSurface in a window has no renderer, so it draws nothing. "
                    + "Build it with TerminalSurface(rows:columns:fontFamily:pointSize:), or assign "
                    + "one from TerminalSurface.makeRenderer(...) before the surface is shown.\n")
                    .utf8
            )
        )
    }

    /// Keeps a withheld live frame owed until output settles or its watchdog expires.
    ///
    /// Called after releasing the model lock because scheduling reads the hold budget.
    internal func deferHeldPresentation() {
        withheldForSyncOutputCount += 1
        isFrameOwed = true
        scheduleSyncOutputRecheck()
    }

    /// Keeps a live resize's frame owed while the redraw behind a
    /// whole-screen erase is still arriving.
    ///
    /// The drain's delivery of the rest of the redraw asks for the frame; the
    /// recheck stands in for a redraw that stops short, which the erase hold's
    /// settle or watchdog then releases. Called after releasing the model lock
    /// because scheduling reads the hold budget.
    internal func deferPresentationForArrivingRedraw() {
        deferredForArrivingRedrawCount += 1
        isFrameOwed = true
        scheduleSyncOutputRecheck()
    }

    /// Ages the held block once its budget can have run out, and re-marks
    /// the view.
    ///
    /// The hold defers a frame, never discards one — but a deferred frame is
    /// only painted if something asks again. Bytes arriving ask; an
    /// application that opened a block and hung does not, so this timer is
    /// the one path that reaches the watchdog for it. It asks Core directly
    /// rather than through a draw: a surface whose display is dark draws
    /// nothing, and a hold that only a draw could expire would outlive the
    /// display. Core names the delay, so one shot lands exactly when the
    /// budget is spent instead of polling towards it.
    private func scheduleSyncOutputRecheck() {
        guard !isSyncOutputRecheckScheduled else {
            return
        }
        let ticks = drive.presentationHoldTicksRemaining(nowTicks: TerminalSurface.monotonicTicksNow())
        guard ticks > 0 else {
            return
        }
        isSyncOutputRecheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ticks) / 60.0) { [weak self] in
            guard let self else {
                return
            }
            self.isSyncOutputRecheckScheduled = false
            let stillHeld = self.drive.shouldWithholdFrame(nowTicks: TerminalSurface.monotonicTicksNow())
            if stillHeld {
                self.scheduleSyncOutputRecheck()
            }
            self.needsDisplay = true
        }
    }

    /// Whether the animation timer is armed — package-visible so the smoke
    /// can assert the arm and disarm edges, which is all a headless test can
    /// see of a schedule whose effect is motion.
    package private(set) var isAnimationClockArmed = false
    private var animationTimer: Timer?

    /// Whether the one-shot the last frame armed is still to fire, so the
    /// crossing it was armed for already has its repaint coming.
    internal var isAnimationRepaintPending: Bool { animationTimer?.isValid ?? false }

    /// Pending cursor presentation shares the surface's one-shot animation timer.
    internal var cursorPresentationDeadline: Double?
    internal var cursorPresentationBypassUntil: Double = 0

    /// Arms or disarms repainting for model animation and pending cursor presentation.
    ///
    /// Called after every drawn frame: the frame consumed the phase the
    /// schedule was computed against, so the next delay is measured from
    /// what is now on screen. The timer requests a repaint and nothing
    /// else — the frame it provokes re-runs this, so the cadence follows
    /// the schedule rather than a fixed rate. Disarmed whenever the model
    /// reports nothing animating, so a quiet terminal costs no frames.
    private func scheduleAnimationIfNeeded() {
        animationTimer?.invalidate()
        animationTimer = nil
        let verdict = drive.nextAnimationDelay()
        // The armed answer covers both cadence loops: the one-shot below and
        // the frame clock's tick, which stops itself one fire after content
        // goes static. An oracle reading only the one-shot passed while the
        // other loop was still ticking.
        let presentationDelay = cursorPresentationDeadline.map { max(0.001, $0 - CACurrentMediaTime()) }
        let slideDelay =
            frameRenderers.values.contains { $0.isCursorSliding }
            ? 1.0 / Double(max(60, clockBridge.frameClockMaxScreenFramesPerSecond(frameClock))) : Double.infinity
        let cursorDelay = min(presentationDelay ?? Double.infinity, slideDelay)
        isAnimationClockArmed = verdict.hasAnimatingContent || cursorDelay.isFinite || frameClock.isTicking
        guard verdict.hasAnimatingContent || cursorDelay.isFinite else { return }
        let contentDelay = verdict.hasAnimatingContent ? max(verdict.delaySeconds, 1.0 / 60.0) : Double.infinity
        let delay = min(contentDelay, cursorDelay)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            // The timer is added to the main run loop below, so the block fires
            // on the main thread.
            MainActor.assumeIsolated {
                // Only a view in a window can show the repaint this requests; a
                // headless surface re-arms on its next driven frame instead, so
                // the timer never draws frames nobody sees.
                guard let self, self.window != nil else { return }
                self.needsDisplay = true
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The surface arrived in, or left, a window.
    ///
    /// Called by each shell from its own lifecycle hook — AppKit's
    /// viewDidMoveToWindow, UIKit's didMoveToWindow — because the edge is the
    /// same fact under two names.
    internal func surfaceDidMoveToWindow() {
        #if canImport(UIKit)
        // An opaque Metal layer promises to cover its bounds, and one with no
        // drawable and no ground leaves what it shows undefined. A pane
        // arrives in its window a display refresh before its first frame can,
        // so until that frame the layer carries the ground the frame will
        // clear to, Core's colour off the model; a translucent layer keeps
        // whatever lies under it.
        if window != nil, isAwaitingFirstFrame {
            metalLayer.backgroundColor = metalLayer.isOpaque ? chromeBackgroundColor().cgColor : nil
        }
        #endif
        #if canImport(AppKit)
        if window == nil {
            secondaryTextPlane?.removeFromSuperview()
            secondaryTextPlane = nil
            backgroundVibrancyPlane?.removeFromSuperview()
            backgroundVibrancyPlane = nil
        }
        #endif
        // The clock's tick parks itself while the view is detached (its
        // repaints can show nowhere); arriving in a window is the edge that
        // re-takes it when anything still animates.
        if window != nil {
            frameClock.noteAnimationActivity()
            // A surface assembled off-window — which is how a split builds its
            // whole pane tree before attaching it — has been sizing its
            // drawable against a scale of one, and no backing-properties
            // callback is owed for arriving somewhere. Arriving is when the
            // scale becomes known, so the drawable is re-sized against it here
            // or the pane draws at one scale into a texture cut for another
            // until some later resize happens to reconcile them.
            let attachedScale = convertToBacking(CGSize(width: 1, height: 1)).width
            if attachedScale > 0 {
                metalLayer.contentsScale = attachedScale
            }
            syncDrawableSize()
            // The bar's geometry is only trustworthy once the surface is in a
            // window: a split assembles its whole pane tree off-window, and a
            // model that moved while the surface was detached reached no
            // drain to tell the bar about it. Quiet, because arriving is not a
            // scroll. AppKit happens to post a backing-properties edge on an
            // arrival too, so the re-mirror below would cover this path as
            // well — the arrival is stated here rather than left to depend on
            // that, which is a fact about the toolkit and not about the rule.
            refreshScrollbackChromeFromModel()
        }
        // The presentation edges live on the window, so the observers move
        // with it: miniaturize/deminiaturize flip the session's presentation,
        // and an occlusion flip back to visible repaints — a frame can be
        // asked for before AppKit flips the state, and that draw is the one
        // that would show stale pixels.
        installPlatformWindowObservers()
        // Arriving in a window is a reveal edge like any other: a pane
        // attached into a window the system reports covered draws its content
        // once rather than waiting for a report about a window it was not in.
        // A departure takes the reveal with it.
        if window != nil {
            noteRevealEdge(recomputing: false)
        } else {
            settleRevealFromReport()
        }
        recomputePresentation()
        // Once here as well as on every edge: a machine already in Low Power
        // Mode when a window opens is not going to post an edge to say so.
        refreshMachineThrottle()
        // A surface assembled off-window and attached into a tab that is
        // already behind starts with the fact rather than learning it at the
        // next key edge.
        refreshWindowTabBackgrounding()
        // Arriving in a window is the first edge with window facts to read:
        // a surface attached into a window that is not key must not keep the
        // focused default until the next key edge. The recompute reconciles
        // the pointer lock too, for a standing 7403 mode this arrival makes
        // an input target for.
        refreshSurfaceFocus()
    }

    /// The surface was hidden or shown.
    internal func surfaceDidChangeVisibility() {
        if !isHiddenOrHasHiddenAncestor {
            noteRevealEdge(recomputing: false)
        }
        recomputePresentation()
    }

    /// The cursor opacity this pane's most recent frame was drawn with.
    package var lastFrameCursorAlpha: Float {
        (renderer as? SurfaceRenderer)?.lastFrameCursorAlpha ?? 1
    }

    /// The blink weight this pane's most recent frame handed its cursor.
    package var lastFrameCursorMixAlpha: Float {
        (renderer as? SurfaceRenderer)?.lastFrameCursorMixAlpha ?? 1
    }

    /// The flash strength this pane's most recent frame carried.
    ///
    /// Zero once the envelope has run out and a frame has been drawn at that
    /// zero, which is the frame that takes the overlay off the screen.
    package var lastFrameBellFlashAlpha: Float {
        (renderer as? SurfaceRenderer)?.lastFrameBellFlashAlpha ?? 0
    }

    /// What the flash asks the animation schedule for at one tick.
    ///
    /// The greater of the envelope at that tick and at the last drawn frame's,
    /// because the overlay leaves the screen only when a frame is drawn
    /// without it: the live alpha alone stops the clock on the step to zero,
    /// and the last non-zero frame stays up as a wash nothing clears. So the
    /// ask outlives the envelope by exactly one frame — that frame draws at
    /// zero, and the next ask is zero.
    ///
    /// Takes the tick rather than reading the clock, so the transition can be
    /// put to it: it is one frame wide and cannot be waited for.
    ///
    /// - Parameter ticks: The tick to ask at.
    /// - Returns: The alpha the schedule reads.
    package func bellFlashDemand(atTicks ticks: UInt32) -> Float {
        guard let renderer = renderer as? SurfaceRenderer else { return 0 }
        return max(drive.bellFlashAlphaAt(ticks), drive.bellFlashAlphaAt(renderer.lastFrameBlinkTicks))
    }

    /// Whether the press in flight was spent on opening a link.
    ///
    /// A press that opened something is never reported, so its release and the
    /// motion before it must not be either — an application that saw a release
    /// with no press reads it as a click whose beginning it missed. Readable
    /// because it is a fact about the gesture in flight, which is what a test
    /// asks rather than the events it can only count indirectly.
    package internal(set) var didPressOpenALink = false

    /// Republishes and re-arms after a preference write.
    ///
    /// A write under the model lock changes what a frame would draw and what
    /// the clock would schedule, and neither reads the model: the frame reads
    /// the published snapshot and the schedule reads the published animation
    /// inputs. So the snapshot is pushed out, the view is marked, and the
    /// clock is woken — a setting that took effect only on the next byte from
    /// the host is one a reader changes and watches do nothing.
    package func republishAfterPreferenceWrite() {
        drive.republishSnapshot()
        needsDisplay = true
        frameClock.noteAnimationActivity()
    }

    /// Starts the visual bell's envelope at the tick the next frame reads.
    ///
    /// The flash is an overlay the assembly draws at the alpha the envelope is
    /// at, and it vanishes only when a frame is drawn without it — so the
    /// repaint is asked for here and the smooth cadence is picked from
    /// ``animationDemand()``, which keeps asking until the alpha reaches zero.
    /// A frame short of that leaves the last non-zero step on screen as a
    /// faint wash nothing clears.
    internal func startBellFlash() {
        drive.noteBellFlashStarted()
        needsDisplay = true
        frameClock.noteAnimationActivity()
    }

    /// Publishes whether this surface deserves current render state.
    ///
    /// The facts are this surface's and the verdict is Core's
    /// (`Runtime::panePresentation`), so a native tab behind the front one
    /// cannot stay on the full-rate tick. The session
    /// reduces a hidden pane's cadence and keeps capturing, so bringing one
    /// forward never shows the state it stopped at.
    internal func recomputePresentation() {
        let visibility = paneVisibility
        let presentation = Ubiquitty.Runtime.panePresentation(visibility)
        drive.setPresentation(presentation)
        let wasMetadataPresented = isMetadataPresented
        isMetadataPresented = isTitlePresentationVisible || !processInspectors.isEmpty
        let needsProcessState = observer?.terminalSurfaceNeedsProcessState(self) ?? hasProcessInspector
        drive.setProcessStatePresentation(needsProcessState ? .Presented : .Hidden)
        if isMetadataPresented && !wasMetadataPresented {
            let metadata = deferredPresentationEvents.subtracting(.screenDirty)
            deferredPresentationEvents.subtract(metadata)
            deliver(metadata)
        }
        // The stable hide (a backgrounded tab, a miniaturized window — not a
        // fleeting occlusion) is what the retained grid follows: a window
        // dragged briefly over another flips occlusion many times a second, and
        // re-minting a screen's worth of GPU memory on each flip costs more
        // than it saves. The layer's drawable pool is not resized on this edge:
        // a write to CAMetalLayer.maximumDrawableCount rebuilds the swap
        // queue, and with drawables in flight the next nextDrawable blocks for
        // the whole one-second timeout — a second of frozen main per tab
        // switch.
        let isPresented = presentation == .Presented
        #if canImport(AppKit)
        secondaryTextPlane?.isHidden = !isPresented
        backgroundVibrancyPlane?.isHidden = !isPresented
        #endif
        if isPresented != isStablyPresented {
            isStablyPresented = isPresented
            // A remote pane nobody sees is Dormant on the host: it is sent a
            // `PaneDirty` when it changes rather than its screen, and the reveal
            // costs only the rows that moved meanwhile.
            reportRemotePaneShown()
            if !isPresented {
                // Hand back each scale's retained grid (a screen of pixels
                // holding an image nobody sees) and drop the baseline with it,
                // so the reveal's first frame captures every row rather than
                // trusting clean rows onto a target that no longer holds them.
                for renderer in frameRenderers.values {
                    renderer.releaseRetainedGrid()
                }
                invalidateRetainedBaseline()
            }
        }
        // The continuous link follows FULL-RATE presentation, which occlusion
        // does move: a covered pane parks its link, an uncovered one takes it
        // back. Re-derive only while output is flowing — an idle pane already
        // holds a stopped link — so a covered terminal under a flood stops
        // driving frames into a drawable nothing composites.
        // Whether a frame drawn now reaches the glass at all, which is the
        // question the draw entry and the repaint mark both consume. Published
        // before the rate is re-derived: parking the link hands the repaint
        // route back to the toolkit with a pass owed, and that pass is what
        // the withhold has to hold.
        let wasWithheld = frameDelivery == .Withhold
        frameDelivery = Ubiquitty.Runtime.paneFrameDelivery(visibility)
        drive.setSyncFramePresentation(frameDelivery == .Draw ? .Presented : .Hidden)
        let isFullRate = Ubiquitty.Runtime.paneFullRatePresentation(visibility) == .Presented
        if isFullRate != isFullRatePresented {
            isFullRatePresented = isFullRate
            if drive.isPresentationContinuous {
                frameClock.resume()
            }
        }
        if frameDelivery == .Withhold {
            if !wasWithheld {
                // The edge itself stands the animation down: a clock left
                // armed keeps firing at the blink cadence for a screen nobody
                // sees, and its readout would say the pane is animating. The
                // re-arm below takes it back only for a hilite deadline, which
                // owes a timeout rather than a frame.
                animationTimer?.invalidate()
                animationTimer = nil
                frameClock.stop()
                drive.resetImageAdvanceClock()
                frameClock.noteAnimationActivity()
                isAnimationClockArmed = frameClock.isTicking
            }
            return
        }
        if wasWithheld {
            let pending = deferredPresentationEvents
            deferredPresentationEvents = []
            deliver(pending.union(.screenDirty))
        }
        if isPresented || wasWithheld {
            needsDisplay = true
            frameClock.noteAnimationActivity()
        }
    }

    /// Notes an edge that brought this pane's window forward.
    ///
    /// The window system reports occlusion a frame or more after the reveal
    /// that ended it (a tab switch flips occlusion a frame after it moves the
    /// group's selection), so a pane that waited for the report would show the
    /// layer it stopped at — after a long cover, content minutes old. The edge
    /// draws now and the report settles it; which panes take one, and for how
    /// long, is Core's (`Runtime::notePaneRevealEdge`).
    ///
    /// - Parameter recomputing: Whether to re-derive the presentation here. A
    ///   caller about to recompute for its own reason passes false.
    package func noteRevealEdge(recomputing: Bool = true) {
        let now = TerminalSurface.monotonicTicksNow()
        let next = Ubiquitty.Runtime.notePaneRevealEdge(reveal, paneVisibility, now)
        guard next.isPending, next.isPending != reveal.isPending || next.deadlineTicks != reveal.deadlineTicks else {
            return
        }
        reveal = next
        revealEdgesForTesting += 1
        // The report is what normally ends the reveal; this is the fallback for
        // an edge the window system never answers — a window ordered front
        // under one that still covers it — so the pane stops drawing again
        // rather than drawing for ever on an edge nothing confirmed.
        revealSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.recomputePresentation()
            }
        }
        revealSettle = settle
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(Ubiquitty.Runtime.revealConfirmationBudgetTicks) / 60.0,
            execute: settle
        )
        if recomputing {
            recomputePresentation()
        }
    }

    /// The window system answered: whatever edge preceded this report, the
    /// report describes the window as it stands now.
    internal func settleRevealFromReport() {
        revealSettle?.cancel()
        revealSettle = nil
        reveal = Ubiquitty.Runtime.PaneReveal()
    }

    /// Whether the pane is a selected, non-miniaturized tab — the drain gate's
    /// presentation, tracked so a stable hide can shrink the drawable pool and
    /// let the retained grid go without churning on occlusion flips.
    private var isStablyPresented = true

    /// Whether the pane has earned a continuous link: presented and not wholly
    /// covered. Tracked so an occlusion edge re-derives the link's drive.
    private var isFullRatePresented = true

    /// Whether the app is in the background, where no pane is seen however
    /// its window stands.
    private var isApplicationBackgrounded = false

    /// Whether the host was last told this pane is shown; a remote pane that
    /// is not is `Dormant` on the host.
    public private(set) var isRemotePaneShown = true

    /// How many times the host has been told the pane was hidden or shown.
    ///
    /// What a check reads across a change that must leave a pane on screen:
    /// a surface taken out of its window and put back reads as shown again
    /// once it is back, and only this count tells it apart from one that
    /// never moved.
    package private(set) var remotePaneViewReportCount = 0

    /// Tells the host whether the pane is shown: presented, in an app in the
    /// foreground.
    private func reportRemotePaneShown() {
        let isShown = isStablyPresented && !isApplicationBackgrounded
        guard isShown != isRemotePaneShown else { return }
        isRemotePaneShown = isShown
        remotePaneViewReportCount += 1
        drive.setRemotePaneShown(isShown)
    }

    /// Tells the surface the app went to the background or came back. In the
    /// background no remote pane is shown, so the host sends none a screen and
    /// a phone's radio stays asleep; coming back shows the presented ones,
    /// each sent only the rows that changed meanwhile.
    ///
    /// - Parameter isBackgrounded: Whether the app is in the background.
    public func noteApplicationBackgrounded(_ isBackgrounded: Bool) {
        isApplicationBackgrounded = isBackgrounded
        reportRemotePaneShown()
    }

    /// The inset this pane's grid draws under at its top edge, in points.
    ///
    /// Off the renderer rather than off the configuration, because the two are
    /// the question and the answer: a window's chrome decides which of the
    /// configured insets applies, and this is what it came to.
    package var contentTopInsetInPoints: Double {
        (renderer as? SurfaceRenderer)?.style.paddingTopPoints ?? 0
    }

    /// Reports whether the window's title has a visible reader.
    package var isTitlePresentationVisible: Bool {
        guard let window else { return false }
        #if canImport(AppKit)
        let presentedWindow = window.tabGroup?.selectedWindow ?? window
        let isOccluded =
            presentedWindow === window
            ? (isFullyOccludedForTesting ?? isWindowReportedOccluded(presentedWindow))
            : isWindowReportedOccluded(presentedWindow)
        return !presentedWindow.isMiniaturized && !isOccluded
        #else
        return !window.isMiniaturized
        #endif
    }

    /// What this shell can see about where its window sits.
    ///
    /// Occlusion is gathered with the rest even though the publish above
    /// ignores it: the rate ladder asks the same struct, and reading the
    /// window in one place keeps the two questions answering for the same
    /// moment.
    internal var paneVisibility: Ubiquitty.Runtime.PaneVisibility {
        var visibility = Ubiquitty.Runtime.PaneVisibility()
        guard let window else { return visibility }
        visibility.hasWindow = true
        visibility.isMiniaturized = window.isMiniaturized
        visibility.isHiddenInWindow = isHiddenOrHasHiddenAncestor
        #if canImport(AppKit)
        visibility.isBackgroundedTab = WindowTabSelection.isBackgroundedTab(window)
        visibility.isFullyOccluded = isFullyOccludedForTesting ?? isWindowReportedOccluded(window)
        #endif
        visibility.isRevealUnconfirmed = Ubiquitty.Runtime.isPaneRevealUnconfirmed(
            reveal,
            TerminalSurface.monotonicTicksNow()
        )
        return visibility
    }

    #if canImport(AppKit)
    /// Whether the window system reports nothing of the window on screen.
    ///
    /// - Parameter window: The surface's window.
    /// - Returns: The report, as the occlusion policy reads it.
    private func isWindowReportedOccluded(_ window: NSWindow) -> Bool {
        #if UBIQUITTY_UI_TESTS
        // The harness parks windows outside every display while
        // remaining ordered and drawable. Treat that containment as visible:
        // the suite is exercising foreground rendering without covering the
        // operator's desktop, not exercising the occlusion power policy.
        return !CommandLine.arguments.contains("--ui-test") && !window.occlusionState.contains(.visible)
        #else
        return !window.occlusionState.contains(.visible)
        #endif
    }
    #endif

    /// Stands in for the window system's occlusion report, nil to read it.
    ///
    /// The one seam a scenario covers or uncovers a window through: a harness
    /// that parks its windows off every display cannot move another window
    /// over one, and the report it would read describes the parking rather
    /// than a cover. The report's notification is still what the policy
    /// answers, so a scenario sets this and posts that notification.
    package var isFullyOccludedForTesting: Bool?

    /// Keeps the display link from driving this surface, for a smoke that
    /// draws through the entry point by hand.
    ///
    /// A visible pane earns the panel's rate, and the first delivery then
    /// hands drawables to the link: a pass called directly, holding none,
    /// defers to the link's next tick instead of drawing. The draw-entry smoke
    /// asks what one pass does, so it keeps the pane on the on-demand route.
    package var isFrameLinkHeldOffForTesting = false

    /// Pushes the machine's own budget to the drain gate.
    ///
    /// Low Power Mode is the reader asking for less and thermal pressure is
    /// the system already shedding work; where the line falls between the
    /// ladder's steps is Core's (`Runtime::machineThrottle`). It reaches the
    /// gate rather than the clock because a throttled machine collapses the
    /// mid-burst backoff on the FOREGROUND pane too — the one place a
    /// terminal can give a laptop its fans back without the reader watching a
    /// slower screen.
    internal func refreshMachineThrottle() {
        machineBudgetPushesForTesting += 1
        let process = ProcessInfo.processInfo
        var budget = Ubiquitty.Runtime.MachineBudget()
        budget.isInLowPowerMode = process.isLowPowerModeEnabled
        budget.thermal = TerminalSurface.thermalPressure(process.thermalState)
        drive.setMachineThrottle(Ubiquitty.Runtime.machineThrottle(budget))
    }

    /// How many times the machine's budget has been pushed to the gate.
    ///
    /// The registration is what a scenario cannot see: a handler that is
    /// never called and one that is called and answers the same thing look
    /// alike from outside, and on a cool machine at full charge every answer
    /// is the same one. Counting the pushes separates them.
    package private(set) var machineBudgetPushesForTesting = 0

    /// The platform's thermal step on Core's ladder.
    ///
    /// - Parameter state: What the system reports.
    /// - Returns: The step, hottest for one this build does not know: a
    ///   pressure reading nobody can place is one to spend less under, not
    ///   more.
    private static func thermalPressure(_ state: ProcessInfo.ThermalState) -> Ubiquitty.Runtime.ThermalPressure {
        switch state {
        case .nominal:
            return .Nominal
        case .fair:
            return .Fair
        case .serious:
            return .Serious
        case .critical:
            return .Critical
        @unknown default:
            return .Critical
        }
    }

    /// The window settled out of a native full-screen transition.
    ///
    /// The transition re-hosts the window, and on the way the layer can pass
    /// through a scale that is not the display's: the layer can measure
    /// one while the window's backing scale stays at two. A
    /// grid published from inside the animation carries that scale into the
    /// pixel-report grid and the image quad, and nothing afterwards moves
    /// them, because the backing-properties edge fires only when the
    /// display's scale changes, and it did not. So the scale is read off the
    /// window again, as that edge would read it; the drawable and the
    /// cell-pixel size follow it; and a frame is forced, so the renderer
    /// re-bakes what it drew against the animation's drawable.
    package func settleAfterFullScreenTransition() {
        surfaceDidChangeBackingProperties()
        invalidateRetainedBaseline()
        // The transition re-hosts the window, and the occlusion report for the
        // window it becomes arrives after the settle: the frame forced here is
        // the one the reader sees, so the pane draws it whatever the last
        // report said.
        noteRevealEdge()
        needsDisplay = true
    }

    /// The window's backing scale changed.
    package func surfaceDidChangeBackingProperties() {
        // The drawable is sized in device pixels, so the scale has to reach the
        // layer before the next frame: presenting at the old scale draws a frame
        // at the wrong resolution and the mismatch reads as a blurred font
        // rather than as a stale scale.
        metalLayer.contentsScale = window?.backingScaleFactor ?? metalLayer.contentsScale
        // Before the grid, not after: the cell the resize divides by is measured
        // off faces built at the scale. Measured on Menlo 12, the cell in points
        // is the same at 2 and at 3 — the advance and the line height are linear
        // in the size the faces are built at, and the measurement divides that
        // scale back out. It stops being the same under `snapsLineHeight`, which
        // rounds at a granularity of one atlas pixel.
        // The drawable's size in pixels follows the scale, and once it has been
        // assigned at all the layer stops deriving it from bounds and scale on
        // its own. Moving a window between displays of different scale changes
        // the scale without changing the frame, so nothing else would resize
        // it: the drawable would keep the pixel dimensions of the display it
        // came from while every frame is composed against the new scale, until
        // some later resize happened to put the two back in agreement.
        syncDrawableSize()
        renderer?.prepare(forDeviceScale: Double(metalLayer.contentsScale))
        resizeGridToBounds()
        // Beside the resize rather than inside it: a scale change leaves the
        // grid where it was, and `resizeGridToBounds` returns early for a grid
        // that did not move — so the re-mirror its reflow carries never runs
        // for the one edge that changes nothing but the scale.
        refreshScrollbackChromeFromModel()
        // And a frame is asked for: the grid
        // that did not move schedules nothing, so without this the layer keeps
        // presenting its last frame at the old scale — a 2x frame on a 1x
        // display reads as a blurred font — until some other dirty signal
        // arrives. The retained target was drawn at the old scale too.
        invalidateRetainedBaseline()
        needsDisplay = true
    }

    /// Sizes the drawable to the bounds, in whole device pixels, at the scale
    /// the renderer encodes against.
    ///
    /// Two properties the layer's own derivation does not give:
    ///
    /// The size is ROUNDED. A drawable is an integer-sized texture, so a
    /// fractional request is coerced, and the residue is a drawable that no
    /// longer covers `bounds x contentsScale` — which Core Animation resolves
    /// by scaling the contents to the bounds. Under the top-left gravity above
    /// that is a sub-pixel gap; under any other it is stretched glyphs.
    ///
    /// The scale is the LAYER's, which is the scale ``SurfaceRenderer`` lays
    /// the cell metrics out at. Read from the view's own conversion instead,
    /// the two diverge whenever the window's backing scale and the layer's
    /// disagree — dragging a window between a retina and a non-retina display
    /// changes them a callback apart — and the grid is then composed for one
    /// scale into a drawable sized for the other, covering the matching
    /// fraction of it. The view's conversion is the fallback for a layer that
    /// has no scale of its own yet.
    package func syncDrawableSize() {
        var scale = metalLayer.contentsScale
        if scale <= 0 {
            scale = convertToBacking(CGSize(width: 1, height: 1)).width
        }
        if scale <= 0 {
            scale = 1
        }
        // Clamped to the largest texture the device makes: a view sized past
        // it by a program's window request would otherwise ask the layer for
        // a drawable it cannot back.
        let limit = CGFloat(Self.maxDrawableExtent)
        let pixels = CGSize(
            width: min((bounds.width * scale).rounded(), limit),
            height: min((bounds.height * scale).rounded(), limit)
        )
        guard pixels.width > 0, pixels.height > 0, pixels != metalLayer.drawableSize else {
            return
        }
        metalLayer.drawableSize = pixels
        drawableSizeChangeCount += 1
    }

    /// The widest or tallest drawable, in device pixels: Metal's 2D texture
    /// limit on every Apple GPU family this arm runs on.
    package static let maxDrawableExtent = 16_384

    /// How many times the drawable was resized: each one discards the layer's
    /// pool and allocates afresh, so a resize storm reads here.
    package private(set) var drawableSizeChangeCount = 0

    /// Drawables this surface's frames asked its layer for on demand.
    package var drawablesRequestedForTesting: Int { (renderer as? SurfaceRenderer)?.drawablesRequested ?? 0 }

    /// Retained-grid allocations across this surface's frame renderers.
    package var gridTextureAllocationsForTesting: Int {
        frameRenderers.values.reduce(0) { $0 + $1.gridTextureAllocations }
    }

    /// The surface's size changed.
    ///
    /// Each shell calls this from its own resize hook: AppKit's setFrameSize,
    /// UIKit's layoutSubviews. The body is the terminal's, and there is one.
    internal func surfaceDidResize(to newSize: CGSize) {
        #if canImport(AppKit)
        if isPasswordPromptShown {
            layoutPasswordBadge()
        }
        #endif
        // A sublayer is not laid out by the view, so its frame is followed by
        // hand; left behind it draws the previous size into the corner.
        layoutDisplayBlankCover()
        #if canImport(AppKit)
        contentClipLayer.frame = bounds
        layoutOverscrollBackground()
        metalLayer.bounds = contentClipLayer.bounds
        metalLayer.position = CGPoint(x: contentClipLayer.bounds.midX, y: contentClipLayer.bounds.midY + verticalOverscroll)
        secondaryTextPlane?.synchronizeGeometry(to: self, matching: metalLayer)
        backgroundVibrancyPlane?.synchronizeGeometry(to: self, matching: metalLayer)
        #else
        metalLayer.frame = bounds
        #endif
        syncDrawableSize()
        // The grid is laid out from the top inset on every step, a drag's
        // included, so a step's frame is the frame the drag settles on. A
        // top-edge drag keeps its last rows by Core's bottom anchor, which
        // moves rows into history whole; a pixel origin shifted to hold the
        // bottom gap instead would lift the first row past the top inset
        // whenever the gap shrinks — the first quantised step out of a window
        // that does not hold a whole number of cells — and clip it.
        resizeGridToBounds()
        // A bounds change owes a frame of its own: the drawable was resized,
        // and the drain's `.screenDirty` for the grid move lands after this
        // turn. The synchronous per-step draw a zoom or a programmatic
        // setFrame takes would otherwise find nothing owed and skip, leaving
        // the compositor to stretch the previous drawable until the animation
        // ends.
        if newSize != lastResizedSize {
            lastResizedSize = newSize
            isFrameOwed = true
        }
    }

    #if canImport(AppKit)
    /// Applies scroll preferences without changing the terminal's viewport.
    package func applyScrollPreferences() {
        terminalScroller.refreshConfiguration()
    }

    private func layoutOverscrollBackground() {
        let extent = contentClipLayer.bounds
        let height = min(abs(verticalOverscroll), extent.height)
        overscrollBackgroundLayer.frame = CGRect(
            x: extent.minX,
            y: verticalOverscroll >= 0 ? extent.minY : extent.maxY - height,
            width: extent.width,
            height: height
        )
    }

    /// Follows AppKit's elastic motion without resizing the drawable or the terminal grid.
    package func applyVerticalOverscroll(_ offset: CGFloat) {
        guard offset.isFinite, offset != verticalOverscroll else { return }
        verticalOverscroll = offset
        layoutOverscrollBackground()
        metalLayer.position = CGPoint(x: contentClipLayer.bounds.midX, y: contentClipLayer.bounds.midY + offset)
        secondaryTextPlane?.synchronizeGeometry(to: self, matching: metalLayer)
        backgroundVibrancyPlane?.synchronizeGeometry(to: self, matching: metalLayer)
        if isPasswordPromptShown { layoutPasswordBadge() }
    }
    #endif

    /// Republishes the grid when the view's size changed it.
    ///
    /// Both the cell grid and the pixel extent go across: applications read the
    /// pixel fields for image geometry, and a resize that moves only pixels —
    /// a backing-scale change — moves no rows at all.
    /// The absolute row of the prompt the last prompt-navigation step landed
    /// on, or -1 to re-derive from the viewport.
    ///
    /// Kept per surface because it is where the reader is in this pane's own
    /// history: two panes stepping through their prompts share nothing,
    /// and a shell-level anchor would drag one pane's walk onto the other's.
    package var promptNavigationAnchorRow = -1

    /// Whether the live drag's stationary edge is the bottom one.
    ///
    /// Read by `isBottomEdgeFixed(resizingFrom:to:)`: the window's bottom
    /// holding still means the reader is dragging the top edge, and the
    /// primary screen should grow upwards from a fixed last row. False outside a
    /// drag, and false for a pane divider — a window frame that never moved
    /// says nothing about which edge is standing still.
    package var isLiveResizeBottomFixed = false

    /// Whether a live resize is in progress, for the image layer's carry.
    ///
    /// An image application redraws by deleting and re-placing its picture
    /// every frame, and a frame captured between the two sees no placement at
    /// all. Outside a drag that is a real delete and the layer goes; inside
    /// one it is the gap, and `Rendering::imageLayerAction` carries the last
    /// good layer across it. The drag is the only thing this arm knows that
    /// Core does not, so it is the one fact reported.
    package internal(set) var isHoldingImageGapsForResize = false

    /// Whether a live resize drag is running.
    ///
    /// The surface's own latch, opened by `viewWillStartLiveResize` and
    /// closed by its partner, rather than AppKit's `inLiveResize`: they say
    /// the same thing during a drag and only this one can be opened by a
    /// caller. A toolkit with no window drag settles every resize, which is
    /// the answer that pays for the rewrap at once.
    internal var isInLiveResizeGesture: Bool {
        #if canImport(AppKit)
        return !liveResizeStartWindowFrame.isEmpty
        #else
        return isPinchingFont
        #endif
    }

    internal func resizeGridToBounds() {
        guard let renderer else { return }
        let cell = renderer.cellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return }
        // Core's one fit, with the renderer's own insets: a second division
        // here is how a frontend and its frame come to disagree about the
        // last column, and Core's is the fit that also clamps into the grid a
        // resize can actually hold.
        //
        // The insets the frame draws inside, whole: this protocol's `top`
        // already carries the reserved band, so the vertical pair is the
        // reserve itself. Passing them and reserving nothing is what left this arm
        // dividing the full height into rows while the renderer laid them out
        // inside the padding — a grid one row taller than the box that holds
        // it, whose last row falls past the bottom edge.
        // The FIT's insets, not the frame's: DECSET 7402 takes the frame to
        // the edge and moves no column, so the grid keeps the padding's box.
        let insets = renderer.gridFitInsets(for: self)
        var request = Ubiquitty.Rendering.GridFitRequest()
        request.insets.left = Float(insets.left)
        request.insets.right = Float(insets.right)
        request.insets.top = Float(insets.top)
        request.insets.bottom = Float(insets.bottom)
        request.viewport.width = Float(bounds.width)
        request.viewport.height = Float(bounds.height)
        request.cell.width = Float(cell.width)
        request.cell.height = Float(cell.height)
        // A view not laid out yet names no grid; the frame it is given next
        // refits it.
        guard Ubiquitty.Rendering.isViewportLaidOut(request.viewport) else { return }
        // DECCOLM's claim on the width, read from the lock-free snapshot the
        // drain publishes: while 132-column mode stands the application owns
        // the count and only the rows follow the window.
        let modes = drive.readSnapshot()
        request.isColumnCountHeld = modes.isColumnCountHeld
        request.heldColumns = modes.columns
        let grid = Ubiquitty.Rendering.fitGridToViewport(request)
        let columns = Int(grid.columns)
        let rows = Int(grid.rows)
        // The layer's scale rather than `convertToBacking`: a surface with no
        // window converts at one, and the model's cell-pixel size — which an
        // image protocol's placements divide by — would name half the pixels
        // the layer draws. The layer follows the window's scale when there is
        // one, and a headless host sets it outright.
        let pixels = CGSize(width: bounds.width * metalLayer.contentsScale, height: bounds.height * metalLayer.contentsScale)
        // The cell's pixel size, every time: a scale change moves it with the
        // grid unchanged, and an image protocol divides by it.
        let cellPixelWidth = Int((cell.width * metalLayer.contentsScale).rounded())
        let cellPixelHeight = Int((cell.height * metalLayer.contentsScale).rounded())
        // The text area is the extent the grid is DRAWN in — the columns
        // times the cell in points, scaled, rounded once — and not the
        // per-cell product, which rounds each cell and drifts by a pixel a
        // column at a fractional advance. CSI 14 t answers with it, the
        // pointer clamp reads it, and a child dividing it by the columns
        // recovers the exact cell for sixel sizing.
        let textAreaWidth = Int((cell.width * CGFloat(columns) * metalLayer.contentsScale).rounded())
        let textAreaHeight = Int((cell.height * CGFloat(rows) * metalLayer.contentsScale).rounded())
        // The drawable beside the grid: under DECSET 7402 a fitted image fills
        // the whole of it, and Core answers CSI 14 t with whichever the mode
        // names, so a flip between two publishes is answered at once.
        drive.publishCellPixelSize(
            cellWidthInPixels: cellPixelWidth,
            cellHeightInPixels: cellPixelHeight,
            textAreaWidthInPixels: textAreaWidth,
            textAreaHeightInPixels: textAreaHeight,
            drawableWidthInPixels: Int(pixels.width.rounded()),
            drawableHeightInPixels: Int(pixels.height.rounded())
        )
        // The winsize pixels are the extent CSI 14 t answers with — the
        // drawn text area, or the drawable under DECSET 7402 — and not the
        // view's whole bounds: a child dividing ws_xpixel by the columns
        // recovers the cell, and the padding in the bounds made that cell
        // oversized. The same fact the publish above handed Core.
        let reportedPixels =
            drive.readSnapshot().modes.isFullscreenContentActive && pixels.width > 0 && pixels.height > 0
            ? (width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded()))
            : (width: textAreaWidth, height: textAreaHeight)
        guard (rows, columns) != publishedGrid else {
            // The grid held but the pixels moved — a scale change, a window
            // reaching its screen — and the child reads ws_xpixel for the
            // cell's device size: re-sent on its own, the grid as it was.
            if reportedPixels != publishedWindowPixels {
                publishedWindowPixels = reportedPixels
                drive.setWindowSize(
                    columns: columns,
                    rows: rows,
                    widthInPixels: reportedPixels.width,
                    heightInPixels: reportedPixels.height
                )
            }
            return
        }
        publishedGrid = (rows, columns)
        publishedWindowPixels = reportedPixels
        // Name the visible text before resizing renumbers its rows.
        noteViewportBeforeResize()
        // A drag's steps defer their history rewrap to the settle; a resize
        // that stands on its own pays for it now. The anchor follows the
        // edge the reader is not moving, so a top-edge drag leaves the
        // prompt where it is instead of dragging it along. The pixels ride
        // with the grid: one winsize per step, so a program that erases its
        // last frame on SIGWINCH is not asked to twice.
        drive.resize(
            rows: rows,
            columns: columns,
            gesture: isInLiveResizeGesture ? .interactive : .settled,
            anchor: observer?.terminalSurfacePreservesVisibleTopOnResize(self) == true
                ? .visibleTop : (isLiveResizeBottomFixed ? .bottom : .top),
            widthInPixels: reportedPixels.width,
            heightInPixels: reportedPixels.height
        )
        // Resolve before the observer, so a host that lays chrome out
        // on the callback is handed a viewport and a bar that already agree
        // about the new grid.
        carryViewOffsetAcrossResize()
        observer?.terminalSurface(self, didResizeGridTo: rows, columns: columns)
    }

    /// The family Core would answer `OSC 50 ?` with.
    ///
    /// Read from the model rather than from the renderer, because the two are
    /// the point: the renderer knows what is drawn and Core knows what it will
    /// report, and a shell that never publishes the first into the second
    /// answers the query with the empty string for the session's whole life.
    package var publishedFontFamilyForTesting: String {
        drive.withTerminal { String($0.font.copyToString()) } ?? ""
    }

    /// Returns the actual fallback face used by this surface's atlas.
    package func routedFamilyForTesting(_ codePoint: UInt32) -> String? {
        (renderer as? SurfaceRenderer)?.routedFamilyForTesting(codePoint, for: self)
    }

    /// The native shaping work and active cache retention of the last frame.
    package var shapingStatisticsForTesting: (lines: Int, segments: Int)? {
        (renderer as? SurfaceRenderer)?.shapingStatisticsForTesting(for: self)
    }

    /// The font family this surface's glyphs are currently drawn from, or nil
    /// for a renderer that names none.
    ///
    /// For an oracle asking what a window settled on rather than what it was
    /// asked for: a family the face store refuses leaves the previous one
    /// standing, and the two answers differ exactly where that happens.
    package var drawnFontFamilyForTesting: String? {
        (renderer as? SurfaceRenderer)?.familyName
    }

    /// The em size this surface's glyphs are currently drawn at, or nil for a
    /// renderer that exposes no font measurement.
    package var drawnFontPointSizeForTesting: Double? {
        (renderer as? SurfaceRenderer)?.pointSize
    }

    /// The em size proportional runs are set at right now, or nil before an
    /// atlas has been cut.
    package var drawnProportionalPointSizeForTesting: Double? {
        (renderer as? SurfaceRenderer)?.proportionalPointSizeForTesting(for: self)
    }

    /// The visible grid as text, one line per row, trailing blanks trimmed:
    /// the harness's grid text, read here for a Swift surface. A continuation cell is the
    /// glyph before it; an empty cell is a space.
    package func gridTextForTesting() -> String {
        drive.withTerminal { terminal -> String in
            let rows = Int(terminal.rows)
            let columns = Int(terminal.columns)
            var lines: [String] = []
            lines.reserveCapacity(rows)
            for row in 0..<rows {
                var line = ""
                for column in 0..<columns {
                    guard let cell = Ubiquitty.Screen.visibleCell(terminal, 0, Int32(row), Int32(column)) else {
                        line.append(" ")
                        continue
                    }
                    if Ubiquitty.isTextContinuation(cell.pointee) {
                        continue
                    }
                    if cell.pointee.codePoint != 0, let scalar = UnicodeScalar(cell.pointee.codePoint) {
                        line.unicodeScalars.append(scalar)
                    } else {
                        line.append(" ")
                    }
                }
                while line.hasSuffix(" ") {
                    line.removeLast()
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        } ?? ""
    }

    /// How long the last live-resize step's grid reflow took, in seconds, or
    /// nil until a drag reflows. Set by the resize path, read and cleared by
    /// the frame that follows it so the perflog can pair the two costs.
    package var lastLiveResizeReflowSeconds: Double?
    /// The atlas slot geometry the frame renderer draws with — the cell box,
    /// its margins and the slot they make — for a scenario; nil before a
    /// frame renderer exists.
    package func glyphSlotForTesting() -> Ubiquitty.Rendering.GlyphSlotGeometry? {
        (renderer as? SurfaceRenderer)?.glyphSlotForTesting(for: self)
    }

    /// Re-adopts the renderer's font, for a scenario that needs a known
    /// primary face under a known typography.
    ///
    /// - Parameters:
    ///   - familyName: The primary family.
    ///   - pointSize: The em size in points.
    ///   - typography: The typography to adopt.
    /// - Returns: Whether the renderer applied it.
    package func adoptFontForTesting(familyName: String, pointSize: Double, typography: SurfaceTypography) -> Bool {
        guard let renderer = renderer as? SurfaceRenderer else { return false }
        return renderer.adopt(pointSize: pointSize, familyName: familyName, typography: typography)
    }

    /// The typography the renderer currently draws under, for a scenario.
    package var typographyForTesting: SurfaceTypography? {
        (renderer as? SurfaceRenderer)?.typography
    }

    /// The background alpha and colour the last frame was drawn with, read off
    /// the frame's uniforms rather than the style: what the compositor was
    /// handed, which is what a Reduce Transparency verdict has to change.
    package func drawnBackgroundForTesting() -> (alpha: Float, color: Ubiquitty.Rendering.Vec4)? {
        (renderer as? SurfaceRenderer)?.drawnBackgroundForTesting(for: self)
    }

    #if canImport(AppKit)
    /// This surface's frame drawn now through its own renderer into an
    /// offscreen target, for a scenario that reads the pixels a reader would
    /// see: the target's size in device pixels and its BGRA rows, top row
    /// first. Nil before the layer has a size or a frame renderer exists.
    /// macOS only, because the read-back is a managed texture synchronised
    /// by a blit, which iOS does not offer.
    package func renderedFrameForTesting() -> (width: Int, height: Int, pixels: Data)? {
        (renderer as? SurfaceRenderer)?.renderedFrameForTesting(for: self)
    }

    /// Attempts one capture and encode without waiting out presentation holds.
    ///
    /// - Parameters:
    ///   - texture: The target for this frame.
    ///   - contentScale: Device pixels per point.
    /// - Returns: Whether the frame was encoded immediately.
    package func renderImmediatelyForTesting(into texture: any MTLTexture, contentScale: Double) -> Bool {
        (renderer as? SurfaceRenderer)?.render(self, into: texture, contentScale: contentScale) ?? false
    }
    #endif

    /// Applies the `[render]` pacing a configuration names: the frame cap to
    /// the clock and the vsync choice to the layer.
    ///
    /// Called at creation and by the host's configuration subscription, so a
    /// key edited in the file reaches a running window rather than waiting
    /// for the next link resume.
    ///
    /// - Parameter configuration: Core's fold of the live document.
    package func applyRenderPreferences(_ configuration: borrowing Ubiquitty.Rendering.RenderConfiguration) {
        isPresentSynchronized = configuration.isPresentSynchronized
        frameClock.setMaxFPS(configuration.maxFramesPerSecond)
        #if canImport(AppKit)
        metalLayer.displaySyncEnabled = isPresentSynchronized
        #endif
    }

    /// Whether presentation waits for the display's refresh, as the last
    /// applied configuration said; the clock re-asserts it on every resume.
    package private(set) var isPresentSynchronized = true

    /// The frame cap the clock holds, for a scenario; 0 is no cap.
    package var frameClockMaxFPSForTesting: Int32 { frameClock.maxFPSForTesting }

    /// Takes the clock's resume edge, for a scenario reading what a resume
    /// re-asserts.
    package func resumeFrameClockForTesting() {
        frameClock.resume()
    }

    /// Arms the present handler without the perflog, for a scenario that
    /// reads the slip accounting off a Swift surface.
    package static var shouldArmPresentSlipForTesting: Bool {
        get { SurfaceRenderer.shouldArmPresentSlipForTesting }
        set { SurfaceRenderer.shouldArmPresentSlipForTesting = newValue }
    }

    /// The presents recorded by the slip accounting, and the refreshes they
    /// latched late by, for a scenario.
    package var presentSlipForTesting: (presented: UInt64, slippedVsyncs: UInt64) {
        guard let renderer = renderer as? SurfaceRenderer else { return (0, 0) }
        return (renderer.presentSlip.presentedCountForTesting, renderer.presentSlip.slippedVsyncs)
    }

    /// The slip field UBIQUITTY_PHASE_LOG prints for this surface's frames, or
    /// nil without a Swift renderer.
    package var phaseLogSlipFieldForTesting: String? {
        (renderer as? SurfaceRenderer)?.phaseLogSlipField
    }

    /// One frame this surface committed to its layer while presents were
    /// recorded, and what the glass did with it.
    package struct PresentedFrameForTesting {
        /// When the encode that committed the frame returned, in
        /// `CACurrentMediaTime` seconds.
        package let committedSeconds: Double
        /// When the frame reached the glass, on the same clock; zero when the
        /// compositor has not reported it, or never showed it.
        package let presentedSeconds: Double
        /// Whether the frame showed a row the glass did not already hold.
        ///
        /// Net change against the shadow baseline, the fact the presentation
        /// driver's screen-change rate is stamped from: a frame that moved
        /// only the caret's blink phase repeats its content.
        package let showsNewContent: Bool
    }

    /// The commits made since ``beginRecordingPresentsForTesting(capacity:)``,
    /// each with the serial of the drawable it armed.
    private var recordedCommitsForTesting: [(serial: UInt64, committedSeconds: Double, showsNewContent: Bool)] = []
    /// The frame observer a recording wraps, put back when it ends.
    private var observerWrappedByRecordingForTesting: (@MainActor (TerminalSurface) -> Void)?
    private var isRecordingPresentsForTesting = false

    /// Starts pairing each frame this surface commits with the time the
    /// compositor reports it reached the glass.
    ///
    /// Arms the slip accounting's presented handler, which a release frame
    /// does not pay for, and reads each commit through
    /// ``frameEncodedObserverForTesting``, which this wraps: the encode path
    /// itself gains nothing. A commit is paired with the drawable it armed by
    /// serial, so the surface must commit asynchronously — a transactional
    /// present, such as a live-resize step's, reports no presented time — and
    /// be the only surface its renderer is presenting.
    ///
    /// - Parameter capacity: The most commits and presents to keep.
    package func beginRecordingPresentsForTesting(capacity: Int = 4096) {
        guard let renderer = renderer as? SurfaceRenderer, !isRecordingPresentsForTesting else { return }
        isRecordingPresentsForTesting = true
        TerminalSurface.shouldArmPresentSlipForTesting = true
        renderer.presentSlip.beginRecordingForTesting(capacity: capacity)
        recordedCommitsForTesting.removeAll(keepingCapacity: true)
        recordedCommitsForTesting.reserveCapacity(max(0, capacity))
        let wrapped = frameEncodedObserverForTesting
        observerWrappedByRecordingForTesting = wrapped
        var lastSerial = renderer.presentSlip.lastArmedSerialForTesting
        let kept = max(0, capacity)
        frameEncodedObserverForTesting = { [weak renderer] surface in
            wrapped?(surface)
            guard let renderer else { return }
            // An encode that reproduced the glass returned without committing,
            // so the serial stands where the last commit left it.
            let serial = renderer.presentSlip.lastArmedSerialForTesting
            guard serial != lastSerial else { return }
            lastSerial = serial
            guard surface.recordedCommitsForTesting.count < kept else { return }
            surface.recordedCommitsForTesting.append(
                (serial, CACurrentMediaTime(), renderer.lastFrameHadNetChange(for: surface))
            )
        }
    }

    /// The frames committed since the recording began, in commit order, each
    /// with its presented time as the compositor has reported it so far.
    package var recordedPresentsForTesting: [PresentedFrameForTesting] {
        guard let renderer = renderer as? SurfaceRenderer else { return [] }
        var presentedAt: [UInt64: Double] = [:]
        for present in renderer.presentSlip.recordedPresentsForTesting where present.serial > 0 {
            presentedAt[present.serial] = present.presentedSeconds
        }
        return recordedCommitsForTesting.map { commit in
            PresentedFrameForTesting(
                committedSeconds: commit.committedSeconds,
                presentedSeconds: max(0, presentedAt[commit.serial] ?? 0),
                showsNewContent: commit.showsNewContent
            )
        }
    }

    /// Stops the recording and puts back the observer it wrapped.
    package func endRecordingPresentsForTesting() {
        guard isRecordingPresentsForTesting else { return }
        isRecordingPresentsForTesting = false
        frameEncodedObserverForTesting = observerWrappedByRecordingForTesting
        observerWrappedByRecordingForTesting = nil
        recordedCommitsForTesting = []
        TerminalSurface.shouldArmPresentSlipForTesting = false
        (renderer as? SurfaceRenderer)?.presentSlip.endRecordingForTesting()
    }

    /// The box the grid is fitted into, and the cell it is divided by.
    ///
    /// For an oracle checking that the published grid actually fits: derived a
    /// second time in the test it would pass against its own arithmetic rather
    /// than against the numbers this surface resized on. Nil before a renderer
    /// is attached.
    package var gridFitBoxForTesting: (insets: PlatformEdgeInsets, cell: CGSize, bounds: CGSize)? {
        guard let renderer else { return nil }
        return (renderer.gridFitInsets(for: self), renderer.cellSize(for: self), bounds.size)
    }

    /// The insets the LAST FRAME's pointer mapping and chrome placement use,
    /// as distinct from the fit's: zero while DECSET 7402's colour letterbox
    /// holds, the padding otherwise. Nil before a renderer is attached.
    package var gridFrameInsetsForTesting: PlatformEdgeInsets? {
        guard let renderer else { return nil }
        return renderer.gridInsets(for: self)
    }

    /// The pixel extent Core tells a program the text area has, read under
    /// the model lock: the drawable under DECSET 7402, the grid otherwise.
    /// Nil before a session is attached.
    package var reportedTextAreaPixelsForTesting: (width: Int, height: Int)? {
        drive.withTerminal { terminal in
            let extent = Ubiquitty.reportedTextAreaPixels(terminal)
            return (Int(extent.width), Int(extent.height))
        }
    }

    /// The 1-based device pixel an SGR-pixel report would carry for a view
    /// point, before Core's clamp.
    ///
    /// - Parameter point: The point, in view coordinates.
    /// - Returns: The pixel, as the pointer fact would carry it.
    package func reportPixelForTesting(atViewPoint point: CGPoint) -> (x: Int, y: Int) {
        reportPixel(atViewPoint: point)
    }

    /// How many live frames skipped the damage drain and the grid copy under
    /// DECSET 7402's opaque letterbox. Nil for a renderer that draws no frames.
    package var gridCaptureSkipsForTesting: Int? {
        (renderer as? SurfaceRenderer)?.gridCaptureSkipCount
    }

    /// How many live frames re-read every row rather than the dirty ones —
    /// the first frame after the letterbox lifts is one. Nil for a renderer
    /// that draws no frames.
    package var gridFullRereadsForTesting: Int? {
        (renderer as? SurfaceRenderer)?.gridFullRereadCount
    }

    /// Where the last frame put the grid's top-left corner, in device pixels.
    ///
    /// Off the frame's own options rather than the style: DECSET 7402 moves
    /// the origin without touching the padding, and a scenario reading the
    /// style would see the padding the mode did not touch. Nil for a renderer
    /// that draws no frames.
    package var lastFrameOriginForTesting: (x: Float, y: Float)? {
        guard let renderer = renderer as? SurfaceRenderer else { return nil }
        return (renderer.lastFrameOriginXInPixels, renderer.lastFrameOriginYInPixels)
    }

    /// The cell the frame draws, in points: the natural one, or DECCOLM's
    /// compressed advance. Nil before a renderer is attached.
    package var lastCapturedViewOffsetForTesting: Int? {
        (renderer as? SurfaceRenderer)?.lastCapturedViewOffsetForTesting(for: self)
    }

    /// Where a column's letter stands on a row of the last frame, in cells
    /// from the grid's left edge (LetterLayout.h), for a scenario comparing
    /// what a press lands on with what the frame drew.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - column: The column.
    /// - Returns: The letter's left edge and advance in cells, and whether the
    ///   row was laid out as letters; nil before a frame was drawn.
    package func letterExtentForTesting(row: Int, column: Int) -> (left: Double, advance: Double, isLetterRow: Bool)? {
        (renderer as? SurfaceRenderer)?.letterExtentForTesting(for: self, row: row, column: column)
    }

    package var drawnCellSizeForTesting: CGSize? {
        guard let renderer else { return nil }
        return renderer.drawnCellSize(for: self)
    }

    /// Whether the model believes a password prompt is on screen, read under
    /// the model lock.
    ///
    /// The lock rather than the lock-free mode snapshot, which a direct feed
    /// leaves where the last drain published it: the badge and the echo mask
    /// are about a secret, and both must read the model as it is.
    package var isPasswordPromptOnScreen: Bool {
        drive.withTerminal { $0.passwordPromptActive } ?? false
    }

    #if canImport(AppKit)
    /// Shows the lock while the model says a password prompt is on screen,
    /// and tells the observer on each change so a host can hold Secure
    /// Keyboard Entry for the prompt.
    ///
    /// Package-visible for the snapshot arm, which feeds the model directly
    /// and has no event drain to call this for it.
    package func updatePasswordPromptBadge(publishedState: Bool? = nil) {
        let isActive = publishedState ?? isPasswordPromptOnScreen
        if isActive {
            // Every update, not only the transition: the glyph stands beside
            // the cursor, and the cursor moves under a masked echo.
            layoutPasswordBadge()
        }
        passwordBadge.setShown(isActive && (renderer as? SurfaceRenderer)?.isBitmapTier != true)
        guard isActive != isPasswordPromptShown else { return }
        isPasswordPromptShown = isActive
        if isActive {
            passwordBadge.apply(foreground: chromeForegroundColor())
        }
        PasswordPromptRegistry.shared.note(self, isActive: isActive)
        observer?.terminalSurface(self, didChangePasswordPrompt: isActive)
    }
    #endif

    #if canImport(AppKit)
    /// Places the glyph in the cell after the cursor — before it when the
    /// cursor stands in the last column — through Core's `cellRect`, the same
    /// inverse the pointer and the candidate window use.
    ///
    /// Scrolled back past the cursor's row, the glyph has no cell to stand in
    /// and takes an empty frame until the view returns.
    private func layoutPasswordBadge() {
        guard let renderer else { return }
        let cell = renderer.drawnCellSize(for: self)
        guard cell.width > 0, cell.height > 0 else { return }
        let grid: (column: Int, row: Int, columns: Int, rows: Int) =
            drive.withTerminal { terminal in
                guard let screen = terminal.screens.active else { return (0, 0, 0, 0) }
                return (
                    column: Int(max(0, screen.pointee.cursorX)),
                    row: Int(max(0, screen.pointee.cursorY)),
                    columns: Int(terminal.columns),
                    rows: Int(terminal.rows)
                )
            } ?? (0, 0, 0, 0)
        var column = grid.column + 1
        if column >= grid.columns {
            column = max(grid.column - 1, 0)
        }
        // A view scrolled back by `viewOffset` rows shows the cursor's row
        // that many rows lower, if it shows it at all.
        let row = grid.row + viewOffset
        guard grid.rows > 0, row < grid.rows else {
            passwordBadge.frame = .zero
            return
        }
        let insets = renderer.gridInsets(for: self)
        let box = Ubiquitty.Rendering.cellRect(
            Ubiquitty.CellPosition(row: Int32(row), column: Int32(column)),
            Ubiquitty.FloatSize(width: Float(cell.width), height: Float(cell.height)),
            Ubiquitty.Rendering.EdgeInsets(
                left: Float(insets.left),
                right: Float(insets.right),
                top: Float(insets.top),
                bottom: Float(insets.bottom)
            ),
            0
        )
        passwordBadge.place(
            in: CGRect(
                x: Double(box.origin.x),
                y: Double(box.origin.y) + verticalOverscroll,
                width: Double(box.size.width),
                height: Double(box.size.height)
            )
        )
    }
    #endif

    /// Drains the session's queued events on the main thread.
    ///
    /// The drain signal's target: one call per eventful ingest pass, reading
    /// whatever accumulated since the last.
    package func serviceIngestEvents() {
        guard SurfaceRenderer.framePerfLog.isActive() else {
            deliver(RuntimeEvents(rawValue: drive.takeEventBits()))
            return
        }
        notePerfDrains()
        let handlerStartedAt = CACurrentMediaTime()
        let events = RuntimeEvents(rawValue: drive.takeEventBits())
        deliver(events)
        SurfaceRenderer.framePerfLog.noteDrainHandler(CACurrentMediaTime() - handlerStartedAt, lastPerfDrainBytes)
    }

    /// Hands the perf log what the ingest loop delivered since the last hop.
    ///
    /// The session tallies on the loop's thread from the first ask on; the
    /// deliveries before it are not the log's.
    private func notePerfDrains() {
        if !isTallyingPerfDrains {
            isTallyingPerfDrains = true
            drive.startTallyingPerfDrains()
        }
        let tally = drive.takePerfDrainTally()
        lastPerfDrainBytes = tally.bytes
        guard tally.deliveries > 0 else { return }
        let snapshot = drive.readSnapshot()
        var sample = Ubiquitty.Diagnostics.PerfDrainSample()
        sample.bytes = tally.bytes
        sample.deliveries = tally.deliveries
        sample.ingestSeconds = Double(tally.ingestMicroseconds) / 1_000_000
        sample.longestIngestSeconds = Double(tally.longestIngestMicroseconds) / 1_000_000
        sample.columns = Int32(snapshot.columns)
        sample.rows = Int32(snapshot.rows)
        SurfaceRenderer.framePerfLog.noteDrain(sample, CACurrentMediaTime())
    }

    /// Turns one poll of the session into observer calls.
    ///
    /// Called by whatever drives the frame clock. Split from the poll so a host
    /// that already pumps ``RuntimeDrive`` does not pump it twice: the events
    /// are consumed by the caller and handed here, rather than read again.
    ///
    /// - Parameter events: The flags this poll produced.
    package func deliver(_ incomingEvents: RuntimeEvents) {
        var events = incomingEvents
        if frameDelivery == .Withhold || !isMetadataPresented {
            var presentationEvents: RuntimeEvents = []
            if frameDelivery == .Withhold {
                presentationEvents.insert(.screenDirty)
            }
            if !isMetadataPresented {
                presentationEvents.formUnion([.titleChanged, RuntimeEvents(.directoryChanged), RuntimeEvents(.processStateChanged)])
            }
            deferredPresentationEvents.formUnion(events.intersection(presentationEvents))
            if frameDelivery == .Withhold && events.contains(.screenDirty) {
                needsDisplay = true
                // Selection anchors follow every output mutation, even when chrome is withheld.
                followTailOrHoldViewport()
                let snapshot = drive.readSnapshot()
                if snapshot.syncHoldActive {
                    scheduleSyncOutputRecheck()
                }
                if snapshot.paletteEpoch != reportedPaletteEpoch {
                    reportedPaletteEpoch = snapshot.paletteEpoch
                    observer?.terminalSurfaceDidChangeWithheldPalette(self)
                }
            }
            events.subtract(presentationEvents)
        }
        if events.contains(.titleChanged), let updated = drive.currentTitle(), updated != title {
            title = updated
            observer?.terminalSurface(self, didChangeTitle: updated)
        }
        if events.contains(.directoryChanged), let updated = drive.currentDirectory(), updated != currentDirectory {
            currentDirectory = updated
            observer?.terminalSurface(self, didChangeCurrentDirectory: updated)
        }
        if events.contains(.processStateChanged) {
            observer?.terminalSurfaceDidChangeProcessState(self)
        }
        if events.contains(.screenDirty) {
            traceFrame("ingest")
            needsDisplay = true
            // Core owns the decision. Adaptive keys continuous-vs-on-demand on the
            // screen-change rate (Core stamps the change in finishDrainPass); off,
            // the clock resumes on the idle→active edge.
            #if canImport(AppKit)
            let isDragResizing = inLiveResize
            #else
            let isDragResizing = false
            #endif
            // A live resize stays link-driven: a non-2026 app clears then
            // redraws across drains, and a present per delivery shows every
            // cleared intermediate.
            // The link is the frame's driver, and a withheld pane has no frame
            // to drive: the mark above is recorded and held, and the reveal is
            // what asks for it. Resuming here would hand the toolkit route back
            // (the rate resolves to zero for a covered pane) and every delivery
            // would draw one.
            if frameDelivery == .Draw {
                if drive.isAdaptivePresentation, !isDragResizing {
                    if drive.isPresentationRecommendedContinuous {
                        if !drive.isPresentationContinuous {
                            frameClock.resume()
                        }
                    } else if drive.isPresentationContinuous {
                        frameClock.pauseToOnDemand()
                    }
                } else if !drive.isPresentationContinuous {
                    frameClock.resume()
                }
            }
            // A block opened by bytes that then stop is expired only by an
            // ask. The draw this mark provokes is one; on a surface with no
            // display to draw to it never runs, so the timer books itself
            // here, on arrival, and does the asking on its own.
            //
            // Read off the published snapshot, which the writer fills for this:
            // asking the model costs a blocking acquisition of the lock the
            // parser is holding, once per eventful drain, to learn a bit the
            // writer already published.
            if drive.readSnapshot().syncHoldActive {
                scheduleSyncOutputRecheck()
            }
            // The tail may have grown under a scrolled-back view: hold the
            // viewed rows or snap home, per the scroll-on-output policy.
            followTailOrHoldViewport()
            #if canImport(AppKit)
            // The grid moved under whatever the pointer was over. Nothing
            // else reports that: a scroll is not a mouse move, so the hand
            // would stay on a link that has scrolled away and be absent from
            // the one that took its place.
            updateLinkAffordanceAtLivePointer()
            #endif
            noteAccessibilityContentChanged()
            let published = drive.readSnapshot()
            let publishedModes = published.modes
            // The colours the observer reads below; a hidden pane's later
            // change is measured from these.
            reportedPaletteEpoch = published.paletteEpoch
            #if canImport(AppKit)
            updatePasswordPromptBadge(publishedState: publishedModes.isPasswordPromptActive)
            #endif
            updateDisplayBlank(isBlanked: publishedModes.isScreenBlanked)
            refreshHint()
            observer?.terminalSurfaceDidUpdateScreen(self)
            traceFrame("ingest-scheduled")
        }
        if events.contains(.progressChanged) {
            observer?.terminalSurfaceDidChangeProgress(self)
        }
        if events.contains(.searchChanged) {
            applySearchOutcome(drive.searchStatus)
            observer?.terminalSurfaceDidChangeSearch(self)
        }
        if events.contains(.tabStatusChanged) {
            observer?.terminalSurfaceDidChangeTabStatus(self)
        }
        if events.contains(.bell) {
            let cue = drive.lastBellCue
            // The visual half is this surface's own: the flash is drawn into
            // its frames, and a host asked to start it would be reaching
            // through the surface to the renderer behind it.
            if cue.mode == .Visual || cue.mode == .Both {
                startBellFlash()
            }
            observer?.terminalSurface(self, didRingBell: BellReaction(cue))
        }
        if events.contains(.exited) {
            observer?.terminalSurfaceDidExit(self)
        }
        if events.contains(.deployConfirmationPending) {
            observer?.terminalSurfaceRequestsDeployConfirmation(self)
        }
        if events.contains(.deployFailed) {
            observer?.terminalSurfaceDidFailHostDeploy(self)
        }
        if events.contains(.deployNeedsManualInstall) {
            observer?.terminalSurfaceNeedsManualHostInstall(self)
        }
        if events.contains(.remoteFileArrived) {
            observer?.terminalSurfaceDidReceiveHostFile(self)
        }
        if events.contains(.fileTransferDetected) {
            observer?.terminalSurfaceDidDetectFileTransfer(self)
        }
        if events.contains(.pastePushSettled) {
            observer?.terminalSurface(self, didSettlePastePushWithStatus: drive.lastPastePushStatus)
        }
        if events.contains(.hostSessionListChanged) {
            observer?.terminalSurfaceDidUpdateHostSessions(self)
        }
        if events.contains(.hostStructureSettled) {
            observer?.terminalSurfaceDidSettleHostStructure(self)
        }
        if events.contains(.hostSessionTerminateSettled) {
            observer?
                .terminalSurface(
                    self,
                    didSettleHostSessionTerminate: drive.lastHostSessionTerminateSessionID,
                    outcome: drive.lastHostSessionTerminateOutcome.flatMap { HostSessionTerminateOutcome(rawValue: $0.rawValue) }
                )
        }
        // Re-read the retained session and link state together: establishment supplies the
        // pairing id, failure supplies the refusal reason, and a link edge updates its indicator.
        if events.contains(.remoteSessionEstablished) || events.contains(.remoteStateChanged) || events.contains(.linkStateChanged) {
            #if canImport(AppKit)
            dismissStaleFileDownloadPrompt()
            #endif
            observer?.terminalSurfaceDidChangeRemoteSession(self)
        }
        if events.contains(.workspaceChanged) {
            observer?.terminalSurfaceDidChangeRemoteWorkspace(self)
        }
        if events.contains(.inputInDoubtChanged) {
            observer?.terminalSurfaceDidChangeInputInDoubt(self)
        }
        if events.contains(.presenceChanged) {
            observer?.terminalSurfaceDidChangePresence(self)
        }
        if events.contains(.consentRequestPending) {
            #if canImport(AppKit)
            askForConsent()
            #else
            observer?.terminalSurfaceDidRequestConsent(self)
            #endif
        }
        // Anything delivered could have started a blink or an animation; the
        // clock re-arms cheaply and a non-animating fire stops itself.
        frameClock.noteAnimationActivity()
        // A drain can set or clear 7403; the reconcile is idempotent and
        // cheap against the published bit.
        updatePointerLock()
        // A drain can arm DECELR under a pointer that has not moved; the
        // locator is told where it stands on that edge and nowhere else.
        reconcileLocatorArm()
        #if canImport(AppKit)
        // A drain can set, push or pop an OSC 22 shape, or flip a mouse mode
        // the pointer ladder ranks; the reconcile is idempotent and cheap
        // against the published fields.
        if frameDelivery == .Draw {
            updatePointerCursorFromSnapshot()
        }
        #endif
        // Notification is only a reason to inspect Core's queue. The leased
        // receipt owns replay protection; observing a generation does not mean
        // that this surface has applied that request.
        if events.contains(.fontSwapRequested) {
            observer?.terminalSurfaceDidRequestFontSwap(self)
        }
        // No generation to compare, because the queue is the state: a host
        // delivering one poll's events twice finds it empty the second time.
        if events.contains(.windowRequestPending) {
            observer?.terminalSurfaceDidRequestWindowOperation(self)
        }
        #if canImport(AppKit)
        if events.contains(.dragDropPending) { dragDrop.drain() }
        #endif
        // The queue is the state here too: a banner is read off it, not off a
        // field, so a host delivering one poll's events twice finds it empty
        // the second time and posts nothing a second time.
        if events.contains(.notificationPosted) {
            observer?.terminalSurfaceDidPostNotification(self)
        }
        // And for the trigger acts: the queue is the state, so a host
        // delivering one poll's events twice performs nothing a second time.
        if events.contains(.triggerMatched) {
            observer?.terminalSurfaceDidMatchTrigger(self)
        }
        // The queue is the state here too: a host delivering one poll's events
        // twice finds it empty the second time.
        if events.contains(.hostedWindowsChanged) {
            observer?.terminalSurfaceDidChangeHostedWindows(self)
        }
    }

    private func rebuildChrome() {
        headerView?.removeFromSuperview()
        accessories.forEach { $0.removeFromSuperview() }
        headerView = chrome?.titleView(for: self)
        accessories = chrome?.accessoryViews(for: self) ?? []
        headerView.map { addSubview($0) }
        accessories.forEach { addSubview($0) }
        needsLayout = true
    }
}

// MARK: - FrameClockDelegate

/// The surface's clock delegate, a separate object because the surface is
/// public and the clock's protocol is package-scoped — conforming the surface
/// itself would force every UbiquittyKit consumer to import RenderKit.
///
/// The clock calls every delegate method on the main thread, and the
/// `@preconcurrency` conformance is what checks it at each thunk: the
/// witnesses reach the surface's main-actor state, while the protocol's
/// `@objc` requirements carry no isolation of their own.
@MainActor
private final class SurfaceClockBridge: NSObject, @preconcurrency FrameClockDelegate {
    unowned let surface: TerminalSurface

    init(surface: TerminalSurface) {
        self.surface = surface
    }
    func frameClockHasLiveTerm(_ clock: FrameClock) -> Bool {
        surface.drive.borrowTerminal() != nil
    }

    func frameClockServiceIngestBelt(_ clock: FrameClock) {
        // The surface's events are pushed through deliver(_:) by its pump;
        // there is no coalesced-signal belt to re-service.
    }

    func frameClockMonotonicTicks(_ clock: FrameClock) -> UInt32 {
        TerminalSurface.monotonicTicksNow()
    }

    func frameClock(_ clock: FrameClock, checkHiliteDeadlineAt nowTicks: UInt32) {
        // The session gates on the published await bit and a try-lock, so
        // the common fire pays a lock-free read; an abort republished the
        // snapshot itself, leaving only the repaint here.
        if surface.drive.tickHiliteDeadline(nowTicks) {
            surface.needsDisplay = true
        }
    }

    func frameClock(_ clock: FrameClock, updateRepaintIfCrossedAt nowTicks: UInt32) {
        // The surface redraws from the live model on every fire while
        // animating: the per-crossing filter the Metal arm applies reads
        // Core state that has no Swift spelling yet. The one-shot the last
        // frame armed is due at the same crossing, so while it is pending the
        // crossing already has its repaint, and asking again here is a second
        // pass per blink edge — a capture and a build that present nothing.
        guard !surface.isAnimationRepaintPending else { return }
        surface.needsDisplay = true
    }

    func frameClockAdvanceImagesIfDue(_ clock: FrameClock) {
        // The session owns the elapsed clock and the advance; the renderer
        // keys its per-image texture cache on a content stamp that folds in
        // the frame index, so the repaint re-uploads.
        if surface.drive.advanceAnimatedImagesNow() {
            surface.needsDisplay = true
        }
    }

    func frameClockResetImageClock(_ clock: FrameClock) {
        surface.drive.resetImageAdvanceClock()
    }

    func frameClockHasAnimatingContent(_ clock: FrameClock) -> Bool {
        // Gathered here, decided in Core. The cursor half is why: a clock that
        // asks only whether the cursor is visible and blink is enabled stays
        // armed for a STEADY cursor and for one in an unfocused pane, spending
        // a frame per tick on a cursor that never changes.
        surface.animationDemand().isAnythingAnimating()
    }

    func frameClock(_ clock: FrameClock, nextAnimationDelayAt nowTicks: UInt32) -> Double {
        // One demand feeds the whole schedule, the same atomicity rule the
        // Metal arm's view keeps, and the same rule that decides whether the
        // clock runs at all — a cadence chosen by a different rule than the
        // arming is a clock that either spins on nothing or sleeps through
        // something.
        //
        // The smooth cadence is for what changes every frame: an animating
        // image, and a bell flash when this arm grows one. A blinking cursor
        // and blinking cells are not that — they change about twice a second,
        // and asking for a frame sixty times a second to move an alpha twice
        // is the whole cost of an idle terminal. Core already resolves when
        // each next changes, under the model lock, and the schedule combines
        // that answer with the smooth terms. Combined there rather than here:
        // a blink alone may sleep past the half-second ceiling to its exact
        // crossing, and a `min` against the idle answer re-imposed the ceiling
        // and woke the pane to an unchanged caret once per cycle.
        let demand = surface.animationDemand()
        var inputs = Ubiquitty.Rendering.AnimationScheduleInputs()
        inputs.smoothAnimationActive =
            demand.isImageAnimating || demand.bellFlashAlpha > 0
            || demand.isFocusedMatchBouncing || demand.isCursorSliding
        inputs.hiliteAwaiting = demand.isHiliteAwaiting
        let blinkVerdict = surface.drive.nextAnimationDelay()
        if blinkVerdict.hasAnimatingContent {
            inputs.resolvedBlinkDelaySeconds = blinkVerdict.delaySeconds
        }
        return inputs.nextDelaySeconds()
    }

    func frameClockHasWindow(_ clock: FrameClock) -> Bool {
        surface.window != nil
    }

    func frameClockNotePerfResume(_ clock: FrameClock) {
        // The idle-to-active edge: the next frame's gap spans a pause the
        // clock asked for, which the perf log keeps out of its drops.
        guard SurfaceRenderer.framePerfLog.isActive() else { return }
        SurfaceRenderer.framePerfLog.noteResume(CACurrentMediaTime())
    }

    func frameClockMaxScreenFramesPerSecond(_ clock: FrameClock) -> Int32 {
        #if canImport(AppKit)
        let rate = surface.window?.screen?.maximumFramesPerSecond ?? 60
        #else
        let rate = surface.window?.screen.maximumFramesPerSecond ?? 60
        #endif
        return Int32(rate > 0 ? rate : 60)
    }

    func frameClockIsPresented(_ clock: FrameClock) -> Bool {
        // A window the reader cannot see paying the panel rate to animate a
        // cursor is the whole cost of a backgrounded terminal. Which facts add
        // up to that is `Runtime::paneFullRatePresentation`, over the same
        // struct the publish reports — the two differ only in that this one
        // counts full occlusion, and Core says so rather than each shell
        // deciding. On UIKit the struct carries neither occlusion nor tabs,
        // so being in a window is the whole of what the phone can answer.
        !surface.isFrameLinkHeldOffForTesting
            && Ubiquitty.Runtime.paneFullRatePresentation(surface.paneVisibility) == .Presented
    }

    func frameClockIsPaused(_ clock: FrameClock) -> Bool {
        #if canImport(AppKit)
        return !(surface.frameLink?.isRunning ?? false)
        #else
        // The phone drives one frame per mark rather than a run of them,
        // so there is no continuous state to be paused out of.
        return true
        #endif
    }

    func frameClock(_ clock: FrameClock, setPreferredFramesPerSecond fps: Int32) {
        // The rate the slip accounting differences presents against: every
        // rate edge funnels through the clock's resume, so this is the one
        // place the period moves.
        if fps > 0 {
            (surface.renderer as? SurfaceRenderer)?.presentSlip.noteRefreshSeconds(1.0 / Double(fps))
        }
        #if canImport(AppKit)
        surface.requestedFramesPerSecond = Int(fps)
        // A rate arriving while the link runs re-rates it; the resume
        // that follows a pause starts it at whatever was last asked for.
        if surface.frameLink?.isRunning == true {
            surface.frameLink?.start(framesPerSecond: Int(fps))
        }
        #endif
    }

    func frameClock(_ clock: FrameClock, setSyncPublishRefreshSeconds seconds: Double) {
        surface.drive.setSyncPublishRefreshSeconds(seconds)
    }

    func frameClock(_ clock: FrameClock, setDriverFrameIntervalSeconds seconds: Double) {
        surface.drive.setPresentationFrameIntervalSeconds(seconds)
    }

    func frameClockApplyVSyncToLayer(_ clock: FrameClock) {
        // [render] vsync: off presents a drawable as soon as it is ready —
        // lower latency, possible tearing. Re-asserted from the clock rather
        // than set once, because the layer is rebuilt on a screen or backing
        // change and comes back with the default.
        #if canImport(AppKit)
        surface.metalLayer.displaySyncEnabled = surface.isPresentSynchronized
        #else
        // iOS presents through the display link unconditionally: there is no
        // tear-for-latency trade to offer, so [render] vsync has nothing to
        // apply here rather than being ignored.
        #endif
    }

    func frameClock(_ clock: FrameClock, setEnableSetNeedsDisplay enable: Bool) {
        // A link presenting at the resolved rate is already asking for every
        // frame that rate allows, so a repaint request must not schedule a
        // toolkit pass beside it. The request itself still lands: the surface
        // records it as owed, and the link's next tick consumes it.
        #if canImport(AppKit)
        surface.isToolkitDisplayRouteEnabled = enable
        if enable {
            // Re-armed with a pass owed, so a frame marked while the link drove
            // is not left for an edge that may not come.
            surface.needsDisplay = true
        }
        #endif
    }

    func frameClock(_ clock: FrameClock, setPaused paused: Bool) {
        #if canImport(AppKit)
        if paused {
            surface.frameLink?.stop()
            return
        }
        surface.ensureFrameLink().start(framesPerSecond: surface.requestedFramesPerSecond)
        #endif
    }

    func frameClockSetNeedsDisplayNow(_ clock: FrameClock) {
        surface.needsDisplay = true
    }

    func frameClockCommitTekFrameIfIdle(_ clock: FrameClock) {
        // On ingest-idle commit the in-progress frame, so a stopped
        // animation shows its last strokes — PAGE commits the rest. Gated
        // on the published bit so a non-Tek session pays a lock-free read.
        guard surface.drive.readSnapshot().isTekModeActive else {
            return
        }
        surface.drive.withTerminal { Ubiquitty.tekCommitFrame($0) }
        surface.needsDisplay = true
    }

    func frameClock(_ clock: FrameClock, setDriverContinuous continuous: Bool) {
        // The policy is the session's `Runtime::FrameDriver`; what is
        // published here is what this surface is actually doing, which is
        // what the next edge test reads.
        surface.drive.setPresentationMode(continuous ? .continuous : .onDemand)
    }

    func frameClockDriverIdleExpired(_ clock: FrameClock) -> Bool {
        surface.drive.isPresentationIdleExpired
    }
}

/// The handoff between the render thread, which owns the atlas, and the
/// reader thread, which measures proportional text on it under the model lock
/// (Docs/proportional-text.md).
///
/// A lock rather than a hop to the main queue: the reader holds the model lock
/// while it measures, and the main thread takes that lock to draw, so waiting
/// on it from under the lock would deadlock. The atlas's measurement itself
/// touches only faces the sheet never swaps, so the lock guards the handle
/// alone.
package final class ProportionalMeasureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var atlas: GlyphAtlas?
    private var richTextShaper: RichTextShaper?
    // A replacement surface can publish on the same attachment. A fresh
    // starting identity prevents its first renderer matching the retired one.
    private var richTextRevision = UInt64.random(in: 1...UInt64.max)

    package func invalidateRichText() {
        lock.lock()
        richTextShaper = nil
        lock.unlock()
    }

    package func adoptRichText(_ shaper: RichTextShaper) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        richTextShaper = shaper
        richTextRevision &+= 1
        if richTextRevision == 0 { richTextRevision = 1 }
        return richTextRevision
    }

    /// Gives Core a new renderer identity when the shared face inventory lands.
    package func refreshRichTextRevision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard richTextShaper != nil else { return 0 }
        richTextRevision &+= 1
        if richTextRevision == 0 { richTextRevision = 1 }
        return richTextRevision
    }

    package func shapeRichText(
        _ document: Ubiquitty.RichText.Document,
        request: Ubiquitty.RichText.ShapeRequest,
        facts: Ubiquitty.RichText.TypographyFacts,
        into result: inout Ubiquitty.RichText.ShapedText
    ) -> Bool {
        lock.lock()
        let current = facts.rendererRevision == richTextRevision ? richTextShaper : nil
        lock.unlock()
        return current?.shape(document, request: request, facts: facts, into: &result) ?? false
    }

    package func queryFonts(
        _ query: Ubiquitty.RichText.FontCatalogQuery,
        facts: Ubiquitty.RichText.TypographyFacts,
        into result: inout Ubiquitty.RichText.FontCatalogPage
    ) -> Bool {
        lock.lock()
        let current = facts.rendererRevision == richTextRevision && query.rendererRevision == richTextRevision ? richTextShaper : nil
        lock.unlock()
        guard let current else {
            result.status = .Stale
            return true
        }
        return current.queryFonts(query, into: &result)
    }

    /// Makes an atlas the one measurements shape with.
    ///
    /// - Parameter atlas: The atlas of the surface's current frame renderer.
    package func adopt(_ atlas: GlyphAtlas) {
        lock.lock()
        defer { lock.unlock() }
        self.atlas = atlas
    }

    /// The cells a run needs, or zero before any atlas was adopted — Core then
    /// answers with the grid-face width.
    ///
    /// - Parameter codePoints: The run's text.
    /// - Returns: The cell count.
    package func cells(_ codePoints: UnsafeBufferPointer<UInt32>) -> Int {
        lock.lock()
        let current = atlas
        lock.unlock()
        return current?.proportionalRunCells(codePoints) ?? 0
    }

    /// The shaped glyphs of a run, or none before any atlas was adopted.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The face the run is set in.
    ///   - weight: The run's SGR 1:n variable weight, 0 for the face's own.
    /// - Returns: The shaper's answer for Core to lay out.
    package func shape(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph] {
        lock.lock()
        let current = atlas
        lock.unlock()
        return current?.shapeProportionalRun(codePoints, measuringIn: face, weight: weight) ?? []
    }

    /// One cell's advance in the adopted atlas's pixels, or zero.
    package var cellAdvanceInPixels: Float {
        lock.lock()
        let current = atlas
        lock.unlock()
        return current?.proportionalCellAdvanceInPixels ?? 0
    }
}

/// One readout of a pane's adaptive drive, for the debug window.
///
/// A class rather than a struct so Objective-C can build one; every field is
/// a fact the driver or the view already holds.
///
/// Declared in this module rather than beside the frame clock it describes: it
/// is named by a public declaration here, and a public declaration naming a
/// type from the render framework puts an import of that framework into this
/// one's interface — which an outside consumer compiling against this framework
/// alone would then have to resolve, across a module built on C++ interop. The
/// clock publishes the numbers; this is the shape they are read in.
@objc(UBAdaptiveDriveFacts)
public final class AdaptiveDriveFacts: NSObject {
    @objc
    public let arm: String
    @objc
    public let surfaceIdentity: Int
    @objc
    public let isAdaptive: Bool
    @objc
    public let isLinkContinuous: Bool
    @objc
    public let isRecommendedContinuous: Bool
    @objc
    public let fastDrainStreak: Int
    @objc
    public let frameIntervalSeconds: Double
    @objc
    public let framesDrawn: Int
    public let framesPresented: Int

    /// Creates a readout.
    ///
    /// - Parameters:
    ///   - arm: Which renderer drew the pane.
    ///   - surfaceIdentity: The pane identity used to restart rate sampling when focus moves.
    ///   - isAdaptive: Whether the adaptive drive is on.
    ///   - isLinkContinuous: Whether the display link is running continuously.
    ///   - isRecommendedContinuous: Whether the drive asks for continuous.
    ///   - fastDrainStreak: Consecutive drains that closed fast.
    ///   - frameIntervalSeconds: The interval the clock is pacing at.
    ///   - framesDrawn: Frames this pane has drawn.
    ///   - framesPresented: Frames committed for presentation.
    @objc
    public init(
        arm: String,
        surfaceIdentity: Int,
        isAdaptive: Bool,
        isLinkContinuous: Bool,
        isRecommendedContinuous: Bool,
        fastDrainStreak: Int,
        frameIntervalSeconds: Double,
        framesDrawn: Int,
        framesPresented: Int
    ) {
        self.arm = arm
        self.surfaceIdentity = surfaceIdentity
        self.isAdaptive = isAdaptive
        self.isLinkContinuous = isLinkContinuous
        self.isRecommendedContinuous = isRecommendedContinuous
        self.fastDrainStreak = fastDrainStreak
        self.frameIntervalSeconds = frameIntervalSeconds
        self.framesDrawn = framesDrawn
        self.framesPresented = framesPresented
    }
}
