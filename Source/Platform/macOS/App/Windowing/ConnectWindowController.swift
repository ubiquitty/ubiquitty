// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ConnectWindowController.swift — the ⌘⇧K window: the places a connection
// starts from (this Mac's host, its tmux sessions, layouts and serial ports,
// the saved hosts, recent targets) in one sidebar, the selected place's
// sessions or form in the content, and the host's details in an inspector.
//
// The window is configured here and drawn by ConnectView; the state is
// ConnectModel's. Every door into it — the File menu, Welcome, Beam, a
// refusal sheet — calls `show(place:intent:)` on the one instance.
//

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit

@objc(UBConnectWindowController)
public final class ConnectWindowController: NSWindowController, NSWindowDelegate {
    /// The one Connect window.
    static let shared = ConnectWindowController()

    /// Opens the window on its default place.
    @objc
    public static func show() {
        show(place: nil)
    }

    /// Opens the window on a place, for a purpose.
    ///
    /// The search text is cleared on every open, so a query from an earlier
    /// visit never filters what the person came back to see.
    ///
    /// - Parameters:
    ///   - place: The place, nil for the key window's host, else the last place
    ///     used, else This Mac.
    ///   - intent: What the place is opened for.
    static func show(place: ConnectPlace?, intent: ConnectIntent = .none) {
        ConnectModel.shared.open(place: place, intent: intent)
        shared.showWindow(nil)
    }

    /// Closes the window after a connect opened its own, so the terminal
    /// window owns the connect's progress from then on.
    static func closeAfterSpawn() {
        shared.window?.close()
    }

    @objc
    public init() {
        let hosting = NSHostingController(rootView: ConnectView(model: ConnectModel.shared))
        // The title, subtitle and toolbar are the view's, bridged into the
        // AppKit window rather than drawn twice.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = ConnectWindow(contentViewController: hosting)
        window.title = "Connect"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.setContentSize(NSSize(width: 900, height: 560))
        window.contentMinSize = NSSize(width: 720, height: 440)
        window.center()
        window.setFrameAutosaveName("UBConnectWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Esc, layered: clears the search, then stops a connect that is waiting,
    /// then closes this window and no other.
    ///
    /// - Parameter sender: The key event's sender.
    public override func cancelOperation(_ sender: Any?) {
        if ConnectModel.shared.handleEscape() == .closeWindow {
            window?.performClose(sender)
        }
    }

    /// Routes File > Close through the native window close without touching host sessions.
    @objc
    public func closePane(_ sender: Any?) {
        window?.performClose(sender)
    }

    /// Edit ▸ Find (⌘F) focuses the search field.
    ///
    /// - Parameter sender: The menu item.
    @objc
    public func performFindAction(_ sender: Any?) {
        ConnectModel.shared.isSearchFocused = true
    }

    #if UBIQUITTY_UI_TESTS
    /// The question last presented before a request that ends sessions, for
    /// a scenario reading its buttons.
    var destructiveAlertForTesting: NSAlert?
    #endif

    public func windowWillClose(_ notification: Notification) {
        ConnectModel.shared.windowWillClose()
    }

    /// Puts Core's question before a request that ends sessions in front of
    /// the person, as a sheet on this window, and sends the request when
    /// they answer with the button that goes through.
    ///
    /// The safe button keeps Return; see ``HostDestructiveAlert``.
    ///
    /// - Parameter question: Core's question.
    func present(_ question: HostDestructiveQuestion) {
        let directory = ConnectModel.shared.directory
        guard let window else { return }
        let alert = HostDestructiveAlert.present(question, for: directory, on: window)
        #if UBIQUITTY_UI_TESTS
        // A question already on the window presents nothing again, and the
        // alert that is up stays the one a scenario reads.
        if let alert { destructiveAlertForTesting = alert }
        #endif
    }
}

extension ConnectWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closePane(_:)) {
            return window?.styleMask.contains(.closable) == true && window?.attachedSheet == nil
        }
        return true
    }
}

