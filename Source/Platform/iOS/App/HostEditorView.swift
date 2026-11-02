// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import CxxStdlib
import SwiftUI
import UbiquittyCore
import UbiquittyIOSBridge
import UbiquittySSH

/// Adding a host, or changing one.
///
/// The secret is write-only here on purpose: it is read back from the keychain
/// only to authenticate, never to show. An editor that redisplayed a stored
/// password would put it on screen every time somebody opened the row to change
/// a port. A stored key is read once to name it by its public half, which is
/// not a secret.
///
/// A field is judged when the person leaves it or taps Save, never before:
/// a form that opens with an error blames someone for not having typed yet.
/// A missing value is reported only on Save; a value that cannot work, such
/// as a port of 70000, as soon as the field is left.
struct HostEditorView: View {
    /// The fields the form moves focus between and reports errors under.
    enum Field: Hashable {
        case address
        case user
        case port
        case name
        case password
        case key
        case workspace
    }

    @Environment(\.dismiss)
    private var dismiss

    @State
    private var record: HostRecord
    /// A password typed to save, empty to keep what is stored.
    @State
    private var password = ""
    /// A key pasted, imported or made to save, empty to keep what is stored.
    @State
    private var keyText = ""
    @FocusState
    private var focus: Field?
    /// The fields the person has left, whose values are now judged.
    @State
    private var leftFields: Set<Field> = []
    @State
    private var hasTriedToSave = false
    @State
    private var saveOutcome = SettledOutcome()
    @State
    private var isForgettingHostKey = false
    @State
    private var learnMore: LearnMoreTopic?
    @State
    private var isConfirmingDiscard = false
    /// The Port field's selection, all of it when the field takes focus, so
    /// the digits typed replace 22 rather than join it.
    @State
    private var portSelection: TextSelection?

    private let isNew: Bool
    /// The record as the editor opened it, to tell an edit from none.
    private let originalRecord: HostRecord
    private let onSave: (HostRecord, String?) -> Void
    /// The method the record was saved with when the editor opened.
    private let originalKind: HostAuthenticationKind
    /// Whether the keychain held a secret for the host when the editor opened.
    private let hasStoredSecret: Bool
    /// The stored key, by its public half, when the host signed in with one.
    private let storedKey: SSHKeyDescription?

