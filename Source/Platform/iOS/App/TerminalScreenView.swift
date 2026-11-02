// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittyCore
import UbiquittyKit

/// A terminal on one host.
///
/// The grid is the shared surface's, drawn by the same Metal renderer the
/// desktop app uses — colour, attributes, cursor and ligatures included. This
/// screen owns the connection and the chrome around it, and nothing else.
struct TerminalScreenView: View {
    @Environment(\.scenePhase)
    private var scenePhase
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    let record: HostRecord
    /// The live session, owned by ``SessionStore`` above the navigation stack rather than by this
    /// view. Leaving the screen must not end the connection, and a `@State` model here is
    /// destroyed with the view that holds it.
    let session: TerminalSessionModel
    /// What this visit attaches to, as Core's plan or the person's pick decided
    /// it. A return visit to a session already up ignores it: the model dials
    /// once, so a second connect cannot open a second shell beside the first.
    let attach: HostAttachIntent
    let onHostKeyPinned: (String) -> Void
    /// Remembers the theme against the host, so the next connection opens in it.
    let onThemeChosen: (String) -> Void
    /// Leaves this screen, keeping the session.
    ///
    /// The navigation's to answer rather than `dismiss`: this screen is the
    /// root of the detail column when a host has no sessions to list, and
    /// dismissing a column root does nothing in an expanded split view.
    let onLeave: () -> Void
    let onChooseSession: () -> Void
    let onCreateSession: () -> Void
    /// Opens the host's settings, where a failure's fix — the port, the
    /// password, the pinned key — is made.
    let onEditHost: () -> Void
    /// Moves to the neighbouring open connection, asked for by a two-finger
    /// swipe. The navigation's to answer, like leaving: which connections are
    /// open, and in what order, is the host list's.
    let onSwitchConnection: (SwipeStep) -> Void

    @State
    fileprivate var isKeyboardActive = false
    /// Whether the software keyboard is on screen. A hardware keyboard
    /// leaves the terminal first responder with no software keyboard up,
    /// and the key row goes with the keyboard it sits on.
    @State
    private var isSoftwareKeyboardShown = false
    /// The keyboard-frame observations, held while the screen is up.
    @State
    private var keyboardObservations: [NotificationCenter.ObservationToken] = []
    /// Where the tab overview grows from: the bar's Show All Tabs button.
    @Namespace
    fileprivate var tabOverviewNamespace
    /// The window's trailing safe-area inset, which iPhone Duo's side rail
    /// takes on its outer display.
    @State
    private var trailingInset: CGFloat = 0
    /// Whether the dictation bar is up on its own, without the keyboard.
    @State
    fileprivate var isDictationActive = false

    /// Whether dictation's controls are visible rather than covered by typing.
    fileprivate var isDictationShown: Bool { isDictationActive && !isKeyboardActive }

    /// Switches from typing to dictation, or closes the visible dictation bar.
    fileprivate func toggleDictation() {
        isDictationActive = isKeyboardActive || !isDictationActive
        isKeyboardActive = false
    }

    @State
    fileprivate var presentedTool: TerminalTool?
    @State
    private var pendingPaste = ""
    @State
    private var isConfirmingPaste = false
    @State
    fileprivate var isShowingConnectionDetails = false
    @State
    private var isConfirmingNewSession = false
    /// Whether the person put the failure banner away; a new failure brings
    /// it back.
    @State
    private var isFailureDismissed = false
    @Environment(\.verticalSizeClass)
    private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    /// Whether the window is short, mirrored from the size class into state so
    /// the surface's tap callback, made once, reads the current answer.
    @State
    fileprivate var isHeightCompact = false
    /// Whether a tap has brought the bottom bar back in a short window.
    @State
    fileprivate var isBarRevealed = false

    /// Whether the bottom bar is on screen.
    ///
    /// Always in a tall window, where the bar costs a few of many rows. In a
    /// short one it costs a sixth of the grid, so it stays away until a tap
    /// on the grid asks for it, and leaves again when the keyboard comes up or
    /// the person stops reaching for it.
    fileprivate var isBottomBarShown: Bool {
        !isHeightCompact || (isBarRevealed && !isKeyboardActive)
    }

    /// The colour scheme the chrome over the grid takes: the one legible on
    /// the terminal's own ground, whatever the system's is.
    fileprivate var groundScheme: ColorScheme {
        session.isGroundDark ? .dark : .light
    }

    /// The screen's title: the host it is on, then what the session calls
    /// itself, marked the way a desktop tab on a host is — the back menu and
    /// the system's window list name two screens on two hosts apart.
    private var navigationTitle: String {
        guard !session.title.isEmpty else { return record.displayName }
        var marks = Ubiquitty.Title.TabLabelMarks()
        marks.hostName = std.string(record.displayName)
        return String(Ubiquitty.Title.markTabLabel(std.string(session.title), marks))
    }

    /// Whether the window is wide enough for the navigation bar and its
    /// toolbar, as Files and Notes are laid out on an iPad, rather than the
    /// bottom bar a phone has.
    fileprivate var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// The tab's name for the title: Core's name for the tab, as the Mac's
    /// tab label shows it, else what the pane calls itself, else the host.
    fileprivate var tabTitle: String {
        if let tab = currentTab, !tab.title.isEmpty { return tab.title }
        if !session.title.isEmpty { return session.title }
        return record.displayName
    }

