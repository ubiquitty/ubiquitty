// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+RemoteWorkspace.swift — a hosted workspace, projected.
//
// The host's workspace is mirrored by every session attached to one of its
// panes (Core's RemoteSessionCore), and the mirror reaches this shell as one
// event beside which the tree is read. A window projects one host tab: its
// remote surface is the pane it attached to, every other pane of the tab gets
// a view attached to that pane's session, and the split views follow the
// tab's tree. One window per host tab, tabbed together per host surface, is
// what the projection keeps across every layout the host sends; a tab or
// pane the host no longer holds leaves with the layout that dropped it.
//
// Every verb goes to the host and nothing is mutated here: a split, a close,
// a zoom, a focus move, a divider drag and a new tab are each one
// WORKSPACE_VERB, and the window changes when the host's next layout says so.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// Retains the display identity and bootstrap settings of a hosted workspace.
struct RemoteConnection {
    let shellCommand: String
    let hostLabel: String
    let quicHost: String
    let quicBootstrapCommand: String
    let hostKey: String
}

/// The windows of one hosted workspace, one per host tab.
@MainActor
final class RemoteWorkspaceProjection {
    private static var projections: [RemoteWorkspaceProjection] = []

    let connection: RemoteConnection
    private var windows: [Ubiquitty.Session.Layout.TabID: TerminalWindowController] = [:]
    // Tabs whose window the user closed: asked of the host as a close, and
    // not reopened by a layout the host sends before, or instead of,
    // dropping them — a root tab the host refuses to close stays detached.
    private var declined: Set<Ubiquitty.Session.Layout.TabID> = []
    private var isReconciling = false
    private var needsReconciliation = false

    /// How many host-applied changes to the windows are in progress.
    ///
    /// A layout the host sent opens, closes, regroups and selects tab
    /// windows, and AppKit moves a group's selection for each. Those moves
    /// are the host's own word coming back, so they are not reported to it
    /// as a person's choice.
    private static var hostLayoutDepth = 0

    /// Whether the windows are being changed to match the host right now.
    static var isApplyingHostLayout: Bool { hostLayoutDepth > 0 }

    /// Runs a change the host asked for, during which a selection AppKit
    /// moves is not a person's.
    ///
    /// - Parameter change: The change to the windows.
    static func applyingHostLayout(_ change: () -> Void) {
        hostLayoutDepth += 1
        defer { hostLayoutDepth -= 1 }
        change()
    }

    private init(connection: RemoteConnection) {
        self.connection = connection
    }

    /// The projection a window belongs to, made on first need.
    static func projection(for controller: TerminalWindowController, workspaceID: UInt32) -> RemoteWorkspaceProjection? {
        guard let connection = controller.remoteConnection,
            let drive = controller.remoteSurface?.drive,
            workspaceID != 0
        else {
            return nil
        }
        if let existing = projections.first(where: { projection in
            projection.windows.values.contains { member in
                guard !member.isWindowClosed, let memberDrive = member.remoteSurface?.drive else { return false }
                return drive.sharesRemoteWorkspaceConnection(with: memberDrive)
            }
        }) {
            existing.register(controller, tab: controller.remoteWorkspaceTab)
            return existing
        }
        let made = RemoteWorkspaceProjection(connection: connection)
        made.register(controller, tab: controller.remoteWorkspaceTab)
        projections.append(made)
        return made
    }

    /// A closing window leaves its projection; the last one out removes it.
    /// A window the user closed declines its tab, so no layout reopens it.
    static func forget(_ controller: TerminalWindowController, declining tab: Ubiquitty.Session.Layout.TabID) {
        for projection in projections where projection.windows.values.contains(where: { $0 === controller }) {
            projection.windows = projection.windows.filter { $0.value !== controller }
            if tab != Ubiquitty.Session.Layout.invalidTab {
                projection.declined.insert(tab)
            }
        }
        projections.removeAll { $0.windows.isEmpty }
    }

    /// Removes local projections without asking the host to change its workspace.
    static func detach(from drive: RuntimeDrive) {
        let members = TerminalWindowController.spawnedControllers.filter { controller in
            guard !controller.isWindowClosed, let other = controller.remoteSurface?.drive else { return false }
            return drive === other || drive.sharesRemoteWorkspaceConnection(with: other)
        }
        // Retire the projection before closing any member: an intervening layout
        // must not recreate windows while their endpoints are being released.
        projections.removeAll { projection in
            projection.windows.values.contains { member in members.contains { $0 === member } }
        }
        for member in members {
            member.isClosingWithHostTab = true
            member.remoteClosePresentation?.cancel()
        }
        applyingHostLayout {
            for member in members { member.close() }
        }
    }

