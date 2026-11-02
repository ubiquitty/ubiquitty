// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ConnectView.swift — the Connect window drawn: the places sidebar, the
// selected host's outline or state, the bottom bar whose default button is
// Core's plan said out loud, the toolbar with its search field, and the
// inspector for the selected host.
//
// Glass is the system's alone: the sidebar list, the toolbar and its search,
// the bottom bar's standard buttons and the sheets. Type is system text styles
// only. Every decision shown here is read off ConnectModel and
// HostDirectoryModel, which read it off Core; the outline's rows are Core's
// and are drawn by the outline views both Apple apps share.
//

import AppKit
import Combine
import SwiftUI
import UbiquittyCore
import UbiquittyKit

import struct UbiquittyRenderKit.HostOutlineOwn
import struct UbiquittyRenderKit.HostOutlineRow
import enum UbiquittyRenderKit.HostWords

/// The window's root view.
struct ConnectView: View {
    @Bindable
    var model: ConnectModel

    @FocusState
    private var isSearchFieldFocused: Bool

    @State
    private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConnectSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 260)
        } detail: {
            HSplitView {
                ConnectContent(model: model)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if model.isInspectorPresented {
                    ConnectInspector(model: model)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360, maxHeight: .infinity)
                }
            }
            // Bound both columns by the navigation proposal so changing
            // content cannot recursively expand the window's minimum size.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .navigationTitle(model.title(for: model.selection))
            .navigationSubtitle(model.subtitle)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search or Enter Address")
        .searchFocused($isSearchFieldFocused)
        .searchSuggestions {
            ForEach(model.suggestions) { suggestion in
                Button {
                    model.choose(suggestion)
                } label: {
                    Label(suggestion.title, systemImage: suggestion.symbol)
                }
                .disabled(suggestion.kind == .invalid)
            }
        }
        .onSubmit(of: .search) {
            // Return in the search field runs the first suggestion only when
            // it is explicit about connecting; typing alone never connects.
            if let first = model.suggestions.first, first.kind != .invalid {
                model.choose(first)
            }
        }
        .toolbar { ConnectToolbar(model: model) }
        .onChangeCompatibility(of: model.isSearchFocused) {
            if model.isSearchFocused {
                isSearchFieldFocused = true
                model.isSearchFocused = false
            }
        }
        .onExitCommand {
            if model.handleEscape() == .closeWindow {
                ConnectWindowController.shared.window?.performClose(nil)
            }
        }
        .sheet(item: $model.addHostDraft) { draft in
            AddHostSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $model.isNamingSession) {
            NewNamedSessionSheet(model: model)
        }
        .onChangeCompatibility(of: model.directory.destructiveQuestion) {
            // An alert rather than a SwiftUI sheet: the safe button has to
            // hold Return, which AppKit's alert decides by button order.
            if let question = model.directory.destructiveQuestion {
                ConnectWindowController.shared.present(question)
            }
        }
        .sheet(item: Bindable(model.directory).presentedQuestion) { question in
            HostAttachQuestionView(question: question) { candidate in
                if model.directory.answerQuestion(with: candidate) {
                    ConnectWindowController.closeAfterSpawn()
                }
            } startNew: {
                model.newSession()
            } cancel: {
                model.directory.presentedQuestion = nil
            }
        }
        .background(ConnectKeyCommands(model: model))
        .frame(minWidth: 720, minHeight: 440)
    }
}

// MARK: - Sidebar

private struct ConnectSidebar: View {
    @Bindable
    var model: ConnectModel

