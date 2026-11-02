// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittySSH

/// What a session's sign-in is waiting on the person for.
///
/// Raised only by the server: a password the server listed and nothing saved
/// answered, or a banner whose link the server waits on, as a Tailscale check
/// does. Nothing here is asked before the server has asked for it.
struct SignInPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The server wants a password.
        case password(SSHPasswordRequest)
        /// The server holds the sign-in until its link is opened and approved.
        case approval(SSHAuthenticationBanner)
    }

    let id = UUID()
    let kind: Kind
    /// The host as the list names it.
    let hostLabel: String
    /// Whether the person may keep the password: the host signs in with one
    /// and nothing usable is saved for it.
    var canSavePassword = false
}

/// Carries the package's questions to the session model on the main actor.
///
/// Weak toward the model: the interaction outlives a model that was ended,
/// and a question for a session nobody is watching is answered no.
final class SignInPerson: SSHAuthenticationPerson, @unchecked Sendable {
    init(model: TerminalSessionModel) {
        self.model = model
    }

    func askForPassword(_ request: SSHPasswordRequest, answer: @escaping @Sendable (String?) -> Void) {
        Task { @MainActor [weak self] in
            guard let model = self?.model else { return answer(nil) }
            model.askForPassword(request, answer: answer)
        }
    }

    func show(_ banner: SSHAuthenticationBanner) {
        Task { @MainActor [weak self] in self?.model?.showSignInBanner(banner) }
    }

    func bannerWaitEnded() {
        Task { @MainActor [weak self] in self?.model?.endSignInApproval() }
    }

    private weak var model: TerminalSessionModel?
}

/// Asks for the password the server wants in an alert with one secure field,
/// as the system asks for a Wi-Fi or file server password.
///
/// A single secret is an alert's job rather than a sheet's: a sheet holding
/// one field leaves most of itself empty and reads as a form to fill in. The
/// alert names the host, says who signs in where, and offers to keep the
/// password where the host can keep one. A kept password is saved only once
/// the server accepts it, so a mistyped one is never kept.
struct PasswordPromptAlert: ViewModifier {
    /// The prompt, when it asks for a password; nil otherwise.
    let prompt: SignInPrompt?
    /// Receives the password, or nil when the person canceled, and whether to
    /// save it.
    let onAnswer: (SignInPrompt, String?, Bool) -> Void

    @State
    private var password = ""

    func body(content: Content) -> some View {
        content.alert(
            "Password for “\(prompt?.hostLabel ?? "")”",
            isPresented: Binding(get: { request != nil }, set: { _ in }),
            presenting: prompt
        ) { prompt in
            SecureField("Password", text: $password)
                // A password field that capitalises its first letter sends a
                // different secret than the one typed, at the same length, and
                // the server answers "incorrect" — which reads as the person's
                // mistake. iOS applies sentence capitalisation unless told
                // otherwise, so every field holding a secret says otherwise.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            Button("Connect") { answer(prompt, save: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            if prompt.canSavePassword {
                Button("Connect and Save Password") { answer(prompt, save: true) }
                    .disabled(password.isEmpty)
            }
            Button("Cancel", role: .cancel) {
                password = ""
                onAnswer(prompt, nil, false)
            }
        } message: { _ in
            if let request {
                Text(message(for: request))
            }
        }
    }

    private var request: SSHPasswordRequest? {
        guard case .password(let request) = prompt?.kind else { return nil }
        return request
    }

    /// Who signs in where, then the start of the server's banner when it
    /// sent one: the only text of its own the password method carries.
    private func message(for request: SSHPasswordRequest) -> String {
        let account = "\(request.username)@\(request.host)"
        guard let banner = request.banner?.message.trimmingCharacters(in: .whitespacesAndNewlines), !banner.isEmpty else {
            return account
        }
        let shown: String = banner.count > Self.bannerCharacters ? String(banner.prefix(Self.bannerCharacters)) + "…" : banner
        return account + "\n\n" + shown
    }

    /// The longest part of a banner the alert shows; the whole of it is in
    /// the connection log.
    private static let bannerCharacters = 280

    private func answer(_ prompt: SignInPrompt, save: Bool) {
        guard !password.isEmpty else { return }
        let typed = password
        password = ""
        onAnswer(prompt, typed, save)
    }
}

/// Shows the page the server is waiting on, in the server's own words.
///
/// A sheet rather than an alert: the server's message can be long and carries
/// a link to open, and the sign-in waits until the server answers.
struct SignInApprovalView: View {
    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.openURL)
    private var openURL

    let banner: SSHAuthenticationBanner
    let hostLabel: String
    /// Called when the person cancels the sign-in.
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(banner.message)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    if let link = banner.link {
                        Button("Open Link", systemImage: "safari") { openURL(link) }
                            .accessibilityIdentifier("sign-in-open-link")
                    }
                } header: {
                    Text("Message from the Server")
                } footer: {
                    Text("The server is waiting for you to approve this sign-in. The connection continues when it answers.")
                }
            }
            .navigationTitle(hostLabel)
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .toolbar {
                SheetToolbar(
                    cancel: {
                        onCancel()
                        dismiss()
                    }
                )
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