    /// Records that a window projects a host tab.
    func register(_ controller: TerminalWindowController, tab: Ubiquitty.Session.Layout.TabID) {
        windows[tab] = controller
    }

    /// Makes the windows match the mirror: a window for every tab of every
    /// surface, tabbed together per surface with the host's active tab
    /// selected, and none for a tab the host no longer holds.
    ///
    /// - Parameter drive: Any member window's drive; every member mirrors the same workspace.
    func reconcile(from drive: RuntimeDrive) {
        guard !isReconciling else {
            needsReconciliation = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }
        Self.applyingHostLayout {
            adoptRestoration(from: drive)
            repeat {
                needsReconciliation = false
                reconcileWindows(from: drive)
            } while needsReconciliation
        }
        resolvePendingActivation(from: drive)
    }

    /// Moves every window, declined tab and pane view kept by the mirror's
    /// ids to the ids a host restored the workspace under, when Core says it
    /// did, and closes each window whose tab the restoration did not pair.
    ///
    /// A host that took in the record of a daemon that stopped restores the
    /// workspace with ids of its own: the window a person had open is still
    /// the window of its tab, under the tab's new id. An id the pairing does
    /// not name is the stopped host's, and the restoring host may have given
    /// the same number to another tab or pane, so nothing stays under one.
    private func adoptRestoration(from drive: RuntimeDrive) {
        guard let restored = drive.takeRemoteWorkspaceRestoredPanes() else { return }
        var tabs: [Ubiquitty.Session.Layout.TabID: Ubiquitty.Session.Layout.TabID] = [:]
        var panes: [Ubiquitty.Session.Layout.PaneID: Ubiquitty.Session.Layout.PaneID] = [:]
        var sessions: [UInt32: UInt32] = [:]
        for pair in restored {
            tabs[pair.formerTab] = pair.tab
            panes[pair.formerPane] = pair.pane
            sessions[pair.formerSessionID] = pair.sessionID
        }
        var moved: [Ubiquitty.Session.Layout.TabID: TerminalWindowController] = [:]
        var unpaired: [TerminalWindowController] = []
        for (tab, controller) in windows {
            guard let restoredTab = tabs[tab] else {
                unpaired.append(controller)
                continue
            }
            moved[restoredTab] = controller
            controller.remoteWorkspaceTab = restoredTab
            var views: [Ubiquitty.Session.Layout.PaneID: TerminalSurface] = [:]
            for (pane, view) in controller.remotePaneSurfaces {
                if let restoredPane = panes[pane] {
                    views[restoredPane] = view
                } else if view !== controller.remoteSurface {
                    view.drive.close()
                }
            }
            controller.remotePaneSurfaces = views
            if let sessionID = sessions[controller.pendingRemoteActivationSessionID] {
                controller.pendingRemoteActivationSessionID = sessionID
            }
        }
        windows = moved
        declined = Set(declined.compactMap { tabs[$0] })
        for controller in unpaired {
            controller.isClosingWithHostTab = true
            controller.close()
        }
    }

