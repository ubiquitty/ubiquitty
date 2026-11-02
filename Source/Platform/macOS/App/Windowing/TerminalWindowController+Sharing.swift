// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Sharing.swift — File ▸ Share This Window with
// Agents, and Stop Sharing This Window.
//
// Sharing hands the window's running shell to the local daemon so an agent the
// person consents to can attach to the terminal in use. Every step of it is
// Core's (`TerminalSession::commitShareIntoLocalDaemon`,
// `attachSharedLocalWindow`, `joinSharedLocalWindow`, `requestReclaim`): which
// daemon, whether it is running, the descriptor handoff, stopping the local
// reader, attaching the window's panes as clients of the adopted sessions on
// one connection, and resuming the same stream when the daemon hands a
// session back. What is here is the menu,
// the words each outcome is told in, and the chrome that says a window is
// shared — the same connection badge and roster a hosted window wears, with the
// window itself unchanged.

import AppKit
internal import UbiquittyAppleCallbacks
internal import UbiquittyCore
internal import UbiquittyRenderKit
internal import UbiquittySessionHandoff

extension TerminalWindowController {
    /// The name the connection badge gives a shared window's daemon.
    static var sharedHostLabel: String { "shared" }

    /// The pane this window shared, while the local daemon drives it.
    package var sharedSurface: TerminalSurface? {
        surfaces.values.first { $0.drive.isSharedIntoLocalDaemon }
    }

    /// Whether this window took the host's confirmation as its published
    /// share, which is what it saves from then on.
    package var isSharePublishedForTesting: Bool { windowSharing?.liveWorkspace != nil }

    /// Includes projected panes outside the local workspace's surface map.
    package var hasUnresolvedLocalAdoption: Bool {
        projectedSurfaces.contains { $0.drive.hasUnresolvedLocalAdoption }
    }

    /// Refuses both ordinary and already-confirmed close paths while ownership
    /// is uncertain. The original terminal and stream must remain reachable.
    package func refuseCloseForLocalAdoptionIfNeeded() -> Bool {
        guard projectedSurfaces.contains(where: { !$0.drive.canClose }) else { return false }
        presentUnresolvedLocalAdoption()
        return true
    }

    /// Reattaches only confirmed adoptions when a quit was cancelled.
    /// An unresolved owner remains paused and is never treated as a client.
    /// Each reattaches on a connection of its own, and the window's panes
    /// then move onto one.
    package func reattachCommittedLocalAdoptions() {
        for surface in projectedSurfaces where surface.drive.isSharedIntoLocalDaemon {
            if !surface.drive.isRemoteAttached, !surface.drive.attachSharedLocalSession() { continue }
            showSharingChrome(on: surface)
        }
        windowSharing?.consolidate()
    }

    /// Resolves visible owners only. Core separately retains owners whose
    /// views were forcibly removed; a window cannot resolve those by guessing.
    package func retryUnresolvedLocalAdoptions() {
        for surface in projectedSurfaces where surface.drive.hasUnresolvedLocalAdoption {
            let ownership = surface.drive.resolveLocalAdoption(
                resolveAddress: UInt(Ubiquitty.Session.resolveHandoffAddress())
            )
            if ownership == .Committed, surface.drive.isRemoteAttached {
                showSharingChrome(on: surface)
            }
        }
        refreshTitles()
        windowSharing?.consolidate()
        if !hasUnresolvedLocalAdoption { windowSharing?.resume() }
    }

    /// File's sharing action becomes an explicit bounded retry while paused.
    @objc
    public func retrySessionHandoff(_ sender: Any?) {
        retryUnresolvedLocalAdoptions()
        if hasUnresolvedLocalAdoption { presentUnresolvedLocalAdoption() }
    }

    func showSharingChrome(on surface: TerminalSurface) {
        remoteHostLabel = Self.sharedHostLabel
        remoteSessionDidChange(on: surface)
        refreshPresence()
    }