/// The Connect window, which routes the Return chords itself.
///
/// ↩, ⌥↩ and ⌥⇧↩ differ only by modifiers, and a SwiftUI shortcut on Return
/// answers more than its own modifiers, so ⌥↩ reached New Named Session. The
/// window compares the modifiers exactly and hands each chord to the model;
/// a field editor, a sheet or a menu keeps Return for itself.
final class ConnectWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == "\r" || event.keyCode == 36 || event.keyCode == 76,
            attachedSheet == nil, !(firstResponder is NSText)
        {
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            let model = ConnectModel.shared
            switch modifiers {
            case []:
                guard model.isPrimaryKeyActive else { break }
                model.performPrimaryAction()
                return true
            case [.option]:
                guard model.selectedServer != nil else { break }
                model.newSession()
                return true
            case [.option, .shift]:
                guard model.selectedServer != nil else { break }
                model.isNamingSession = true
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Connection kinds

/// The kinds of connection a one-off form opens.
enum ConnectKind: String, CaseIterable, Identifiable {
    case ubiquittyHost
    case localTmux
    case remoteTmux
    case ssh
    case mosh
    case serial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ubiquittyHost: "Ubiquitty Host"
        case .localTmux: "tmux on This Mac"
        case .remoteTmux: "tmux over SSH"
        case .ssh: "SSH Shell"
        case .mosh: "mosh Shell"
        case .serial: "Serial Port"
        }
    }

    var subtitle: String {
        switch self {
        case .ubiquittyHost: "Persistent workspaces on a local or remote host"
        case .localTmux: "A tmux control-mode session on this Mac"
        case .remoteTmux: "tmux -CC over SSH"
        case .ssh: "A native SSH shell"
        case .mosh: "A roaming mosh shell"
        case .serial: "A tty or USB serial adapter"
        }
    }

    var symbol: String {
        switch self {
        case .ubiquittyHost: "bolt.horizontal.circle"
        case .localTmux: "square.split.2x2"
        case .remoteTmux: "square.split.2x2"
        case .ssh: "terminal"
        case .mosh: "antenna.radiowaves.left.and.right"
        case .serial: "cable.connector"
        }
    }

    var usesCharacterLocalePolicy: Bool {
        switch self {
        case .localTmux, .remoteTmux, .ssh, .mosh:
            true
        case .ubiquittyHost, .serial:
            false
        }
    }

    var defaultCharacterLocalePolicy: ConnectCharacterLocalePolicy {
        switch self {
        case .mosh:
            .forceUTF8
        case .ubiquittyHost, .localTmux, .remoteTmux, .ssh, .serial:
            .automatic
        }
    }
}

enum ConnectCharacterLocalePolicy: Int, CaseIterable, Identifiable {
    case automatic
    case preserve
    case forceUTF8

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .preserve: "Preserve"
        case .forceUTF8: "UTF-8"
        }
    }

    var corePolicy: Ubiquitty.PAL.CharacterLocalePolicy {
        switch self {
        case .automatic: .auto
        case .preserve: .preserve
        case .forceUTF8: .utf8
        }
    }
}

// MARK: - One-off connection form

/// The fields one kind of connection needs, as a grouped form.
struct ConnectForm: View {
    let kind: ConnectKind

    @State
    private var host = ""
    @State
    private var tmuxArgument = ""
    @State
    private var forwardAgent = ConnectModel.defaultForwardsSSHAgent()
    @State
    private var characterLocalePolicy: ConnectCharacterLocalePolicy
    @State
    private var serialDevice = ""
    @State
    private var baudRate = "115200"
    @FocusState
    private var isPrimaryFieldFocused: Bool
    /// Why the last launch opened no window, shown in place of the form.
    @State
    private var failure: ConnectLaunchFailure?

