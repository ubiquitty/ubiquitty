// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SettingsListScaffold.swift — the shared list+CRUD shape of the bespoke
// Settings panes (Keys / Profiles / Themes / Agents). Each pane supplies its
// items, row content, and edit sheet; the scaffold owns the card /
// empty-state / Add-button skeleton, the (editing, isNew) session state, and
// the modal button pair. The per-pane data funnels (reload / commit / remove)
// stay in the panes: the bridges differ in shape (whole-list rewrite vs.
// save/delete-by-name vs. the token CLI), so only the UI scaffold and the
// session state are truly shared.
//

import AppKit
import SwiftUI

// Append " 2", " 3", … to `base` until it is unique among `existing`.
func uniqueName(_ base: String, existing: some Sequence<String>) -> String {
    let names = Set(existing)
    if !names.contains(base) { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
}

// A name is saveable when it has any non-whitespace content.
func isValidName(_ name: String) -> Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
}

// The (editing, isNew) pair every CRUD pane tracks. `editing` drives
// `.sheet(item:)`; `isNew` picks the sheet title and save semantics.
struct EditSession<Item: Identifiable> {
    var editing: Item?
    var isNew = false

    mutating func new(_ item: Item) {
        isNew = true
        editing = item
    }

    mutating func edit(_ item: Item) {
        isNew = false
        editing = item
    }

    // A duplicate is a new item the caller has already copied and renamed.
    mutating func duplicate(_ item: Item) {
        new(item)
    }
}

// The SettingsPaneStack → SettingsCardView → empty-state/rows → Add-button
// skeleton shared by the CRUD panes. Attach the pane's edit sheet to this
// view (`.sheet(item: $session.editing) { … }`). `leadingCards` are catalog
// cards drawn above the list, for a setting that governs every item in it.
struct SettingsListPane<Item: Identifiable, Row: View>: View {
    let title: String
    let footer: String
    let emptyText: String
    let addLabel: String
    let items: [Item]
    let onAdd: () -> Void
    let reload: () -> Void
    var addSearchID: String? = nil
    var leadingCards: [SettingsCard] = []
    @ViewBuilder
    let row: (Item) -> Row

    var body: some View {
        SettingsPaneStack {
            // By position: a card made with the pane gets a new id each time
            // the pane is made, and its slider would be rebuilt mid-drag.
            ForEach(leadingCards.indices, id: \.self) { SettingsCatalogCardView(card: leadingCards[$0]) }
            SettingsCardView(title: title, footer: footer) {
                if items.isEmpty {
                    SettingsListRow(isFirst: true) {
                        Text(emptyText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(items) { item in
                        SettingsListRow(isFirst: item.id == items.first?.id) {
                            row(item)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Label(addLabel, systemImage: "plus")
                }
                .settingsSearchTarget(addSearchID)
            }
        }
        .onAppear(perform: reload)
    }
}

// The Cancel/Save pair every edit sheet ends with, with the standard
// keyboard shortcuts. `dismissesOnSave: false` keeps the sheet up after
// saving (the Agents issue flow swaps to its one-time secret view instead).
struct ModalButtons: View {
    var saveLabel = "Save"
    var saveDisabled = false
    var dismissesOnSave = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(saveLabel) {
                onSave()
                if dismissesOnSave { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(saveDisabled)
        }
    }
}

// Modal error alert for bridge failures (e.g. a token revoke that the CLI
// rejected).
@MainActor
func presentError(_ message: String, informativeText: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = informativeText
    alert.runModal()
}