    fileprivate var currentTab: TerminalTab? { session.activeTab }

    /// Whether the connection is still being made, which the title shows in
    /// place of the grid being covered.
    fileprivate var isConnecting: Bool {
        !session.isConnected && !session.hasFailed && !session.hasExited
    }

    /// The title's second line: the host, and which tab of how many; while
    /// connecting, how that stands.
    fileprivate var tabSubtitle: String {
        if isConnecting { return session.isReconnecting ? session.statusDetail : session.connectingStep }
        // The host once: a tab with no name of its own is already titled by it.
        let host = tabTitle == record.displayName ? "" : record.displayName
        func joined(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
        if session.hasFailed || session.hasExited { return joined(host, "Not connected") }
        let tabs = session.tabs
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == currentTab?.id }) else {
            return host.isEmpty ? "Connected" : host
        }
        return joined(host, "\(index + 1) of \(tabs.count)")
    }

    fileprivate enum TerminalTool: String, Identifiable {
        case settings, files, fileDownload, consent
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable
        var session = session
        screen
            .focusedSceneValue(\.terminalWorkspace, presentedTool == nil && !isShowingConnectionDetails ? session : nil)
            // The terminal's own ground behind every edge, so the grid is not
            // framed in a system band it does not have. The cells stay inside
            // the safe area; only the colour reaches past it.
            .background { Color(uiColor: session.groundColor).ignoresSafeArea() }
            .navigationTitle(navigationTitle)
            .navigationSubtitle(isRegularWidth ? tabSubtitle : "")
            .navigationBarTitleDisplayMode(.inline)
            // No bar above the grid on a phone: the rows it would cost are the
            // rows a person is reading. Tabs opens the named cards from below.
            // A wide window has the rows to spare and shows the navigation bar
            // with the title and the toolbar, and no bottom bar.
            .toolbarVisibility(isRegularWidth ? .automatic : .hidden, for: .navigationBar)
            .modifier(TerminalToolbar(screen: self))
            .toolbarVisibility(isBottomBarShown && !isRegularWidth ? .visible : .hidden, for: .bottomBar)
            // Scoped to the bars over the grid: the status bar and the bottom
            // bar follow the ground, while the sheets this screen presents keep
            // the system's scheme.
            .toolbarColorScheme(groundScheme, for: .navigationBar, .bottomBar)
            // The modifier above does not reach the bottom bar's glass: the
            // split view hosts that bar, outside this stack, and draws it in
            // the scheme of its own environment. The scheme goes up to the
            // split view, which puts it there.
            .preference(key: TerminalGroundSchemeKey.self, value: groundScheme)
            .onAppear { isHeightCompact = verticalSizeClass == .compact }
            .onChange(of: verticalSizeClass) { _, sizeClass in
                isHeightCompact = sizeClass == .compact
                isBarRevealed = false
            }
            .onChange(of: isKeyboardActive) { _, isActive in
                if isActive { isBarRevealed = false }
            }
            .task(id: isBarRevealed) {
                // A bar brought back and then left alone goes away again.
                guard isBarRevealed else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { isBarRevealed = false }
            }
            .confirmationDialog("Paste multiple lines into the terminal?", isPresented: $isConfirmingPaste, titleVisibility: .visible) {
                Button("Paste") {
                    session.pasteText(pendingPaste)
                    pendingPaste = ""
                }
                Button("Cancel", role: .cancel) { pendingPaste = "" }
            }
            .alert(
                session.keyboardCloseRequest?.title ?? "",
                item: $session.keyboardCloseRequest
            ) { request in
                Button(TerminalSessionModel.closeVerb, role: .destructive) { session.confirmKeyboardClose(request) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                if !request.body.isEmpty { Text(request.body) }
            }
            .onChange(of: session.keyboardCloseRequest?.id) { _, id in
                // A close question owns focus. Keeping the terminal keyboard
                // active makes UIKit restore it inside the alert dismissal.
                if id != nil { isKeyboardActive = false }
            }
            .sheet(isPresented: $isShowingConnectionDetails) { connectionDetailsSheet { isShowingConnectionDetails = false } }
            .confirmationDialog(
                "Create a new workspace on \(record.displayName)?",
                isPresented: $isConfirmingNewSession,
                titleVisibility: .visible
            ) {
                Button("Create Workspace") { onCreateSession() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This starts a separate workspace. It does not restore or replace the unavailable workspace.")
            }
            // Again for each pick: a row chosen for the host already on screen
            // moves this connection onto it, and the same pick is left alone.
            .task(id: attach) { beginConnecting() }
            // A pane switch is a choice moving, and a connection settling is
            // an outcome: the two haptics the HIG gives those.
            .sensoryFeedback(.selection, trigger: session.activePaneID)
            .sensoryFeedback(.success, trigger: session.isConnected) { wasConnected, isConnected in !wasConnected && isConnected }
            .sensoryFeedback(.error, trigger: session.hasFailed) { hadFailed, hasFailed in !hadFailed && hasFailed }
            .onChange(of: session.hasFailed) { _, hasFailed in
                if hasFailed { isFailureDismissed = false }
            }
            .onAppear {
                session.screenDidAppear()
                if session.consentRequest != nil { presentedTool = .consent }
            }
            .onDisappear {
                session.onPasteRequested = nil
                session.screenDidDisappear()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { session.clearUnheardBellIfActive() }
            }
            .onChange(of: session.isConnected) { _, isConnected in
                // Pinned only once a connection actually succeeded. Pinning from
                // inside the validator would record a key that then failed to
                // authenticate, which is the one case trust-on-first-use must not
                // remember.
                guard isConnected else { return }
                let fingerprint = session.presentedHostKeyFingerprint
                if !fingerprint.isEmpty {
                    onHostKeyPinned(fingerprint)
                }
            }
            // Over the whole screen, as Safari's tab overview is: the cards are
            // the content, not a sheet over it.
            .fullScreenCover(isPresented: Bindable(session).isShowingTabOverview) {
                TerminalTabOverview(session: session)
                    .sheetChrome()
                    .navigationTransition(.zoom(sourceID: TerminalToolbar.tabOverviewSourceID, in: tabOverviewNamespace))
            }
            .sheet(item: $presentedTool) { tool in
                toolSheet(tool).sheetChrome().modifier(BesideTheTerminal(isWide: isRegularWidth))
            }
            .onChange(of: session.consentRequest?.id) { _, id in
                if id != nil {
                    isKeyboardActive = false
                    presentedTool = .consent
                } else if presentedTool == .consent {
                    presentedTool = nil
                }
            }
            .onChange(of: session.fileDownloadRequest?.id) { _, id in
                if id != nil {
                    isKeyboardActive = false
                    presentedTool = .fileDownload
                } else if presentedTool == .fileDownload {
                    presentedTool = nil
                }
            }
    }

    /// The sheet a tool opens.
    @ViewBuilder
    private func toolSheet(_ tool: TerminalTool) -> some View {
        switch tool {
        case .settings: settingsSheet
        case .files: TerminalFilesView(session: session)
        case .fileDownload:
            if let request = session.fileDownloadRequest {
                TerminalFileDownloadView(session: session, request: request) { presentedTool = .files }
            }
        case .consent:
            if let request = session.consentRequest { TerminalConsentView(session: session, request: request) }
        }
    }

    private var settingsSheet: some View {
        AppSettingsView()
    }

    /// Connection progress and failures float over the grid so their arrival
    /// never resizes the program. Cancellation stays available while dialing.
    @ViewBuilder
    private var connectionStatus: some View {
        if session.hasFailed || session.hasExited {
            if !isFailureDismissed {
                let notice = connectionPresentation
                TerminalFailureBanner(
                    cause: notice.cause,
                    fix: notice.fix,
                    hasFailed: session.hasFailed,
                    onDetails: { isShowingConnectionDetails = true },
                    onDismiss: { isFailureDismissed = true }
                ) {
                    connectionActions(notice)
                }
            }
        } else if !session.isConnected {
            TerminalConnectingCapsule(
                step: session.isReconnecting ? session.statusDetail : session.connectingStep,
                isReconnecting: session.isReconnecting,
                onCancel: { session.cancelConnecting() },
                onRetryNow: { session.reconnectNow() }
            )
        }
    }

    /// Core's notice while some of what was typed may not have reached the
    /// host; it waits for the person's answer and never sends unasked.
    @ViewBuilder
    private var inputInDoubtNotice: some View {
        if let inputInDoubt = session.inputInDoubt {
            TerminalInputInDoubtBanner(
                notice: inputInDoubt.notice,
                onResend: { session.resendInputInDoubt() },
                onDiscard: { session.discardInputInDoubt() }
            )
        }
    }

    private var connectionPresentation: TerminalConnectionPresentation {
        TerminalConnectionPresentation(
            hasFailed: session.hasFailed,
            hasExited: session.hasExited,
            isReconnecting: session.isReconnecting,
            detail: session.statusDetail,
            refusal: session.lastHostRefusalReason,
            failure: session.failure,
            sshFailure: session.sshFailureSummary
        )
    }

    /// The banner's buttons: the first prominent, as the default.
    @ViewBuilder
    private func connectionActions(_ notice: TerminalConnectionPresentation) -> some View {
        ForEach(Array(notice.actions.enumerated()), id: \.element) { index, action in
            if index == 0 {
                actionButton(action).buttonStyle(.glassProminent).fixedSize()
            } else {
                actionButton(action).buttonStyle(.glass).fixedSize()
            }
        }
    }

    private func actionButton(_ action: TerminalConnectionPresentation.Action) -> some View {
        Button(action.title) { perform(action) }
            .accessibilityIdentifier(action.accessibilityIdentifier)
    }

    private func perform(_ action: TerminalConnectionPresentation.Action) {
        switch action {
        case .tryAgain, .reconnect: beginConnecting()
        case .editHost, .reviewHostKey: onEditHost()
        case .openLoginShell, .newSSHShell: session.openLoginShellInstead(to: record, secret: secret)
        case .chooseWorkspace:
            session.setAsideUnreachedPick()
            onChooseSession()
        case .newWorkspace: isConfirmingNewSession = true
        case .retryNow: session.reconnectNow()
        }
    }

    private func connectionDetailsSheet(onDone: @escaping () -> Void) -> some View {
        ConnectionDetailsView(
            session: session,
            presentation: connectionPresentation,
            hostLabel: record.displayName,
            onDone: onDone,
            onThemeChosen: { name in
                session.selectTheme(named: name)
                onThemeChosen(name)
            }
        )
    }

    /// Where a swipe landed. Top centre, where the eye already is after a
    /// sideways swipe across the grid, below the connection's state when that
    /// is showing, and like the hint it never takes the touch: the next swipe
    /// may already be under way.
    @ViewBuilder
    private var swipeNotice: some View {
        if !session.notice.isEmpty {
            Text(session.notice)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 12)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityIdentifier("terminal-toast")
        }
    }

    /// Asks the person what to do about a picked workspace that was not
    /// reached, rather than opening some other shell in its place.
    ///
    /// Named by the workspace's own name, as the person picked it. A
    /// workspace the host no longer runs offers a new one or another; one
    /// that could not be reached offers another try, and a login shell only
    /// where the host was reached and the workspace's QUIC carrier is what it
    /// could not have.
    private var unreachedPickAlert: some View {
        let name = session.unreachedPick?.name ?? ""
        let isGone = session.lastHostRefusalReason == .SessionGone
        let notice = connectionPresentation
        return Color.clear
            .frame(width: 0, height: 0)
            .alert(
                isGone
                    ? (name.isEmpty ? "This Workspace Is No Longer Running" : "“\(name)” Is No Longer Running")
                    : (name.isEmpty ? "Couldn’t Reach the Workspace" : "Couldn’t Reach “\(name)”"),
                isPresented: Binding(
                    get: { session.unreachedPick != nil && presentedTool == nil },
                    set: { _ in }
                )
            ) {
                if isGone {
                    Button("New Workspace") {
                        session.setAsideUnreachedPick()
                        onCreateSession()
                    }
                    Button("Choose Another…") {
                        session.setAsideUnreachedPick()
                        onChooseSession()
                    }
                } else {
                    Button("Try Again") { beginConnecting() }
                    if session.unreachedPick?.offersLoginShell == true {
                        Button("Open Login Shell") {
                            session.openLoginShellInstead(to: record, secret: secret)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    session.setAsideUnreachedPick()
                    onLeave()
                }
            } message: {
                Text(notice.fix.isEmpty ? notice.cause : "\(notice.cause) \(notice.fix)")
            }
    }

    private var screen: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Behind the grid, and invisible: it exists to be first
                // responder so the keyboard has somewhere to deliver keys.
                TerminalKeyboardInput(
                    session: session,
                    isFirstResponder: $isKeyboardActive
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)

                terminalPanes
                    // Clear of the bezel's curve and the sensor housing; the
                    // ground behind still reaches every edge.
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomTrailing) {
                if let position = session.scrollback, position.isScrolledBack {
                    TerminalScrollbackControls(position: position) { session.jumpToBottom() }
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                // A bar put away in a short window leaves a grabber where it
                // was, so a person can see it is there to bring back.
                if isHeightCompact, !isBottomBarShown, !isKeyboardActive, !isDictationActive, !isRegularWidth {
                    Button("Show Toolbar") { isBarRevealed = true }
                        .buttonStyle(TerminalGrabberStyle())
                        .accessibilityIdentifier("terminal-show-toolbar")
                }
            }
            // Over the grid rather than beside it: a phone has no title row to
            // put this in, and the lesson is about the gesture the reader is
            // making right now. Bottom-trailing keeps it away from the top-left
            // origin where output lands, and it never takes the touch — the
            // gesture it is teaching is still in progress.
            .overlay(alignment: .bottomTrailing) {
                if !session.hint.isEmpty {
                    Text(session.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .rect(cornerRadius: 8))
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityLabel(session.hint)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    connectionStatus
                    inputInDoubtNotice
                    swipeNotice
                }
            }
            // A fade, which Reduce Motion keeps, only shortened to a cut.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.notice)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.scrollback?.isScrolledBack)
            .background { unreachedPickAlert }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            // The chrome floating over the grid reads against the grid's
            // ground, not against the system's appearance.
            .environment(\.colorScheme, groundScheme)
            .onAppear {
                applyGeometry(geometry.size)
                // The surface owns the tap: which of the two things it means —
                // summon the keyboard, or press a button — is the terminal's
                // rule, and a second tap handler here would answer it first.
                // In a short window with the bar away, the first tap brings
                // the bar back, which holds the keyboard button.
                session.onKeyboardRequested = {
                    if isHeightCompact, !isBarRevealed {
                        isBarRevealed = true
                    } else {
                        isKeyboardActive = true
                    }
                }
                session.onSettingsRequested = { presentedTool = .settings }
                session.onPasteRequested = { paste($0) }
                session.onConnectionSwitchRequested = { step in onSwitchConnection(step) }
                session.isKeyboardPresented = isKeyboardActive
            }
            .onChange(of: isKeyboardActive) { _, active in
                session.isKeyboardPresented = active
                if !active { session.keyboardModifiers = TerminalKeyboardModifiers() }
            }
            .onChange(of: geometry.size) { _, size in applyGeometry(size) }
            .onChange(of: geometry.safeAreaInsets.trailing, initial: true) { _, inset in trailingInset = inset }
        }
        .onAppear {
            guard keyboardObservations.isEmpty else { return }
            keyboardObservations = [
                NotificationCenter.default.addObserver(for: UIResponder.KeyboardWillChangeFrameMessage.self) { message in
                    isSoftwareKeyboardShown = Self.softwareKeyboardIsShown(message)
                },
                NotificationCenter.default.addObserver(for: UIResponder.KeyboardWillHideMessage.self) { _ in
                    isSoftwareKeyboardShown = false
                },
            ]
        }
        .onDisappear {
            for observation in keyboardObservations { NotificationCenter.default.removeObserver(observation) }
            keyboardObservations = []
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // A wide window has room for the tabs themselves, so switching is
            // one tap rather than a visit to the overview.
            if horizontalSizeClass == .regular, session.tabs.count > 1 {
                TerminalTabStrip(session: session)
            }
        }
        // A bar the grid scrolls under, with the system's scroll-edge effect.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if session.isFindingInScrollback {
                TerminalFindBar(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.isFindingInScrollback)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isKeyboardActive {
                // iPad puts these keys in the keyboard's shortcuts bar, and
                // the bar's own keyboard button puts the keyboard away unless
                // a short window has taken the bar.
                if isSoftwareKeyboardShown, UIDevice.current.userInterfaceIdiom == .phone {
                    TerminalKeyboardAccessory(
                        session: session,
                        hideKeyboard: hasSideRail ? nil : { isKeyboardActive = false },
                        dictate: hasSideRail ? nil : { toggleDictation() }
                    )
                    .environment(\.colorScheme, groundScheme)
                }
            } else if isDictationActive {
                TerminalDictationBar(
                    session: session,
                    isKeyboardActive: isKeyboardActive,
                    shouldStartListening: isDictationActive && !isKeyboardActive,
                    hideKeyboard: { isKeyboardActive = false },
                    close: { isDictationActive = false }
                )
            }
        }
    }

    /// Whether the bar stands as a rail beside the grid, where the keyboard
    /// does not cover its keyboard button. On an iPhone held upright the
    /// grid has no trailing inset; a landscape window's inset is the
    /// camera's, and its bar is away while the keyboard is up.
    fileprivate var hasSideRail: Bool {
        !isHeightCompact && trailingInset > 20
    }

    /// Whether a keyboard frame change leaves a software keyboard on screen.
    ///
    /// With a hardware keyboard the system still reports a frame: offscreen,
    /// or only the slim bar of candidates it floats. A keyboard with keys is
    /// taller than that in every orientation.
    private static func softwareKeyboardIsShown(_ message: UIResponder.KeyboardWillChangeFrameMessage) -> Bool {
        message.screen.bounds.intersection(message.endFrame).height >= 120
    }

    /// The workspace's panes, as wide as the window has room for.
    private var terminalPanes: some View {
        TerminalPaneLayout(session: session)
    }

    /// Pastes text, asking first when Core's policy wants the paste confirmed.
    fileprivate func paste(_ text: String) {
        if session.requiresPasteConfirmation(text) {
            pendingPaste = text
            isConfirmingPaste = true
        } else {
            session.pasteText(text)
        }
    }

    /// Connects, or dials again when the last attempt failed or ended; a live
    /// connection is left as it is.
    private func beginConnecting() {
        session.connect(to: record, secret: secret, attach: attach)
    }

    /// What the keychain holds for this host, empty when nothing is saved.
    private var secret: String {
        SecretStore.secret(for: record.id) ?? ""
    }

    /// The surface refits its own grid from its bounds, using the renderer's
    /// measured cell, and reports the result. A second measurement here is how
    /// a grid comes to disagree with what is drawn.
    private func applyGeometry(_ size: CGSize) {}
}

