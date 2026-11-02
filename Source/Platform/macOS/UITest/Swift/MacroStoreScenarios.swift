// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

// MacroStoreScenarios.swift — the `[macros]` table written through its store,
// and the Macros menu's two standing items.
//
// The store's answers are read back through the live values after the reload
// its writes end in, so an entry that reached the file and not the table, or
// the table and not the file, reads differently from one that reached both. The
// runner sandboxes config.toml, so nothing here touches the reader's own.

/// The sandboxed config.toml, as text.
///
/// - Returns: The file's contents, or "" when there is none to read.
private func configurationText() -> String {
    guard let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] else {
        return ""
    }
    let path = (root as NSString).appendingPathComponent("ubiquitty/config.toml")
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// The Settings window, when it is on screen.
@MainActor
private func visibleSettingsWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.windowController is SettingsWindowController }
}

/// The Macros menu, rebuilt the way it is each time it opens.
@MainActor
private func openedMacrosMenu() -> NSMenu? {
    guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Macros" })?.submenu else {
        return nil
    }
    menu.delegate?.menuNeedsUpdate?(menu)
    return menu
}

/// Registers the macro scenarios with the UI-test runner.
enum MacroStoreScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_macro_store_saves_renames_and_deletes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let suffix = UUID().uuidString.prefix(8).lowercased()
                let name = "uitest-macro-\(suffix)"
                let renamed = "uitest-renamed-\(suffix)"
                defer {
                    MacroStore.delete(named: name)
                    MacroStore.delete(named: renamed)
                }
                let before = MacroStore.entries()

                // The body carries its escapes raw and a quote, which the file
                // has to hold as TOML and the table has to give back unchanged.
                let body = #"printf "%s\n" done\e[0m"#
                t.expect(MacroStore.save(MacroEntry(name: name, body: body), replacing: ""), desc: "a new macro saves")
                t.expect(
                    MacroStore.entries() == before + [MacroEntry(name: name, body: body)],
                    desc: "it joins the table after the others, its body unchanged (\(MacroStore.entries()))"
                )
                t.expect(configurationText().contains("[macros]"), desc: "the file carries a [macros] table")
                t.expect(configurationText().contains("\(name) = "), desc: "and the macro's key")

                // A rename leaves no stale entry behind under the old name.
                t.expect(
                    MacroStore.save(MacroEntry(name: renamed, body: "second"), replacing: name),
                    desc: "a rename saves"
                )
                let afterRename = MacroStore.entries()
                t.expect(!afterRename.contains { $0.name == name }, desc: "the old name is gone from the table")
                t.expect(
                    afterRename.filter { $0.name == renamed } == [MacroEntry(name: renamed, body: "second")],
                    desc: "the new name stands once, with the new body (\(afterRename))"
                )
                t.expect(!configurationText().contains("\(name) = "), desc: "and the old key is gone from the file")

                // Overwriting in place keeps one entry.
                t.expect(
                    MacroStore.save(MacroEntry(name: renamed, body: "third"), replacing: renamed),
                    desc: "an edit that keeps the name saves"
                )
                t.expect(
                    MacroStore.entries().filter { $0.name == renamed } == [MacroEntry(name: renamed, body: "third")],
                    desc: "and overwrites the one entry"
                )

                // A nameless macro is refused before anything is written.
                let text = configurationText()
                t.expect(!MacroStore.save(MacroEntry(name: "", body: "x"), replacing: ""), desc: "an empty name is refused")
                t.expect(configurationText() == text, desc: "and writes nothing")

                t.expect(MacroStore.delete(named: renamed), desc: "a delete succeeds")
                t.expect(MacroStore.entries() == before, desc: "and the table is as it was (\(MacroStore.entries()))")
                t.expect(!configurationText().contains("\(renamed) = "), desc: "and the key is gone from the file")
            }
        }

        UBUITestRegister("swift_macros_menu_items_open_the_macros_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                defer { visibleSettingsWindow()?.close() }
                for title in ["New Macro…", "Edit Macros…"] {
                    visibleSettingsWindow()?.close()
                    t.pump(0.1)
                    guard let menu = openedMacrosMenu(), let item = menu.items.first(where: { $0.title == title }),
                        let action = item.action
                    else {
                        t.expect(false, desc: "the Macros menu offers \(title)")
                        continue
                    }
                    t.expect(
                        (item.target as AnyObject?)?.responds(to: action) == true,
                        desc: "\(title) has a target that answers it"
                    )
                    NSApp.sendAction(action, to: item.target, from: item)
                    t.expect(
                        t.wait(until: { visibleSettingsWindow()?.title == "Macros" }, timeout: 5),
                        desc: "\(title) opens Settings on Macros (title \(visibleSettingsWindow()?.title ?? "none"))"
                    )
                }
            }
        }
    }
}
