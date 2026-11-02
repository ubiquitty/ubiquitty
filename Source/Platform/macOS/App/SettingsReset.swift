// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UbiquittyKit

/// Removing an explicit value lets Core resolve its default without pinning it in the file.
struct SettingsResetProposal: Identifiable {
    let id = UUID()
    let title: String
    let rows: [SettingsRow]

    static func removing(_ row: SettingsRow, from document: std.string) -> std.string {
        guard let key = Ubiquitty.Preferences.keyForAddress(std.string(row.id)).value else { return document }
        let descriptor = Ubiquitty.Preferences.descriptorFor(key).pointee
        guard let section = descriptor.section, let name = descriptor.key else { return document }
        return Ubiquitty.Preferences.removeSectionKey(document, std.string(section), std.string(name))
    }

    static func customized(_ rows: [SettingsRow]) -> [SettingsRow] {
        let document = Ubiquitty.Preferences.liveDocument().pointee
        return rows.filter { removing($0, from: document) != document }
    }

    var document: std.string {
        rows.reduce(Ubiquitty.Preferences.liveDocument().pointee) { Self.removing($1, from: $0) }
    }

    func apply() { _ = Ubiquitty.Preferences.configureOwnDocument(document) }
}

/// Previews the exact document edit; opening or canceling the sheet writes nothing.
struct SettingsResetSheet: View {
    let proposal: SettingsResetProposal
    @State
    private var revision = 0

    var body: some View {
        let _ = revision
        let preview = Ubiquitty.Preferences.previewConfiguration(proposal.document)
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset \(proposal.title)?").font(.headline)
            Text("Removes these overrides from app settings. Platform settings and profiles keep their overrides.")
                .foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("Setting")
                        Text("Current")
                        Text("After Reset")
                    }
                    .font(.headline)
                    ForEach(SettingsResetProposal.customized(proposal.rows)) { row in
                        if let key = Ubiquitty.Preferences.keyForAddress(std.string(row.id)).value {
                            GridRow {
                                Text(row.label)
                                Text(display(Ubiquitty.Preferences.effectiveValue(key, Ubiquitty.Preferences.values().pointee).value))
                                Text(display(Ubiquitty.Preferences.effectiveValue(key, preview).value))
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ModalButtons(
                saveLabel: "Reset",
                saveDisabled: SettingsResetProposal.customized(proposal.rows).isEmpty,
                onCancel: {},
                onSave: proposal.apply
            )
        }
        .padding(24)
        .frame(width: 560, height: 350)
        .onReceive(NotificationCenter.default.publisher(for: SettingsBridge.valuesChanged)) { _ in revision &+= 1 }
    }

    private func display(_ value: Ubiquitty.Preferences.Value?) -> String {
        guard let value else { return "Automatic" }
        switch value.kind {
        case .Bool, .LegacyBoolOrToken: return value.boolean ? "On" : "Off"
        case .Int: return value.integer.formatted()
        case .Double: return value.number.formatted()
        default: return value.text.empty() ? "Automatic" : String(value.text)
        }
    }
}