    private func resolvePendingActivation(from drive: RuntimeDrive) {
        for requester in Array(windows.values) where requester.pendingRemoteActivationSessionID != 0 {
            let sessionID = requester.pendingRemoteActivationSessionID
            for candidate in Array(windows.values) where !candidate.isWindowClosed {
                let pane =
                    candidate.remotePaneSurfaces.values.first { $0.remoteSessionID == sessionID }
                    ?? candidate.remoteSurface.flatMap { $0.remoteSessionID == sessionID ? $0 : nil }
                if let pane {
                    requester.pendingRemoteActivationSessionID = 0
                    candidate.activateRemotePane(pane)
                    return
                }
            }
            var isPresent = false
            for surfaceIndex in 0..<drive.remoteWorkspaceSurfaceCount {
                let surface = drive.remoteWorkspaceSurface(at: surfaceIndex)
                for tabIndex in 0..<drive.remoteWorkspaceTabCount(of: surface) {
                    let tab = drive.remoteWorkspaceTab(of: surface, at: tabIndex)
                    let tree = drive.remoteWorkspacePaneTreeSnapshot(of: surface, tab: tab)
                    for index in 0..<Ubiquitty.Panes.maxNodes where tree.isLeaf(index) {
                        if let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(tree.node(index).paneID)),
                            drive.remoteWorkspaceSession(for: pane) == sessionID
                        {
                            isPresent = true
                        }
                    }
                }
            }
            if !isPresent {
                requester.pendingRemoteActivationSessionID = 0
            }
        }
    }

    private func reconcileWindows(from drive: RuntimeDrive) {
        var held = Set<Ubiquitty.Session.Layout.TabID>()
        var destinations: [(Ubiquitty.Session.Layout.SurfaceID, Ubiquitty.Session.Layout.TabID)] = []
        var views: [Ubiquitty.Session.Layout.PaneID: TerminalSurface] = [:]
        for controller in windows.values {
            for (pane, view) in controller.remotePaneSurfaces { views[pane] = view }
            if let root = controller.remoteSurface { views[root.drive.remoteWorkspacePane] = root }
        }
        for surfaceIndex in 0..<drive.remoteWorkspaceSurfaceCount {
            let surface = drive.remoteWorkspaceSurface(at: surfaceIndex)
            for tabIndex in 0..<drive.remoteWorkspaceTabCount(of: surface) {
                let tab = drive.remoteWorkspaceTab(of: surface, at: tabIndex)
                held.insert(tab)
                guard !declined.contains(tab) else { continue }
                if windows[tab] == nil { _ = open(surface: surface, tab: tab, from: drive, available: views) }
                destinations.append((surface, tab))
            }
        }
        // A pane's view follows its identity. All windows adopt before an empty source closes.
        for (surface, tab) in destinations {
            guard let controller = windows[tab] else { continue }
            controller.projectRemoteWorkspaceTab(from: drive, surface: surface, tab: tab, available: views)
            // The tab's custom title is the host's and is read from the layout
            // as it stands; this pass is the edge that moved it, so the titles
            // re-derive here. The weave's memo absorbs a pass that moved none.
            controller.refreshTitles()
        }
        // AppKit owns provisional tab groups until its tear-off tracker returns.
        if !PaneTransferCoordinator.shared.isTrackingNativeTab(from: drive) {
            var leaders: [Ubiquitty.Session.Layout.SurfaceID: NSWindow] = [:]
            let surfaceByWindow = Dictionary(
                uniqueKeysWithValues: destinations.compactMap { surface, tab in
                    windows[tab]?.window.map { (ObjectIdentifier($0), surface) }
                }
            )
            // Every window this workspace opened, including one whose host tab
            // is gone and which closes below, belongs to it.
            let ownedWindows = Set(windows.values.compactMap { $0.window.map(ObjectIdentifier.init) })
            // Only this workspace's windows are the projection's to arrange: a
            // window of another surface leaves a group it shares with one of
            // this one, but a window this workspace does not project (a local
            // shell, another host's tab) is the person's to group with it.
            let isOfAnotherSurface = { (window: NSWindow, surface: Ubiquitty.Session.Layout.SurfaceID) in
                surfaceByWindow[ObjectIdentifier(window)].map { $0 != surface } ?? false
            }
            for (surface, tab) in destinations {
                guard let controller = windows[tab], let window = controller.window else { continue }
                if let group = window.tabGroup, group.windows.contains(where: { isOfAnotherSurface($0, surface) }) {
                    group.removeWindow(window)
                }
                if let lead = leaders[surface], window.tabGroup !== lead.tabGroup {
                    lead.addTabbedWindow(window, ordered: .above)
                    controller.refreshTabGroupForFocusChange()
                } else if leaders[surface] == nil {
                    leaders[surface] = window
                }
            }
            // Joining every new window above the lead inserts it second.
            // Restore the host's order even when the group already exists;
            // slots occupied by local or other-host tabs stay where they are.
            for (surface, leader) in leaders {
                guard let group = leader.tabGroup else { continue }
                let ordered = destinations.compactMap { destination, tab -> NSWindow? in
                    destination == surface ? windows[tab]?.window : nil
                }
                TerminalWindowController.orderProjectedTabs(ordered, in: group)
            }
            // The tab in front is Core's answer among this surface's tabs: the
            // host's active tab, or the one a person here chose while the host
            // has yet to say so. A window this workspace does not project in
            // front of the group is the person's choice and stays in front.
            for (surface, _) in leaders {
                if let selected = windows[drive.remoteWorkspaceFrontTab(of: surface)]?.window,
                    let group = selected.tabGroup, group.selectedWindow !== selected,
                    group.selectedWindow.map({ ownedWindows.contains(ObjectIdentifier($0)) }) ?? true
                {
                    group.selectedWindow = selected
                }
            }
            // Every window of a group hears its selection move, whichever of
            // them was key when the group formed.
            for (_, tab) in destinations {
                windows[tab]?.observeTabSelection()
            }
        }
        let adopted = Set(
            windows.filter { held.contains($0.key) }.values.flatMap { $0.remotePaneSurfaces.values.map(ObjectIdentifier.init) }
        )
        for view in views.values where !adopted.contains(ObjectIdentifier(view)) { view.drive.close() }
        declined = declined.intersection(held)
        for (tab, controller) in windows where !held.contains(tab) {
            windows.removeValue(forKey: tab)
            controller.remoteSurface = nil
            controller.remotePaneSurfaces.removeAll()
            controller.isClosingWithHostTab = true
            controller.close()
        }
    }

    /// Opens a window for a host tab, attached to the session of the tab's
    /// focused pane; its own first layout projects the rest of the tab.
    private func open(
        surface: Ubiquitty.Session.Layout.SurfaceID,
        tab: Ubiquitty.Session.Layout.TabID,
        from drive: RuntimeDrive,
        available: [Ubiquitty.Session.Layout.PaneID: TerminalSurface]
    ) -> TerminalWindowController? {
        let tree = drive.remoteWorkspacePaneTreeSnapshot(of: surface, tab: tab)
        guard let pane = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(tree.focusedPaneID())) else {
            return nil
        }
        let sessionID = drive.remoteWorkspaceSession(for: pane)
        guard sessionID != 0,
            let source = windows.values.first(where: { !$0.isWindowClosed }),
            let controller = TerminalWindowController.spawnRemoteWindow(
                shellCommand: connection.shellCommand,
                hostLabel: connection.hostLabel,
                quicHost: connection.quicHost,
                quicBootstrapCommand: connection.quicBootstrapCommand,
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: sessionID,
                workspaceName: "",
                hostKey: connection.hostKey,
                sharingWorkspaceWith: source,
                reusingSurface: available[pane]
            )
        else {
            return nil
        }
        controller.remoteWorkspaceTab = tab
        windows[tab] = controller
        return controller
    }
}