/// The terminal's bars.
///
/// On a phone, one bottom bar modelled on Safari's: Back to the workspaces,
/// Tabs and the current tab/pane position in the centre, and the keyboard, Dictate and More at
/// the trailing end. On iPhone Duo folded the system stands the bar on its
/// side as a trailing rail. In a wide window the navigation bar carries the title, its
/// menu and the toolbar, as Files and Notes do, and there is no bottom bar.
///
/// Each item is hosted by the bar itself. A single item wrapping its own
/// stack of buttons put them under a zero-sized container in the
/// accessibility tree, so an accessibility hit test found none of them.
private struct TerminalToolbar: ViewModifier {
    let screen: TerminalScreenView

    /// The tab overview's zoom source: the bar's Show All Tabs button.
    static let tabOverviewSourceID = "tab-overview"

    func body(content: Content) -> some View {
        content
            .toolbar {
                if screen.isRegularWidth {
                    regularToolbar
                } else {
                    compactToolbar
                }
            }
            .modifier(TerminalOverflowMenu(isActive: screen.isRegularWidth) { secondaryActions.labelStyle(.titleAndIcon) })
            .toolbarTitleMenu {
                if screen.isRegularWidth {
                    Button("Show All Tabs", systemImage: InterfaceSymbol.tabs) { screen.session.showTabOverview() }
                    Button("New Tab", systemImage: "plus") { screen.session.addTab() }
                        .disabled(!screen.session.canChangePanes)
                }
            }
    }

