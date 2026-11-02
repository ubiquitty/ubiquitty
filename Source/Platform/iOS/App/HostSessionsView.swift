// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyKit

import struct UbiquittyRenderKit.HostDaemonInstance
import struct UbiquittyRenderKit.HostOutlineIdentity
import struct UbiquittyRenderKit.HostOutlineRow
import class UbiquittyRenderKit.RuntimeDrive

/// What a host is holding, and the way into one of it.
///
/// A pushed screen between the host row and the terminal, the way Mail drills
/// from an account to its mailboxes: the host's name as the title and whether
/// it is connected under it; first the panes that need the person, each with
/// the one action that answers it; then the workspaces, two lines each, which
/// open to list their tabs; then the workspaces nothing runs in, saved to be
/// restored.
///
/// Nothing here decides anything. Which connect to make is Core's rule over the
/// host's tree, the saved host's workspace name and what this device was last
/// attached on (``TerminalSessionModel/decideHostAttach(on:)``); what each row
/// says, which panes need the person and what opening a row reaches are
/// Core's outline; what ending one asks is Core's question. This screen
/// forwards the plans that name a session and shows the outline for the plans
/// that ask.
struct HostSessionsView: View {
    let record: HostRecord
    /// The session this host's connection lives in — the same model the
    /// terminal draws, because the directory errand and the attach that follows
    /// share one carrier.
    let session: TerminalSessionModel
    /// The credential the directory errand authenticates with.
    let secret: String
    /// One visit explicitly asks to choose, without changing the saved name.
    var isExplicitChoice = false
    /// The split view decides whether this screen occupies its sidebar.
    /// A sidebar can itself report a compact horizontal size class.
    var isInSidebar = false
    /// Raised with the connect to make, once one is chosen.
    let onAttach: (HostAttachIntent) -> Void

    @Environment(\.supportsMultipleWindows)
    private var supportsMultipleWindows
    @Environment(\.openWindow)
    private var openWindow

    /// How the person orders the workspaces, kept across launches.
    @AppStorage("workspaceListOrder")
    private var order: WorkspaceOrder = .recent
    /// Core's question for ending what a row stands for, while it waits for an
    /// answer, and the row it was asked from, which the question points at.
    @State
    private var pendingEnding: PendingEnding?
    /// A sentence of Core's that answers a tap: why a row cannot be opened, or
    /// why there is nothing to ask about ending it.
    @State
    private var notice: WorkspaceNotice?
    /// Whether Core's plan has been read for this visit.
    ///
    /// Once, because the plans that name a session push the terminal: deciding
    /// again when the person comes back would push it a second time and leave
    /// them unable to return.
    @State
    private var hasReadThePlan = false
    /// The naming alert for a new workspace, while it is up.
    @State
    private var newWorkspace: WorkspaceNaming?
    /// The workspace being renamed.
    @State
    private var renaming: WorkspaceRename?
    /// The name typed into the naming or renaming alert.
    ///
    /// Apart from the alert's item, which the alert takes away before its
    /// button acts, so the button reads what was typed.
    @State
    private var draftName = ""
    /// Whether this connection's permission request is on screen.
    @State
    private var isAnsweringPermission = false

    @State
    private var selectedInstance: HostDaemonInstance?
    @State
    private var instanceSession: TerminalSessionModel?
    @State
    private var knownInstances: [HostDaemonInstance] = []
    @State
    private var defaultSocket = ""

    private var directorySession: TerminalSessionModel { instanceSession ?? session }