extension TerminalWindowController {
    /// Reorders only projected members, leaving other hosts' and local slots intact.
    package static func orderProjectedTabs(_ windows: [NSWindow], in group: NSWindowTabGroup) {
        let ordered = windows.filter { member in group.windows.contains { $0 === member } }
        let projected = Set(ordered.map(ObjectIdentifier.init))
        var next = 0
        let desired = group.windows.map { window -> NSWindow in
            guard projected.contains(ObjectIdentifier(window)) else { return window }
            defer { next += 1 }
            return ordered[next]
        }
        let selected = group.selectedWindow
        for (index, window) in desired.enumerated() where group.windows[index] !== window {
            // A native pill moves with a window that leaves and rejoins its group.
            group.removeWindow(window)
            group.insertWindow(window, at: index)
        }
        if let selected, group.windows.contains(where: { $0 === selected }) {
            group.selectedWindow = selected
        }
    }

    /// Keeps a tab's surviving panes attached when its initial pane exits.
    func promoteRemoteAnchor(after exiting: TerminalSurface) -> Bool {
        guard exiting === remoteSurface else { return false }
        let focused = activeSurface
        let candidates = remotePaneSurfaces.sorted { left, right in
            if (left.value === focused) != (right.value === focused) {
                return left.value === focused
            }
            return left.key.rawValue < right.key.rawValue
        }
        guard
            let survivor = candidates.first(where: {
                $0.value !== exiting && exiting.drive.remoteWorkspaceSession(for: $0.key) != 0
            })
        else { return false }
        let departedPane = remotePaneSurfaces.first { $0.value === exiting }?.key
        remoteSurface = survivor.value
        remotePaneSurfaces = remotePaneSurfaces.filter { $0.value !== exiting }
        exiting.removeFromSuperview()
        remoteRequestedSessionID = survivor.value.remoteSessionID
        remoteSessionDidChange(on: survivor.value)
        // A sibling may receive the new tree before the departing pane's
        // EXIT. Otherwise its later layout event performs this reconciliation.
        if let departedPane, survivor.value.drive.remoteWorkspaceSession(for: departedPane) == 0 {
            remoteWorkspaceDidChange(on: survivor.value)
        }
        return true
    }