    /// The phone's bar keeps Tabs directly reachable. The system sets custom
    /// labels apart from a side rail, so the rail keeps its icon-only controls
    /// and Show All Tabs heads its More menu.
    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        if screen.hasSideRail {
            ToolbarItemGroup(placement: .bottomBar) {
                leaveButton.labelStyle(.iconOnly)
                keyboardButton.labelStyle(.iconOnly)
                dictationButton.labelStyle(.iconOnly)
                moreMenu.labelStyle(.iconOnly)
            }
        } else {
            ToolbarItem(placement: .bottomBar) { leaveButton.labelStyle(.iconOnly) }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { tabsButton }
                .matchedTransitionSource(id: Self.tabOverviewSourceID, in: screen.tabOverviewNamespace)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItemGroup(placement: .bottomBar) {
                keyboardButton.labelStyle(.iconOnly)
                dictationButton.labelStyle(.iconOnly)
                moreMenu.labelStyle(.iconOnly)
            }
        }
    }

    /// The wide window's toolbar: New Tab and Split give way first when the
    /// bar runs short, into the system's overflow menu. Keyboard and Dictate
    /// stay pinned at the trailing edge.
    @ToolbarContentBuilder
    private var regularToolbar: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItem(placement: .primaryAction) { newTabButton }
                .visibilityPriority(.low)
            ToolbarItem(placement: .primaryAction) { splitMenu }
                .visibilityPriority(.low)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .topBarPinnedTrailing) { keyboardButton }
            ToolbarItem(placement: .topBarPinnedTrailing) { dictationButton }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                newTabButton
                splitMenu
                keyboardButton
                dictationButton
                moreMenu
            }
        }
    }

    private var newTabButton: some View {
        Button("New Tab", systemImage: "plus") { screen.session.addTab() }
            .disabled(!screen.session.canChangePanes)
            .accessibilityIdentifier("terminal-new-tab")
    }

    private var splitMenu: some View {
        Menu("Split", systemImage: InterfaceSymbol.splitRight) {
            splitButtons
        }
        .disabled(!screen.session.canChangePanes)
        .accessibilityIdentifier("terminal-split")
    }

    private var tabsButton: some View {
        let count = screen.session.tabs.count
        let tabNumber = screen.session.tabs.firstIndex { $0.id == screen.currentTab?.id }.map { $0 + 1 }
        let tabPosition = tabNumber.map { "\($0)/\(count)" } ?? (count == 0 ? "0" : "–/\(count)")
        let tabDescription = tabNumber.map { "Tab \($0) of \(count)" } ?? "\(count) tabs"
        let paneCount = screen.currentTab?.panes.count ?? 0
        let paneNumber = screen.currentTab?.panes.firstIndex { $0.id == screen.session.activePaneID }.map { $0 + 1 }
        let panePosition = paneNumber.map { "\($0)/\(paneCount)" }
        let paneDescription = paneNumber.map { "pane \($0) of \(paneCount)" }
        let description = [tabDescription, paneCount > 1 ? paneDescription : nil].compactMap { $0 }.joined(separator: ", ")
        return Button {
            screen.session.showTabOverview()
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: InterfaceSymbol.tabs)
                    Text(tabPosition)
                }
                .font(.subheadline.weight(.semibold))
                if paneCount > 1, let panePosition {
                    HStack(spacing: 4) {
                        Image(systemName: InterfaceSymbol.session)
                        Text(panePosition)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show All Tabs")
        .accessibilityValue(description)
        .accessibilityHint("Shows this workspace’s tabs and panes.")
        .accessibilityIdentifier("terminal-tabs")
        .accessibilityShowsLargeContentViewer()
    }

    /// The actions the bar has no room for, in the groups a person scans
    /// them by, where the system has no overflow menu of its own to hold
    /// them.
    private var moreMenu: some View {
        Menu {
            secondaryActions
                .labelStyle(.titleAndIcon)
        } label: {
            // The bare glyph: the bar's glass is already the circle.
            Label("More", systemImage: "ellipsis")
                .frame(width: 44, height: 44)
        }
        // Read top to bottom wherever the menu opens, so an upward menu does
        // not list its items in reverse.
        .menuOrder(.fixed)
        .accessibilityHint("Shows paste, files, new tabs, terminal keys and settings.")
        .accessibilityIdentifier("terminal-more")
    }

    /// Back to the workspaces, where Back always is. The session keeps
    /// running; the system's edge swipe does the same.
    private var leaveButton: some View {
        Button {
            screen.onLeave()
        } label: {
            Label("Workspaces", systemImage: "chevron.backward")
                .frame(width: 44, height: 44)
        }
        .accessibilityHint("Returns to this host’s workspaces. The session keeps running.")
        .accessibilityIdentifier("terminal-leave")
    }

    @ViewBuilder
    private var splitButtons: some View {
        Button("Split Right", systemImage: InterfaceSymbol.splitRight) { screen.session.performPaneAction(.splitBeside) }
        Button("Split Down", systemImage: InterfaceSymbol.splitDown) { screen.session.performPaneAction(.splitBelow) }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if screen.hasSideRail {
            Section {
                Button("Show All Tabs", systemImage: InterfaceSymbol.tabs) { screen.session.showTabOverview() }
            }
        }
        Section {
            pasteButton
            Button("Find in Scrollback…", systemImage: "magnifyingglass") { screen.session.beginFind() }
                .accessibilityIdentifier("terminal-find-menu")
            Button("Copy", systemImage: "doc.on.doc") { screen.session.copySelection() }
                .disabled(!screen.session.hasSelection)
            Button("Select All", systemImage: "selection.pin.in.out") { screen.session.selectAll() }
                .disabled(!screen.session.isConnected)
        }
        Section {
            Button("Files…", systemImage: "folder") { screen.presentedTool = .files }
                .accessibilityIdentifier("terminal-files-menu")
        }
        Section {
            Button("New Tab", systemImage: "plus") { screen.session.addTab() }
            splitButtons
            if screen.session.panes.count >= TerminalPaneArrangement.capacity {
                Toggle(isOn: Bindable(screen.session).prefersTwoPanes) {
                    Label("Show Two Panes When Wide", systemImage: InterfaceSymbol.splitRight)
                }
            }
        }
        .disabled(!screen.session.canChangePanes)
        Section {
            Menu("Terminal Keys", systemImage: "command") {
                Button("Escape") { screen.session.sendKey(named: .Escape) }
                Button("Tab") { screen.session.sendKey(named: .Tab) }
                Button("Control-C") { screen.session.sendKey(letter: "c", control: true) }
                Button("Control-D") { screen.session.sendKey(letter: "d", control: true) }
                Button("Control-L") { screen.session.sendKey(letter: "l", control: true) }
                Divider()
                Button("Up Arrow") { screen.session.sendKey(named: .UpArrow) }
                Button("Down Arrow") { screen.session.sendKey(named: .DownArrow) }
                Button("Left Arrow") { screen.session.sendKey(named: .LeftArrow) }
                Button("Right Arrow") { screen.session.sendKey(named: .RightArrow) }
            }
            .disabled(!screen.session.isConnected)
        }
        Section {
            Button("Settings", systemImage: "gearshape") { screen.presentedTool = .settings }
            Button("Connection Details", systemImage: InterfaceSymbol.info) { screen.isShowingConnectionDetails = true }
                .accessibilityIdentifier("terminal-connection-log")
        }
    }

    private var dictationButton: some View {
        Button(action: screen.toggleDictation) {
            Label(
                screen.isDictationShown ? "Close Dictation" : "Dictate",
                systemImage: screen.isDictationShown ? "mic.fill" : "mic"
            )
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(screen.isDictationShown ? "Closes dictation." : "Starts dictation into the terminal.")
        .accessibilityIdentifier("terminal-dictate")
        .accessibilityShowsLargeContentViewer()
    }

    private var keyboardButton: some View {
        Button {
            screen.isKeyboardActive.toggle()
        } label: {
            Label(
                screen.isKeyboardActive ? "Hide Keyboard" : "Show Keyboard",
                systemImage: screen.isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard"
            )
            .frame(width: 44, height: 44)
        }
        .accessibilityHint("Types into the terminal.")
        .accessibilityIdentifier("terminal-keyboard")
    }

    /// The system's Paste, which asks for no permission: the pasteboard is
    /// read only when the person taps it.
    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { strings in
            screen.paste(strings.joined(separator: "\n"))
        }
    }
}