    var body: some View {
        VStack(spacing: 0) {
            if knownInstances.contains(where: { $0.socketName != defaultSocket }) {
                Picker(
                    "Running Sessions",
                    selection: Binding(
                        get: { selectedInstance?.socketName ?? "" },
                        set: selectInstance
                    )
                ) {
                    Text("Default Host").tag("")
                    ForEach(knownInstances.filter { $0.socketName != defaultSocket }) { instance in
                        Text(instance.title).tag(instance.socketName)
                    }
                }
                .padding(.horizontal)
                .accessibilityIdentifier("host-instance-picker")
            }
            content
        }
        .navigationTitle(record.displayName)
        .toolbarTitleDisplayMode(isInSidebar ? .inline : .large)
        .navigationSubtitle(Text(verbatim: subtitle))
        .toolbar { toolbar }
        // Every visit asks again: the person may have just left a
        // workspace they started, and the answer from before it does not
        // hold it.
        .task {
            if instanceSession == nil, session.hostInstance != nil {
                instanceSession = TerminalSessionModel()
            }
            directorySession.askHostForSessions(on: record, secret: secret)
        }
        // A wide layout keeps this sidebar mounted while the terminal
        // connects. Ask after the attach settles, when a newly created
        // workspace exists, rather than relying on another appearance.
        .onChange(of: directorySession.isConnected) { _, connected in
            if connected { refresh() }
        }
        .onChange(of: directorySession.hasFailed) { _, failed in
            if failed && !directorySession.isHostAnswerCurrent { refresh() }
        }
        .onChange(of: directorySession.hostSessionAnswers) { _, _ in
            rememberInstances()
            readThePlan()
        }
        .onDisappear { instanceSession?.disconnect() }
        .onChange(of: directorySession.reattachRefusal) { _, refusal in
            // The outline the person is looking at was answered before the
            // host refused, so it still offers the session that is gone.
            guard !refusal.isEmpty else { return }
            refresh()
        }
        .onChange(of: directorySession.lastTerminateReport?.id) { _, _ in
            // A session that ended is gone from the host's tree, and the tree
            // this screen draws is the one the host answered before it ended.
            guard directorySession.lastTerminateReport?.outcome == .terminated else { return }
            refresh()
        }
        .sensoryFeedback(trigger: directorySession.lastTerminateReport?.id) { _, id in
            guard id != nil else { return nil }
            return directorySession.lastTerminateReport?.outcome == .terminated ? .success : .error
        }
        .alert("New Workspace", item: $newWorkspace) { _ in
            TextField("Name", text: $draftName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") { createWorkspace() }
        } message: { _ in
            Text("The workspace keeps running on \(record.displayName) after you leave it.")
        }
        .alert("Rename Workspace", item: $renaming) { renaming in
            TextField("Name", text: $draftName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(renaming) }
        } message: { _ in
            Text("Leave the name empty to call the workspace after its folder.")
        }
        .alert(notice?.title ?? "", item: $notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(verbatim: notice.message)
        }
        .alert(
            "Couldn’t Rename Workspace",
            item: Binding(
                get: { directorySession.lastStructureRefusal },
                set: { if $0 == nil { directorySession.clearStructureRefusal() } }
            )
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { refusal in
            Text(verbatim: refusal.reason)
        }
        .alert(
            terminateTitle,
            item: Binding(get: { directorySession.lastTerminateReport }, set: { if $0 == nil { directorySession.clearTerminateReport() } })
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text(terminateDetail)
        }
        .sheet(isPresented: $isAnsweringPermission) {
            if let request = directorySession.consentRequest {
                TerminalConsentView(session: directorySession, request: request)
                    .sheetChrome()
            }
        }
        .onChange(of: directorySession.consentRequest?.id) { _, id in
            if id == nil { isAnsweringPermission = false }
        }
    }

    // MARK: - Content

    /// The list, or the one sentence that stands in for it.
    ///
    /// An empty list is the host's word only when the host answered and
    /// nothing has changed on it since, as far as this device knows: an
    /// answer from before this device connected says nothing about the
    /// workspace it started, so it is asked again rather than shown.
    @ViewBuilder
    private var content: some View {
        if !directorySession.hostOutline.rows.isEmpty || directorySession.consentRequest != nil {
            list
        } else if directorySession.isAskingHostForSessions
            || (directorySession.hasHostAnsweredSessions && !directorySession.isHostAnswerCurrent)
        {
            ProgressView("Getting workspaces from the host…")
                .accessibilityIdentifier("workspace-list-progress")
        } else if directorySession.hasHostAnsweredSessions {
            ContentUnavailableView {
                Label("No Workspaces", systemImage: InterfaceSymbol.workspaces)
            } description: {
                Text("Start a workspace to keep programs running on \(record.displayName) after you leave.")
            } actions: {
                Button("New Workspace") { beginNaming() }
                    .buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("workspace-list-empty")
        } else {
            ContentUnavailableView {
                Label("Couldn’t Ask the Host", systemImage: InterfaceSymbol.error)
            } description: {
                Text("Ubiquitty couldn’t get the list of workspaces from \(record.displayName). Check the connection, then try again.")
            } actions: {
                Button("Try Again") { refresh() }
                    .buttonStyle(.borderedProminent)
                Button("New Workspace") { beginNaming() }
            }
            .accessibilityIdentifier("workspace-list-unanswered")
        }
    }

    private var list: some View {
        let groups = order.sorted(WorkspaceGroup.groups(of: directorySession.hostOutline.rows))
        let live = groups.filter { !$0.isSaved }
        let saved = groups.filter(\.isSaved)
        let everyRow = directorySession.hostOutlineEveryRow.rows
        let needs = needsYou(in: everyRow)
        return List {
            if !needs.isEmpty || directorySession.consentRequest != nil {
                Section("Needs You") {
                    if let request = directorySession.consentRequest {
                        NeedsYouRow(
                            question: request.question,
                            place: "Permission request on this connection",
                            status: .blocked,
                            action: { isAnsweringPermission = true }
                        )
                        .accessibilityIdentifier("workspace-needs-permission")
                    }
                    ForEach(needs, id: \.row.key) { need in
                        NeedsYouRow(
                            question: need.row.needsYouTitle,
                            place: need.place,
                            status: need.row.status,
                            action: { respond(to: need.row) }
                        )
                        .accessibilityIdentifier("workspace-needs-\(Self.identifier(of: need.row))")
                    }
                }
            }
            if !live.isEmpty {
                Section("Workspaces") {
                    ForEach(live) { group in workspace(group, everyRow: everyRow) }
                }
            }
            if !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved) { group in workspace(group, everyRow: everyRow) }
                }
            }
        }
        .modifier(WorkspaceListStyle(isSidebar: isInSidebar))
        .refreshable { refresh() }
        .onAppear { directorySession.hostOutline.startRefreshingAges() }
        .onDisappear { directorySession.hostOutline.stopRefreshingAges() }
        .accessibilityIdentifier("workspace-list")
    }