    /// The host's workspace was mirrored anew by this window's remote
    /// surface: the window projects its tab, and the workspace's windows are
    /// reconciled with the mirror.
    func remoteWorkspaceDidChange(on surface: TerminalSurface) {
        remoteClosePresentation?.retireIfStale()
        guard !isWindowClosed, !isClosingWithHostTab, surface === remoteSurface else {
            return
        }
        let drive = surface.drive
        switch drive.takeRemoteWorkspacePaneChange().outcome {
        case .Refused, .Interrupted:
            if let window {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Change the Workspace"
                alert.informativeText = "The host didn’t confirm the change. Review the current workspace before trying again."
                alert.icon = NSApp.applicationIconImage
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        case .Idle, .Pending, .Accepted:
            break
        @unknown default:
            break
        }
        if remoteWorkspaceName != drive.remoteWorkspaceName {
            remoteWorkspaceName = drive.remoteWorkspaceName
            if !remoteHostKey.isEmpty, surface.remoteSessionID != 0 {
                HostDirectory.remember(host: remoteHostKey, sessionID: surface.remoteSessionID, workspaceName: remoteWorkspaceName)
            }
        }
        if drive.isRemoteWorkspaceRestoredAfterHostRestart, !hasShownHostRestartNotice {
            hasShownHostRestartNotice = true
            showHostRestartNotice()
        }
        switch drive.takeRemoteWorkspaceCloseOutcome() {
        case .Refused:
            resetRemoteCloseConfirmation()
            if let window {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Close the Window"
                alert.informativeText = "The host didn’t accept the request to close. The sessions are still open."
                alert.icon = NSApp.applicationIconImage
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
            break
        case .Idle, .Pending, .Accepted:
            // An accepted request may target another tab. The result also
            // precedes the host's layout and exits, which retire the affected
            // projections without closing the window that sent the request.
            break
        @unknown default:
            break
        }
        let tab = drive.remoteWorkspaceTab
        guard tab != Ubiquitty.Session.Layout.invalidTab else {
            return
        }
        if remoteWorkspaceTab == Ubiquitty.Session.Layout.invalidTab { remoteWorkspaceTab = tab }
        guard let projection = RemoteWorkspaceProjection.projection(for: self, workspaceID: drive.remoteWorkspaceID) else {
            return
        }
        projection.reconcile(from: drive)
    }

    /// Reports that this window's tab came to the front of its group by a
    /// person's hand: a click on its face, its number, the next-tab key.
    ///
    /// Which tab a hosted window shows is the host's to say, so the choice is
    /// reported and the host's structure is what keeps the tab in front, here
    /// and on every other client of the workspace. A selection the host's own
    /// layout moved is not reported back to it, and neither is one AppKit
    /// moves while it tears a tab out of the strip.
    func reportTabBroughtToFront() {
        guard !isWindowClosed, remoteClosePresentation == nil, !RemoteWorkspaceProjection.isApplyingHostLayout,
            !PaneTransferCoordinator.shared.isDraggingNativeTab,
            let window, window.tabGroup?.selectedWindow === window, let drive = remoteSurface?.drive
        else {
            return
        }
        drive.remoteWorkspaceBringTabToFront()
    }

    /// What the window says under its title when the host recreated its
    /// workspace after restarting: the panes are back, and what they showed is not.
    static let hostRestartNotice = "Restored after the host restarted. Earlier output is gone."

    /// How long the notice stands before the title is the window's alone again.
    static let hostRestartNoticeDuration: Duration = .seconds(30)

    /// Says, in one line under the window's title, that the host restarted and
    /// this workspace's shells are fresh ones in the directories they were in.
    fileprivate func showHostRestartNotice() {
        guard let window else {
            return
        }
        window.subtitle = Self.hostRestartNotice
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hostRestartNoticeDuration)
            guard let window = self?.window, window.subtitle == Self.hostRestartNotice else {
                return
            }
            window.subtitle = ""
        }
    }

