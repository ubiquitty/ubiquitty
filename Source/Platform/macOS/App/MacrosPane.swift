// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// MacrosPane.swift — the in-window [macros] manager. Lists defined macros
// and lets the user create / edit / delete them. A macro is a name -> body
// pair; the body carries C-style escapes (\e \n \t \\ \xNN) the engine
// decodes at invoke time, same as [keys] send:.
//
// A keybind is bound separately, in the Keys pane, via the "macro:<name>"
// action (its freeform action field already accepts it) — [macros] itself
// has no keybind field, so this pane doesn't capture one.
//
// Reads and writes go through MacroStore, over config.toml; the Macros menu
// re-reads the live table each time it opens, so no menu rebuild is needed
// here.
//

import AppKit
import SwiftUI
import UbiquittyKit

/// Routes macro menu actions to the terminal window the reader is working in.
@objc(UBMacroActions)
@MainActor
final class MacroActions: NSObject {
    /// Invokes a macro in the key terminal window, whichever shell drew it —
    /// the one the Macros menu enables its items for.
    ///
    /// - Parameter name: The configured macro name.
    @objc
    static func invokeNamed(_ name: String) {
        invokeNamed(name, in: TerminalWindows.keyTerminal()?.window)
    }

    static func invokeNamed(_ name: String, in window: NSWindow?) {
        if let controller = window?.windowController as? TerminalWindowController {
            controller.invokeMacroNamed(name)
        } else {
            NSSound.beep()
        }
    }
}

private struct Macro: Identifiable {
    var id = UUID()
    var originalName: String // empty for a not-yet-saved macro
    var name: String
    var body: String

    init(entry: MacroEntry) {
        name = entry.name
        originalName = entry.name
        body = entry.body
    }

    init(name: String) {
        self.name = name
        originalName = ""
        body = ""
    }

    var entry: MacroEntry {
        MacroEntry(name: name, body: body)
    }
}

// Collapse a (possibly multiline) body into a single dim preview line.
private func preview(_ body: String) -> String {
    let collapsed = body.replacingOccurrences(of: "\n", with: "⏎")
    if collapsed.isEmpty { return "empty" }
    if collapsed.count > 60 {
        return String(collapsed.prefix(60)) + "…"
    }
    return collapsed
}

struct MacrosPane: View {
    @State
    private var macros: [Macro] = []
    @State
    private var session = EditSession<Macro>()

    var body: some View {
        SettingsListPane(
            title: "Macros",
            footer:
                "A macro sends its text to the active session. Run it from the Macros menu, or bind a shortcut to it in Keyboard ▸ New Binding with the action macro:<name>.",
            emptyText: "No macros.",
            addLabel: "New Macro",
            items: macros,
            onAdd: { session.new(Macro(name: uniqueName("New Macro", existing: macros.map(\.name)))) },
            reload: reload,
            addSearchID: "macros.new"
        ) { macro in
            row(macro)
        }
        .sheet(item: $session.editing) { macro in
            MacroEditorSheet(
                macro: macro,
                isNew: session.isNew,
                onCommit: { commit($0) },
                onCancel: {}
            )
        }
    }

    @ViewBuilder
    private func row(_ macro: Macro) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(macro.name)
                Text(preview(macro.body)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Edit") { session.edit(macro) }
            Button(role: .destructive) {
                remove(macro)
            } label: {
                Image(systemName: "trash")
            }
        }
    }

    // MARK: data

    private func reload() {
        macros = MacroStore.entries().map { Macro(entry: $0) }
    }

    private func remove(_ macro: Macro) {
        if !MacroStore.delete(named: macro.name) {
            NSSound.beep()
        }
        reload()
    }

    private func commit(_ macro: Macro) {
        if !MacroStore.save(macro.entry, replacing: macro.originalName) {
            NSSound.beep()
        }
        reload()
    }
}

private struct MacroEditorSheet: View {
    @State
    var macro: Macro
    let isNew: Bool
    let onCommit: (Macro) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Macro" : "Edit Macro").font(.headline)

            HStack {
                Text("Name").frame(width: 60, alignment: .leading)
                TextField("Macro name", text: $macro.name)
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Text").frame(width: 60, alignment: .leading)
                TextEditor(text: $macro.body)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 360, height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                Text("The text or escape sequence to send. Escapes use the same syntax as the settings file: \\e, \\n, \\t, \\\\, \\xNN.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 360, alignment: .leading)
            }

            Text(
                "To bind a shortcut, choose Keyboard ▸ New Binding and use the action macro:\(macro.name.isEmpty ? "<name>" : macro.name)."
            )
            .font(.caption).foregroundStyle(.secondary)

            ModalButtons(
                saveDisabled: !isValidName(macro.name),
                onCancel: onCancel,
                onSave: { onCommit(macro) }
            )
        }
        .padding(24)
        .frame(width: 400)
    }
}