    /// One workspace: its row, and its tabs while it is open.
    @ViewBuilder
    private func workspace(_ group: WorkspaceGroup, everyRow: [HostOutlineRow]) -> some View {
        let nestsPanes = isInSidebar
        if group.row.isExpandable {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { group.row.isExpanded },
                    set: { directorySession.hostOutline.setExpanded($0, group.row) }
                )
            ) {
                let disclosed = group.disclosedRows(nestsPanes: nestsPanes)
                let base = disclosed.map(\.depth).min() ?? 0
                ForEach(disclosed, id: \.key) { child in
                    Button {
                        open(child)
                    } label: {
                        WorkspaceChildRow(row: child, indent: nestsPanes ? child.depth - base : 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(Self.identifier(of: child))
                }
            } label: {
                workspaceButton(group, everyRow: everyRow)
            }
        } else {
            workspaceButton(group, everyRow: everyRow)
        }
    }

    /// A workspace's row: tapped, it opens; swiped and pressed, its actions.
    private func workspaceButton(_ group: WorkspaceGroup, everyRow: [HostOutlineRow]) -> some View {
        let row = group.row
        // The question is this row's only while it was asked from this row.
        let asked = Binding(
            get: { pendingEnding?.rowKey == row.key ? pendingEnding : nil },
            set: { if $0 == nil { pendingEnding = nil } }
        )
        return Button {
            open(row)
        } label: {
            WorkspaceRowLabel(group: group)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.identifier(of: row))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button("Open", systemImage: "play.fill") { open(row) }
                .tint(.green)
        }
        // Terminate rather than Delete: the row is running programs on
        // somebody's machine, and what the swipe asks the host to do is end
        // them. A tint rather than the destructive role, which starts the row
        // leaving before the question has been answered; no full swipe.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if Self.ending(of: row) != nil {
                Button("Terminate", systemImage: "xmark.octagon") { askToEnd(row) }
                    .tint(.red)
            }
            if row.id != nil {
                Button("Rename", systemImage: "pencil") { beginRenaming(row) }
                    .tint(.gray)
            }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { open(row) }
            if supportsMultipleWindows, let intent = intent(for: row) {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                    openWindow(value: WorkspaceWindowRequest(hostID: record.id, intent: intent))
                }
            }
            if row.id != nil {
                Button("Rename…", systemImage: "pencil") { beginRenaming(row) }
            }
            Button("Copy Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.title }
            if Self.ending(of: row) != nil {
                Divider()
                Button("Terminate…", systemImage: "xmark.octagon", role: .destructive) { askToEnd(row) }
            }
        } preview: {
            WorkspacePreview(group: group, everyRow: rows(under: row, in: everyRow))
        }
        // On the row, so the question points at the workspace it ends.
        .confirmationDialog(
            asked.wrappedValue?.confirmation.title ?? "",
            item: asked,
            titleVisibility: .visible
        ) { ending in
            Button(ending.confirmation.destructiveButton, role: .destructive) {
                directorySession.terminate(ending.request, target: ending.target, confirmedBy: ending.confirmation)
            }
            Button(ending.confirmation.safeButton, role: .cancel) {}
        } message: { ending in
            Text(verbatim: ending.confirmation.body)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isInSidebar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Workspace", systemImage: "plus", action: beginNaming)
                    sortPicker
                } label: {
                    Label("Workspace Actions", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("workspace-actions")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("New Workspace", systemImage: "plus", action: beginNaming)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    sortPicker
                } label: {
                    Label("Sort By", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
    }

    private var sortPicker: some View {
        Picker("Sort By", selection: $order) {
            ForEach(WorkspaceOrder.allCases) { order in
                Text(order.title).tag(order)
            }
        }
    }

    /// Under the title: whether the host is connected and how many
    /// workspaces it holds, or when it last answered.
    private var subtitle: String {
        let count = WorkspaceGroup.groups(of: directorySession.hostOutline.rows).count
        let workspaces = count == 1 ? "1 workspace" : "\(count) workspaces"
        if directorySession.isAskingHostForSessions && !directorySession.isHostAnswerCurrent {
            return "Checking…"
        }
        guard directorySession.hasHostAnsweredSessions else { return "Not connected" }
        if directorySession.isConnected { return "Connected · \(workspaces)" }
        guard let answeredAt = directorySession.hostAnsweredAt else { return workspaces }
        return "\(workspaces) · Updated \(answeredAt.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Needs You

    /// A pane that needs the person, and where it is.
    private struct Need {
        let row: HostOutlineRow
        let place: String
    }

    /// The panes Core gives a second line, each with the workspace it is in.
    ///
    /// - Parameter everyRow: The outline with every row open.
    /// - Returns: The panes, in Core's order.
    private func needsYou(in everyRow: [HostOutlineRow]) -> [Need] {
        var workspaceTitle = ""
        var needs: [Need] = []
        for row in everyRow {
            if row.level == .workspace { workspaceTitle = row.title }
            guard row.needsThePerson else { continue }
            let place = row.level == .workspace || row.title == workspaceTitle ? workspaceTitle : "\(workspaceTitle) · \(row.title)"
            needs.append(Need(row: row, place: place))
        }
        return needs
    }

    /// Answers a pane that needs the person: a permission request on this
    /// connection is answered in its sheet; anything else is answered where
    /// it is asked, in the pane.
    ///
    /// - Parameter row: The pane's row.
    private func respond(to row: HostOutlineRow) {
        if row.blockKind == .permission, directorySession.consentRequest != nil {
            isAnsweringPermission = true
            return
        }
        open(row)
    }

    /// The rows under a workspace, with every row open.
    private func rows(under workspace: HostOutlineRow, in everyRow: [HostOutlineRow]) -> [HostOutlineRow] {
        guard let start = everyRow.firstIndex(where: { $0.key == workspace.key }) else { return [] }
        return Array(everyRow[(start + 1)...].prefix { $0.level != .workspace })
    }

    // MARK: - Actions

    private func rememberInstances() {
        // A picked daemon that stopped gives way to the host's current one,
        // and is no longer offered: Core says when it is known gone.
        if let picked = selectedInstance, directorySession.isGone(picked) {
            knownInstances.removeAll { $0.socketName == picked.socketName }
            selectInstance("")
            return
        }
        if !directorySession.hostInstances.isEmpty { knownInstances = directorySession.hostInstances }
        if selectedInstance == nil, !directorySession.hostSessionDaemonSocketName.isEmpty {
            defaultSocket = directorySession.hostSessionDaemonSocketName
        }
    }

    private func selectInstance(_ socket: String) {
        let instance = knownInstances.first { $0.socketName == socket }
        guard socket.isEmpty || instance != nil else { return }
        instanceSession?.disconnect()
        instanceSession = nil
        selectedInstance = instance
        hasReadThePlan = true
        if instance != nil || session.hostInstance != nil {
            let directory = TerminalSessionModel()
            directory.hostInstance = instance
            instanceSession = directory
        }
        directorySession.askHostForSessions(on: record, secret: secret)
    }

    private func targeted(_ intent: HostAttachIntent) -> HostAttachIntent {
        intent.targeting(
            selectedInstance,
            socket: directorySession.hostSessionDaemonSocketName,
            daemon: directorySession.hostSessionDaemonInstanceID
        )
    }

    private func refresh() {
        directorySession.refreshHostSessions(on: record, secret: secret)
    }

    /// The connect opening a row makes, nil when it cannot be opened.
    private func intent(for row: HostOutlineRow) -> HostAttachIntent? {
        directorySession.attachIntent(for: row).map(targeted)
    }

    /// Opens what a row stands for, as Core's outline says it is opened.
    ///
    /// - Parameter row: The row tapped or chosen from its menu.
    private func open(_ row: HostOutlineRow) {
        guard let intent = directorySession.openHostOutlineRow(row).map(targeted) else {
            notice = WorkspaceNotice(title: "Can’t Open", message: row.open.obstacle)
            return
        }
        onAttach(intent)
    }

    /// Asks for a new workspace's name, suggesting one the host does not
    /// hold, since a name it holds opens that workspace instead.
    private func beginNaming() {
        let groups = WorkspaceGroup.groups(of: directorySession.hostOutline.rows)
        let taken = Set(groups.flatMap { [$0.row.title, $0.row.open.workspaceName] })
        var suggestion = "workspace"
        var number = 2
        while taken.contains(suggestion) {
            suggestion = "workspace \(number)"
            number += 1
        }
        draftName = suggestion
        newWorkspace = WorkspaceNaming()
    }

    /// Starts the workspace named in the alert; with no name, an unnamed one.
    ///
    /// A name the listed daemon holds opens that workspace there. Any other
    /// name creates one on the host's current daemon, unpinned.
    private func createWorkspace() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        newWorkspace = nil
        let isHeld = WorkspaceGroup.groups(of: directorySession.hostOutline.rows)
            .contains {
                $0.row.title == name || $0.row.open.workspaceName == name
            }
        if name.isEmpty {
            onAttach(.newSession)
        } else if isHeld {
            onAttach(targeted(directorySession.attachIntent(forWorkspace: name)))
        } else {
            onAttach(.workspace(name))
        }
    }

    private func beginRenaming(_ row: HostOutlineRow) {
        guard let id = row.id else { return }
        draftName = row.own.first?.name ?? ""
        renaming = WorkspaceRename(workspace: id)
    }

    private func rename(_ renaming: WorkspaceRename) {
        self.renaming = nil
        directorySession.renameWorkspace(renaming.workspace, to: draftName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The identifier a scenario finds a row by, the same as the shared
    /// outline's.
    static func identifier(of row: HostOutlineRow) -> String {
        if let id = row.id {
            return "host-outline-row-\(id.kind)-\(id.number)"
        }
        return "host-outline-row-\(row.level)-\(row.pathWorkspace)-\(row.pathWindow)-\(row.pathTab)-\(row.pathPane)"
    }

    /// Reads Core's plan for this host, and acts on it.
    ///
    /// Runs when an errand settles. One that settled without the host's answer
    /// has nothing for a plan to read: the wire carries no reason with an
    /// unanswered ask, and the screen that dials is the one that says why, in
    /// the host's words. So that case connects, rather than claiming on this
    /// screen that a host nobody heard from is holding nothing.
    private func readThePlan() {
        guard !isExplicitChoice else {
            hasReadThePlan = true
            return
        }
        guard !hasReadThePlan, !directorySession.hasBegunConnecting else { return }
        guard directorySession.hasHostAnsweredSessions, let decision = directorySession.decideHostAttach(on: record) else {
            onAttach(.newSession)
            return
        }
        hasReadThePlan = true
        switch decision.plan {
        case .attachNamed:
            onAttach(targeted(directorySession.attachIntent(forWorkspace: decision.workspaceName)))
        case .createNamed:
            // Created on the host's current daemon, not the one that listed.
            onAttach(.workspace(decision.workspaceName))
        case .createNew, .awaitListing:
            onAttach(.newSession)
        case .attachByID, .chooseFromList:
            // The plans that leave a session to pick: the person chooses,
            // because they asked for this screen by opening a host that names
            // no workspace.
            break
        }
    }

    /// What ending a row asks the host for, and about what: a workspace's row
    /// ends its sessions, a pane's row or one standing for a pane ends that
    /// pane's session. Nothing for a workspace nothing runs in, or for a
    /// window or tab of several panes.
    ///
    /// - Parameter row: The row.
    /// - Returns: The request and its target, nil when the row ends nothing.
    static func ending(of row: HostOutlineRow) -> (request: RuntimeDrive.HostDestructiveRequest, target: HostOutlineIdentity)? {
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

    /// Asks Core what ending a row would cost, and puts the question in front
    /// of the person, pointing at the row; where Core says there is nothing
    /// to ask, shows why.
    ///
    /// - Parameter row: The row the person asked to end.
    private func askToEnd(_ row: HostOutlineRow) {
        guard let ending = Self.ending(of: row) else { return }
        switch directorySession.terminateQuestion(ending.request, target: ending.target, hostName: record.displayName) {
        case .success(let confirmation):
            pendingEnding = PendingEnding(rowKey: row.key, request: ending.request, target: ending.target, confirmation: confirmation)
        case .failure(.refused(let sentence)):
            notice = WorkspaceNotice(title: "Can’t Terminate", message: sentence)
        case nil:
            notice = WorkspaceNotice(title: "Can’t Terminate", message: "The host hasn’t sent its list of workspaces yet.")
        }
    }

    /// The title for the outcome the host answered a terminate with.
    ///
    /// Five outcomes, five sentences: four of them leave the session running,
    /// and a frontend that folded them into "could not terminate" would have
    /// the person retrying a request somebody on the session refused.
    private var terminateTitle: String {
        // A request that never left the device is not one of the host's five
        // answers, and reading it as one names the wrong machine.
        if directorySession.lastTerminateReport?.didReachTheHost == false {
            return "Request Not Sent"
        }
        switch directorySession.lastTerminateReport?.outcome {
        case .terminated: return "Session Terminated"
        case .denied: return "Request Declined"
        case .timedOut: return "No Response"
        case .failed: return "Request Didn’t Reach the Host"
        case .refused: return "Host Refused the Request"
        case nil: return "Unrecognized Response"
        }
    }

    private var terminateDetail: String {
        guard let report = directorySession.lastTerminateReport else {
            return ""
        }
        guard report.didReachTheHost else {
            return "This device did not send the request. \(report.whyNotSent) Nothing on the host changed."
        }
        let named = "session \(report.sessionID)"
        switch report.outcome {
        case .terminated:
            return "The host ended \(named)."
        case .denied:
            return "Someone attached to \(named) declined the request. The session is still running."
        case .timedOut:
            return "No one attached to \(named) answered in time. The session is still running."
        case .failed:
            // Failed is Core's word for a request that never left the device, so
            // the host saw nothing and the session is untouched.
            return "The request to end \(named) didn’t reach the host. The session is still running."
        case .refused:
            return "The host refused the request to end \(named). The session is still running."
        case nil:
            return "The host sent a response about \(named) that this version of Ubiquitty doesn’t recognize. "
                + "Refresh to see the host’s current workspaces."
        }
    }
}

/// Core's question for ending what a row stands for, what answering it
/// sends, and the row it was asked from.
private struct PendingEnding: Identifiable {
    let id = UUID()
    let rowKey: HostOutlineRowKey
    let request: RuntimeDrive.HostDestructiveRequest
    let target: HostOutlineIdentity
    let confirmation: RuntimeDrive.HostDestructiveConfirmation
}

/// The list as its column wears it: grouped where it is the whole screen, a
/// sidebar where it stands beside the terminal it opened.
private struct WorkspaceListStyle: ViewModifier {
    let isSidebar: Bool

    func body(content: Content) -> some View {
        if isSidebar {
            content.listStyle(.sidebar)
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}

/// A workspace being renamed.
private struct WorkspaceRename: Identifiable {
    let workspace: HostOutlineIdentity

    var id: HostOutlineIdentity { workspace }
}

/// A new workspace being named.
private struct WorkspaceNaming: Identifiable {
    let id = UUID()
}

/// Why a tap did nothing, in Core's words under a title that names what was
/// asked.
private struct WorkspaceNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A workspace to open in a window of its own: the host, and the connect
/// that reaches the workspace.
struct WorkspaceWindowRequest: Hashable, Codable {
    let hostID: UUID
    let intent: HostAttachIntent
}
