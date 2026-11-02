// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+SessionCapture.swift — what the application asks of
// a Swift-shell window when it saves the session, checks a menu item against
// the window in front, or points the shared inspector at it.
//
// Facts only. Which of them decide what a tab stores is Core's
// (`Session::planCapturedTab`); the application reads these from whichever
// shell drew the window and hands them to that one rule.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit
internal import UbiquittySessionHandoff

/// Stores presentation separately from the daemon reference that owns a live session.
package struct SavedTerminalPresentation: Codable {
    package static let prefix = "ubiquitty-arrangement:"

    package struct LiveWorkspace: Codable {
        package var daemonInstanceID: UInt64
        package var workspaceID: UInt32
        package var sessionID: UInt32
        package var bridgeCommand: String
        package var hostLabel: String
        package var socketName: String
    }

    /// Keeps the tmux server identity distinct from the ability to reach its socket.
    package struct TmuxWindow: Codable, Equatable {
        package var serverProcessID: UInt64 = 0
        package var serverStartTime: UInt64 = 0
        package var sessionID: UInt64 = 0
        package var sessionCreated: UInt64 = 0
        package var socketPath: String = ""
        package var canReconnectLocally = false
        package var sshHost: String = ""
        package var windowID: Int32 = -1
        package var focusedPaneID: Int32 = -1

        package var coreReference: Ubiquitty.`Protocol`.Tmux.SessionReference {
            var reference: Ubiquitty.`Protocol`.Tmux.SessionReference = .init()
            reference.serverProcessID = serverProcessID
            reference.serverStartTime = serverStartTime
            reference.sessionID = sessionID
            reference.sessionCreated = sessionCreated
            reference.socketPath = std.string(socketPath)
            return reference
        }

        /// Matches a server, session, and window independently of client focus.
        ///
        /// - Parameter other: The other captured window.
        /// - Returns: Whether both references identify the same window on one authority.
        package func identifiesSameWindow(as other: Self) -> Bool {
            identifiesSameSession(as: other) && windowID == other.windowID
        }

        /// Matches the server lifetime and session independently of its rendered window.
        ///
        /// - Parameter other: The other captured window.
        /// - Returns: Whether both references identify the same session on one authority.
        package func identifiesSameSession(as other: Self) -> Bool {
            ((canReconnectLocally && other.canReconnectLocally) || (!sshHost.isEmpty && sshHost == other.sshHost))
                && sshHost == other.sshHost && serverProcessID != 0
                && serverProcessID == other.serverProcessID && serverStartTime == other.serverStartTime
                && sessionID == other.sessionID && sessionCreated == other.sessionCreated
                && socketPath == other.socketPath
        }
    }

    /// A split a quit handed to the local daemon whole, which its restore
    /// regroups there: until then the daemon holds each pane in a workspace
    /// of its own.
    package struct HandedOverSplit: Codable, Equatable {
        /// The split, as `Session::serializeWorkspaceText` writes it.
        package var arrangement: String
        /// Each pane's adopted session, in the arrangement's leaf order.
        package var sessions: [UInt32]
    }

    package var liveWorkspace: LiveWorkspace? = nil
    package var tmuxWindow: TmuxWindow? = nil
    package var localArrangement: String?
    /// Present only beside `liveWorkspace`, whose session is the first leaf's.
    package var handedOverSplit: HandedOverSplit? = nil
    package var profileName: String
    package var tabTitle: String
    package var windowTitle: String

    /// Encodes the presentation for the session store's opaque layout field.
    package func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.prefix + text
    }

    /// Decodes a presentation from the session store.
    package static func decoded(_ text: String) -> Self? {
        guard text.hasPrefix(prefix), let data = String(text.dropFirst(prefix.count)).data(using: .utf8) else { return nil }
        guard let presentation = try? JSONDecoder().decode(Self.self, from: data),
            [presentation.liveWorkspace != nil, presentation.tmuxWindow != nil, presentation.localArrangement != nil].filter({ $0 }).count
                <= 1,
            presentation.handedOverSplit.map({ split in
                presentation.liveWorkspace?.sessionID == split.sessions.first && split.sessions.count >= 2
                    && Set(split.sessions).count == split.sessions.count && !split.sessions.contains(0)
            }) ?? true
        else { return nil }
        return presentation
    }
}

/// Reports whether a restored window can replace another window safely.
package enum ArrangementReadiness {
    case ready
    case waiting
    case unavailable
}