    /// Makes this window the host tab its remote surface belongs to: a view
    /// attached to every other pane's session, none for a pane the host no
    /// longer holds, and the split views the tab's tree describes.
    fileprivate func projectRemoteWorkspaceTab(
        from drive: RuntimeDrive,
        surface: Ubiquitty.Session.Layout.SurfaceID,
        tab: Ubiquitty.Session.Layout.TabID,
        available: [Ubiquitty.Session.Layout.PaneID: TerminalSurface]
    ) {
        let previousRoot = remoteSurface
        remotePaneSurfaces.removeAll()
        let tree = drive.remoteWorkspacePaneTreeSnapshot(of: surface, tab: tab)
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        var held = Set<Ubiquitty.Session.Layout.PaneID>()
        var joined: [TerminalSurface] = []
        for index in 0..<Ubiquitty.Panes.maxNodes where tree.isLeaf(index) {
            guard let leaf = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(tree.node(index).paneID)) else {
                continue
            }
            held.insert(leaf)
            if let existing = available[leaf] {
                remotePaneSurfaces[leaf] = existing
                adoptTransferredSurface(existing)
                continue
            }
            if let previousRoot, previousRoot.drive.remoteWorkspacePane == leaf {
                remotePaneSurfaces[leaf] = previousRoot
                continue
            }
            let sessionID = drive.remoteWorkspaceSession(for: leaf)
            guard sessionID != 0, let view = TerminalSurface(rows: launch.rows, columns: launch.columns) else {
                continue
            }
            view.renderer = windowRenderer
            view.observer = windowBridge
            view.remoteFileHost = previousRoot?.remoteFileHost ?? remoteSurface?.remoteFileHost ?? ""
            view.remoteFileHostLabel = previousRoot?.remoteFileHostLabel ?? remoteSurface?.remoteFileHostLabel ?? ""
            if isTranslucent {
                view.metalLayer.isOpaque = false
            }
            guard
                view.attachRemoteSibling(
                    to: drive,
                    sessionID: sessionID
                )
            else {
                continue
            }
            remotePaneSurfaces[leaf] = view
            joined.append(view)
        }
        remoteSurface = remotePaneSurfaces.values.first { $0 === previousRoot } ?? remotePaneSurfaces.values.first
        if let previousRoot, previousRoot !== remoteSurface,
            !available.values.contains(where: { $0 === previousRoot })
        {
            previousRoot.drive.close()
        }
        remoteRequestedSessionID = remoteSurface?.remoteSessionID ?? 0
        rebuildPaneLayout(tree: tree, zoomed: drive.remoteWorkspaceZoomedPane(of: surface), views: remotePaneSurfaces)
        if let focused = Ubiquitty.Session.Layout.PaneID(rawValue: UInt32(tree.focusedPaneID())),
            let view = remotePaneSurfaces[focused],
            window?.firstResponder !== view
        {
            window?.makeFirstResponder(view)
        }
        refreshTabTitle()
        if let hook = Self.remotePaneJoinedForTesting {
            for view in joined { hook(self, view) }
        }
    }

    /// Called with each pane a host layout adds to a window, once it stands in
    /// the window's layout and before a run-loop turn: no frame of its
    /// session can have reached it, so what it shows is its first commit.
    package static var remotePaneJoinedForTesting: ((TerminalWindowController, TerminalSurface) -> Void)?

    /// A divider drag on a hosted workspace is the host's to keep: the
    /// ratio goes out once the drag settles, not on every pixel, and the
    /// layout that answers re-mirrors the tab.
    func scheduleRemoteDividerRatio(splitIndex: Int32, ratio: Float) {
        guard let surface = remoteSurface else { return }
        let generation = surface.drive.remoteWorkspaceMirrorGeneration
        guard generation != 0 else { return }
        pendingRemoteDivider = (surface, generation, splitIndex, ratio)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            _ = self?.finishRemoteDividerRatio(surface: surface, generation: generation, splitIndex: splitIndex)
        }
    }

    /// Completes only the drag scheduled against this exact surface and topology.
    @discardableResult
    package func finishRemoteDividerRatio(surface: TerminalSurface, generation: UInt64, splitIndex: Int32) -> Bool {
        guard let pending = pendingRemoteDivider, pending.surface === surface,
            pending.generation == generation, pending.splitIndex == splitIndex
        else { return false }
        pendingRemoteDivider = nil
        guard remoteSurface === surface, remoteSurface?.drive === surface.drive,
            generation != 0, surface.drive.remoteWorkspaceMirrorGeneration == generation
        else { return false }
        return surface.drive.remoteWorkspaceSetDividerRatio(splitIndex: pending.splitIndex, ratio: pending.ratio)
    }
}

enum RemoteWindowCloseIntent {
    case closeTab
    case closeWindow
    case detachWorkspace
}

/// Owns its refresh delegate so menu construction stays in the Swift shell.
@MainActor
final class RemoteWorkspaceMenu: NSMenu, NSMenuDelegate {
    override init(title: String) {
        super.init(title: title)
        delegate = self
        autoenablesItems = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        TerminalWindowController.populateRemoteWorkspaceMenu(menu)
    }
}

/// Holds one native answer to the exact host window shown in the question.
@MainActor
final class RemoteWindowClosePresentation {
    private weak var controller: TerminalWindowController?
    private weak var surface: TerminalSurface?
    private let daemonID: UInt64
    private let workspaceID: UInt32
    private let surfaceID: Ubiquitty.Session.Layout.SurfaceID
    private let tabID: Ubiquitty.Session.Layout.TabID
    private let state: Ubiquitty.Session.State
    private let prompt: RuntimeDrive.RemoteWindowClosePrompt?
    private let alert = NSAlert()
    private var choices: [RemoteWindowCloseIntent?] = [nil]
    /// The destructive button, which waits for the host to stand where it
    /// stood when the question was asked; nil when the question offers none.
    private var closeButton: NSButton?
    /// Whether the link has left the state the question was asked in. From
    /// then on the question no longer describes what a close would end, so
    /// closing on the host stays disabled until the reader asks again.
    private var hasLinkMoved = false
    private var isFinished = false

