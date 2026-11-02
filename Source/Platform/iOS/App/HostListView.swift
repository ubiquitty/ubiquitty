// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittyKit

import struct UbiquittyRenderKit.HostOutlineRow

/// The saved hosts, and the way to a terminal on one.
struct HostListView: View {
    /// The workspace a window opened for one shows first, nil for a window
    /// that opens on the host list.
    var opening: WorkspaceWindowRequest?

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    /// The scheme the app is drawn in, from outside the override below.
    @Environment(\.colorScheme)
    private var systemScheme
    /// The scheme of the terminal on screen, nil when none is.
    @State
    private var terminalScheme: ColorScheme?
    @State
    private var searchText = ""
    @State
    private var isShowingSettings = false

    /// The hosts the search leaves: those it names, and the connected hosts
    /// holding a workspace, tab or pane it matches.
    private var filteredHosts: [HostRecord] {
        store.hosts.filter {
            searchText.isEmpty || isNamedBySearch($0) || liveOutline(of: $0).map { $0.matchCount > 0 } == true
        }
    }

    /// Whether the search names the host itself.
    private func isNamedBySearch(_ record: HostRecord) -> Bool {
        record.displayName.localizedCaseInsensitiveContains(searchText)
            || record.hostName.localizedCaseInsensitiveContains(searchText)
    }

    /// Keeps the last received rows while a returning screen reconnects its
    /// watch, so refresh does not discard the person's expanded tree.
    private func liveOutline(of record: HostRecord) -> HostOutlineStore? {
        guard let session = existingSession(for: record), session.isConnected, session.hasHostAnsweredSessions else { return nil }
        return session.hostListOutline
    }

    /// The hosts whose outline is live, so the search reaches each as it
    /// comes up.
    private var liveOutlineHostIDs: [UUID] {
        store.hosts.filter { liveOutline(of: $0) != nil }.map(\.id)
    }

    /// Hands the search to each connected host's outline, as Core reads a
    /// query: a host the search names keeps every row, and any other keeps
    /// the rows that match and the way to them.
    private func searchTheOutlines() {
        for record in store.hosts {
            guard let outline = existingSession(for: record)?.hostListOutline else { continue }
            outline.query = searchText.isEmpty || isNamedBySearch(record) ? "" : searchText
        }
    }

    private var openHosts: [HostRecord] {
        filteredHosts.filter { existingSession(for: $0)?.isLive == true }
    }

    private var savedHosts: [HostRecord] {
        filteredHosts.filter { existingSession(for: $0)?.isLive != true }
    }

    /// Borrows a model without creating a connection while the list is drawn.
    ///
    /// - Parameter record: The saved host whose current model is requested.
    /// - Returns: Its existing model, or nil when the host has not been opened.
    private func existingSession(for record: HostRecord) -> TerminalSessionModel? {
        sessions.hasSession(for: record.id) ? sessions.session(for: record.id) : nil
    }

    /// The app's one store, shared with the pairing Core writes through it.
    @State
    private var store = HostStore.shared
    @State
    private var backgroundRefresh = BackgroundRefreshCoordinator.shared
    @State
    private var cachedRecord: HostRecord?
    /// The live sessions, held here rather than in the screen that draws them, so going back
    /// keeps the connection. See SessionStore for why a view is the wrong owner.
    @State
    private var sessions = SessionStore()
    @State
    private var editedRecord: HostRecord?
    /// Where the new-host editor's zoom transition starts and ends.
    @Namespace
    private var editorTransition
    private static let addHostTransition = "add-host"
    @State
    private var openedRecord: HostRecord?
    /// The host whose sessions are being shown, nil when none is.
    @State
    private var listedRecord: HostRecord?
    @State
    private var isChoosingSessionExplicitly = false
    /// What the terminal about to be pushed should attach to.
    ///
    /// Beside the pushed record rather than inside it, the way the password is:
    /// a saved host is a document and this is a fact about one visit to it.
    @State
    private var attachIntent: HostAttachIntent = .newSession
    /// The host a delete is waiting on a confirmation for, nil when none is.
    @State
    private var recordAwaitingDeletion: HostRecord?
    /// Why the last save or delete was not wholly carried out, nil when it was.
    @State
    private var updateFailure: HostUpdateFailure?
    /// The connected hosts whose outline the person folded away.
    @State
    private var foldedOutlineHosts: Set<UUID> = []
    /// Core's sentence for a row of a host's outline that cannot be opened.
    @State
    private var outlineObstacle: OutlineObstacle?

    /// Which column a collapsed split view shows.
    ///
    /// Follows the records rather than being set beside them, so the column and
    /// what it would show cannot disagree: a compact window shows the detail
    /// exactly when a host is listed or opened.
    @State
    private var compactColumn: NavigationSplitViewColumn = .sidebar