extension TerminalWindowController {
    /// Captures every hosted window, including one whose carrier cannot be reconstructed.
    package var savedTmuxWindow: SavedTerminalPresentation.TmuxWindow? {
        guard isRenderOnly else { return nil }
        var saved = SavedTerminalPresentation.TmuxWindow()
        saved.windowID = hostedWindowID
        saved.focusedPaneID = tmuxSurfaces.first(where: { $0.value === tmuxIntentSurface })?.key ?? -1
        if let reference = hostingSurface?.drive.hostedSessionReference, reference.isConfirmed {
            saved.serverProcessID = reference.tmux.serverProcessID
            saved.serverStartTime = reference.tmux.serverStartTime
            saved.sessionID = reference.tmux.sessionID
            saved.sessionCreated = reference.tmux.sessionCreated
            saved.socketPath = String(reference.tmux.socketPath)
            saved.canReconnectLocally = reference.canReconnectLocally
            saved.sshHost = String(reference.sshHost)
        }
        return saved
    }

    /// Keeps the control client alive while one of its restored windows remains in use.
    package var arrangementSupportingWindow: NSWindow? { hostingSurface?.window }

    /// Restores client focus without sending a command to another tmux client.
    ///
    /// - Parameter paneID: The saved pane to focus, if it still exists.
    package func focusRestoredHostedPane(_ paneID: Int32) {
        guard let surface = tmuxSurfaces[paneID] else { return }
        lastFocusedTmuxSurface = surface
        window?.makeFirstResponder(surface)
    }

    package var arrangementReadiness: ArrangementReadiness {
        guard !isWindowClosed else { return .unavailable }
        if isRenderOnly { return tmuxSurfaces.isEmpty ? .waiting : .ready }
        guard let surface = remoteSurface else { return .ready }
        switch surface.drive.remoteState {
        case .Connected: return .ready
        case .Idle, .Failed: return .unavailable
        case .Connecting, .Reconnecting, .Deploying: return .waiting
        @unknown default: return .unavailable
        }
    }

    /// Captures device-local titles and the profile identity beside the portable layout.
    ///
    /// A split the local daemon holds whole, from a quit that handed it over
    /// rather than from Share This Window, also carries its arrangement and
    /// every pane's session, which the restore regroups on the daemon. A
    /// split it holds only in part has no live workspace to rejoin, and
    /// stores the local arrangement its panes restore fresh from.
    package func savedPresentation(
        needsLocalArrangement: Bool,
        liveReference: Ubiquitty.Session.RestoredTab? = nil
    ) -> SavedTerminalPresentation {
        let drive = (remoteSurface ?? activeSurface)?.drive
        let attachment = remoteAttachment
        let isHeldByLocalDaemon = Self.windowModel?.isSurfaceHeldByLocalDaemon(workspaceSurface) == true
        let hasLiveWorkspace = attachment != nil || isHeldByLocalDaemon || (liveReference?.sessionID ?? 0) != 0
        let hosted = savedTmuxWindow
        let archive =
            needsLocalArrangement && !hasLiveWorkspace && hosted == nil
            ? Self.windowModel.map { String($0.captureWindowArrangement(workspaceSurface)) } : nil
        let sessionID = liveReference?.sessionID ?? attachment?.sessionID ?? 0
        let split = windowSharing == nil && isHeldByLocalDaemon ? handedOverSplit(firstSession: sessionID) : nil
        // A handed-over split's panes are each in a workspace of their own
        // until the restore regroups them, so its reference names the first
        // pane's session and no workspace: the focused pane's would name
        // another pane's.
        let liveWorkspace: SavedTerminalPresentation.LiveWorkspace? =
            windowSharing?.liveWorkspace
            ?? (hasLiveWorkspace
                ? .init(
                    daemonInstanceID: drive?.remoteDaemonInstanceID ?? 0,
                    workspaceID: split == nil ? drive?.remoteWorkspaceID ?? 0 : 0,
                    sessionID: sessionID,
                    bridgeCommand: liveReference.map { String($0.bridgeCommand) } ?? attachment?.bridgeCommand ?? "",
                    hostLabel: liveReference.map { String($0.hostLabel) } ?? attachment?.hostLabel ?? "",
                    socketName: liveReference.map { String($0.socketName) } ?? attachment?.socketName ?? ""
                ) : nil)
        return SavedTerminalPresentation(
            liveWorkspace: liveWorkspace,
            tmuxWindow: hosted,
            localArrangement: archive,
            handedOverSplit: split,
            profileName: appliedProfileName,
            tabTitle: customTabTitle,
            windowTitle: customWindowTitle
        )
    }

    /// The split the local daemon holds whole, as its restore regroups it.
    ///
    /// - Parameter firstSession: The session the stored tab rejoins, which
    ///   must be the first leaf's: the restore attaches through it.
    /// - Returns: The split, or nil for a lone pane or a split the daemon does
    ///   not hold whole.
    private func handedOverSplit(firstSession: UInt32) -> SavedTerminalPresentation.HandedOverSplit? {
        guard let model = Self.windowModel, model.paneCount(workspaceSurface) > 1 else { return nil }
        let held = model.captureSharedSurface(workspaceSurface)
        let sessions = Array(held.sessions)
        guard sessions.count >= 2, sessions.first == firstSession else { return nil }
        let arrangement = String(Ubiquitty.Session.serializeWorkspaceText(held.arrangement))
        return arrangement.isEmpty ? nil : .init(arrangement: arrangement, sessions: sessions)
    }

