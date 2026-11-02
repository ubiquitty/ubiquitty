// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import SwiftUI
import UbiquittyAppleCallbacks
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

/// Owns one host's administration channel and its last successful snapshot.
@MainActor
final class HostManagementModel: ObservableObject {
    typealias Wire = Ubiquitty.`Protocol`.Sync
    let server: HostServer
    /// The outline and its actions use the same shared client as Connect.
    let directory = HostDirectoryModel()
    @Published
    private(set) var snapshot = Wire.ManagementReply()
    @Published
    private(set) var isBusy = false
    @Published
    private(set) var status = ""
    @Published
    var issuedToken = ""
    /// The host's directory client, shared with the Connect window.
    private var endpoint: HostDirectoryEndpoint?
    private var pendingOperation = Wire.ManagementOperation.List

    init(server: HostServer) {
        self.server = server
        directory.point(at: server)
    }

    func refresh() {
        if endpoint == nil {
            guard case .success(let plan) = HostTransport.plan(for: server) else {
                status = "This host’s connection settings are incomplete."
                return
            }
            let shared = HostDirectoryClients.shared.endpoint(for: plan.shellCommand)
            shared.subscribe(self) { [weak self] in self?.receive() }
            endpoint = shared
        }
        directory.refresh()
        send(Wire.ManagementRequest())
    }

    /// Releases this window's watch without interrupting another reader.
    func stopFollowing() {
        directory.stopFollowing()
    }

    /// Core's details for every live session under the selected row.
    var selectedSessionDetails: [Ubiquitty.Runtime.HostSessionDetails] {
        _ = directory.outline.revision
        guard let row = directory.outline.row(for: directory.selection) else { return [] }
        return directory.sessionDetails(for: row)
    }

    func confirmTerminateSelection() {
        guard let row = directory.outline.row(for: directory.selection), let ending = directory.terminateRequest(for: row) else { return }
        directory.askToEnd(ending.request, ending.target, named: row.title)
    }

    func send(_ request: Wire.ManagementRequest) {
        guard !isBusy else { return }
        var request = request
        if request.operation != .List { request.daemonInstanceID = snapshot.daemonInstanceID }
        pendingOperation = request.operation
        isBusy = true
        status = "Contacting \(server.displayName)…"
        if endpoint?.manage(request) != true {
            isBusy = false
            status = "Refresh this host before making changes."
        }
    }

    private func receive() {
        guard let result = endpoint?.snapshot else { return }
        // The client is shared with the Connect window, so its listings and
        // terminates settle here too. Busy is the client's whole queue, which
        // holds this window's request until its own reply arrives.
        isBusy = endpoint?.isBusy == true
        if result.event == .Failed {
            status = "Couldn’t update this host: \(String(result.error)). The information shown may be out of date."
            return
        }
        guard result.event == .ManagementReply else { return }
        let reply = result.management
        guard reply.status == .Success else {
            status = String(reply.detail)
            return
        }
        if pendingOperation == .List {
            snapshot = reply
            status = reply.detail.empty() ? "Updated \(Date.now.formatted(date: .omitted, time: .standard))." : String(reply.detail)
        } else {
            if !reply.issuedToken.empty() { issuedToken = String(reply.issuedToken) }
            status = String(reply.detail)
            refresh()
        }
    }
}

private enum ManagementSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case clients = "Clients"
    case permissions = "Permissions"
    case tokens = "Tokens"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .sessions: "terminal"
        case .clients: "person.2"
        case .permissions: "hand.raised"
        case .tokens: "key"
        }
    }
}

private struct ManagementAction: Identifiable {
    let id = UUID()
    let title: String
    let target: String
    let request: Ubiquitty.`Protocol`.Sync.ManagementRequest
}

/// Presents live host facts with explicit, target-named administration actions.
private struct HostManagementView: View {
    @ObservedObject
    var model: HostManagementModel
    let presentQuestion: (HostDestructiveQuestion) -> Void
    @State
    private var section: ManagementSection? = .sessions
    @State
    private var action: ManagementAction?
    @State
    private var isIssuing = false
    @State
    private var handoffSessionID: UInt32?