    private func presentUnresolvedLocalAdoption() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(Ubiquitty.Session.shareFailureTitle(.unresolved))
        alert.informativeText = String(Ubiquitty.Session.shareFailureDetail(.unresolved))
        alert.addButton(withTitle: "Retry Handoff")
        alert.addButton(withTitle: "Keep Open")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // AppKit keeps the sheet attached during this callback. Resolve
            // after it detaches so another unresolved result can be explained.
            DispatchQueue.main.async { [weak self] in self?.retrySessionHandoff(nil) }
        }
    }

    /// File ▸ Share This Window with Agents: hands the window's running shell to
    /// the local daemon and shows the window as that session's client.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func shareThisWindow(_ sender: Any?) {
        if hasUnresolvedLocalAdoption {
            retrySessionHandoff(sender)
            return
        }
        guard isWindowShareable, let window else {
            return
        }
        if let windowSharing {
            windowSharing.resume()
            return
        }
        guard let hostBinary = ShareSessionSupport.localHostBinaryPath() else {
            ShareSessionSupport.present(.missingHost, attachedTo: window)
            return
        }
        let controllers = (window.tabbedWindows ?? [window]).compactMap { $0.windowController as? TerminalWindowController }
        let sharing = WindowSharing(owner: self, controllers: controllers, hostBinary: hostBinary)
        for controller in controllers { controller.windowSharing = sharing }
        sharing.chooseDestination()
    }

    /// File ▸ Stop Sharing This Window: asks the daemon for the shared session
    /// back. The window goes local when the answer arrives, through
    /// ``remoteSessionDidChange(on:)``.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func stopSharingWindow(_ sender: Any?) {
        let controllers = windowSharing?.controllers ?? [self]
        for controller in controllers {
            controller.windowSharing = nil
            for surface in controller.projectedSurfaces where surface.drive.isSharedIntoLocalDaemon {
                surface.drive.requestReclaim()
            }
        }
    }

    /// Takes the hosted-session chrome off a pane that is local again.
    ///
    /// A shared session handed back is the one way a pane stops being a thin
    /// client while its window stays open, so this is the reclaim's half of
    /// the chrome: the badge, the status plate, the roster and the name the
    /// window's title fell back to.
    ///
    /// - Parameter surface: The pane that went local.
    func withdrawSharingChrome(from surface: TerminalSurface) {
        surface.subviews.compactMap { $0 as? RemoteConnectionStatusView }.forEach { $0.removeFromSuperview() }
        guard sharedSurface == nil else { return }
        remoteConnectionIndicator?.withdraw()
        remoteHostLabel = ""
        refreshHostSubtitle(host: Ubiquitty.Session.PaneHost())
        refreshPresence()
        reportClipboardScope(for: surface)
        refreshTitles()
    }
}

/// Coordinates one native window's tabs while Core retains each PTY's ownership.
/// A failed publication keeps the same destination and session IDs for a retry.
@MainActor
final class WindowSharing: NSObject {
    private struct Participant {
        weak var controller: TerminalWindowController?
    }

    private enum Phase { case choosing, transferring, waiting, publishing, published, failed }

    private weak var owner: TerminalWindowController?
    private let participants: [Participant]
    private let hostBinary: String
    private let bridgeCommand: String
    private var directory: Ubiquitty.Runtime.HostDirectoryClient
    private var phase = Phase.choosing
    private var destinationWorkspaceID: UInt32 = 0
    private var destinationDaemonID: UInt64 = 0
    private var workspaceName = "Shared Window"
    private var suggestedWorkspaceName = "Shared Window"
    private var publication: Ubiquitty.Session.SharedWorkspace?
    private weak var publisher: TerminalSurface?
    /// The pane whose connection every pane of a fresh share joins.
    private weak var anchor: TerminalSurface?
    private let destination = NSPopUpButton(frame: .zero, pullsDown: false)
    private let name = NSTextField(string: "Shared Window")
    private var deadline: TimeInterval = 0
    private var isAdvanceScheduled = false
    private var publishedWorkspaceID: UInt32 = 0

    var controllers: [TerminalWindowController] { participants.compactMap(\.controller) }
    var canRetry: Bool { phase == .failed }

    /// Saves the confirmed host identity, even if the pane that published it closed.
    var liveWorkspace: SavedTerminalPresentation.LiveWorkspace? {
        guard phase == .published, publishedWorkspaceID != 0,
            let surface = controllers.flatMap(\.projectedSurfaces).first(where: { $0.drive.isSharedIntoLocalDaemon })
        else { return nil }
        return .init(
            daemonInstanceID: surface.drive.remoteDaemonInstanceID,
            workspaceID: publishedWorkspaceID,
            sessionID: surface.drive.remoteSessionID,
            bridgeCommand: bridgeCommand,
            hostLabel: String(cString: Ubiquitty.Session.localHostLabel),
            socketName: surface.drive.remoteSocketName
        )
    }

    init(owner: TerminalWindowController, controllers: [TerminalWindowController], hostBinary: String) {
        self.owner = owner
        self.participants = controllers.map { Participant(controller: $0) }
        self.hostBinary = hostBinary
        let quoted = hostBinary.withCString { String(Ubiquitty.Transport.shellSingleQuote(std.string_view($0))) }
        let command = quoted.withCString { Ubiquitty.Session.localBridgeCommand(std.string_view($0)) }
        self.bridgeCommand = String(command)
        self.directory = Ubiquitty.Runtime.HostDirectoryClient(command, Ubiquitty.Apple.mainQueueLoop())
        super.init()
        directory.setChangeCallback(
            Ubiquitty.Apple.ownedCallback { [weak self] in
                MainActor.assumeIsolated { self?.reloadDestinations() }
            }
        )
    }

