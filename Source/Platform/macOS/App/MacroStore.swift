// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// MacroStore.swift — the `[macros]` table: its entries in file order, and the
// writes that keep config.toml the one place a macro lives.
//
// A macro is a name mapped to a body carrying C-style escapes (\n \r \t \e
// \xNN), decoded when the macro is sent, the same way a `[keys]` `send:` action
// is. A shortcut binds one separately, in `[keys]`, through the `macro:<name>`
// action; `[macros]` itself has no shortcut field.
//
// Reads come straight from the live values. Writes go through the preference
// write surface every Swift settings row uses, and a successful save or delete
// ends in one reload, so the live table — which the Macros menu rebuilds from
// each time it opens — is the file's.
//

import AppKit
import CxxStdlib
import UbiquittyAppBridge
import UbiquittyCore

/// One `[macros]` entry.
struct MacroEntry: Equatable {
    /// The table key, and the name `macro:<name>` binds.
    var name: String
    /// The text sent, escapes kept raw.
    var body: String
}

/// The `[macros]` table in config.toml.
@MainActor
enum MacroStore {
    /// Every named `[macros]` entry, in file order.
    ///
    /// - Returns: The entries the live values hold.
    static func entries() -> [MacroEntry] {
        var entries: [MacroEntry] = []
        for macro in Ubiquitty.Preferences.values().pointee.macros {
            let name: std.string = macro.name
            let body: std.string = macro.body
            guard !name.empty() else { continue }
            entries.append(MacroEntry(name: String(name), body: String(body)))
        }
        return entries
    }

    /// Creates, renames or overwrites an entry.
    ///
    /// A rename removes the old key before the new one is written, so it never
    /// leaves the old entry standing beside the new one.
    ///
    /// - Parameters:
    ///   - entry: The entry as it should stand.
    ///   - previousName: The name the entry had before the edit; empty for a
    ///     new macro.
    /// - Returns: Whether the configuration took the edit; an empty name is
    ///   refused before anything is.
    @discardableResult
    static func save(_ entry: MacroEntry, replacing previousName: String) -> Bool {
        guard !entry.name.isEmpty else { return false }
        if !previousName.isEmpty, previousName != entry.name {
            guard removeSectionSetting("macros", previousName) else { return false }
        }
        return setSectionSetting("macros", entry.name, toml: tomlQuoted(entry.body))
    }

    /// Deletes the entry with this name.
    ///
    /// - Parameter name: The entry's name.
    /// - Returns: Whether the configuration took the removal.
    @discardableResult
    static func delete(named name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return removeSectionSetting("macros", name)
    }
}

/// The Macros menu's two standing items, New Macro… and Edit Macros….
///
/// Both open Settings on the Macros pane, where the pane's own New Macro button
/// is on screen, so the menu is somewhere to act from even with no macro
/// defined.
@objc(UBMacroMenuActions)
@MainActor
final class MacroMenuActions: NSObject {
    /// The object both items send to. A menu item holds its target weakly, so
    /// the target has to be owned somewhere that outlives the menu.
    @objc
    static let shared = MacroMenuActions()

    /// Opens Settings on the Macros pane.
    ///
    /// - Parameter sender: The menu item.
    @objc(showMacrosSettings:)
    func showMacrosSettings(_ sender: Any?) {
        SettingsBridge.app?.showSettingsWindow(forCategory: "macros")
    }
}