    init(controller: TerminalWindowController, surface: TerminalSurface, intent: RemoteWindowCloseIntent) {
        self.controller = controller
        self.surface = surface
        let drive = surface.drive
        daemonID = drive.remoteDaemonInstanceID
        workspaceID = drive.remoteWorkspaceID
        surfaceID = drive.remoteWorkspaceSurface
        tabID = drive.remoteWorkspaceTab
        state = drive.remoteState
        prompt = drive.prepareRemoteWindowClose()
        let host = controller.remoteConnection?.hostLabel ?? controller.remoteHostLabel
        let workspace = controller.remoteWorkspaceName.isEmpty ? "Workspace" : controller.remoteWorkspaceName
        alert.icon = NSApp.applicationIconImage
        let isTab = intent == .closeTab && drive.remoteWorkspaceTabCount(of: surfaceID) > 1
        let closeTitle = isTab ? "Close Tab" : "Close Window"
        alert.messageText = intent == .detachWorkspace ? "Detach from \(workspace)?" : "\(closeTitle) on \(host)?"
        let count =
            intent == .closeTab
            ? UInt32(drive.remoteWorkspacePaneTreeSnapshot(of: surfaceID, tab: tabID).paneCount())
            : prompt?.sessionCount ?? 0
        let ending = count == 1 ? "the session" : "all \(count) sessions"
        let closeText =
            prompt == nil
            ? "The host window can’t be closed until its connection is ready."
            : intent == .closeTab
                ? "\(closeTitle) ends \(ending) in this \(isTab ? "tab" : "window") on \(host). Other tabs and windows stay connected."
                : "Close Window ends \(ending) in this window on \(host), including its other tabs."
        let detachText = "Detach closes all local windows for \(workspace). Its sessions keep running on \(host)."
        switch intent {
        case .closeTab:
            alert.informativeText = closeText + "\n\n" + detachText
        case .closeWindow:
            alert.informativeText = closeText
        case .detachWorkspace:
            alert.informativeText = detachText
        }
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        if intent != .closeWindow {
            alert.addButton(withTitle: "Detach from Workspace").keyEquivalent = ""
            choices.append(.detachWorkspace)
        }
        if intent != .detachWorkspace {
            let close = alert.addButton(withTitle: closeTitle)
            close.hasDestructiveAction = true
            close.isEnabled = prompt != nil
            close.keyEquivalent = ""
            closeButton = close
            choices.append(intent)
        }
    }

    func present(on window: NSWindow) {
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.answer(response)
        }
    }

    /// Whether the question is still about the window on screen: the same
    /// controller, open, showing the same surface.
    ///
    /// Detaching is answered on this alone. It closes only this machine's
    /// windows and leaves the sessions running on the host, so a link that
    /// connects, drops or reconnects under the question changes nothing about
    /// which windows those are, and a reader whose link keeps cycling must
    /// still be able to leave it.
    private var isSameWindow: Bool {
        guard let controller, !controller.isWindowClosed, !controller.isClosingWithHostTab,
            let surface, controller.remoteSurface === surface
        else { return false }
        return true
    }

    /// Whether the host still stands where it stood when the question was
    /// asked, so a close the reader chooses ends the sessions it named.
    private var isCurrent: Bool {
        guard isSameWindow, let surface,
            surface.drive.isRemoteAttached,
            surface.drive.remoteDaemonInstanceID == daemonID,
            surface.drive.remoteWorkspaceID == workspaceID,
            surface.drive.remoteWorkspaceSurface == surfaceID,
            surface.drive.remoteWorkspaceTab == tabID,
            surface.drive.remoteState == state
        else { return false }
        return prompt.map { surface.drive.pendingRemoteWindowCloseToken == $0.token } ?? true
    }

    /// Takes the question down when what it asks about is gone, and keeps it
    /// up while only the link moves.
    ///
    /// A window that closed, or a host that changed the window under a link
    /// that held, makes the question wrong, and it is retired. A link that
    /// connects, drops or reconnects leaves the windows the question is about
    /// in place: the question stays, with closing on the host disabled, so
    /// Cancel and Detach still answer for a link that never settles.
    func retireIfStale() {
        guard !isFinished else { return }
        guard isSameWindow, let surface else {
            cancel()
            return
        }
        if surface.drive.remoteState != state || !surface.drive.isRemoteAttached {
            hasLinkMoved = true
        }
        guard hasLinkMoved else {
            if !isCurrent { cancel() }
            return
        }
        closeButton?.isEnabled = false
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        if controller?.remoteClosePresentation === self { controller?.remoteClosePresentation = nil }
        if let prompt { _ = surface?.drive.answerRemoteWindowClose(prompt.token, closeWindow: false) }
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
    }

    private func answer(_ response: NSApplication.ModalResponse) {
        guard !isFinished else { return }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choice = choices.indices.contains(index) ? choices[index] : nil
        guard isSameWindow, let surface else {
            cancel()
            return
        }
        if choice == .detachWorkspace {
            isFinished = true
            if controller?.remoteClosePresentation === self { controller?.remoteClosePresentation = nil }
            if let prompt { _ = surface.drive.answerRemoteWindowClose(prompt.token, closeWindow: false) }
            RemoteWorkspaceProjection.detach(from: surface.drive)
            return
        }
        guard !hasLinkMoved, isCurrent else {
            cancel()
            return
        }
        isFinished = true
        if controller?.remoteClosePresentation === self { controller?.remoteClosePresentation = nil }
        if choice == .closeWindow, let prompt {
            _ = surface.drive.answerRemoteWindowClose(prompt.token, closeWindow: true)
            return
        }
        if let prompt { _ = surface.drive.answerRemoteWindowClose(prompt.token, closeWindow: false) }
        if choice == .closeTab, prompt != nil { _ = surface.drive.remoteWorkspaceCloseTab(tabID) }
    }
}