    /// What the session capture decides this window's tab by.
    ///
    /// The model's facts for a window whose panes it owns
    /// (`WorkspaceSession::tabCaptureFacts`): its split, whether a quit can
    /// hand its shell to the daemon, and the daemon session a shared window
    /// lives in. A window a remote host drives adds the attachment it keeps.
    package var tabCaptureFacts: Ubiquitty.Session.TabCaptureFacts {
        var facts = Self.windowModel?.tabCaptureFacts(workspaceSurface) ?? Ubiquitty.Session.TabCaptureFacts()
        facts.isRenderOnly = isRenderOnly
        facts.hasHostedReference = isRenderOnly
        if let shared = windowSharing?.liveWorkspace {
            facts.paneLayout = std.string()
            facts.isRemote = true
            facts.remoteSessionID = shared.sessionID
            facts.remoteHostLabel = std.string(shared.hostLabel)
            facts.remoteBridgeCommand = std.string(shared.bridgeCommand)
            facts.remoteSocketName = std.string(shared.socketName)
            return facts
        }
        if let remote = remoteAttachment {
            facts.isRemote = true
            facts.remoteSessionID = remote.sessionID
            facts.remoteHostLabel = std.string(remote.hostLabel)
            facts.remoteBridgeCommand = std.string(remote.bridgeCommand)
            facts.remoteSocketName = std.string(remote.socketName)
        }
        return facts
    }

    /// Hands every pane's running shell of this window to the local daemon at
    /// quit, leaving the window as it is
    /// (`WorkspaceSession::handSurfaceToLocalDaemon`).
    ///
    /// - Parameters:
    ///   - socketPath: The daemon's control socket, already answering.
    ///   - bridgeCommand: The same daemon target's owned reconnect command.
    /// - Returns: The daemon's id for the first pane's shell once it holds
    ///   every pane, or zero when the window has no shell to hand over, a
    ///   pane met a proven refusal, or ownership is unresolved.
    package func handShellToDaemon(atSocketPath socketPath: String, bridgeCommand: String) -> UInt32 {
        let panes = Array(surfaces.values)
        guard let model = Self.windowModel, !panes.isEmpty, panes.allSatisfy({ $0.drive.canClose }) else { return 0 }
        let sessionID = model.handSurfaceToLocalDaemon(
            workspaceSurface,
            std.string(socketPath),
            UInt(Ubiquitty.Session.adoptHandoffAddress())
        )
        // Quit can still be cancelled. Keep the original target with both a
        // committed owner and an unresolved attempt, never a borrowed view.
        for pane in panes {
            pane.drive.setLocalAdoptionBridgeCommand(bridgeCommand)
        }
        return sessionID
    }

    /// Whether this window only shows panes another authority owns — a tmux
    /// window's — so it is a view rather than a session of its own.
    package var isRenderOnly: Bool {
        workspaceSurface == Ubiquitty.Session.Layout.invalidSurface && remoteSurface == nil
    }

    /// The daemon session a thin-client window is attached to, and the way
    /// back to it; nil for every other window shape.
    package var remoteAttachment: (sessionID: UInt32, hostLabel: String, bridgeCommand: String, socketName: String)? {
        guard let remoteSurface, let remoteConnection else { return nil }
        return (
            remoteSurface.drive.remoteSessionID, remoteConnection.hostLabel, remoteConnection.shellCommand,
            remoteSurface.drive.remoteSocketName
        )
    }

    /// The focused pane's grid, which a restored tab opens at.
    package var capturedGrid: (columns: Int, rows: Int) {
        guard let surface = activeSurface ?? remoteSurface ?? tmuxIntentSurface else { return (0, 0) }
        return (surface.publishedGrid.columns, surface.publishedGrid.rows)
    }

    /// The catalog theme the focused pane paints, which the Theme menu checks.
    ///
    /// - Returns: The theme's index, or -1 for a palette no catalog theme
    ///   matches.
    package var paintedThemeIndex: Int {
        guard let surface = activeSurface ?? remoteSurface else { return -1 }
        return Int(surface.drive.currentThemeIndex())
    }

    /// Points an inspector at the pane this window would inspect itself.
    ///
    /// - Parameter model: The inspector's model.
    package func inspect(in model: TerminalInspectorModel) {
        guard let surface = activeSurface ?? remoteSurface ?? projectedSurfaces.first else { return }
        model.controller = self
        model.refresh(from: surface)
    }
}
