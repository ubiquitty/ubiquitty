// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Reordering writes the shared preference, so every open keyboard follows it.
struct AccessoryKeysView: View {
    let settings: AppSettingsModel

    private var available: [TerminalAccessoryKey] {
        let shown = Set(settings.accessorySymbols.map(\.id))
        return TerminalAccessoryKey.symbols.filter { !shown.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                ForEach(settings.accessorySymbols) { key in
                    row(key)
                }
                .onMove { source, destination in
                    var keys = settings.accessorySymbols
                    keys.move(fromOffsets: source, toOffset: destination)
                    settings.setAccessorySymbols(keys)
                }
                .onDelete { offsets in
                    var keys = settings.accessorySymbols
                    keys.remove(atOffsets: offsets)
                    settings.setAccessorySymbols(keys)
                }
            } header: {
                Text("Shown")
            } footer: {
                Text("Escape, Tab, modifiers, arrows, and function keys are always available.")
            }
            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { key in
                        Button {
                            settings.setAccessorySymbols(settings.accessorySymbols + [key])
                        } label: {
                            HStack {
                                row(key)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
                        .accessibilityLabel("Add \(key.spokenName)")
                    }
                }
            }
            if settings.hasCustomAccessorySymbols {
                Section {
                    Button("Reset to Default") { settings.resetAccessorySymbols() }
                }
            }
        }
        .navigationTitle("Accessory Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func row(_ key: TerminalAccessoryKey) -> some View {
        HStack(spacing: 16) {
            Text(key.capTitle).font(.title3.monospaced()).frame(minWidth: 24)
            Text(key.spokenName)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.spokenName)
        .accessibilityIdentifier("accessory-symbol-\(key.id)")
    }
}