    /// One split view at every width, never a stack swapped in for it.
    ///
    /// A window's width class changes under a live terminal — an iPhone that
    /// unfolds, a large iPhone turned sideways, an iPad window resized — and a
    /// container chosen by that class is torn down and rebuilt on each change,
    /// taking the terminal screen's state with it: the keyboard goes down, an
    /// open sheet closes, and a permission request on screen is dismissed
    /// unread. The split view collapses into a stack on a compact width and
    /// expands again on a regular one while keeping the detail column's views,
    /// so the terminal is the same view on both sides of the change.
    ///
    /// The sidebar is a stack of its own, Hosts then a host's Workspaces, the
    /// way Mail goes from accounts to mailboxes, and the terminal is the
    /// detail. Side by side — an iPad, an unfolded iPhone Duo — a workspace
    /// tapped in the sidebar replaces the terminal beside it without a push;
    /// collapsed, the terminal is pushed over the workspaces and going back
    /// returns to them.
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            NavigationStack {
                hostList
                    .navigationDestination(item: $listedRecord) { record in sessionsView(for: record) }
            }
        } detail: {
            NavigationStack {
                detail
            }
            // One stack per host, so a connection switch replaces the terminal
            // rather than handing the screen already built a new host.
            .id(openedRecord?.id)
        }
        .navigationSplitViewStyle(.balanced)
        // The terminal's bottom bar is hosted by the split view, not by the
        // stack the terminal is in, and its glass and glyphs take the scheme
        // of the environment here. While a terminal is on screen that is the
        // scheme of the terminal's ground, so the bar reads against the grid
        // it floats over. A sheet inherits this environment but draws its
        // ground in the window's scheme, so each sheet over the terminal sets
        // its scheme back with `sheetChrome()`.
        // At compact width only, where the split view is collapsed and the
        // terminal is the whole window. Beside a sidebar the override would
        // darken the sidebar too; there the terminal's bars are its own
        // navigation bar, which the terminal's stack colours itself.
        .environment(\.colorScheme, horizontalSizeClass == .compact ? terminalScheme ?? systemScheme : systemScheme)
        .environment(\.systemColorScheme, systemScheme)
        .onChange(of: systemScheme, initial: true) { _, scheme in
            sessions.setSystemAppearance(isDark: scheme == .dark)
        }
        .onPreferenceChange(TerminalGroundSchemeKey.self) { scheme in
            // Delivered on the main thread, where the view's state lives.
            MainActor.assumeIsolated { terminalScheme = scheme }
        }
        .onChange(of: compactColumn) { _, column in
            // Going back from the terminal in a collapsed split view leaves it;
            // the sidebar's own stack keeps the workspaces it was opened from.
            // In an expanded one the sidebar is beside the detail, and the
            // column says nothing about what the detail shows.
            guard column == .sidebar, horizontalSizeClass == .compact else { return }
            openedRecord = nil
        }
        .sheet(isPresented: $isShowingSettings) { AppSettingsView() }
        .sheet(item: $editedRecord) { record in
            let editor = HostEditorView(record: record, isNew: !store.hosts.contains { $0.id == record.id }) { saved, secret in
                saveHost(saved, secret: secret)
                // A model that failed or ended was dialled with what the
                // editor just changed, and the next open must dial what it
                // says now. A live connection is left running: the edit
                // changes where the next connect goes, not the shell open now.
                if sessions.hasSession(for: saved.id), !sessions.session(for: saved.id).isLive {
                    sessions.end(for: saved.id)
                }
            }
            // A new host's editor grows out of Add Host; an existing host's
            // was opened from its row or a failure, which is no toolbar item.
            Group {
                if store.hosts.contains(where: { $0.id == record.id }) {
                    editor
                } else {
                    editor.navigationTransition(.zoom(sourceID: Self.addHostTransition, in: editorTransition))
                }
            }
            .modifier(TrailingSheetPlacement())
        }
        .sheet(item: $cachedRecord) { record in
            BackgroundRefreshView(record: record) {
                cachedRecord = nil
                open(record)
            }
        }
        .modifier(HostUpdateFailureAlert(failure: $updateFailure))
        // At the root rather than on the screen that dialled: a sign-in can
        // ask while the terminal or the session list is still being pushed,
        // and a sheet requested from inside a presentation that is animating
        // in is dropped.
        .sheet(item: approvalPrompt) { prompt in
            if case .approval(let banner) = prompt.kind {
                SignInApprovalView(banner: banner, hostLabel: prompt.hostLabel) {
                    sessions.answerSignIn(prompt, with: nil)
                }
            }
        }
        .modifier(
            PasswordPromptAlert(prompt: sessions.pendingSignInPrompt) { prompt, password, savesPassword in
                sessions.answerSignIn(prompt, with: password, savesPassword: savesPassword)
            }
        )
        .onChange(of: openedRecord) { _, _ in detailDidChange() }
        .onChange(of: listedRecord) { _, _ in detailDidChange() }
        .task {
            sessions.onPasswordAccepted = { hostID, password in savePassword(password, for: hostID) }
            openRequestedWorkspace()
            openHostNamedByEnvironment()
            showRequestedCachedHost()
        }
        .onChange(of: backgroundRefresh.requestedHostID) { _, _ in showRequestedCachedHost() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            sessions.noteSuspension()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            sessions.resumeAfterSuspension()
        }
    }

    /// What the detail column shows: the terminal, or what to choose to get
    /// one — a workspace once a host's are listed, else a host.
    @ViewBuilder
    private var detail: some View {
        if let record = openedRecord {
            terminal(for: record)
        } else if listedRecord != nil {
            ContentUnavailableView(
                "Choose a Workspace",
                systemImage: InterfaceSymbol.workspace,
                description: Text("The workspace you choose opens here.")
            )
        } else {
            ContentUnavailableView(
                "Choose a Host",
                systemImage: "terminal",
                description: Text("Your remote workspaces appear here.")
            )
        }
    }

    private var hostList: some View {
        Group {
            if store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a host to open a terminal on it.")
                } actions: {
                    Button("Add Host") { editedRecord = HostRecord() }
                        .buttonStyle(.glassProminent)
                }
            } else {
                styled(
                    List {
                        if !openHosts.isEmpty {
                            Section("Open Connections") {
                                hostRows(openHosts)
                            }
                        }
                        if !savedHosts.isEmpty {
                            Section("Saved Hosts") {
                                hostRows(savedHosts)
                            }
                        }
                    }
                )
                .overlay {
                    if filteredHosts.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
        .navigationTitle("Hosts")
        .toolbarTitleDisplayMode(.large)
        // Each connected host's tree is followed while the list that shows
        // it is on screen, and let go once it is not.
        .onAppear { sessions.setHostOutlinesShown(true) }
        .onDisappear { sessions.setHostOutlinesShown(false) }
        .onChange(of: searchText, initial: true) { _, _ in searchTheOutlines() }
        .onChange(of: liveOutlineHostIDs) { _, _ in searchTheOutlines() }
        .alert("Can’t Open", item: $outlineObstacle) { _ in
            Button("OK", role: .cancel) {}
        } message: { obstacle in
            Text(verbatim: obstacle.message)
        }
        .confirmationDialog(
            "Delete “\(recordAwaitingDeletion?.displayName ?? "")”?",
            item: $recordAwaitingDeletion,
            titleVisibility: .visible
        ) { record in
            Button("Delete Host", role: .destructive) { delete(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(deletionMessage(for: record))
        }
        // The system's search item, which minimizes to a glass button in the
        // toolbar until it is tapped, as the system apps' lists search.
        .searchable(text: $searchText, prompt: "Search Hosts")
        .searchToolbarBehavior(.minimize)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityIdentifier("app-settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editedRecord = HostRecord()
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
            // The editor grows out of the button that opened it.
            .matchedTransitionSource(id: Self.addHostTransition, in: editorTransition)
        }
    }

    /// The list as its column wears it: grouped where it is the whole screen,
    /// a sidebar where it stands beside the host it opened.
    @ViewBuilder
    private func styled(_ list: some View) -> some View {
        if horizontalSizeClass == .compact {
            list.listStyle(.insetGrouped)
        } else {
            list.listStyle(.sidebar)
        }
    }

    /// Keeps both sections on the same navigation and destructive-action paths.
    ///
    /// - Parameter records: Hosts in their saved order within one section.
    /// - Returns: Rows that open, edit, or ask before deleting those hosts.
    private func hostRows(_ records: [HostRecord]) -> some View {
        ForEach(records) { record in
            if let outline = liveOutline(of: record) {
                // A connected host discloses what it holds beneath its row;
                // a search holds the disclosure open on what it matched.
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { !searchText.isEmpty || !foldedOutlineHosts.contains(record.id) },
                        set: { isExpanded in
                            if isExpanded {
                                foldedOutlineHosts.remove(record.id)
                            } else {
                                foldedOutlineHosts.insert(record.id)
                            }
                        }
                    )
                ) {
                    HostLiveOutlineRows(
                        hostName: record.displayName,
                        store: outline,
                        isNestingPanes: horizontalSizeClass == .regular,
                        open: { row in open(row, on: record) }
                    )
                } label: {
                    hostRow(record, showsDisclosure: false)
                }
            } else {
                hostRow(record, showsDisclosure: horizontalSizeClass == .compact)
            }
        }
    }

    /// One host's row, with its swipe actions and its menu.
    ///
    /// - Parameters:
    ///   - record: The host.
    ///   - showsDisclosure: Whether the row shows that tapping it pushes.
    /// - Returns: The row.
    private func hostRow(_ record: HostRecord, showsDisclosure: Bool) -> some View {
        let session = existingSession(for: record)
        let openTitle = session?.isLive == true ? "Open" : "Connect"
        // Beside its detail, the list marks the host the detail shows;
        // collapsed, the detail covers the list and there is nothing to mark.
        let isSelected =
            horizontalSizeClass != .compact && (openedRecord?.id == record.id || listedRecord?.id == record.id)
        return Button {
            open(record)
        } label: {
            HostRow(record: record, session: session, showsDisclosure: showsDisclosure)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.25) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(session?.isLive == true ? "Open connection" : "Saved host")
        .accessibilityHint(session?.hasFailed == true ? session?.statusDetail ?? "" : "")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(openTitle, systemImage: "play.fill") { open(record) }
                .tint(.green)
        }
        // A full swipe cannot remove the host's saved credential.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash") { recordAwaitingDeletion = record }
                .tint(.red)
            Button("Edit", systemImage: "pencil") { editedRecord = record }
                .tint(.blue)
        }
        .contextMenu {
            Button(openTitle, systemImage: "play") { open(record) }
            Button("Edit", systemImage: "pencil") { editedRecord = record }
            if record.isBackgroundRefreshEnabled {
                Button("Cached Status", systemImage: "clock.arrow.circlepath") { cachedRecord = record }
            }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                recordAwaitingDeletion = record
            }
        }
    }

    /// The host's sessions, rebuilt whenever the store replaces the model
    /// behind them, so a screen never keeps drawing a model that was ended.
    private func sessionsView(for record: HostRecord) -> some View {
        let session = sessions.session(for: record.id)
        return HostSessionsView(
            record: record,
            session: session,
            secret: secret(for: record),
            isExplicitChoice: isChoosingSessionExplicitly,
            isInSidebar: horizontalSizeClass == .regular,
            onAttach: { intent in
                isChoosingSessionExplicitly = false
                attachIntent = intent
                openedRecord = record
            }
        )
        .id(ObjectIdentifier(session))
    }

    /// Opens a row of a connected host's outline: attaches to its workspace
    /// and shows its tab and pane, by the attach a pick on the host's
    /// workspaces screen makes, with no stop on that screen.
    ///
    /// - Parameters:
    ///   - row: The row tapped.
    ///   - record: The host it is under.
    private func open(_ row: HostOutlineRow, on record: HostRecord) {
        guard let intent = sessions.session(for: record.id).openHostOutlineRow(row) else {
            outlineObstacle = OutlineObstacle(message: row.open.obstacle)
            return
        }
        isChoosingSessionExplicitly = false
        listedRecord = nil
        attachIntent = intent
        openedRecord = record
    }

    /// The host's terminal, rebuilt whenever the store replaces the model
    /// behind it, so the new model is the one that connects.
    private func terminal(for record: HostRecord) -> some View {
        let session = sessions.session(for: record.id)
        return TerminalScreenView(
            record: record,
            session: session,
            attach: attachIntent,
            onHostKeyPinned: { fingerprint in
                store.pinFingerprint(fingerprint, for: record.id)
            },
            onThemeChosen: { name in
                store.setThemeName(name, for: record.id)
            },
            onLeave: { openedRecord = nil },
            onChooseSession: {
                isChoosingSessionExplicitly = true
                listedRecord = record
                openedRecord = nil
            },
            onCreateSession: {
                attachIntent = .newSession
                session.connect(to: record, secret: secret(for: record), attach: .newSession)
            },
            onEditHost: { editedRecord = record },
            onSwitchConnection: { step in switchConnection(from: record, step) }
        )
        // When it last connected is what the list says of a host with
        // nothing open. Noted as the connection is made, which is the one
        // moment certain to pass through this screen.
        .onChange(of: session.isConnected) { _, isConnected in
            if isConnected { store.noteConnection(for: record.id) }
        }
        // One screen per model, and so per host: a switch between connections
        // or a replaced model rebuilds the screen rather than handing the old
        // one a new session, whose state — the keyboard, an open sheet, the
        // callbacks wired on appear — belongs to the connection it was drawn for.
        .id(ObjectIdentifier(session))
    }

    /// Moves from one open connection to its neighbour in the host list.
    ///
    /// The route a tap on a connected host takes: the session list is left
    /// behind, and the terminal opens on whatever its session is already
    /// attached to. The arrival is named on the destination's own model, which
    /// is what the screen being opened draws.
    ///
    /// - Parameters:
    ///   - record: The host whose terminal was swiped.
    ///   - step: Which neighbour.
    private func switchConnection(from record: HostRecord, _ step: SwipeStep) {
        let choice = TerminalSwipeNavigation.connectionSwitch(
            from: record.id,
            hosts: store.hosts.map(\.id),
            isOpen: { sessions.hasSession(for: $0) && sessions.session(for: $0).hasBegunConnecting },
            step: step
        )
        guard let destinationID = choice.destination,
            let destination = store.hosts.first(where: { $0.id == destinationID })
        else {
            sessions.session(for: choice.announcedOn).announce(TerminalSwipeNavigation.onlyOneConnectionNotice)
            return
        }
        let session = sessions.session(for: choice.announcedOn)
        session.announce(
            TerminalSwipeNavigation.connectionNotice(hostName: destination.displayName, sessionSummary: session.sessionSummary)
        )
        attachIntent = session.currentAttachIntent
        listedRecord = nil
        openedRecord = destination
    }

    /// Goes wherever this host's next screen is.
    ///
    /// A host already connected goes back to its terminal, a host that holds no
    /// sessions to list has none to choose from, and a host that names a
    /// workspace has already answered the question the list would ask. What is
    /// left is the screen that asks it.
    ///
    /// Which connect the workspace name implies is Core's answer and not this
    /// file's: a host that names one attaches to the session bearing it and
    /// creates one under it when nothing does, and asking `decide` with an
    /// unanswered listing is how that reaches the attach door without a
    /// directory errand nobody would read the result of. A plan that leaves the
    /// choice open goes to the list, which is the screen that asks the host.
    private func proceed(to record: HostRecord) {
        isChoosingSessionExplicitly = false
        if sessions.hasSession(for: record.id), sessions.session(for: record.id).isLive {
            attachIntent = sessions.session(for: record.id).currentAttachIntent
            openedRecord = record
            return
        }
        guard record.canListSessions else {
            attachIntent = .newSession
            openedRecord = record
            return
        }
        guard record.workspaceName.isEmpty else {
            let decision = HostDirectory.decideBeforeListing(
                host: record.pairingKey,
                predefinedWorkspaceName: record.workspaceName
            )
            guard let intent = Self.intent(for: decision) else {
                listedRecord = record
                return
            }
            attachIntent = intent
            openedRecord = record
            return
        }
        listedRecord = record
    }

    /// One of Core's plans, as the attach door spells it.
    ///
    /// - Parameter decision: What Core's connect rule answered.
    /// - Returns: The connect to make, or nil when the plan leaves the session
    ///   to be picked from the host's list.
    private static func intent(for decision: HostAttachDecision) -> HostAttachIntent? {
        switch decision.plan {
        case .attachByID:
            return nil
        case .createNamed, .attachNamed:
            return .workspace(decision.workspaceName)
        case .createNew:
            return .newSession
        case .chooseFromList, .awaitListing:
            return nil
        }
    }

    /// Removes a confirmed host: its session first, then the record and the
    /// secret stored with it.
    ///
    /// The session goes first because it holds a carrier dialled with that
    /// secret, and a connection outliving the record it was opened for is one
    /// nothing on screen can reach to close.
    private func delete(_ record: HostRecord) {
        if openedRecord?.id == record.id {
            openedRecord = nil
        }
        if listedRecord?.id == record.id {
            listedRecord = nil
        }
        sessions.end(for: record.id)
        guard backgroundRefresh.revoke(record) else {
            var disabled = record
            disabled.isBackgroundRefreshEnabled = false
            disabled.backgroundRefreshPermissionID = nil
            let didSave = store.save(disabled)
            report(
                .storage(
                    didSave
                        ? "Check While Away is off, but some of its saved data couldn’t be removed. Try deleting this host again."
                        : "The host’s settings and background data couldn’t be fully removed. Check While Away is paused. Try deleting this host again before you close Ubiquitty."
                ),
                for: record
            )
            backgroundRefresh.settingsChanged()
            return
        }
        if let index = store.hosts.firstIndex(where: { $0.id == record.id }) {
            if !store.remove(atOffsets: [index]) {
                report(
                    .storage("Protected session data couldn’t be removed. Unlock this device, then try deleting the host again."),
                    for: record
                )
            }
        }
        backgroundRefresh.settingsChanged()
    }

    /// What deleting a host takes with it, so the question names the cost.
    private func deletionMessage(for record: HostRecord) -> String {
        var sentences: [String] = []
        if SecretStore.secret(for: record.id) != nil {
            sentences.append(
                record.savedCredential == .privateKey
                    ? "Its private key is deleted from the keychain."
                    : "Its saved password is deleted from the keychain."
            )
        }
        if sessions.hasSession(for: record.id), sessions.session(for: record.id).isLive {
            sentences.append("Its open connection is closed.")
        }
        sentences.append("This can’t be undone.")
        return sentences.joined(separator: " ")
    }

    /// What the keychain holds for this host, empty when nothing is saved.
    private func secret(for record: HostRecord) -> String {
        SecretStore.secret(for: record.id) ?? ""
    }

    /// The sign-in prompt a session is waiting on the person for.
    ///
    /// Put away by the session when the server answers; the prompt's own
    /// buttons answer it, so dismissing the sheet changes nothing here.
    private var approvalPrompt: Binding<SignInPrompt?> {
        Binding(
            get: {
                guard let prompt = sessions.pendingSignInPrompt, case .approval = prompt.kind else { return nil }
                return prompt
            },
            set: { _ in }
        )
    }

    /// Keeps a password the server accepted for a host whose sign-in may keep
    /// one, through the keychain path the host editor saves with.
    ///
    /// - Parameters:
    ///   - password: The password the server accepted.
    ///   - hostID: The host it was typed for.
    private func savePassword(_ password: String, for hostID: UUID) {
        guard var record = store.hosts.first(where: { $0.id == hostID }), record.canSavePromptedPassword,
            (SecretStore.secret(for: hostID) ?? "").isEmpty
        else { return }
        guard SecretStore.save(password, for: hostID) else {
            report(.secretNotSaved, for: record)
            return
        }
        record.authenticationKind = .password
        if !store.save(record) { report(.secretNotSaved, for: record) }
    }

    /// Shows the detail column when a host is listed or opened.
    private func detailDidChange() {
        compactColumn = openedRecord != nil ? .detail : .sidebar
    }

    /// Opens a host named by the environment, for a driver that cannot tap.
    ///
    /// The screen this reaches is the one a person reaches, rather than a
    /// parallel path built for testing: a harness that drove its own view would
    /// prove that view works and say nothing about the app. `first` is accepted
    /// alongside an identifier so a scenario can seed one host and open it
    /// without knowing the identifier it just generated.
    /// Opens the workspace this window was opened for, straight into its
    /// terminal.
    ///
    /// The window keeps its own connection, as a second device would: the
    /// workspace stays the host's, and each window is one more client on it.
    private func openRequestedWorkspace() {
        guard let opening, openedRecord == nil, listedRecord == nil,
            let record = store.hosts.first(where: { $0.id == opening.hostID })
        else { return }
        attachIntent = opening.intent
        openedRecord = record
    }

    private func openHostNamedByEnvironment() {
        guard let requested = ProcessInfo.processInfo.environment["UBIQUITTY_IOS_OPEN_HOST"],
            !requested.isEmpty, openedRecord == nil, listedRecord == nil
        else {
            return
        }
        if let first = store.hosts.first, requested == "first" {
            proceed(to: first)
            return
        }
        if let named = store.hosts.first(where: { $0.id.uuidString == requested }) {
            proceed(to: named)
        }
    }

    /// Saves background authorization only after its separate keychain copy succeeds.
    private func saveHost(_ record: HostRecord, secret: String?) {
        var saved = record
        updateFailure = nil
        let previous = store.hosts.first { $0.id == saved.id }
        if saved.isBackgroundRefreshEnabled {
            saved.backgroundRefreshPermissionID = previous?.backgroundRefreshPermissionID ?? UUID()
            if let old = previous?.backgroundRefreshAuthorization, let proposed = saved.backgroundRefreshAuthorization,
                secret == nil, old.hasSameEndpoint(as: proposed)
            {
                saved.backgroundRefreshPermissionID = old.permissionID
            } else {
                saved.backgroundRefreshPermissionID = UUID()
            }
        } else {
            saved.backgroundRefreshPermissionID = nil
        }
        if let previous, previous.backgroundRefreshAuthorization != saved.backgroundRefreshAuthorization,
            !backgroundRefresh.revoke(previous)
        {
            saved.isBackgroundRefreshEnabled = false
            saved.backgroundRefreshPermissionID = nil
            report(
                .storage(
                    "Check While Away is paused, but some of its old data couldn’t be removed. Leave Check While Away off and save again."
                ),
                for: saved
            )
        }
        // A host that asks each time keeps nothing: a secret left behind by
        // the method it had before is one nobody can see in order to delete.
        if saved.authenticationKind == .passwordPrompt { SecretStore.remove(for: saved.id) }
        let didSaveSecret = secret.map { SecretStore.save($0, for: saved.id) } ?? true
        if !didSaveSecret { report(.secretNotSaved, for: saved) }
        if saved.isBackgroundRefreshEnabled {
            if didSaveSecret, let stored = SecretStore.secret(for: saved.id), BackgroundRefreshSecretStore.save(stored, for: saved) {
                backgroundRefresh.requestNotificationPermission()
            } else {
                saved.isBackgroundRefreshEnabled = false
                report(.backgroundRefreshRefused, for: saved)
            }
        }
        if !saved.isBackgroundRefreshEnabled {
            saved.backgroundRefreshPermissionID = nil
            if !backgroundRefresh.revoke(saved) {
                report(
                    .storage("Check While Away is paused, but some of its saved data couldn’t be removed. Save again to retry."),
                    for: saved
                )
            }
        }
        if !store.save(saved) {
            let didRevoke = backgroundRefresh.revoke(saved)
            saved.isBackgroundRefreshEnabled = false
            saved.backgroundRefreshPermissionID = nil
            _ = store.save(saved)
            report(
                .storage(
                    didRevoke
                        ? "The host’s settings couldn’t be saved, and background access was removed. Save this host again."
                        : "The host’s settings couldn’t be saved, and background access couldn’t be removed. Check While Away is paused. Save this host again before you close Ubiquitty."
                ),
                for: saved
            )
        }
        backgroundRefresh.settingsChanged()
    }

    /// Records why a save or delete fell short, keeping the more telling
    /// cause when one change fails in more than one way.
    private func report(_ cause: HostUpdateFailure.Cause, for record: HostRecord) {
        if let updateFailure, updateFailure.cause.rank > cause.rank { return }
        updateFailure = HostUpdateFailure(hostName: record.displayName, cause: cause)
    }

    /// Opens cached context on a notification tap without attaching or changing host focus.
    private func showRequestedCachedHost() {
        guard let identifier = backgroundRefresh.requestedHostID else { return }
        backgroundRefresh.requestedHostID = nil
        cachedRecord = store.hosts.first { $0.id == identifier }
    }
}

