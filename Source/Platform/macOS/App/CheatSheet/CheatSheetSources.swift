// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// CheatSheetSources.swift — the two shortcut inventories the cheat sheet lists:
// the menu bar's keyEquivalents and the user's [keys] bindings. Read-only.
//

import AppKit

// One cheat-sheet row: a glyph/spec on the left, the action label on the right.
struct CheatSheetEntry: Identifiable {
    let id = UUID()
    let shortcut: String
    let label: String
    let group: String // the top-level menu title, or "Custom keys"
}

@MainActor
enum CheatSheetSources {
    // Every menu item with a key equivalent, grouped by its top-level menu.
    // Skips the dynamic per-window / value-picker items Beam's menu walk also
    // skips (they have no equivalents anyway). menuNeedsUpdate populates lazy
    // submenus without the app-wide validateMenuItem cascade update() triggers.
    static func menuShortcuts() -> [CheatSheetEntry] {
        guard let mainMenu = NSApp.mainMenu else { return [] }
        var out: [CheatSheetEntry] = []
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            let group = topItem.title
            collect(submenu, group: group, into: &out)
        }
        return out
    }

    private static func collect(_ menu: NSMenu, group: String, into out: inout [CheatSheetEntry]) {
        // View ▸ Font is populated only with family choices, none of which
        // has a key equivalent. Opening it here scans every installed font
        // and changes the cold menu without adding a shortcut.
        if let fontMenu = (NSApp.delegate as? UBAppDelegate)?.fontMenu, menu === fontMenu { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden { continue }
            if let submenu = item.submenu {
                collect(submenu, group: group, into: &out)
                continue
            }
            let glyphs = shortcut(for: item)
            guard !glyphs.isEmpty, !item.title.isEmpty else { continue }
            out.append(CheatSheetEntry(shortcut: glyphs, label: item.title, group: group))
        }
    }

    // The user's live [keys] bindings (Core-sourced), one row each.
    static func userBindings() -> [CheatSheetEntry] {
        KeysCatalog.userBindings()
            .compactMap { binding in
                guard !binding.spec.isEmpty else { return nil }
                return CheatSheetEntry(
                    shortcut: binding.spec,
                    label: binding.label,
                    group: "Custom keys"
                )
            }
    }

    // Glyph form of a menu item's key equivalent, or "" when it has none.
    private static func shortcut(for item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var glyphs = ""
        if mask.contains(.control) { glyphs += "⌃" }
        if mask.contains(.option) { glyphs += "⌥" }
        if mask.contains(.shift) { glyphs += "⇧" }
        if mask.contains(.command) { glyphs += "⌘" }
        return glyphs + keyGlyph(key)
    }

    private static func keyGlyph(_ key: String) -> String {
        switch key {
        case "\r", "\u{3}": return "↩"
        case "\t": return "⇥"
        case " ": return "Space"
        case "\u{8}", "\u{7f}": return "⌫"
        case "\u{1b}": return "⎋"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): return "↑"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): return "↓"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): return "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): return "→"
        default: return key.uppercased()
        }
    }
}