/// A menu item retains an identity, not whichever window later becomes key.
@MainActor
private final class RemoteWorkspaceMenuAction: NSObject {
    private weak var controller: TerminalWindowController?
    private weak var surface: TerminalSurface?
    private let daemonID: UInt64
    private let workspaceID: UInt32
    private let surfaceID: Ubiquitty.Session.Layout.SurfaceID
    private let intent: RemoteWindowCloseIntent

    init(controller: TerminalWindowController, surface: TerminalSurface, intent: RemoteWindowCloseIntent) {
        self.controller = controller
        self.surface = surface
        daemonID = surface.drive.remoteDaemonInstanceID
        workspaceID = surface.drive.remoteWorkspaceID
        surfaceID = surface.drive.remoteWorkspaceSurface
        self.intent = intent
    }

    @objc
    func invoke(_ sender: Any?) {
        guard let controller, !controller.isWindowClosed, let surface,
            controller.remoteSurface === surface,
            surface.drive.remoteDaemonInstanceID == daemonID,
            surface.drive.remoteWorkspaceID == workspaceID,
            surface.drive.remoteWorkspaceSurface == surfaceID
        else { return }
        controller.presentRemoteWindowClose(intent)
    }
}

extension TerminalWindowController {
    func presentRemoteWindowClose(_ intent: RemoteWindowCloseIntent) {
        guard !isWindowClosed, !isClosingWithHostTab, remoteClosePresentation == nil,
            let window, window.attachedSheet == nil, let surface = remoteSurface
        else { return }
        let presentation = RemoteWindowClosePresentation(controller: self, surface: surface, intent: intent)
        remoteClosePresentation = presentation
        presentation.present(on: window)
    }

    /// Creates the dynamic workspace menu without exposing its implementation.
    package static func makeRemoteWorkspaceMenu() -> NSMenu {
        RemoteWorkspaceMenu(title: "Remote Workspaces")
    }

    /// Rebuilds commands for every locally open remote workspace.
    package static func populateRemoteWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        var groups: [[TerminalWindowController]] = []
        for controller in spawnedControllers where !controller.isWindowClosed && !controller.isClosingWithHostTab {
            guard let drive = controller.remoteSurface?.drive else { continue }
            if let index = groups.firstIndex(where: { group in
                guard let other = group.first?.remoteSurface?.drive else { return false }
                return drive.sharesRemoteWorkspaceConnection(with: other)
            }) {
                groups[index].append(controller)
            } else {
                groups.append([controller])
            }
        }
        for group in groups {
            guard let first = group.first else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let workspace = first.remoteWorkspaceName.isEmpty ? "Workspace" : first.remoteWorkspaceName
            let host = first.remoteConnection?.hostLabel ?? first.remoteHostLabel
            let heading = menu.addItem(withTitle: "\(workspace) — \(host)", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            var surfaces = Set<Ubiquitty.Session.Layout.SurfaceID>()
            for controller in group {
                guard let surface = controller.remoteSurface,
                    surfaces.insert(surface.drive.remoteWorkspaceSurface).inserted
                else { continue }
                let action = RemoteWorkspaceMenuAction(controller: controller, surface: surface, intent: .closeWindow)
                let windowName = controller.window?.title ?? "Window \(surface.drive.remoteWorkspaceSurface.rawValue)"
                let item = menu.addItem(
                    withTitle: "Close Window on \(host): \(windowName)…",
                    action: #selector(RemoteWorkspaceMenuAction.invoke(_:)),
                    keyEquivalent: ""
                )
                item.target = action
                item.representedObject = action
                item.indentationLevel = 1
                item.toolTip = controller.window?.title
                item.isEnabled = surface.drive.remoteState == .Connected
            }
            if let surface = first.remoteSurface {
                let action = RemoteWorkspaceMenuAction(controller: first, surface: surface, intent: .detachWorkspace)
                let item = menu.addItem(
                    withTitle: "Detach from \(workspace)…",
                    action: #selector(RemoteWorkspaceMenuAction.invoke(_:)),
                    keyEquivalent: ""
                )
                item.target = action
                item.representedObject = action
                item.indentationLevel = 1
            }
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Open Remote Workspaces", action: nil, keyEquivalent: "").isEnabled = false
        }
    }
}