/// The terminal's secondary actions in the navigation bar's system overflow
/// menu, which also takes whatever the bar drops when it runs short; before
/// iOS 27, and in the phone's bottom bar, the bar carries its own More.
private struct TerminalOverflowMenu<Actions: View>: ViewModifier {
    /// Whether the navigation bar is the terminal's bar, the one the system
    /// gives an overflow menu.
    let isActive: Bool
    @ViewBuilder
    let actions: () -> Actions

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *), isActive {
            content.toolbarOverflowMenu { actions() }
        } else {
            content
        }
    }
}

/// A tool sheet beside the terminal in a wide window, so the grid stays in
/// view while it is open; centred over it otherwise.
private struct BesideTheTerminal: ViewModifier {
    /// The terminal's window width class; a sheet's own is compact.
    let isWide: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *), isWide {
            content.presentationPlacement(.trailing)
        } else {
            content
        }
    }
}

/// The grabber a hidden bar leaves: a short capsule at the bottom edge, with
/// a touch target taller than what it draws.
private struct TerminalGrabberStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(.secondary.opacity(configuration.isPressed ? 0.9 : 0.5))
            .frame(width: 40, height: 5)
            .frame(width: 88, height: 24)
            .contentShape(.rect)
            .accessibilityLabel(Text("Show Toolbar"))
    }
}