    /// Creates the editor.
    ///
    /// - Parameters:
    ///   - record: The host to edit, or a new record.
    ///   - isNew: Whether the record has never been saved, which titles the
    ///     sheet New Host until it is.
    ///   - onSave: Takes the saved record and the secret to store, nil to keep
    ///     what the keychain holds.
    init(record: HostRecord, isNew: Bool, onSave: @escaping (HostRecord, String?) -> Void) {
        _record = State(initialValue: record)
        originalRecord = record
        self.isNew = isNew
        self.onSave = onSave
        originalKind = record.authenticationKind
        let stored = isNew ? nil : SecretStore.secret(for: record.id)
        hasStoredSecret = stored != nil
        if record.authenticationKind == .privateKey, let stored, case .key(let key) = SSHPrivateKeyText.read(stored) {
            storedKey = SSHKeyDescription(key)
        } else {
            storedKey = nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                signInSection
                workspacesSection
                notificationsSection
                if !record.pinnedHostKeyFingerprint.isEmpty {
                    securitySection
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("host-editor-form")
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .namingTheHost(isNew ? nil : originalRecord.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .toolbar {
                // The system draws both: an X that cancels, a checkmark that
                // saves, each with its spoken name.
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        if hasUnsavedEdits { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("Discard Changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save)
                        .disabled(!canTrySave)
                }
                // A number pad has no return key, and on a short display it
                // covers every row under the port: without a way to put it
                // away the form cannot be finished.
                ToolbarItemGroup(placement: .keyboard) {
                    if focus == .port {
                        Spacer()
                        Button("Done") { focus = nil }
                            .accessibilityIdentifier("host-editor-keyboard-done")
                    }
                }
            }
            .guardingUnsavedEdits(hasUnsavedEdits) { dismiss() }
            .onChange(of: focus) { left, entered in
                if entered == .port {
                    let text = portText.wrappedValue
                    portSelection = TextSelection(range: text.startIndex..<text.endIndex)
                }
                guard let left else { return }
                if left == .address { splitAddress() }
                leftFields.insert(left)
            }
            .onChange(of: record.hostName) { old, new in
                // A paste arrives as one change of many characters. Typing
                // arrives one at a time and is left alone until the field is
                // left, or `user@` would jump out of the field mid-word.
                if new.count - old.count > 1 { splitAddress() }
            }
            .onChange(of: canSaveCredential) { _, canSave in
                if !canSave { record.isBackgroundRefreshEnabled = false }
            }
            .sensoryFeedback(trigger: saveOutcome, SettledOutcome.feedback)
            .learnMoreLinks([Self.workspacesTopic, notificationsTopic], shown: $learnMore)
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Server") {
            field("Address", .address) {
                TextField("Address", text: $record.hostName, prompt: Text(verbatim: "host.example.com"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focus = .user }
            }
            field("User Name", .user) {
                TextField("User Name", text: $record.username, prompt: Text("Required"))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focus = .port }
            }
            field("Port", .port) {
                TextField("Port", text: portText, selection: $portSelection, prompt: Text(verbatim: "22"))
                    .keyboardType(.numberPad)
            }
            field("Name", .name) {
                TextField("Name", text: $record.name, prompt: Text(namePrompt))
                    .submitLabel(.done)
            }
        }
    }

    private var signInSection: some View {
        Section {
            Picker("Sign In With", selection: $record.authenticationKind) {
                ForEach(HostAuthenticationKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            switch record.authenticationKind {
            case .password:
                field("Password", .password) {
                    SecureField("Password", text: $password, prompt: Text(isStoredSecretKept ? "Saved" : "Required"))
                        // An autocapitalized first letter is a different secret
                        // of the same length, and the server's refusal names the
                        // person rather than the keyboard.
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                }
            case .privateKey:
                NavigationLink {
                    HostKeyView(keyText: $keyText, storedKey: isStoredSecretKept ? storedKey : nil)
                } label: {
                    LabeledContent("Key", value: keySummary)
                }
                if let problem = problem(for: .key) {
                    ErrorMessage(problem).font(.footnote)
                }
            case .passwordPrompt:
                EmptyView()
            }
        } header: {
            Text("Sign In")
        } footer: {
            Text(signInFooter)
        }
    }

    @ViewBuilder
    private var workspacesSection: some View {
        Section {
            Toggle("Use Workspaces", isOn: $record.prefersQUIC.animation())
        } header: {
            Text("Workspaces")
        } footer: {
            Text(Self.workspacesTopic.footer(String(localized: "Keeps your sessions running on the host when you disconnect.")))
        }
        if record.prefersQUIC {
            Section {
                field("Workspace", .workspace) {
                    TextField("Workspace", text: $record.workspaceName, prompt: Text("Optional"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                }
            } footer: {
                Text("Opens this workspace when you connect. Leave it empty to choose each time.")
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $record.isBackgroundRefreshEnabled) {
                Text("Check While Away")
                if let reason = backgroundRefreshObstruction {
                    Text(reason)
                }
            }
            .disabled(backgroundRefreshObstruction != nil)
        } header: {
            Text("Notifications")
        } footer: {
            Text(
                notificationsTopic.footer(String(localized: "Checks this host for messages while your \(InterfaceDevice.name) is locked."))
            )
        }
    }

    private var securitySection: some View {
        Section("Security") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Host Key")
                CharacterWrappedText(record.pinnedHostKeyFingerprint, style: .caption1, color: .secondaryLabel)
            }
            Button("Forget Key…", role: .destructive) { isForgettingHostKey = true }
                .confirmationDialog("Forget Host Key?", isPresented: $isForgettingHostKey, titleVisibility: .visible) {
                    Button("Forget Key", role: .destructive) {
                        record.pinnedHostKeyFingerprint = ""
                        record.isBackgroundRefreshEnabled = false
                    }
                } message: {
                    Text(
                        "The next connection trusts whatever key the host offers. Forget the key only if you know why the host’s key changed."
                    )
                }
        }
    }

    // MARK: - Rows

    /// One labeled row with the field trailing, and the field's error, when it
    /// has one, under it.
    ///
    /// A row of its own rather than `LabeledContent`, which merges its label
    /// and content into one element: VoiceOver would read the row and never
    /// reach the field inside it. The field carries the label's name, so the
    /// visible label is hidden from accessibility rather than read twice.
    @ViewBuilder
    private func field<Content: View>(_ label: LocalizedStringKey, _ field: Field, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .accessibilityHidden(true)
            Spacer(minLength: 16)
            content()
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: field)
                .accessibilityLabel(Text(label))
        }
        if let problem = problem(for: field) {
            ErrorMessage(problem).font(.footnote)
        }
    }

    // MARK: - What the form says

    /// What the Name field shows until a name is typed: the name the list
    /// gives a host without one.
    private var namePrompt: String {
        var unnamed = record
        unnamed.name = ""
        return unnamed.hostName.isEmpty ? String(localized: "Optional") : unnamed.displayName
    }

    private var signInFooter: String {
        switch record.authenticationKind {
        case .password: return String(localized: "Saved in the keychain on this \(InterfaceDevice.name).")
        case .passwordPrompt:
            return String(localized: "You’re asked for the password when the server wants one. You can choose to save it when you connect.")
        case .privateKey: return String(localized: "If the server refuses the key, you’re asked for a password.")
        }
    }

    /// The port as the field edits it: digits only, read as text so the
    /// caret stays where the person put it, which a formatted number field
    /// moves to the start when it takes focus.
    ///
    /// An empty field is port 0, which the field reports as out of range
    /// once it is left.
    private var portText: Binding<String> {
        Binding(
            get: { record.port == 0 ? "" : String(record.port) },
            set: { text in
                let digits = String(text.filter(\.isASCII).filter(\.isNumber).prefix(5))
                record.port = Int(digits) ?? 0
            }
        )
    }

    /// The key row's value: the key's algorithm and the start of its
    /// fingerprint, or that there is none.
    private var keySummary: String {
        guard let key = editedKey else { return String(localized: "No Key") }
        return "\(key.algorithm) · \(key.fingerprint.prefix(11))…"
    }

    /// The key the host will sign in with once saved.
    private var editedKey: SSHKeyDescription? {
        if !keyText.isEmpty, case .key(let key) = SSHPrivateKeyText.read(keyText) { return SSHKeyDescription(key) }
        return isStoredSecretKept ? storedKey : nil
    }

    private var notificationsTopic: LearnMoreTopic {
        let device = InterfaceDevice.name
        return LearnMoreTopic(
            title: String(localized: "Check While Away"),
            paragraphs: [
                String(
                    localized:
                        "While your \(device) is locked, Ubiquitty can sign in to this host from time to time to check whether a program is waiting for you, and notify you when one is."
                ),
                String(
                    localized:
                        "To do that, Ubiquitty keeps a separate copy of this host’s saved password or key that it can use while your \(device) is locked, once you’ve unlocked it after a restart. The copy has the same access to the host as your account."
                ),
                String(
                    localized:
                        "iOS decides when the checks run, so a notification can arrive late. Connect to the host once before you turn this on, so Ubiquitty knows the host’s key."
                ),
                String(localized: "Turning this off deletes the copy and anything Ubiquitty saved from the checks."),
            ]
        )
    }

    private static let workspacesTopic = LearnMoreTopic(
        title: String(localized: "Workspaces"),
        paragraphs: [
            String(
                localized:
                    "A workspace is a set of tabs and panes that keeps running on the host after you disconnect. When you connect again, from this device or another, it’s as you left it."
            ),
            String(
                localized:
                    "Workspaces need Ubiquitty on the host. Ubiquitty signs in over SSH and checks the host’s key, then moves the session to QUIC, which keeps it connected as your network changes."
            ),
            String(
                localized:
                    "If the host can’t use QUIC, Ubiquitty opens a regular SSH session instead, without workspaces, and shows which kind of connection it made."
            ),
        ]
    )

    // MARK: - Judging the form

    /// Whether closing the sheet would lose something the person typed,
    /// pasted or made: a generated key exists nowhere else until it is saved.
    private var hasUnsavedEdits: Bool {
        record != originalRecord || !password.isEmpty || !keyText.isEmpty
    }

    /// Whether the secret already in the keychain is still the kind the form
    /// edits. A saved password is not a key, so changing the method asks for
    /// the new secret rather than reading the old one as the new kind.
    private var isStoredSecretKept: Bool {
        hasStoredSecret && record.authenticationKind.savedCredential == originalKind.savedCredential
    }

    /// The secret to store with this edit, nil to keep what the keychain holds.
    private var editedSecret: String? {
        switch record.authenticationKind {
        case .password: return password.isEmpty ? nil : password
        case .privateKey: return keyText.isEmpty ? nil : keyText
        case .passwordPrompt: return nil
        }
    }

    /// Whether the host will have a saved credential once this edit is saved.
    private var canSaveCredential: Bool {
        record.authenticationKind.savedCredential != .none && (editedSecret != nil || isStoredSecretKept)
    }

    /// Why Check While Away cannot be turned on, or nil when it can.
    private var backgroundRefreshObstruction: String? {
        if !canSaveCredential { return String(localized: "Needs a saved password or key.") }
        if record.pinnedHostKeyFingerprint.isEmpty { return String(localized: "Connect once to turn this on.") }
        return nil
    }

    /// Save is offered once there is an address and a user to sign in as;
    /// anything else wrong is said under its field when Save is tapped.
    private var canTrySave: Bool {
        !record.hostName.trimmingCharacters(in: .whitespaces).isEmpty && !record.username.isEmpty
    }

    /// What is wrong with a field, once the person has left it or tried to
    /// save; nil when nothing is, or when it is not yet time to say.
    private func problem(for field: Field) -> String? {
        let isJudged = hasTriedToSave || leftFields.contains(field)
        switch field {
        case .address:
            if record.hostName.isEmpty { return hasTriedToSave ? String(localized: "Enter an address.") : nil }
            return isJudged ? addressProblem : nil
        case .user:
            return hasTriedToSave && record.username.isEmpty ? String(localized: "Enter a user name.") : nil
        case .port:
            return isJudged && !(1...65535).contains(record.port) ? String(localized: "Enter a port from 1 to 65535.") : nil
        case .password:
            guard hasTriedToSave, record.authenticationKind == .password, !canSaveCredential else { return nil }
            return String(localized: "Enter a password, or choose Ask for Password.")
        case .key:
            guard hasTriedToSave, record.authenticationKind == .privateKey, editedKey == nil else { return nil }
            return String(localized: "Add a key, or choose another way to sign in.")
        case .name, .workspace:
            return nil
        }
    }

    /// Why the address cannot be dialled, in Core's words, or nil when it can.
    ///
    /// Core's address parse is the one every client's address field asks, and
    /// `ubiquittyIOSValidateSSHHost` is the rule the dialling code holds the
    /// record to.
    private var addressProblem: String? {
        let address = Self.parse(record.hostName)
        if !address.isValid { return String(address.reason) }
        if !ubiquittyIOSValidateSSHHost(record.hostName) {
            return String(localized: "The address contains a character that isn’t allowed.")
        }
        return nil
    }

    /// The fields in the order the form shows them, for the first error.
    private static let fieldOrder: [Field] = [.address, .user, .port, .name, .password, .key, .workspace]

    private func save() {
        hasTriedToSave = true
        splitAddress()
        if let first = Self.fieldOrder.first(where: { problem(for: $0) != nil }) {
            saveOutcome.record(succeeded: false)
            if first != .key { focus = first }
            return
        }
        var saved = record
        saved.hostName = saved.hostName.trimmingCharacters(in: .whitespaces)
        onSave(saved, editedSecret)
        dismiss()
    }

    /// Takes a pasted or typed `user@host:port` apart into the three fields.
    ///
    /// Read by Core's address parse, so `[v6]:port`, a bare IPv6 literal and
    /// an `ssh ` prefix split here exactly as they do in every other client.
    private func splitAddress() {
        let address = Self.parse(record.hostName)
        guard address.isValid, address.kindHint == .None || address.kindHint == .SSH else { return }
        let user = String(address.user)
        guard !user.isEmpty || address.port != 0 || address.kindHint == .SSH else { return }
        record.hostName = String(address.host)
        if !user.isEmpty { record.username = user }
        if address.port != 0 { record.port = Int(address.port) }
    }

    private static func parse(_ text: String) -> Ubiquitty.Transport.ConnectAddress {
        text.withCString { Ubiquitty.Transport.parseConnectAddress(std.string_view($0)) }
    }
}

extension View {
    /// Names the host being edited under the sheet's title; a new host has
    /// no name to give yet.
    ///
    /// - Parameter name: The host's name as the list shows it, nil for none.
    @ViewBuilder
    fileprivate func namingTheHost(_ name: String?) -> some View {
        if let name {
            navigationSubtitle(Text(verbatim: name))
        } else {
            self
        }
    }
}
