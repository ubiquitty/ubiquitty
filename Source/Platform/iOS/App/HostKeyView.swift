// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit
import UbiquittySSH
import UniformTypeIdentifiers

/// The key a host signs in with: which one it is, and the three ways to give
/// it one.
///
/// A key arrives as text — pasted, read from a file, or made here — and the
/// editor stores that text in the keychain when the host is saved, so every
/// key takes the one path the connection reads. A key is accepted here only
/// once the reader has read it, so a file that cannot sign in is refused with
/// its reason now rather than at the server later.
struct HostKeyView: View {
    /// The key text to save with the host, empty to keep the stored one.
    @Binding
    var keyText: String
    /// The key the keychain holds for the host, nil when none is kept.
    let storedKey: SSHKeyDescription?

    @State
    private var refusal: String?
    @State
    private var isImporting = false
    @State
    private var isConfirmingReplacement = false
    @State
    private var shownPublicKey: PublicKey?

    /// A public key line on its way to the sheet that shows it.
    struct PublicKey: Identifiable {
        let line: String
        /// Whether the key was made just now, which the sheet's wording says.
        let isNew: Bool
        var id: String { line }
    }

    var body: some View {
        Form {
            Section("Current Key") {
                if let key {
                    LabeledContent("Type", value: key.algorithm)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint")
                        CharacterWrappedText(key.fingerprint, style: .caption1, color: .secondaryLabel)
                    }
                    .accessibilityElement(children: .combine)
                    Button("Show Public Key") {
                        shownPublicKey = PublicKey(line: key.authorizedKeysLine(comment: Self.comment), isNew: false)
                    }
                } else {
                    Text("No Key").foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Paste Key", systemImage: "doc.on.clipboard") { accept(UIPasteboard.general.string ?? "") }
                    .disabled(!UIPasteboard.general.hasStrings)
                Button("Import from Files…", systemImage: "folder") { isImporting = true }
                Button("Generate New Key", systemImage: "key") {
                    if key == nil { generate() } else { isConfirmingReplacement = true }
                }
            } footer: {
                if let refusal {
                    ErrorMessage(refusal)
                } else {
                    Text("Ed25519 and ECDSA keys are supported, in OpenSSH or PEM format.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data, .text]) { result in
            switch result {
            case .success(let url): accept(Self.read(url))
            case .failure: refusal = String(localized: "The file couldn’t be opened.")
            }
        }
        .confirmationDialog("Replace Current Key?", isPresented: $isConfirmingReplacement, titleVisibility: .visible) {
            Button("Replace Key", role: .destructive) { generate() }
        } message: {
            Text("The host won’t accept the new key until you add its public key to the host.")
        }
        .sheet(item: $shownPublicKey) { PublicKeySheet(publicKey: $0) }
    }

    /// The key the host will sign in with once saved.
    private var key: SSHKeyDescription? {
        if !keyText.isEmpty, case .key(let key) = SSHPrivateKeyText.read(keyText) { return SSHKeyDescription(key) }
        return storedKey
    }

    /// What a public key line ends with, to tell this device's key apart in a
    /// host's `authorized_keys`.
    private static var comment: String { "Ubiquitty on \(InterfaceDevice.name)" }

    /// Takes a key's text when it reads as a key, or says why it does not.
    private func accept(_ text: String) {
        switch SSHPrivateKeyText.read(text) {
        case .key:
            keyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            refusal = nil
        case .refused(let reason):
            refusal = reason
        }
    }

    private func generate() {
        let text = SSHPrivateKeyText.makeP256Key()
        guard case .key(let made) = SSHPrivateKeyText.read(text) else { return }
        keyText = text
        refusal = nil
        shownPublicKey = PublicKey(line: SSHKeyDescription(made).authorizedKeysLine(comment: Self.comment), isNew: true)
    }

    /// The text of an imported file, read no further than a key can be long.
    private static func read(_ url: URL) -> String {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: SSHPrivateKeyText.maxTextLength + 1)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// A public key, to copy or share to the host that should accept it.
struct PublicKeySheet: View {
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var copies = 0

    let publicKey: HostKeyView.PublicKey

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CharacterWrappedText(publicKey.line, style: .footnote, color: .label)
                } footer: {
                    Text("Add this line to ~/.ssh/authorized_keys on the host.")
                }
                Section {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = publicKey.line
                        copies += 1
                    }
                    ShareLink(item: publicKey.line) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(publicKey.isNew ? "New Public Key" : "Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .sheetChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .sensoryFeedback(.success, trigger: copies)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Monospaced text that wraps at any character and never hyphenates.
///
/// A fingerprint or a public key is one long word. SwiftUI's `Text` breaks
/// such a word with a hyphen, which reads as part of the value a person
/// compares or copies by eye; a label wrapping by character breaks it
/// without adding anything.
struct CharacterWrappedText: UIViewRepresentable {
    private let text: String
    private let style: UIFont.TextStyle
    private let color: UIColor

    /// Creates the text.
    ///
    /// - Parameters:
    ///   - text: The value to show.
    ///   - style: The text style whose size the monospaced face takes, scaled
    ///     with Dynamic Type.
    ///   - color: The text's color.
    init(_ text: String, style: UIFont.TextStyle, color: UIColor) {
        self.text = text
        self.style = style
        self.color = color
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = NSLineBreakMode.byCharWrapping
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
            .pointSize
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
        label.textColor = color
        label.text = text
        label.accessibilityLabel = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fitted = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? fitted.width, height: fitted.height)
    }
}