/// Core's sentence for why a row of a host's outline cannot be opened.
private struct OutlineObstacle: Identifiable {
    let id = UUID()
    let message: String
}

/// One row: which host, where it is, and how it stands now.
///
/// What a person scans a host list for, and nothing more. How the host signs
/// in, its pinned key and its background refresh are the host's settings, and
/// they are in its editor.
private struct HostRow: View {
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    let record: HostRecord
    let session: TerminalSessionModel?
    /// Whether the row shows that tapping it pushes a screen: a collapsed
    /// split view pushes, a sidebar beside its detail selects.
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    identity
                    trailing
                }
            } else {
                identity
                Spacer(minLength: 8)
                trailing
            }
            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The host's kind, name and address, read as one label so the list's
    /// separator starts where its text does.
    private var identity: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    ForEach(Array(hostLabel.tags.enumerated()), id: \.offset) { _, tag in
                        HostTagCapsule(tag: tag)
                    }
                }
                address
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(hostLabel.tint.map { Color(uiColor: $0) } ?? Color.accentColor)
        }
    }

    /// The endpoint, shortened at the end of the host when the row is narrow
    /// and wrapped at accessibility sizes. The port stays whole: a middle cut
    /// set its ellipsis beside the host's own dots ("build.ex....com") and
    /// could take the port's digits with it.
    @ViewBuilder
    private var address: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Keep the port after the complete host when the address wraps.
            Text(verbatim: record.userAndHost + (record.port == 22 ? "" : ":\(record.port)"))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: record.userAndHost)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if record.port != 22 {
                    Text(verbatim: ":\(record.port)")
                        .fixedSize()
                }
            }
        }
    }

    /// What needs the person, then how the connection stands.
    private var trailing: some View {
        HStack(spacing: 6) {
            if session?.consentRequest != nil {
                // Red, as a badge is: the one row state that is waiting on
                // the person rather than describing the connection.
                Image(systemName: InterfaceSymbol.attention)
                    .foregroundStyle(StatusTone.error.color)
            }
            if session?.hasUnheardBell == true {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.tint)
            }
            if let color = session?.programStatusColor {
                Circle()
                    .fill(Color(uiColor: color))
                    .frame(width: 8, height: 8)
            }
            statusText
                .font(.subheadline)
                .lineLimit(1)
        }
        .imageScale(.small)
        .fixedSize()
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .connected:
            Text("Connected").foregroundStyle(StatusTone.connected.color)
        case .connecting:
            Text("Connecting…").foregroundStyle(.secondary)
        case .reconnecting:
            Text("Reconnecting…").foregroundStyle(.secondary)
        case .needsUpdate:
            Label("Needs update", systemImage: InterfaceSymbol.error).foregroundStyle(StatusTone.error.color)
        case .cannotConnect:
            Label("Can’t connect", systemImage: InterfaceSymbol.error).foregroundStyle(StatusTone.error.color)
        case .lastConnected(let date):
            Text(date, format: Self.dateFormat).foregroundStyle(.secondary)
        case .never:
            EmptyView()
        }
    }

    /// How the row's host stands, in the order a person cares: what is
    /// happening now, then what happened last.
    private enum Status: Equatable {
        case connected
        case connecting
        case reconnecting
        case needsUpdate
        case cannotConnect
        case lastConnected(Date)
        case never
    }

    private var status: Status {
        if let session, session.hasBegunConnecting || session.hasFailed {
            if session.hasFailed {
                return session.lastHostRefusalReason == .VersionMismatch ? .needsUpdate : .cannotConnect
            }
            if !session.hasExited {
                if session.isConnected { return .connected }
                return session.isReconnecting ? .reconnecting : .connecting
            }
        }
        return record.lastConnectedAt.map(Status.lastConnected) ?? .never
    }

    /// "yesterday", "2 hours ago": the system's words for a date near now,
    /// spelled out, since an abbreviation such as "last mo" reads as a typo.
    private static let dateFormat = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)

    /// The record's own name, or the machine's when it has none; the address
    /// is the second line, so a name made of the address would say it twice.
    private var title: String {
        record.name.isEmpty ? record.hostName : record.name
    }

    /// The kind of host: a Ubiquitty host that keeps workspaces, drawn as
    /// the empty list draws a host, or a login shell over ssh.
    private var symbol: String {
        record.prefersQUIC ? "server.rack" : "terminal"
    }

    private var hostLabel: HostLabel {
        HostLabel(
            record: record,
            usesQUIC: session.map { $0.isConnected && $0.transport == .quic } ?? record.prefersQUIC,
            isSync: session.map { $0.transport != .ssh } ?? record.prefersQUIC
        )
    }

    private var accessibilityDescription: String {
        var parts = [title, record.endpoint]
        switch status {
        case .connected:
            parts.append("Connected over \(session?.transport.rawValue ?? "SSH")")
        case .connecting:
            parts.append("Connecting")
        case .reconnecting:
            parts.append("Reconnecting")
        case .needsUpdate:
            parts.append("Needs update")
        case .cannotConnect:
            parts.append("Can’t connect")
        case .lastConnected(let date):
            parts.append("Last connected \(date.formatted(Self.dateFormat))")
        case .never:
            break
        }
        if session?.consentRequest != nil { parts.append("Permission request waiting") }
        if session?.hasUnheardBell == true { parts.append("Unheard terminal bell") }
        if let program = session?.programStatusLabel, session?.programStatusColor != nil, !program.isEmpty {
            parts.append(program)
        }
        if !hostLabel.tags.isEmpty { parts.append("Tagged " + hostLabel.tags.map(\.spokenName).joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

extension HostListView {
    /// Opens a host.
    ///
    /// Nothing is asked here: the connection asks the server what it accepts,
    /// and the person is asked for a password only when the server lists one
    /// and none is saved, through the root's sign-in sheet.
    fileprivate func open(_ record: HostRecord) {
        // The detail column shows one host at a time, whatever the width.
        openedRecord = nil
        listedRecord = nil
        // A host whose session is already up needs no credential: the carrier is authenticated
        // and running, and prompting again would ask for a password to resume a connection that
        // never dropped.
        if sessions.hasSession(for: record.id) {
            if sessions.session(for: record.id).isLive {
                proceed(to: record)
                return
            }
            // A model that failed or ended holds latches from the attempt
            // that failed. Opening the host starts over on a fresh one, and
            // asks again for a password the host may have refused.
            sessions.end(for: record.id)
        }
        proceed(to: record)
    }
}

/// Why a host's save or delete was not wholly carried out, for the alert
/// that says so.
struct HostUpdateFailure: LocalizedError {
    enum Cause {
        /// The keychain refused the password or key.
        case secretNotSaved
        /// Background refresh could not be given its own credential.
        case backgroundRefreshRefused
        /// The host's settings or protected data could not be written or
        /// removed, in the sentence that says which.
        case storage(String)

        /// How much the cause tells the person: a storage failure says what
        /// is left to do, and outranks a refused credential.
        var rank: Int {
            switch self {
            case .secretNotSaved: 0
            case .backgroundRefreshRefused: 1
            case .storage: 2
            }
        }
    }

    let hostName: String
    let cause: Cause

    var errorDescription: String? { String(localized: "Couldn’t Update Host") }

    var failureReason: String? {
        switch cause {
        case .secretNotSaved:
            String(
                localized:
                    "The password or key for \(hostName) couldn’t be saved to the keychain. Edit the host and enter it again before you connect."
            )
        case .backgroundRefreshRefused:
            String(
                localized:
                    "Check While Away wasn’t turned on for \(hostName). Save a password or private key and connect once to trust the host key, then try again."
            )
        case .storage(let sentence): sentence
        }
    }
}

/// The alert that says why a host's save or delete fell short.
private struct HostUpdateFailureAlert: ViewModifier {
    @Binding
    var failure: HostUpdateFailure?

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.alert(error: $failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.failureReason ?? "")
            }
        } else {
            content.alert(
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                error: failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.failureReason ?? "")
            }
        }
    }
}

/// Places a sheet beside the content on a wide layout rather than over it,
/// so what it edits stays in view. iOS 26 has no horizontal placement and
/// centres the sheet.
private struct TrailingSheetPlacement: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.presentationPlacement(.trailing)
        } else {
            content
        }
    }
}