/// The card's ground: glass, or with Increase Contrast an opaque material and
/// an edge, which glass over moving text does not keep legible.
struct StatusCardBackground: ViewModifier {
    let isContrastIncreased: Bool

    func body(content: Content) -> some View {
        if isContrastIncreased {
            content
                .background(.regularMaterial, in: .rect(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.5), lineWidth: 1) }
        } else {
            content.glassEffect(in: .rect(cornerRadius: 22))
        }
    }
}

/// The colour scheme of the terminal on screen, read by the split view that
/// hosts the terminal's bottom bar; nil when no terminal is on screen.
struct TerminalGroundSchemeKey: PreferenceKey {
    static let defaultValue: ColorScheme? = nil

    /// The first terminal's: one screen is on top of the stack at a time.
    static func reduce(value: inout ColorScheme?, nextValue: () -> ColorScheme?) {
        value = value ?? nextValue()
    }
}

/// What the banner over the grid says while there is no live connection: the
/// cause, what to do about it, and the actions that do it, the default first.
///
/// Built from the typed failure the session recorded; the carrier's own
/// description stays in the connection log, and no sentence here sends the
/// person to the details for the cause.
struct TerminalConnectionPresentation: Equatable {
    /// One action the banner offers.
    enum Action: Hashable {
        case tryAgain, editHost, reviewHostKey, openLoginShell, chooseWorkspace, newWorkspace
        case reconnect, retryNow, newSSHShell