    var body: some View {
        // Only a different place is a selection. A report of the place
        // already selected, which the list may send as its rows reload, must
        // neither ask the host again nor clear what the place shows.
        List(
            selection: Binding(
                get: { model.selection },
                set: { place in
                    if place != model.selection {
                        model.select(place)
                    }
                }
            )
        ) {
            Section("This Mac") {
                placeRow(.thisMacHost, title: "Ubiquitty Host", symbol: "bolt.horizontal.circle", hostKey: "local")
                placeRow(.thisMacTmux, title: "tmux", symbol: "square.split.2x2", hostKey: nil)
                placeRow(.layouts, title: "Layouts", symbol: "rectangle.3.group", hostKey: nil)
                placeRow(.serialPorts, title: "Serial Ports", symbol: "cable.connector", hostKey: nil)
                placeRow(.shell(.ssh), title: "SSH Shell", symbol: "terminal", hostKey: nil)
                placeRow(.shell(.mosh), title: "mosh Shell", symbol: "antenna.radiowaves.left.and.right", hostKey: nil)
                placeRow(.shell(.remoteTmux), title: "tmux over SSH", symbol: "square.split.2x2", hostKey: nil)
            }
            Section("Hosts") {
                if model.listedHosts.isEmpty {
                    Button("Add Host…") { model.addHostDraft = HostServers.blankRemote() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.filteredHosts) { server in
                        // A row on this Mac's daemon names a session of its
                        // own; the daemon's count is This Mac's to show.
                        placeRow(
                            .host(server.id),
                            title: server.displayName,
                            symbol: server.kind.symbol,
                            hostKey: server.kind == .ubiquittyHost && !server.isLocal ? server.pairingKey : nil,
                            note: server.isLocal ? "This Mac" : nil
                        )
                        .contextMenu {
                            Button("Duplicate Host") { model.duplicateHost(server.id) }
                            Button("Manage “\(server.displayName)”…") { HostManagementWindows.shared.show(server: server) }
                            Divider()
                            Button("Remove Host") { model.removeHost(server.id) }
                        }
                    }
                    .onMove { source, destination in model.moveHosts(from: source, to: destination) }
                }
            }
            .sectionActions {
                Button("Add Host", systemImage: "plus") { model.addHostDraft = HostServers.blankRemote() }
            }
            if !model.recents.isEmpty {
                Section("Recent") {
                    ForEach(model.recents, id: \.self) { target in
                        placeRow(.recent(target), title: target, symbol: "clock", hostKey: target)
                            .contextMenu {
                                Button("Save as Host…") { model.addHostDraft = HostServers.blankRemote(host: target) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("connect-sidebar")
        .onDeleteCommand {
            if case .host(let id) = model.selection {
                model.removeHost(id)
            }
        }
    }

    private func placeRow(_ place: ConnectPlace, title: String, symbol: String, hostKey: String?, note: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let hostKey {
                accessory(for: hostKey, place: place)
            } else if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(place)
        .accessibilityIdentifier("connect-place-\(place.identifier)")
    }

    @ViewBuilder
    private func accessory(for hostKey: String, place: ConnectPlace) -> some View {
        let isSelected = model.selection == place
        let state = isSelected ? model.contentState : model.summaries[hostKey]?.state
        let count = isSelected ? model.directory.workspaceCount : model.summaries[hostKey]?.sessionCount
        let markWords = isSelected ? String(model.directory.sectionWords.markWords) : model.summaries[hostKey]?.markWords ?? ""
        HStack(spacing: 4) {
            if RemoteWindowRegistry.isShowingHost(hostKey) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(HostWords.text(.aWindowShowsThisHost))
            }
            switch state {
            case .askingCold where isSelected:
                ProgressView().controlSize(.small).accessibilityLabel(markWords)
            case .unreachable, .signInRequired, .authenticationAttemptsExhausted, .endedBeforeAnswer, .malformed, .refused:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityLabel(markWords)
            case .notInstalled:
                Image(systemName: "arrow.down.circle").accessibilityLabel(markWords)
            case .olderHost:
                Image(systemName: "arrow.up.circle").accessibilityLabel(markWords)
            case .needsToken, .tokenInvalid, .tokenExpired, .tokenRevoked, .tokenScope:
                Image(systemName: "lock.fill").accessibilityLabel(markWords)
            case .sessions, .empty:
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(HostDirectoryModel.sessionCount(count))
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Content

private struct ConnectContent: View {
    @Bindable
    var model: ConnectModel

    var body: some View {
        Group {
            switch model.selection {
            case .host(let id) where model.hosts.first(where: { $0.id == id })?.kind != .ubiquittyHost:
                if let server = model.hosts.first(where: { $0.id == id }) {
                    SavedShellContent(model: model, server: server)
                }
            case .thisMacTmux:
                TmuxSessionsPane(model: model)
            case .layouts:
                LayoutsPane(model: model)
            case .serialPorts:
                SerialPortsPane(model: model)
            case .thisMacHost, .host, .recent:
                HostPlaceContent(model: model)
            case .shell(let kind):
                ConnectForm(kind: kind).id(kind)
            case nil:
                ContentUnavailableView("Select a Place", systemImage: "sidebar.left")
            }
        }
        .onChangeCompatibility(of: model.directory.workspaceCount) { model.noteDirectoryChanged() }
        .onChangeCompatibility(of: model.directory.phase) { model.noteDirectoryChanged() }
    }
}

/// A host's outline, or the state its listing is in.
private struct HostPlaceContent: View {
    @Bindable
    var model: ConnectModel

    private var directory: HostDirectoryModel { model.directory }

    var body: some View {
        VStack(spacing: 0) {
            if !model.otherHostInstances.isEmpty {
                Picker("Running sessions", selection: Binding(get: { model.selectedHostSocket }, set: { model.selectHostInstance($0) })) {
                    Text("Default Host").tag("")
                    ForEach(model.otherHostInstances) { instance in
                        Text(instance.title).tag(instance.socketName)
                    }
                }
                .padding()
                Divider()
            }
            if let banner = model.visibleBanner {
                ConnectBannerView(model: model, banner: banner)
            }
            stateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The bar is opaque: a row scrolled beneath it is not drawn through
        // the sentence and the button.
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                ConnectBottomBar(model: model)
            }
            .background(.background)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        let state = model.contentState
        Group {
            switch state {
            case .sessions:
                SessionsOutline(model: model)
            case .askingCold:
                ContentUnavailableView {
                    Label {
                        Text(String(directory.sectionWords.title))
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                } description: {
                    Text(directory.primaryAction.sentence)
                }
            case .empty:
                ContentUnavailableView {
                    Label(String(directory.sectionWords.title), systemImage: "rectangle.stack")
                } description: {
                    Text(directory.primaryAction.sentence)
                }
            case .invalidAddress:
                ContentUnavailableView {
                    Label(String(directory.sectionWords.title), systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(ConnectModel.parse(model.selectedServer?.host ?? "").reason)
                } actions: {
                    Button("Edit Host…") { model.isInspectorPresented = true }
                        .buttonStyle(.borderedProminent)
                }
            case .hostBinaryMissing:
                ContentUnavailableView {
                    Label(String(directory.sectionWords.title), systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(String(directory.sectionWords.shortSentence))
                }
            default:
                RemedyStateView(model: model, state: state)
            }
        }
        .accessibilityIdentifier("connect-state-\(state.name)")
    }
}

/// A failed listing, with Core's remedies as its buttons.
private struct RemedyStateView: View {
    @Bindable
    var model: ConnectModel
    let state: ConnectContentState

    @State
    private var token = ""

    private var isTokenState: Bool {
        model.isTokenEntryRequested || [.needsToken, .tokenInvalid, .tokenExpired, .tokenRevoked, .tokenScope].contains(state)
    }

    var body: some View {
        let fact = model.remedyFact
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            VStack(spacing: 8) {
                Text(fact.sentence)
                    .textSelection(.enabled)
                if fact.versionTitle.isEmpty, let detail = model.directory.failure?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } actions: {
            if isTokenState {
                HStack(spacing: 12) {
                    SecureField("Paste token", text: $token)
                        .frame(maxWidth: 260)
                        .onSubmit { model.saveToken(token) }
                    Button("Save and Connect") { model.saveToken(token) }
                        .buttonStyle(.borderedProminent)
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(fact.remedies.enumerated()).filter { !isTokenState || $0.element != .enterToken }, id: \.offset) {
                    index,
                    remedy in
                    if index == 0 {
                        Button(model.title(for: remedy)) { model.perform(remedy) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("refusal-action-\(model.identifier(for: remedy))")
                    } else {
                        Button(model.title(for: remedy)) { model.perform(remedy) }
                            .accessibilityIdentifier("refusal-action-\(model.identifier(for: remedy))")
                    }
                }
            }
        }
    }

    private var title: String {
        let versionTitle = model.remedyFact.versionTitle
        return versionTitle.isEmpty ? String(model.directory.sectionWords.title) : versionTitle
    }

    private var symbol: String {
        switch state {
        case .unreachable: "network.slash"
        case .signInRequired, .authenticationAttemptsExhausted, .needsToken, .tokenInvalid, .tokenExpired, .tokenRevoked, .tokenScope: "key"
        case .notInstalled: "arrow.down.app"
        case .olderHost, .olderClient: "arrow.up.circle"
        default: "exclamationmark.triangle.fill"
        }
    }
}

/// One line above the content.
private struct ConnectBannerView: View {
    @Bindable
    var model: ConnectModel
    let banner: ConnectBanner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.message)
                if !banner.detail.isEmpty {
                    Text(banner.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            Spacer()
            switch banner.action {
            case .tryAgain:
                Button(HostWords.text(.tryAgain)) { model.directory.refresh() }
            case .undoRemoval:
                Button("Undo") { model.undoRemoval() }
            case .askAgain(let sessionID):
                Button(HostWords.text(.askAgain)) { model.directory.terminateAgain(sessionID) }
            case nil:
                EmptyView()
            }
            Button("Dismiss", systemImage: "xmark") { model.dismissBanner() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connect-banner")
    }
}

/// The footer the model composes, then the default button.
private struct ConnectBottomBar: View {
    @Bindable
    var model: ConnectModel

    var body: some View {
        let action = model.directory.primaryAction
        let footer = model.footer
        HStack(spacing: 12) {
            if let sentence = footer.sentence {
                // Two lines at most: a question Core asks is a whole sentence
                // and is read whole, with the buttons keeping their size.
                Text(sentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(sentence)
                    .accessibilityIdentifier("connect-sentence")
            }
            Spacer(minLength: 8)
            if footer.isNewSessionOffered {
                Button(HostWords.text(.newSession)) { model.newSession() }
                    .help(HostWords.text(.newSession) + " (⌥↩)")
                    .disabled(model.selectedServer == nil)
                    .accessibilityIdentifier("connect-new-session")
            }
            if action.effect == .waiting {
                ProgressView().controlSize(.small)
            }
            // Return reaches this button through ConnectWindow, which tells
            // ↩, ⌥↩ and ⌥⇧↩ apart by their exact modifiers.
            Button(action.title) { model.performPrimaryAction() }
                .buttonStyle(.borderedProminent)
                .disabled(!action.isEnabled)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("connect-primary")
        }
        .padding(12)
    }
}

// MARK: - Sessions outline

/// The selected host's outline: Core's rows, with this window's actions on
/// each and its own marks beside a workspace.
private struct SessionsOutline: View {
    @Bindable
    var model: ConnectModel

    var body: some View {
        VStack(spacing: 0) {
            HostSessionsOutline(
                directory: model.directory,
                open: open,
                copyLink: model.copyLink,
                deleteSelection: model.confirmTerminateSelection
            ) { _ in
                if let server = model.selectedServer {
                    Button("Manage “\(server.displayName)”…") { HostManagementWindows.shared.show(server: server) }
                }
            } rowAccessory: { row in
                rowAccessory(row)
            }
            if let ended = model.endedSessionName {
                HStack(spacing: 6) {
                    Text(ended)
                    Text(HostWords.text(.ended))
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("connect-session-ended")
            }
        }
        .accessibilityIdentifier("connect-sessions-outline")
    }

    private func open(_ row: HostOutlineRow) {
        #if UBIQUITTY_UI_TESTS
        if model.recordOpenForTesting(row) { return }
        #endif
        if model.directory.open(row) {
            ConnectWindowController.closeAfterSpawn()
        }
    }

    /// This window's own marks on a workspace's row: Core's word on which one
    /// a connect returns to, and whether a window here already shows it.
    @ViewBuilder
    private func rowAccessory(_ row: HostOutlineRow) -> some View {
        switch model.directory.marker(for: row) {
        case .lastUsed:
            Label(HostWords.text(.lastUsed), systemImage: "arrow.uturn.backward").font(.caption).foregroundStyle(.secondary)
        case .alwaysOpens:
            Label(HostWords.text(.alwaysOpens), systemImage: "pin").font(.caption).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
        if model.directory.isShownHere(row) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
                .accessibilityLabel(HostWords.text(.shownInAWindowHere))
        }
    }
}

/// The common outline and row actions used by Connect and host management.
/// Each window contributes only its additional actions and row accessories.
struct HostSessionsOutline<AdditionalActions: View, RowAccessory: View>: View {
    @Bindable
    var directory: HostDirectoryModel

    let open: (HostOutlineRow) -> Void
    let copyLink: (HostOutlineRow) -> Void
    let deleteSelection: () -> Void
    @ViewBuilder
    let additionalActions: (HostOutlineRow) -> AdditionalActions
    @ViewBuilder
    let rowAccessory: (HostOutlineRow) -> RowAccessory

    @State
    private var editing: EditTarget?

    @FocusState
    private var isOutlineFocused: Bool

    /// What an edit sheet is changing, with the text it opens on: what the
    /// row states the thing holds, so nothing already there is lost.
    private struct EditTarget: Identifiable {
        enum Kind {
            case workspaceName
            case tabName
            case label(HostOutlineOwn)
            case tags(HostOutlineOwn)
        }

        let kind: Kind
        let row: HostOutlineRow
        let title: String
        let text: String
        let prompt: String
        let id = UUID()
    }

    var body: some View {
        VStack(spacing: 0) {
            HostOutlineList(
                store: directory.outline,
                selection: Bindable(directory).selection,
                open: open,
                rowMenu: { row in rowMenu(row) },
                rowAccessory: { row in rowAccessory(row) }
            )
            .focused($isOutlineFocused)
            .defaultFocus($isOutlineFocused, true)
            .onDeleteCommand(perform: deleteSelection)
            if directory.outline.isSearching, directory.outline.rows.isEmpty {
                ContentUnavailableView.search(text: directory.outline.query)
                    .accessibilityIdentifier("connect-outline-no-matches")
            }
        }
        .sheet(item: $editing) { target in
            EditTextSheet(title: target.title, text: target.text, prompt: target.prompt) { text in
                switch target.kind {
                case .workspaceName: directory.renameWorkspace(target.row, to: text)
                case .tabName: directory.renameTab(target.row, to: text)
                case .label(let level): directory.setLabel(text, on: level)
                case .tags(let level):
                    directory.setTags(
                        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                        on: level
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: HostOutlineRow) -> some View {
        Button(HostWords.text(.open)) { open(row) }
        if directory.namesOneSession(row) {
            Button(HostWords.text(.copySessionLink)) { copyLink(row) }
        }
        // Every change below is offered where the row states what it would
        // change: a level it is or stands for, the tab it is, the moves the
        // host would accept. A row of a workspace nothing runs in states only
        // the workspace.
        if !row.own.isEmpty {
            Divider()
            Menu(HostWords.text(.label)) {
                ForEach(row.own, id: \.id) { level in
                    Button(HostWords.levelMenuTitle(level.id.kind)) {
                        editing = EditTarget(
                            kind: .label(level),
                            row: row,
                            title: HostWords.text(.label),
                            text: level.label,
                            prompt: HostWords.text(.noLabel)
                        )
                    }
                }
            }
            Menu(HostWords.text(.tags)) {
                ForEach(row.own, id: \.id) { level in
                    Button(HostWords.levelMenuTitle(level.id.kind)) {
                        editing = EditTarget(
                            kind: .tags(level),
                            row: row,
                            title: HostWords.text(.tags),
                            text: level.tags.joined(separator: ", "),
                            prompt: HostWords.text(.tagsSeparatedByCommas)
                        )
                    }
                }
            }
        }
        if row.level == .workspace, row.id != nil, row.workspaceState != .restorable {
            Button(HostWords.text(.renameSession)) {
                editing = EditTarget(
                    kind: .workspaceName,
                    row: row,
                    title: HostWords.text(.sessionName),
                    text: row.own.first { $0.id.kind == .workspace }?.name ?? "",
                    prompt: HostWords.text(.noName)
                )
            }
        }
        if let place = row.tabPlace {
            Button(HostWords.text(.renameTab)) {
                editing = EditTarget(
                    kind: .tabName,
                    row: row,
                    title: HostWords.text(.tabName),
                    text: row.own.first { $0.id == place.tab }?.name ?? "",
                    prompt: HostWords.text(.noName)
                )
            }
            Button(HostWords.text(.moveTabEarlier)) { directory.moveTab(place, earlier: true) }
                .disabled(!place.canMoveEarlier)
            Button(HostWords.text(.moveTabLater)) { directory.moveTab(place, earlier: false) }
                .disabled(!place.canMoveLater)
            if !place.destinations.isEmpty {
                Menu(HostWords.text(.moveTabToWindow)) {
                    ForEach(place.destinations, id: \.window) { destination in
                        Button(destination.title) { directory.moveTab(place, to: destination) }
                    }
                }
            }
        }
        Divider()
        additionalActions(row)
        // Each ends sessions, so each asks Core's question first and sends
        // nothing unless the person answers it with the button that goes
        // through.
        if let window = directory.window(of: row) {
            Button(HostWords.text(.closeWindow)) { directory.askToEnd(.closeWindow, window, named: row.title) }
        }
        if let ending = directory.terminateRequest(for: row) {
            Button(HostWords.text(.terminate)) { directory.askToEnd(ending.request, ending.target, named: row.title) }
        }
    }
}

/// One line of text, edited and committed.
private struct EditTextSheet: View {
    let title: String
    let prompt: String
    let commit: (String) -> Void

    @Environment(\.dismiss)
    private var dismiss
    @State
    private var text: String

    init(title: String, text: String, prompt: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.commit = commit
        _text = State(initialValue: text)
    }

    var body: some View {
        Form {
            Section(title) {
                TextField(title, text: $text, prompt: Text(prompt))
                    .labelsHidden()
                    .onSubmit(save)
                    .accessibilityIdentifier("connect-edit-field")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(HostWords.text(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(HostWords.text(.save)) { save() }
            }
        }
    }

    private func save() {
        dismiss()
        commit(text.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Toolbar

private struct ConnectToolbar: ToolbarContent {
    @Bindable
    var model: ConnectModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.selectedServer == nil)
                .help("Ask the host again (⌘R)")
                .accessibilityIdentifier("connect-refresh")
            Button("Add Host", systemImage: "plus") { model.addHostDraft = HostServers.blankRemote() }
                .help("Add a host")
            Menu("More", systemImage: "ellipsis.circle") {
                Button(HostWords.text(.newNamedSession)) { model.isNamingSession = true }
                    .disabled(model.selectedServer == nil)
                if let server = model.selectedServer {
                    Button("Manage “\(server.displayName)”…") { HostManagementWindows.shared.show(server: server) }
                }
                if case .host(let id) = model.selection {
                    Button("Duplicate Host") { model.duplicateHost(id) }
                }
                if let row = model.selectedRow, model.directory.namesOneSession(row) {
                    Button(HostWords.text(.copySessionLink)) { model.copyLink(for: row) }
                }
            }
        }
        ToolbarSpacer()
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.trailing") { model.isInspectorPresented.toggle() }
                .help("Show or hide the inspector (⌃⌘I)")
        }
    }
}

/// The window's chords, as buttons the hosting view answers before the menu
/// bar does.
///
/// Invisible rather than absent: a keyboard shortcut lives on a control in the
/// view tree, and these chords have no visible control of their own.
private struct ConnectKeyCommands: View {
    @Bindable
    var model: ConnectModel

    var body: some View {
        ZStack {
            Button("Refresh") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Toggle Inspector") { model.isInspectorPresented.toggle() }
                .keyboardShortcut("i", modifiers: [.control, .command])
            Button(HostWords.text(.terminateSession)) { model.confirmTerminateSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Undo Remove Host") { model.undoRemoval() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.pendingRemoval == nil)
            Button("Save as Host") { model.saveSelectionAsHost() }
                .keyboardShortcut("s", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Inspector

/// The fields one host's kind uses, edited as a draft that commits on Return
/// or when focus leaves.
private struct HostFields: View {
    @Binding
    var draft: HostServer
    let addressReason: String
    let commit: () -> Void

    var body: some View {
        Section("General") {
            TextField("Name", text: $draft.name)
                .onSubmit(commit)
                .accessibilityIdentifier("connect-inspector-name")
            Picker("Connect With", selection: Binding(get: { draft.kind }, set: { draft = draft.changingKind(to: $0) })) {
                ForEach(HostKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .accessibilityIdentifier("connect-inspector-kind")
        }
        if draft.kind == .serial {
            Section("Serial") {
                TextField("Device", text: $draft.device, prompt: Text("/dev/cu.usbserial"))
                    .onSubmit(commit)
                    .accessibilityIdentifier("connect-inspector-device")
                Picker("Baud", selection: $draft.baudRate) {
                    ForEach([Int32(9600), 19200, 38400, 57600, 115200, 230400], id: \.self) { rate in
                        Text(rate, format: .number.grouping(.never)).tag(rate)
                    }
                }
            }
        } else {
            Section {
                TextField("Address", text: $draft.host, prompt: Text("you@server.example"))
                    .onSubmit(commit)
                    .accessibilityIdentifier("connect-inspector-address")
            } header: {
                Text("Address")
            } footer: {
                if !addressReason.isEmpty {
                    Text(addressReason).font(.callout).foregroundStyle(.red)
                }
            }
        }
        switch draft.kind {
        case .ubiquittyHost:
            Section {
                TextField("Workspace Name", text: $draft.workspaceName, prompt: Text("Choose each time"))
                    .onSubmit(commit)
                    .accessibilityIdentifier("connect-inspector-session-name")
            } header: {
                Text("Session")
            } footer: {
                Text(
                    draft.workspaceName.isEmpty
                        ? "Connect asks which workspace to open when the host holds more than one."
                        : "Opens or creates “\(draft.workspaceName)” every time."
                )
                .font(.callout)
            }
        case .ssh, .mosh, .remoteTmux:
            Section("Shell") {
                if draft.kind == .remoteTmux {
                    TextField("Session", text: $draft.tmuxSession, prompt: Text("main"))
                        .onSubmit(commit)
                }
                if draft.kind == .ssh {
                    Toggle("Forward SSH Agent", isOn: $draft.shouldForwardAgent)
                }
                Picker("Locale", selection: $draft.localePolicy) {
                    ForEach(ConnectCharacterLocalePolicy.allCases) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
            }
        case .serial:
            EmptyView()
        }
    }
}

private struct ConnectInspector: View {
    @Bindable
    var model: ConnectModel

    @State
    private var draft = ConnectModel.thisMac
    @State
    private var addressReason = ""

    var body: some View {
        Group {
            if case .host(let id) = model.selection, let server = model.hosts.first(where: { $0.id == id }) {
                Form {
                    HostFields(draft: $draft, addressReason: addressReason, commit: commit)
                    if server.kind == .ubiquittyHost {
                        Section("Security") {
                            LabeledContent("Access Token") {
                                if model.hasToken {
                                    Button("Remove") { model.removeToken() }
                                } else {
                                    Text("None").foregroundStyle(.secondary)
                                }
                            }
                            Toggle(
                                "Trusted to Install",
                                isOn: Binding(
                                    get: { HostDirectory.isDeployTrusted(host: server.host) },
                                    set: { isTrusted in
                                        if isTrusted {
                                            HostDirectory.trustDeploy(host: server.host)
                                        } else {
                                            HostDirectory.revokeDeployTrust(host: server.host)
                                        }
                                    }
                                )
                            )
                            Button("Manage “\(server.displayName)”…") { HostManagementWindows.shared.show(server: server) }
                        }
                    }
                    Section {
                        Button("Remove Host…", role: .destructive) { model.removeHost(server.id) }
                    }
                }
                .formStyle(.grouped)
                .controlSize(.small)
                .onAppear { load(server) }
                .onChangeCompatibility(of: id) { load(server) }
                .onChangeCompatibility(of: draft.kind) { commit() }
                .onChangeCompatibility(of: draft.shouldForwardAgent) { commit() }
                .onChangeCompatibility(of: draft.localePolicy) { commit() }
                .onChangeCompatibility(of: draft.baudRate) { commit() }
                .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { notification in
                    // Leaving a field commits it: an edit is never lost to a
                    // focus change, and never written per keystroke either.
                    // AppKit broadcasts this notification for every control,
                    // including fields in other windows and old Connect views.
                    guard let control = notification.object as? NSControl,
                        control.window === ConnectWindowController.shared.window,
                        control.accessibilityIdentifier().hasPrefix("connect-inspector-")
                    else { return }
                    commit()
                }
            } else {
                ContentUnavailableView(
                    "No Host Selected",
                    systemImage: "sidebar.trailing",
                    description: Text("Select a saved host to edit it.")
                )
            }
        }
        .accessibilityIdentifier("connect-inspector")
    }

    private func load(_ server: HostServer) {
        draft = server
        addressReason = ""
    }

    private func commit() {
        guard case .host(let id) = model.selection, id == draft.id else { return }
        addressReason = model.updateHost(draft) ?? ""
    }
}

// MARK: - Sheets

private struct AddHostSheet: View {
    @Bindable
    var model: ConnectModel

    @Environment(\.dismiss)
    private var dismiss
    @State
    private var draft: HostServer

    init(model: ConnectModel, draft: HostServer) {
        self.model = model
        _draft = State(initialValue: draft)
    }

    private var reason: String { ConnectModel.validationReason(for: draft) }

    var body: some View {
        Form {
            HostFields(draft: $draft, addressReason: draft.host.isEmpty && draft.device.isEmpty ? "" : reason, commit: add)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }
                    .disabled(!reason.isEmpty)
            }
        }
    }

    private func add() {
        guard reason.isEmpty else { return }
        var server = draft
        if server.kind != .serial {
            let parsed = ConnectModel.parse(server.host)
            server.host = parsed.destination
            if server.name.isEmpty {
                server.name = parsed.host
            }
        }
        dismiss()
        model.addHost(server)
    }
}

// MARK: - Shells, tmux and serial

/// A saved shell host: what it opens, and the button that opens it.
private struct SavedShellContent: View {
    @Bindable
    var model: ConnectModel
    let server: HostServer

    var body: some View {
        Group {
            if let failure = model.launchFailure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(failure.sentence).textSelection(.enabled)
                } actions: {
                    Button("Edit Host…") { model.isInspectorPresented = true }
                }
                .accessibilityIdentifier("connect-state-\(failure.stateName)")
            } else {
                Form {
                    Section {
                        LabeledContent("Connect With") { Label(server.kind.title, systemImage: server.kind.symbol) }
                        if server.kind == .serial {
                            LabeledContent("Device", value: server.device)
                            LabeledContent("Baud") { Text(server.baudRate, format: .number.grouping(.never)) }
                        } else {
                            LabeledContent("Address", value: server.host)
                        }
                        if server.kind == .remoteTmux {
                            LabeledContent("Session", value: server.tmuxSession.isEmpty ? "main" : server.tmuxSession)
                        }
                        if server.kind == .ssh {
                            LabeledContent("Forward SSH Agent", value: server.shouldForwardAgent ? "On" : "Off")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 12) {
                Text(model.shellSentence(for: server))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("connect-sentence")
                Spacer()
                Button(model.shellTitle(for: server)) { model.openShell(server) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("connect-primary")
            }
            .padding(12)
        }
    }
}

/// The tmux sessions on this Mac.
private struct TmuxSessionsPane: View {
    @Bindable
    var model: ConnectModel

    @State
    private var selection: String?

    var body: some View {
        Group {
            if let failure = model.launchFailure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(failure.sentence).textSelection(.enabled)
                }
                .accessibilityIdentifier("connect-state-\(failure.stateName)")
            } else if model.tmuxSessions.isEmpty {
                ContentUnavailableView {
                    Label("No tmux Sessions on This Mac", systemImage: "square.split.2x2")
                } description: {
                    Text("New Session starts one in control mode.")
                }
            } else {
                Table(model.tmuxSessions, selection: $selection) {
                    TableColumn("Session", value: \.name)
                    TableColumn("Windows") { session in Text(session.windows, format: .number).monospacedDigit() }
                    TableColumn("Attached") { session in Text(session.attached == 0 ? "—" : "\(session.attached)").monospacedDigit() }
                }
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { names in
                    if let name = names.first { model.openTmux(session: name) }
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 12) {
                Spacer()
                Button("New Session") { model.openTmux(session: "new-session") }
                Button(selection.map { "Attach “\($0)”" } ?? "Attach") {
                    if let selection { model.openTmux(session: selection) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .onAppear { model.reloadTmuxSessions() }
    }
}

/// The serial devices attached to this Mac.
private struct SerialPortsPane: View {
    @Bindable
    var model: ConnectModel

    @State
    private var selection: String?
    @State
    private var baudRate: Int32 = 115200

    var body: some View {
        Group {
            if let failure = model.launchFailure {
                ContentUnavailableView {
                    Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(failure.sentence).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { model.launchFailure = nil }
                }
                .accessibilityIdentifier("connect-state-\(failure.stateName)")
            } else if model.serialDevices.isEmpty {
                ContentUnavailableView {
                    Label("No Serial Devices", systemImage: "cable.connector")
                } description: {
                    Text("Connect an adapter, then refresh.")
                } actions: {
                    Button("Refresh") { model.reloadSerialDevices() }
                }
                .accessibilityIdentifier("connect-state-serial-none")
            } else {
                List(model.serialDevices, id: \.self, selection: $selection) { device in
                    Label(device, systemImage: "cable.connector")
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 12) {
                Picker("Baud", selection: $baudRate) {
                    ForEach([Int32(9600), 19200, 38400, 57600, 115200, 230400], id: \.self) { rate in
                        Text(rate, format: .number.grouping(.never)).tag(rate)
                    }
                }
                .frame(maxWidth: 180)
                Spacer()
                Button("Open") {
                    if let selection { model.openSerial(device: selection, baudRate: baudRate) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .onAppear { model.reloadSerialDevices() }
    }
}

private struct NewNamedSessionSheet: View {
    @Bindable
    var model: ConnectModel

    @Environment(\.dismiss)
    private var dismiss
    @State
    private var name = ""

    var body: some View {
        let plan = model.directory.plannedConnect(named: name)
        let isTooLong = name.utf8.count > ConnectModel.maxWorkspaceNameLength
        Form {
            Section {
                TextField(HostWords.text(.sessionName), text: $name, prompt: Text("ci"))
                    .onSubmit(create)
            } footer: {
                if isTooLong {
                    Text(HostWords.sessionNameTooLong).font(.callout).foregroundStyle(.red)
                } else if plan?.plan == .attachNamed {
                    Text(HostWords.sessionNameTaken(name)).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(HostWords.text(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(plan?.plan == .attachNamed ? HostWords.openExisting(name) : HostWords.text(.create)) { create() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isTooLong)
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= ConnectModel.maxWorkspaceNameLength else { return }
        dismiss()
        if model.directory.newSession(named: trimmed) {
            ConnectWindowController.closeAfterSpawn()
        }
    }
}
