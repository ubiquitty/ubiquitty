// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// AgentsPane.swift — Settings → Agents: issue, list, and revoke the
// capability tokens that authorize an AI agent to attach to this host.
//
// Reads + writes funnel through the application delegate, which backs onto the
// bundled `ubiquitty-host token …` CLI + the ~/.ubiquitty/tokens store: listing
// parses the store, issuing runs `token issue` (the secret is surfaced once),
// and revoking runs `token revoke` (which also drops any live connection using
// the token). The daemon + CLI stay the single source of truth.
//

import AppKit
import SwiftUI

// One issued token as the pane sees it. The plaintext secret is never here —
// only the digest (id), shown so revoke has a handle.
private struct AgentToken: Identifiable {
    var id: String // full sha256 digest
    var idShort: String
    var label: String
    var scope: String // decoded comma list
    var expiry: String // "never" / "active" / "expired"

    init(dict: [String: Any]) {
        id = dict["id"] as? String ?? ""
        idShort = dict["idShort"] as? String ?? ""
        label = dict["label"] as? String ?? ""
        scope = dict["scope"] as? String ?? ""
        expiry = dict["expiry"] as? String ?? ""
    }
}

// (scope-token, human description). The token strings match what the CLI's
// --scope list accepts.
private let scopeChoices: [(key: String, label: String)] = [
    ("observe", "Observe — attach and read the screen"),
    ("drive", "Drive — send keystrokes and paste"),
    ("control", "Control — list and terminate sessions"),
    ("region", "Region — read parts of the screen and the last output"),
    ("new", "New — create sessions"),
]

struct AgentsPane: View {
    @State
    private var tokens: [AgentToken] = []
    @State
    private var issuing = false

    var body: some View {
        SettingsListPane(
            title: "Agent Tokens",
            footer: "A token lets an AI agent attach to this host. Its secret is shown only once, "
                + "when the token is issued, so store it then. Revoking a token ends any "
                + "connection that uses it.",
            emptyText: "No tokens issued.",
            addLabel: "Issue Token",
            items: tokens,
            onAdd: { issuing = true },
            reload: reload,
            addSearchID: "agents.issue"
        ) { token in
            row(token)
        }
        .sheet(isPresented: $issuing) {
            AgentTokenIssueSheet(onIssued: reload)
        }
    }

    @ViewBuilder
    private func row(_ token: AgentToken) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.label.isEmpty ? "(unlabeled)" : token.label)
                Text("\(token.idShort) · \(token.scope)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(token.expiry)
                .font(.caption)
                .foregroundStyle(token.expiry == "expired" ? .red : .secondary)
            Button(role: .destructive) {
                revoke(token)
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    private func reload() {
        tokens = (SettingsBridge.app?.settingsAgentTokens() ?? []).map { AgentToken(dict: $0) }
    }

    private func revoke(_ token: AgentToken) {
        var revokeError: NSString?
        let revoked = SettingsBridge.app?.settingsRevokeAgentToken(token.id, error: &revokeError) ?? false
        if !revoked {
            presentError(
                "Couldn’t Revoke the Token",
                informativeText: (revokeError as String?) ?? "An unknown error occurred. Try again."
            )
        }
        reload()
    }
}

// Issue sheet: a label + scope form that, on success, swaps to a one-time
// reveal of the secret (copy + done). The secret exists only here, once.
private struct AgentTokenIssueSheet: View {
    let onIssued: () -> Void
    @Environment(\.dismiss)
    private var dismiss

    @State
    private var label = ""
    @State
    private var scopes: Set<String> = ["observe", "drive"]
    @State
    private var secret: String? // set after a successful issue
    @State
    private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let secret {
                secretView(secret)
            } else {
                formView
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Issue Agent Token").font(.headline)
            HStack {
                Text("Label").frame(width: 70, alignment: .leading)
                TextField("e.g. claude", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Scopes").font(.subheadline).foregroundStyle(.secondary)
                ForEach(scopeChoices, id: \.key) { choice in
                    Toggle(
                        isOn: Binding(
                            get: { scopes.contains(choice.key) },
                            set: { on in
                                if on { scopes.insert(choice.key) } else { scopes.remove(choice.key) }
                            }
                        )
                    ) { Text(choice.label) }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            // The sheet stays up on Issue: a success swaps to the one-time
            // secret reveal, a failure shows the inline error.
            ModalButtons(
                saveLabel: "Issue",
                saveDisabled: scopes.isEmpty,
                dismissesOnSave: false,
                onCancel: {},
                onSave: issue
            )
        }
    }

    private func secretView(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Token issued", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Copy it now. It’s shown only once and can’t be recovered.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func issue() {
        let scopeList = scopeChoices.map(\.key).filter { scopes.contains($0) }.joined(separator: ",")
        var err: NSString?
        let result = SettingsBridge.app?.settingsIssueAgentToken(withLabel: label, scope: scopeList, error: &err)
        if let result, !result.isEmpty {
            secret = result
            onIssued()
        } else {
            error = (err as String?) ?? "The token couldn’t be issued. Try again."
        }
    }
}