        init(_ action: ConnectionFailure.Action) {
            switch action {
            case .tryAgain: self = .tryAgain
            case .editHost: self = .editHost
            case .reviewHostKey: self = .reviewHostKey
            case .openLoginShell: self = .openLoginShell
            case .chooseWorkspace: self = .chooseWorkspace
            case .newWorkspace: self = .newWorkspace
            }
        }

        /// The button's title.
        var title: LocalizedStringKey {
            switch self {
            case .tryAgain: "Try Again"
            case .editHost: "Edit Host"
            case .reviewHostKey: "Review Key…"
            case .openLoginShell: "Open Login Shell"
            case .chooseWorkspace: "Choose Workspace"
            case .newWorkspace: "New Workspace…"
            case .reconnect: "Reconnect"
            case .retryNow: "Retry Now"
            case .newSSHShell: "Open New SSH Shell"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .tryAgain: "terminal-connection-try-again"
            case .editHost: "terminal-connection-edit-host"
            case .reviewHostKey: "terminal-connection-review-key"
            case .openLoginShell: "terminal-connection-login-shell"
            case .chooseWorkspace: "terminal-connection-sessions"
            case .newWorkspace: "terminal-connection-new-session"
            case .reconnect: "terminal-connection-reconnect"
            case .retryNow: "terminal-connection-retry-now"
            case .newSSHShell: "terminal-connection-new-shell"
            }
        }
    }