    func chooseDestination() {
        guard let window = owner?.window, window.attachedSheet == nil else {
            cancel()
            return
        }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Share This Window"
        alert.informativeText =
            "Move all tabs and split panes into a workspace on this Mac. Their running programs will continue, and you can open the workspace from another device."
        alert.addButton(withTitle: "Share")
        alert.addButton(withTitle: "Cancel")
        destination.target = self
        destination.action = #selector(destinationChanged)
        destination.setAccessibilityIdentifier("share-workspace-destination")
        name.setAccessibilityIdentifier("share-workspace-name")
        let content = NSStackView(views: [destination, name])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        destination.widthAnchor.constraint(equalToConstant: 360).isActive = true
        name.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = content
        reloadDestinations()
        _ = directory.refresh()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.cancel()
                return
            }
            self.destinationWorkspaceID = UInt32(self.destination.selectedTag())
            self.destinationDaemonID = self.destinationWorkspaceID == 0 ? 0 : self.directory.snapshot().daemonInstanceID
            self.workspaceName = self.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
    }

    @objc
    private func destinationChanged() {
        name.isEnabled = destination.selectedTag() == 0
    }

    private func reloadDestinations() {
        guard phase == .choosing else { return }
        let selected = destination.selectedTag()
        destination.removeAllItems()
        destination.addItem(withTitle: "Create New Workspace")
        destination.lastItem?.tag = 0
        let outline = HostOutline(directory.outlineRows(HostOutlineReader().request))
        if name.stringValue == suggestedWorkspaceName {
            let taken = Set(outline.rows.filter { $0.level == .workspace }.flatMap { [$0.title, $0.open.workspaceName] })
            var suggestion = "Shared Window"
            var number = 2
            while taken.contains(suggestion) {
                suggestion = "Shared Window \(number)"
                number += 1
            }
            suggestedWorkspaceName = suggestion
            name.stringValue = suggestion
        }
        for row in outline.rows where row.level == .workspace && row.workspaceState != .restorable {
            guard let id = row.id, id.number > 0, id.number <= UInt32.max else { continue }
            destination.addItem(withTitle: "Add to \(row.title)")
            destination.lastItem?.tag = Int(id.number)
        }
        if !destination.selectItem(withTag: selected) { destination.selectItem(withTag: 0) }
        destinationChanged()
    }

    private func cancel() {
        for controller in controllers { controller.windowSharing = nil }
    }

    func resume() {
        guard phase == .choosing || phase == .failed else { return }
        guard controllers.count == participants.count else {
            fail("A tab closed before the window could be shared.")
            return
        }
        if let publisher, publication != nil {
            let result = publisher.drive.sharedWorkspaceResult
            if result.isPending || result.workspaceID != 0 {
                phase = .publishing
                deadline = ProcessInfo.processInfo.systemUptime + 20
                advance()
                return
            }
        }
        phase = .transferring
        let surfaces = controllers.flatMap(\.projectedSurfaces)
        // A window none of whose panes is shared yet rides one connection.
        // A retry finds panes already attached on connections of their own;
        // they move onto one once the host confirms the window.
        let isFreshShare = !surfaces.contains { $0.drive.isSharedIntoLocalDaemon }
        for surface in surfaces where !surface.drive.isSharedIntoLocalDaemon {
            let outcome = surface.drive.commitShareIntoLocalDaemon(
                hostBinaryPath: hostBinary,
                handoffAddress: UInt(Ubiquitty.Session.adoptHandoffAddress())
            )
            guard outcome == .shared else {
                fail(String(Ubiquitty.Session.shareFailureDetail(outcome)))
                return
            }
        }
        anchor = nil
        if isFreshShare, let first = surfaces.first, first.drive.attachSharedLocalWindow() {
            anchor = first
            // Core joins each pane to the anchor's connection as the host
            // places its session in the published workspace.
            for member in surfaces.dropFirst() where !member.drive.joinSharedLocalWindow(anchor: first.drive) {
                member.drive.attachSharedLocalSession()
            }
        } else {
            attachUnjoinedPanes()
        }
        phase = .waiting
        deadline = ProcessInfo.processInfo.systemUptime + 20
        advance()
    }

    /// Gives every committed pane without a client a connection of its own,
    /// so no failure leaves a pane the daemon drives without a view of it.
    private func attachUnjoinedPanes() {
        for surface in controllers.flatMap(\.projectedSurfaces)
        where surface.drive.isSharedIntoLocalDaemon && !surface.drive.isRemoteAttached && !surface.drive.hasUnresolvedLocalAdoption {
            surface.drive.attachSharedLocalSession()
        }
    }

    func advance() {
        guard phase == .waiting || phase == .publishing else { return }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            fail(
                "The terminals are on the host, but the complete workspace has not been confirmed. Choose Share This Window again to retry the same handoff."
            )
            return
        }
        if phase == .waiting {
            let surfaces = controllers.flatMap(\.projectedSurfaces)
            guard controllers.count == participants.count, !surfaces.isEmpty else {
                fail("A tab closed before the window could be published.")
                return
            }
            // The anchor's connection is the one that publishes; the panes
            // waiting to join it have none of their own to wait for.
            let carriers = anchor.map { [$0] } ?? surfaces
            guard carriers.allSatisfy({ $0.drive.remoteState == .Connected }) else {
                scheduleAdvance()
                return
            }
            guard let first = carriers.first,
                surfaces.allSatisfy({ $0.drive.remoteDaemonInstanceID == first.drive.remoteDaemonInstanceID }),
                destinationDaemonID == 0 || destinationDaemonID == first.drive.remoteDaemonInstanceID
            else {
                fail("The host changed while sharing. Keep these terminals open and reconnect to their host.")
                return
            }
            if publication == nil {
                var shared = Ubiquitty.Session.SharedWorkspace()
                for controller in controllers {
                    guard let model = TerminalWindowController.windowModel,
                        shared.append(model.captureSharedSurface(controller.workspaceSurface), controller === owner)
                    else {
                        fail("The complete window does not fit in one hosted workspace.")
                        return
                    }
                }
                shared.arrangement.name = std.string(workspaceName)
                shared.destinationWorkspaceID = destinationWorkspaceID
                publication = shared
            }
            guard let publication else { return }
            publisher = first
            // Set the phase before sending: a carrier may deliver its answer synchronously.
            phase = .publishing
            if !first.drive.publishSharedWorkspace(publication) {
                // Connected precedes the pane binding that admits control calls.
                phase = .waiting
                scheduleAdvance()
                return
            }
        }
        guard phase == .publishing else { return }
        guard let publisher else {
            fail("The publishing terminal closed.")
            return
        }
        let result = publisher.drive.sharedWorkspaceResult
        if result.isPending {
            scheduleAdvance()
            return
        }
        guard result.workspaceID != 0 else {
            fail(String(result.detail))
            return
        }
        // Confirmed once every pane has a client: those joining the anchor's
        // connection join as the host binds them there.
        guard controllers.flatMap(\.projectedSurfaces).allSatisfy({ $0.drive.isRemoteAttached }) else {
            scheduleAdvance()
            return
        }
        publishedWorkspaceID = result.workspaceID
        phase = .published
        consolidate()
        for controller in controllers {
            for surface in controller.projectedSurfaces { controller.showSharingChrome(on: surface) }
        }
        ShareSessionSupport.present(.started, attachedTo: owner?.window)
    }

    /// Moves every attached pane of the confirmed window onto one connection.
    ///
    /// Panes attached on connections of their own before the host confirmed
    /// the window's workspace (a share retried after some attached, a quit
    /// cancelled after its hand-over, a handoff resolved later) join the
    /// connection that survives: the anchor's when there is one, else the one
    /// this process keeps for the workspace, else the publisher's. Core moves
    /// each pane once its input has settled and its questions have been
    /// answered on the connection it leaves, which then detaches.
    func consolidate() {
        guard phase == .published, publishedWorkspaceID != 0 else { return }
        let attached = controllers.flatMap(\.projectedSurfaces)
            .filter {
                $0.drive.isSharedIntoLocalDaemon && $0.drive.isRemoteAttached && !$0.drive.hasUnresolvedLocalAdoption
            }
        let isAttached = { (surface: TerminalSurface) in attached.contains { $0 === surface } }
        let preferred = [anchor, attached.first(where: { $0.drive.isOnIndexedWorkspaceConnection }), publisher, attached.first]
        guard let carrier = preferred.lazy.compactMap({ $0 }).first(where: isAttached),
            carrier.drive.anchorSharedLocalWindow(workspaceID: publishedWorkspaceID)
        else { return }
        anchor = carrier
        for member in attached where member !== carrier {
            _ = member.drive.joinSharedLocalWindow(anchor: carrier.drive)
        }
    }

    private func scheduleAdvance() {
        guard !isAdvanceScheduled else { return }
        isAdvanceScheduled = true
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAdvanceScheduled = false
                self.advance()
            }
        }
    }

    private func fail(_ detail: String) {
        phase = .failed
        // A committed handoff stays committed: each pane the daemon now
        // drives keeps a client, on a connection of its own if it has to.
        attachUnjoinedPanes()
        ShareSessionSupport.present(
            .failed(
                title: "Window Sharing Needs Attention",
                detail: detail.isEmpty ? "The host did not confirm the complete window. Keep it open and retry sharing." : detail
            ),
            attachedTo: owner?.window
        )
    }
}