    var body: some View {
        NavigationSplitView {
            List(ManagementSection.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if section == .sessions || section == nil {
                    sessions
                } else {
                    List {
                        switch section ?? .sessions {
                        case .sessions:
                            EmptyView()
                        case .clients:
                            if model.snapshot.clients.isEmpty { Text("No attached clients").foregroundStyle(.secondary) }
                            ForEach(Array(model.snapshot.clients), id: \.clientID) { client in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(String(client.label).isEmpty ? "Client \(client.clientID)" : String(client.label))
                                            .font(.headline)
                                        Text("\(String(client.principal)) · \(String(client.transport)) · Session \(client.sessionID)")
                                        Text("Attached \(date(client.attachedUnix))").foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Disconnect…") {
                                        var request = HostManagementModel.Wire.ManagementRequest()
                                        request.operation = .DisconnectClient
                                        request.clientID = client.clientID
                                        action = ManagementAction(
                                            title: "Disconnect Client",
                                            target: "Client \(client.clientID)",
                                            request: request
                                        )
                                    }
                                }
                            }
                        case .permissions:
                            if model.snapshot.grants.isEmpty { Text("No recorded permissions").foregroundStyle(.secondary) }
                            ForEach(Array(model.snapshot.grants.enumerated()), id: \.offset) { _, grant in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(String(grant.capability)).font(.headline)
                                        Text("\(String(grant.origin)) · \(String(grant.lifetime)) · Session \(grant.sessionID)")
                                        Text(String(grant.identity)).font(.caption).textSelection(.enabled)
                                        Text(
                                            "Granted \(date(grant.grantedUnix))\(grant.grantedBy.empty() ? "" : " by " + String(grant.grantedBy))"
                                        )
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Revoke…") {
                                        var request = HostManagementModel.Wire.ManagementRequest()
                                        request.operation = .RevokeGrant
                                        request.identity = grant.identifier
                                        action = ManagementAction(
                                            title: "Revoke Permission",
                                            target: String(grant.capability) + " for " + String(grant.identity),
                                            request: request
                                        )
                                    }
                                }
                            }
                        case .tokens:
                            if model.snapshot.tokens.isEmpty { Text("No issued tokens").foregroundStyle(.secondary) }
                            ForEach(Array(model.snapshot.tokens.enumerated()), id: \.offset) { _, token in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(String(token.label)).font(.headline)
                                        Text(String(HostManagementModel.Wire.scopeMaskToString(token.scopes)))
                                        Text(token.expiryUnix == 0 ? "No expiry" : "Expires \(date(token.expiryUnix))")
                                        Text(String(token.fingerprint)).font(.caption.monospaced()).textSelection(.enabled)
                                        Text(
                                            "Created \(date(token.createdUnix)) · Last used \(date(token.lastUsedUnix))\(token.lastUsedBy.empty() ? "" : " by " + String(token.lastUsedBy))"
                                        )
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Revoke…") {
                                        var request = HostManagementModel.Wire.ManagementRequest()
                                        request.operation = .RevokeToken
                                        request.identity = token.fingerprint
                                        action = ManagementAction(title: "Revoke Token", target: String(token.label), request: request)
                                    }
                                }
                            }
                        }
                    }
                    .disabled(model.isBusy)
                }
                Divider()
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                }
                .padding(12)
            }
            .navigationTitle("Manage \(model.server.displayName)")
            .navigationSubtitle(section?.rawValue ?? "Sessions")
            .toolbar {
                if section == .tokens {
                    Button("Issue Token…") { isIssuing = true }.disabled(model.isBusy || model.snapshot.daemonInstanceID == 0)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.isBusy)
            }
        }
        .task { model.refresh() }
        .onChangeCompatibility(of: model.directory.destructiveQuestion) {
            if let question = model.directory.destructiveQuestion { presentQuestion(question) }
        }
        .sheet(item: $action) { action in
            VStack(alignment: .leading, spacing: 16) {
                Text("\(action.title)?").font(.headline)
                Text("\(action.target) on \(model.server.displayName)").textSelection(.enabled)
                Text(
                    action.request.operation == .TerminateSession
                        ? "This stops the session and its processes. You can’t undo this action."
                        : "This changes access to the running host."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { self.action = nil }.keyboardShortcut(.cancelAction)
                    Button(action.title, role: .destructive) {
                        model.send(action.request)
                        self.action = nil
                    }
                }
            }
            .padding(24).frame(width: 460)
        }
        .sheet(isPresented: Binding(get: { handoffSessionID != nil }, set: { if !$0 { handoffSessionID = nil } })) {
            if let sessionID = handoffSessionID {
                HostHandoffView(
                    sessionID: sessionID,
                    daemonInstanceID: model.snapshot.daemonInstanceID,
                    host: model.server.isLocal ? "" : model.server.host
                )
            }
        }
        .sheet(isPresented: $isIssuing) { IssueHostTokenView(model: model) }
        .sheet(isPresented: Binding(get: { !model.issuedToken.isEmpty }, set: { if !$0 { model.issuedToken = "" } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Token Created").font(.headline)
                Text("Save this token now. The host stores only its fingerprint.")
                Text(model.issuedToken).font(.body.monospaced()).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Done") { model.issuedToken = "" }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 540)
        }
    }

    private var sessions: some View {
        VStack(spacing: 0) {
            if model.directory.outline.freshness == .stale {
                HostOutlineStaleBanner(message: model.directory.outline.watchError, retry: model.refresh)
            }
            HostSessionsOutline(
                directory: model.directory,
                open: { _ = model.directory.open($0) },
                copyLink: model.directory.copyLink,
                deleteSelection: model.confirmTerminateSelection
            ) { row in
                if row.level == .workspace, row.open.sessionID != 0 {
                    Button(HostWords.text(.continueOnAnotherDevice)) { handoffSessionID = row.open.sessionID }
                }
            } rowAccessory: { _ in
                EmptyView()
            }
            .searchable(text: Bindable(model.directory.outline).query)
            if model.directory.outline.rows.isEmpty, !model.directory.outline.isSearching {
                Text(String(model.directory.sectionWords.title))
                    .foregroundStyle(.secondary)
                    .padding()
            }
            if !model.selectedSessionDetails.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.selectedSessionDetails, id: \.sessionID) { detail in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(detail.title)).font(.headline)
                                Text(String(detail.directory))
                                Text(String(detail.placement)).foregroundStyle(.secondary)
                                LabeledContent(String(detail.creationLabel)) {
                                    Text(
                                        detail.createdUnixSeconds == 0
                                            ? String(detail.unknownCreationTime) : date(detail.createdUnixSeconds)
                                    )
                                }
                                Text(String(detail.origin))
                                Text(String(detail.sharing))
                                Text(String(detail.lifetime))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                .frame(maxHeight: 180)
                .accessibilityIdentifier("host-management-session-details")
            }
            if let notice = model.directory.notice {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                    if !notice.message.isEmpty { Text(notice.message).foregroundStyle(.secondary) }
                    if notice.askAgainSessionID != 0 {
                        Button(HostWords.text(.askAgain)) { model.directory.terminateAgain(notice.askAgainSessionID) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .accessibilityIdentifier("host-management-sessions-outline")
    }

    private func date(_ timestamp: UInt64) -> String {
        timestamp == 0
            ? "not recorded" : Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct IssueHostTokenView: View {
    @ObservedObject
    var model: HostManagementModel
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var label = ""
    @State
    private var expiry = Date.now.addingTimeInterval(86400)
    @State
    private var scopes: UInt8 = 0
    private let choices: [(String, UInt8)] = [
        ("Observe", 1), ("Send Input", 2), ("Control Sessions", 4), ("Read Screen", 8), ("Create Sessions", 16), ("Read Files", 32),
        ("Administer Host", 64),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Issue Token on \(model.server.displayName)").font(.headline)
            TextField("Label", text: $label)
            DatePicker("Expires", selection: $expiry, in: Date.now...)
            ForEach(choices, id: \.1) { title, bit in
                Toggle(title, isOn: Binding(get: { scopes & bit != 0 }, set: { if $0 { scopes |= bit } else { scopes &= ~bit } }))
            }
            Text("Administer Host allows changing permissions and issuing other tokens.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Issue Token") {
                    var request = HostManagementModel.Wire.ManagementRequest()
                    request.operation = .IssueToken
                    request.label = std.string(label)
                    request.scopes = HostManagementModel.Wire.ScopeSet.fromRaw(scopes)
                    request.expiryUnix = UInt64(expiry.timeIntervalSince1970)
                    dismiss()
                    model.send(request)
                }
                .disabled(label.isEmpty || label.utf8.count > 128 || scopes == 0)
            }
        }
        .padding(24).frame(width: 420)
    }
}

/// Retains administration windows only while they are open.
@MainActor
final class HostManagementWindows {
    static let shared = HostManagementWindows()
    private var windows: [UUID: Controller] = [:]
    func show(server: HostServer) {
        let controller = Controller(server: server)
        windows[controller.id] = controller
        controller.onClose = { [weak self] id in self?.windows.removeValue(forKey: id) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private final class Controller: NSWindowController, NSWindowDelegate {
        let id = UUID()
        var onClose: ((UUID) -> Void)?
        let model: HostManagementModel
        init(server: HostServer) {
            model = HostManagementModel(server: server)
            let window = NSWindow()
            window.title = "Manage \(server.displayName)"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 580))
            window.minSize = NSSize(width: 700, height: 440)
            window.isReleasedWhenClosed = false
            super.init(window: window)
            window.contentViewController = NSHostingController(
                rootView: HostManagementView(model: model) { [weak self] question in
                    self?.present(question)
                }
            )
            window.delegate = self
            window.center()
        }
        required init?(coder: NSCoder) { nil }
        func windowWillClose(_ notification: Notification) {
            model.stopFollowing()
            onClose?(id)
        }

        /// The shared alert keeps the safe button as Return and Escape.
        private func present(_ question: HostDestructiveQuestion) {
            guard let window else { return }
            _ = HostDestructiveAlert.present(question, for: model.directory, on: window)
        }
    }
}