    /// What happened, in one sentence.
    let cause: String
    /// What to do about it; empty when the actions say it.
    let fix: String
    let actions: [Action]

    init(
        hasFailed: Bool,
        hasExited: Bool,
        isReconnecting: Bool,
        detail: String,
        refusal: Ubiquitty.`Protocol`.Sync.ByeReason?,
        failure: ConnectionFailure? = nil,
        sshFailure: SSHFailurePresentation.Summary? = nil
    ) {
        if hasFailed {
            if refusal == nil, let sshFailure, sshFailure.recovery == .newShell {
                cause = failure?.cause ?? sshFailure.message
                fix = sshFailure.fix
                actions = [.newSSHShell]
                return
            }
            let failure =
                failure
                ?? refusal.map { refusal in
                    ConnectionFailure(
                        refusal: refusal,
                        cause: refusal == .VersionMismatch ? detail : String(Ubiquitty.Session.connectRefusalNotice(refusal)),
                        hasWorkspaceName: false
                    )
                }
                // Nothing typed says what failed, and the detail may be a
                // carrier's own words, which belong in the log.
                ?? ConnectionFailure(cause: String(localized: "The connection failed."))
            cause = failure.cause
            fix = failure.fix
            actions = failure.actions.map(Action.init)
        } else if hasExited {
            cause = String(localized: "The session ended.")
            fix = String(localized: "Reconnect when you’re ready.")
            actions = [.reconnect]
        } else {
            cause = detail
            fix = ""
            actions = isReconnecting ? [.retryNow] : []
        }
    }
}

/// How far the connection being made has got, in a capsule at the top of the
/// grid that covers no more of it than its own words; after a few seconds
/// with no live connection it offers Cancel.
///
/// The words are the step the session reports — "Connecting…", "Signing
/// in…", "Starting session…" — so a slow sign-in reads as one, not as a
/// host that never answered.
struct TerminalConnectingCapsule: View {
    let step: String
    let isReconnecting: Bool
    let onCancel: () -> Void
    let onRetryNow: () -> Void

    /// How long a connection may take before Cancel is offered: long enough
    /// that a quick connect never shows it, short enough that a stuck one
    /// does not leave the person without a way out.
    static let cancelDelay: Duration = .seconds(3)

    @State
    private var isCancelOffered = false
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.colorSchemeContrast)
    private var contrast

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(step)
                .font(.subheadline)
                .lineLimit(1)
                .accessibilityIdentifier("terminal-connecting-step")
            if isReconnecting {
                Button("Retry Now", action: onRetryNow)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("terminal-connection-retry-now")
            } else if isCancelOffered {
                Button("Cancel", role: .cancel, action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("terminal-connecting-cancel")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .modifier(StatusCapsuleBackground(isContrastIncreased: contrast == .increased))
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .default, value: isCancelOffered)
        .task {
            try? await Task.sleep(for: Self.cancelDelay)
            if !Task.isCancelled { isCancelOffered = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-connection-status")
    }
}

/// Puts a sheet beside the terminal on a wide display, where iOS 27 offers
/// it, so the grid whose theme and font it changes stays in view.
private struct TrailingSheetPlacement: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.presentationPlacement(.trailing)
        } else {
            content
        }
    }
}

/// The connecting capsule's ground: glass, or with Increase Contrast an opaque
/// material and an edge.
private struct StatusCapsuleBackground: ViewModifier {
    let isContrastIncreased: Bool

    func body(content: Content) -> some View {
        if isContrastIncreased {
            content
                .background(.regularMaterial, in: .capsule)
                .overlay { Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1) }
        } else {
            content.glassEffect(in: .capsule)
        }
    }
}