    private var serialDevices: [String] { ConnectModel.availableSerialDevices() }

    init(kind: ConnectKind) {
        self.kind = kind
        _characterLocalePolicy = State(initialValue: kind.defaultCharacterLocalePolicy)
    }

    var body: some View {
        if let failure {
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(failure.sentence).textSelection(.enabled)
            } actions: {
                Button("Try Again") { self.failure = nil }
                    .buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("connect-state-\(failure.stateName)")
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                fields
            } footer: {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if kind.usesCharacterLocalePolicy {
                Section {
                    Picker("Locale", selection: $characterLocalePolicy) {
                        ForEach(ConnectCharacterLocalePolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .help("Sets LC_CTYPE for the program that opens.")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            HStack {
                Spacer()
                Button(primaryButtonTitle) { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
            }
            .padding(12)
        }
        .onAppear {
            if serialDevice.isEmpty {
                serialDevice = serialDevices.first ?? ""
            }
            isPrimaryFieldFocused = true
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .localTmux:
            TextField("Session", text: $tmuxArgument, prompt: Text("main"))
                .focused($isPrimaryFieldFocused)
                .onSubmit(connect)
        case .remoteTmux, .ssh, .mosh, .ubiquittyHost:
            TextField("Address", text: $host, prompt: Text("you@server.example"))
                .focused($isPrimaryFieldFocused)
                .onSubmit(connect)
            if kind == .remoteTmux {
                TextField("Session", text: $tmuxArgument, prompt: Text("main"))
                    .onSubmit(connect)
            }
            if kind == .ssh {
                Toggle("Forward SSH Agent", isOn: $forwardAgent)
            }
        case .serial:
            if serialDevices.isEmpty {
                TextField("Device", text: $serialDevice, prompt: Text("/dev/cu.usbserial"))
                    .focused($isPrimaryFieldFocused)
                    .onSubmit(connect)
            } else {
                Picker("Device", selection: $serialDevice) {
                    ForEach(serialDevices, id: \.self) { device in
                        Text(device).tag(device)
                    }
                }
            }
            Picker("Baud", selection: $baudRate) {
                ForEach(["9600", "19200", "38400", "57600", "115200", "230400"], id: \.self) {
                    Text($0).tag($0)
                }
            }
        }
    }

    /// Core's reason for refusing the typed address, empty when it is one.
    private var addressReason: String {
        guard kind == .ssh || kind == .mosh || kind == .remoteTmux, !host.isEmpty else { return "" }
        let parsed = ConnectModel.parse(host)
        return parsed.isValid ? "" : parsed.reason
    }

    private var canConnect: Bool {
        switch kind {
        case .ssh, .mosh, .remoteTmux:
            !host.trimmingCharacters(in: .whitespaces).isEmpty && addressReason.isEmpty
        case .serial:
            !serialDevice.isEmpty
        case .localTmux, .ubiquittyHost:
            true
        }
    }

    private var footer: String {
        if !addressReason.isEmpty {
            return addressReason
        }
        switch kind {
        case .localTmux: return "Leave this blank to attach to or create “main”. Enter “attach” to join the last session."
        case .remoteTmux: return "Leave this blank to attach to or create “main” on the host."
        case .ssh, .mosh: return "Opens a shell in a new window."
        case .serial: return "Opens the device in a new window."
        case .ubiquittyHost: return ""
        }
    }

    private var primaryButtonTitle: String {
        switch kind {
        case .serial: "Open"
        case .localTmux, .remoteTmux: "Attach"
        default: "Open Shell"
        }
    }

    private func connect() {
        guard canConnect else { return }
        let target: String
        switch kind {
        case .localTmux: target = tmuxArgument
        case .serial: target = serialDevice
        default: target = host
        }
        failure = launch(
            kind: kind,
            target: target,
            tmuxSession: kind == .remoteTmux ? tmuxArgument : "",
            shouldForwardAgent: forwardAgent,
            localePolicy: characterLocalePolicy,
            baudRate: Int32(baudRate) ?? 115200
        )
        if failure == nil {
            ConnectWindowController.closeAfterSpawn()
        }
    }
}

// The single per-kind dispatch, shared by the form, the search suggestions and
// Beam's recents. Every launch goes through ConnectLauncher, which records a
// recent only for a target that opened.
@MainActor
private func launch(
    kind: ConnectKind,
    target: String,
    tmuxSession: String,
    shouldForwardAgent: Bool,
    localePolicy: ConnectCharacterLocalePolicy,
    baudRate: Int32
) -> ConnectLaunchFailure? {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .ubiquittyHost:
        ConnectRecents.record(trimmed.isEmpty ? "local" : trimmed, for: .ubiquittyHost)
        ConnectWindowController.show(place: trimmed.isEmpty || trimmed == "local" ? .thisMacHost : .recent(trimmed))
        return nil
    case .localTmux:
        return ConnectLauncher.openTmux(host: nil, session: target, localePolicy: localePolicy)
    case .remoteTmux:
        return ConnectLauncher.openTmux(host: trimmed, session: tmuxSession, localePolicy: localePolicy)
    case .ssh, .mosh:
        return ConnectLauncher.openShell(kind: kind, address: trimmed, shouldForwardAgent: shouldForwardAgent, localePolicy: localePolicy)
    case .serial:
        return ConnectLauncher.openSerial(device: trimmed, baudRate: baudRate)
    }
}

// MARK: - Quick connect (Beam recents)

// The fast path Beam's recents and the search suggestions use: connect with
// the kind's default extra fields.
enum ConnectQuickConnect {
    /// Connects to a recent target with the kind's defaults.
    ///
    /// A target that fails opens Connect on it rather than failing silently.
    ///
    /// - Parameters:
    ///   - kind: The kind.
    ///   - target: The address, session or device.
    /// - Returns: Whether a window opened.
    @MainActor
    @discardableResult
    static func run(kind: ConnectKind, target: String) -> Bool {
        let forwardAgent = ConnectModel.defaultForwardsSSHAgent()
        let failure = launch(
            kind: kind,
            target: target,
            tmuxSession: "",
            shouldForwardAgent: forwardAgent,
            localePolicy: kind.defaultCharacterLocalePolicy,
            baudRate: 115200
        )
        guard kind != .ubiquittyHost else { return false }
        if failure != nil {
            ConnectWindowController.show(place: kind == .localTmux ? .thisMacTmux : (kind == .serial ? .serialPorts : .shell(kind)))
        }
        return failure == nil
    }
}

// MARK: - Layouts

/// The saved window arrangements, opened beside what is already open.
struct LayoutsPane: View {
    @Bindable
    var model: ConnectModel

    @State
    private var selection: String?
    @State
    private var newName = ""

    var body: some View {
        Group {
            if model.layouts.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Layouts", systemImage: "rectangle.3.group")
                } description: {
                    Text("A layout is a whole arrangement of windows and tabs, reopened beside what is already open.")
                }
                .accessibilityIdentifier("connect-state-layouts-empty")
            } else {
                List(model.layouts, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                }
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first { model.openLayout(id) }
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            HStack(spacing: 12) {
                TextField("Layout Name", text: $newName, prompt: Text("Name this layout"))
                    .frame(maxWidth: 220)
                    .onSubmit(saveCurrent)
                Button("Save Current Layout", action: saveCurrent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !model.hasWindowsToSave)
                Text(model.layoutFooter)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connect-sentence")
                Spacer()
                Button("Open") { if let selection { model.openLayout(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil)
            }
            .padding(12)
        }
        .onAppear {
            model.reloadLayouts()
            if selection == nil { selection = model.layouts.first?.id }
        }
    }

    private func saveCurrent() {
        if model.saveLayout(named: newName) {
            newName = ""
        }
    }
}
