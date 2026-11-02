// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyAppBridge
import UbiquittyKit
import UbiquittyRenderKit

/// Exercises the settings window's native chrome and independently scrolling columns.
enum SettingsWindowScenarios {
    static func register() {
        UBUITestRegister("edit_current_theme_opens_the_swift_editor_without_changing_the_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let controller = t.newWindowRunning(nil)
                else {
                    t.expect(false, desc: "a terminal and application settings owner exist")
                    return
                }
                defer {
                    dismissEditSheet(t)
                    settingsPanelWindow()?.close()
                    controller.window?.close()
                }
                let originalTheme = controller.beamSurface?.drive.currentThemeIndex()
                t.expect(
                    NSApp.sendAction(NSSelectorFromString("editCurrentTheme:"), to: app, from: nil),
                    desc: "the Theme menu action reaches the Swift settings editor"
                )
                t.expect(
                    t.wait(
                        until: {
                            NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                                .contains { content in
                                    descendants(of: content).contains { ($0 as? NSTextField)?.placeholderString == "Theme name" }
                                }
                        },
                        timeout: 3
                    ),
                    desc: "the theme editor opens even when Settings was not already showing Themes"
                )
                t.expect(
                    controller.beamSurface?.drive.currentThemeIndex() == originalTheme,
                    desc: "opening an editable draft leaves the live session's palette unchanged"
                )
                dismissEditSheet(t)
                t.expect(
                    controller.beamSurface?.drive.currentThemeIndex() == originalTheme,
                    desc: "cancelling leaves the session's palette unchanged"
                )
            }
        }

        UBUITestRegister("swift_config_reload_removes_deleted_presentation_values") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
                    let app = NSApp.delegate as? UBAppDelegate,
                    let controller = t.newWindowRunning(["/bin/cat"]),
                    let surface = controller.beamSurface
                else { return }
                SystemDisplayOptions.pinForTesting(reduceMotion: false, reduceTransparency: false)
                defer { SystemDisplayOptions.unpinForTesting() }
                let path = URL(fileURLWithPath: home + "/ubiquitty/config.toml")
                let saved = try? Data(contentsOf: path)
                defer {
                    if let saved { try? saved.write(to: path) }
                    loadPreferencesIntoDefaults()
                    app.applyAllPersistedSettings()
                    controller.window?.close()
                }
                do {
                    try "[font]\nsize = 19\n[cursor]\nblink = false\n[appearance]\nbackground_opacity = 0.5\n"
                        .write(to: path, atomically: false, encoding: .utf8)
                    loadPreferencesIntoDefaults()
                    app.applyAllPersistedSettings()
                    t.expect(
                        surface.drive.withTerminal { $0.fontRequests.actualSizePoints() } == 19,
                        desc: "reloading changes the live font size"
                    )
                    t.expect(!surface.drive.readSnapshot().cursorBlinkEnabled, desc: "reloading disables cursor blinking")
                    t.expect(
                        surface.overscrollBackgroundColor?.alpha == 0.5 && controller.window?.isOpaque == false,
                        desc: "reloading changes the pane's background opacity and window compositing"
                    )
                    try "".write(to: path, atomically: false, encoding: .utf8)
                    loadPreferencesIntoDefaults()
                    app.applyAllPersistedSettings()
                    let defaults = Ubiquitty.Preferences.Values()
                    t.expect(
                        surface.drive.withTerminal { $0.fontRequests.actualSizePoints() }
                            == Ubiquitty.Preferences.Effective.fontSize(defaults),
                        desc: "deleting the font setting restores its default in the open pane"
                    )
                    t.expect(
                        surface.drive.readSnapshot().cursorBlinkEnabled == Ubiquitty.Preferences.Effective.cursorBlink(defaults),
                        desc: "deleting the cursor setting restores its default"
                    )
                    guard let fresh = t.newWindowRunning(["/bin/cat"]) else { return }
                    defer { fresh.window?.close() }
                    t.expect(
                        controller.paneHost.layer?.backgroundColor?.alpha == fresh.paneHost.layer?.backgroundColor?.alpha,
                        desc: "deleting opacity gives the open pane the same background as a fresh window"
                    )
                } catch {
                    t.expect(false, desc: "the isolated configuration can be edited: \(error)")
                }
            }
        }

        UBUITestRegister("settings_option_meta_persists_all_choices") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                let choices: [(String, Ubiquitty.Input.OptionAsAlternate)] = [
                    ("none", .None), ("left", .Left), ("right", .Right), ("both", .Both),
                ]
                for (token, expected) in choices {
                    t.expect(setOptionAsAlternate(token), desc: "the picker persists \(token)")
                    t.expect(
                        Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) == expected,
                        desc: "the live encoder reads \(token) immediately"
                    )
                    // The live configuration is moved off the choice without
                    // touching the file, so only a reload can bring it back.
                    t.configureAppending("[keys]\noption_as_alt = \"none\"\n")
                    loadPreferencesIntoDefaults()
                    t.expect(
                        Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) == expected,
                        desc: "the saved \(token) choice survives configuration reload"
                    )
                }
                t.expect(
                    !setOptionAsAlternate("invalid"),
                    desc: "an invalid token cannot alter the setting"
                )
                let view = NSHostingView(rootView: KeysPane())
                view.frame = NSRect(x: 0, y: 0, width: 650, height: 500)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                defer { window.close() }
                window.orderFront(nil)
                t.pump(0.5)
                let menus = descendants(of: view).compactMap { $0 as? NSPopUpButton }
                guard
                    let picker = menus.first(where: { button in
                        button.itemTitles == ["Neither Key", "Left Option", "Right Option", "Both Keys"]
                    })
                else {
                    t.expect(false, desc: "Keyboard settings presents all four choices in a native picker")
                    return
                }
                for (index, choice) in choices.enumerated() {
                    picker.selectItem(at: index)
                    picker.sendAction(picker.action, to: picker.target)
                    t.pump(0.1)
                    t.expect(
                        Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) == choice.1,
                        desc: "selecting \(choice.0) in the native control updates the encoder"
                    )
                    loadPreferencesIntoDefaults()
                    t.expect(
                        Ubiquitty.Preferences.Effective.optionAsAlternate(Ubiquitty.Preferences.values().pointee) == choice.1,
                        desc: "selecting \(choice.0) persists to configuration"
                    )
                }
            }
        }

        UBUITestRegister("settings_font_features_identify_affected_characters") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                for (family, expected) in [
                    ("JetBrains Mono", [("cv01", "l"), ("cv02", "t"), ("cv03", "g")]),
                    ("Monaspace Neon", [("cv01", "0"), ("cv02", "1")]),
                ] {
                    let groups = FontFeatureCatalog.groups(forFamilyNamed: family)
                    for (tag, character) in expected {
                        guard let option = groups.flatMap(\.options).first(where: { $0.tag == tag && $0.value == 1 }) else {
                            t.expect(false, desc: family + " advertises " + tag)
                            continue
                        }
                        let sample = FontFeatureCatalog.example(for: option, familyName: family)
                        t.expect(
                            sample?.contains(character) == true,
                            desc: family + " " + tag + " identifies " + character + ", got " + (sample ?? "nil")
                        )
                        t.expect(sample?.contains("->") != true, desc: "a letter variant does not get a generic operator specimen")
                    }
                }
            }
        }

        UBUITestRegister("settings_specification_and_native_selectors_refresh") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app else { return }
                let originalFeatures = app.settingsFontFeatures() ?? ""
                let originalSymbol = app.settingsSymbolFallbackFont() ?? ""
                let options = ["Default", "Apple Symbols", "STIX Two Math"]
                let hosting = NSHostingController(
                    rootView: VStack {
                        TextFieldControl(
                            placeholder: "Features",
                            get: { app.settingsFontFeatures() ?? "" },
                            set: { app.settingsSetFontFeatures($0) }
                        )
                        SettingsFontPicker(
                            options: options,
                            get: {
                                switch app.settingsSymbolFallbackFont() {
                                case "Apple Symbols": return 1
                                case "STIX Two Math": return 2
                                default: return 0
                                }
                            },
                            set: { app.settingsSetSymbolFallbackFont($0 == 0 ? "" : options[$0]) }
                        )
                    }
                    .padding()
                )
                let window = NSWindow(contentViewController: hosting)
                defer {
                    window.close()
                    app.settingsSetFontFeatures(originalFeatures)
                    app.settingsSetSymbolFallbackFont(originalSymbol)
                }
                window.orderFront(nil)
                t.pump(0.2)
                guard
                    let field = descendants(of: hosting.view).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.placeholderString == "Features" })
                else {
                    t.expect(false, desc: "the specification has an editable native field")
                    return
                }
                for specification in ["ss01 -calt", "cv01 ss02", ""] {
                    app.settingsSetFontFeatures(specification)
                    t.pump(0.2)
                    t.expect(
                        field.stringValue == (app.settingsFontFeatures() ?? ""),
                        desc: "an external feature selection refreshes the existing text field"
                    )
                }
                app.settingsSetSlashedZero(true)
                t.pump(0.2)
                t.expect(app.settingsSlashedZero(), desc: "slashed zero can be enabled with an empty feature specification")
                t.expect(
                    FontFeatureCatalog.settings(inSpecification: field.stringValue)["zero"] == 1,
                    desc: "slashed zero synchronizes the advanced specification"
                )
                app.settingsSetSlashedZero(false)
                t.pump(0.2)
                t.expect(!app.settingsSlashedZero(), desc: "slashed zero can return to the default specification")
                for (family, index) in [("Apple Symbols", 1), ("STIX Two Math", 2), ("", 0)] {
                    app.settingsSetSymbolFallbackFont(family)
                    // Waited for, as the navigation scenario waits for its title:
                    // the pop-up follows the setting through a notification whose
                    // delivery a fixed pump only guesses at. The lookup stays
                    // inside the condition, so a pop-up that was rebuilt is the
                    // one asked, as the assertion's name requires.
                    let currentPopup = { descendants(of: hosting.view).compactMap { $0 as? NSPopUpButton }.first }
                    let shown = t.wait(until: { currentPopup()?.indexOfSelectedItem == index }, timeout: 4)
                    let popup = currentPopup()
                    if !shown {
                        print(
                            "    symbol fallback pop-up after selecting '\(family)': "
                                + (popup.map { "index \($0.indexOfSelectedItem) of \($0.numberOfItems)" } ?? "no pop-up")
                        )
                        // No pop-up is a class the lookup does not know, so the tree
                        // under the hosting view names it.
                        if popup == nil {
                            print("    hosting view tree:")
                            for line in classTreeLines(of: hosting.view, depth: 0, limit: 8) {
                                print("      " + line)
                            }
                        }
                    }
                    t.expect(shown, desc: "the native pop-up shows the current fallback without rebuilding")
                    if let popup {
                        popup.menu?.performActionForItem(at: 1)
                        t.pump(0.2)
                        t.expect(app.settingsSymbolFallbackFont() == "Apple Symbols", desc: "native menu selection writes through")
                    }
                }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.insertText("ss03", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    app.settingsSetSymbolFallbackFont("STIX Two Math")
                    t.pump(0.2)
                    t.expect(editor.string == "ss03", desc: "an unrelated setting does not discard an uncommitted specification")
                    window.makeFirstResponder(nil)
                    t.pump(0.2)
                    t.expect(
                        FontFeatureCatalog.settings(inSpecification: app.settingsFontFeatures() ?? "")["ss03"] == 1,
                        desc: "the edited specification commits on focus loss"
                    )
                }
            }
        }

        UBUITestRegister("settings_font_preview_survives_subsection_navigation") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let state = FontSettingsPreviewState()
                let model = SettingsCatalogModel()
                let hosting = NSHostingController(rootView: SettingsView(catalogModel: model, previewState: state))
                let window = NSWindow(contentViewController: hosting)
                window.setContentSize(NSSize(width: 760, height: 640))
                defer { window.close() }
                window.orderFront(nil)
                model.selectCategory = "fonts"
                t.pump(0.2)
                guard let initial = descendants(of: hosting.view).compactMap({ $0 as? TerminalSettingsPreview }).first else {
                    t.expect(false, desc: "Fonts owns a terminal preview")
                    return
                }
                state.selectedSample = .math
                for category in ["font-routing", "font-features", "font-rendering", "fonts"] {
                    model.selectCategory = category
                    t.pump(0.2)
                    let previews = descendants(of: hosting.view).compactMap { $0 as? TerminalSettingsPreview }
                    t.expect(previews.count == 1, desc: "font settings own one terminal preview, including feature rows")
                    let current = previews.first
                    t.expect(current === initial, desc: "font subsections preserve the terminal view")
                    t.expect(state.selectedSample == .math, desc: "navigation preserves sample identity")
                    t.expect(
                        current?.sample == FontRoutePreview.samples.last?.text,
                        desc: "the last sample remains rendered in " + category
                    )
                }
                model.selectCategory = "cursor"
                t.pump(0.2)
                model.selectCategory = "fonts"
                t.pump(0.2)
                t.expect(state.selectedSample == .math, desc: "leaving the font section does not reset its sample")
            }
        }

        UBUITestRegister("settings_preview_renders_shaped_terminal_cells") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let preview = TerminalSettingsPreview(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
                preview.sample = "بسم\r\nلا\r\nسلام دنیا  שלום עולם"
                guard let surface = preview.surface else {
                    t.expect(false, desc: "the preview owns a terminal surface")
                    return
                }
                surface.drive.withTerminal { terminal in
                    let columns = Int(terminal.columns)
                    var storage = [Ubiquitty.Cell](repeating: Ubiquitty.Cell(), count: columns)
                    storage.withUnsafeMutableBufferPointer { cells in
                        Ubiquitty.Screen.getDisplayRow(terminal, 0, 0, cells.baseAddress, terminal.columns)
                        let shaped = (0..<3).map { cells[$0].codePoint }
                        t.expect(
                            shaped == [0xFEE2, 0xFEB4, 0xFE91],
                            desc: "Arabic reaches the renderer as joined, visual-order forms: \(shaped)"
                        )
                        Ubiquitty.Screen.getDisplayRow(terminal, 0, 1, cells.baseAddress, terminal.columns)
                        t.expect(cells[0].codePoint == 0xFEFB, desc: "lam-alef reaches the renderer as a ligature")
                        Ubiquitty.Screen.getDisplayRow(terminal, 0, 2, cells.baseAddress, terminal.columns)
                        let mixed = (0..<20).map { cells[$0].codePoint }
                        t.expect(
                            mixed.contains(where: { $0 >= 0xFB50 && $0 <= 0xFEFF }),
                            desc: "the mixed-language sample contains shaped Arabic: \(mixed)"
                        )
                    }
                }
            }
        }

        UBUITestRegister("settings_sidebar_keeps_search_outside_scrolling_content") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let controller = SettingsWindowController()
                defer { controller.close() }
                controller.showWindow(nil)
                t.pump(0.4)
                guard let window = controller.window, let content = window.contentView else {
                    t.expect(false, desc: "Settings opens")
                    return
                }
                t.expect(window.styleMask.contains(.fullSizeContentView), desc: "content extends through the titlebar")
                t.expect(window.toolbar != nil, desc: "navigation uses a native toolbar")
                t.expect(window.titlebarSeparatorStyle == .none, desc: "no separate titlebar separator")

                for size in [NSSize(width: 720, height: 460), NSSize(width: 920, height: 720)] {
                    window.setContentSize(size)
                    t.pump(0.3)
                    guard let search = descendants(of: content).compactMap({ $0 as? NSSearchField }).first,
                        let sidebar = sidebarScrollView(in: content, search: search)
                    else {
                        t.expect(false, desc: "the sidebar contains native search and a scroll view")
                        return
                    }
                    let searchFrame = search.convert(search.bounds, to: nil)
                    let viewport = sidebar.convert(sidebar.bounds, to: nil)
                    t.expect(!searchFrame.intersects(viewport), desc: "search has a separate, non-overlapping viewport")
                    t.expect(searchFrame.minY >= viewport.maxY, desc: "search stays above the list")
                    t.expect(searchFrame.maxX < content.bounds.midX, desc: "search stays in the left column")
                    let initialFrame = searchFrame
                    if let document = sidebar.documentView {
                        document.scroll(NSPoint(x: 0, y: document.bounds.height))
                        sidebar.reflectScrolledClipView(sidebar.contentView)
                        t.pump(0.2)
                        t.expect(search.convert(search.bounds, to: nil) == initialFrame, desc: "scrolling never moves search")
                    }
                    controller.performFindAction(nil)
                    t.expect(search.currentEditor() != nil, desc: "Edit > Find focuses Settings search")
                }
            }
        }

        UBUITestRegister("settings_categories_and_search_keep_navigation_reachable") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let controller = SettingsWindowController()
                defer { controller.close() }
                controller.showWindow(nil)
                t.pump(0.3)
                guard let window = controller.window, let content = window.contentView else {
                    t.expect(false, desc: "Settings opens")
                    return
                }
                for category in SettingsCatalog.categories() {
                    controller.select(category: category.id)
                    // Waited for, not pumped for: the first navigation loads its
                    // pane cold and a fixed pump is a guess about how long that
                    // takes on the machine running it. The title the window did
                    // settle on is printed when it is not the category's, so a
                    // run that fails says what it saw.
                    let titled = t.wait(until: { window.title == category.title }, timeout: 4)
                    if !titled {
                        // Title, subtitle and the toolbar's selection together: which
                        // of them a release routes the page's name to is the question.
                        let toolbarItem = window.toolbar?.selectedItemIdentifier?.rawValue ?? "none"
                        print(
                            "    settings window after selecting \(category.id): title '\(window.title)', "
                                + "subtitle '\(window.subtitle)', toolbar selection '\(toolbarItem)'"
                        )
                    }
                    t.expect(titled, desc: "navigation opens " + category.title)
                    t.expect(window.toolbar != nil, desc: "every settings page retains the toolbar")
                    t.expect(
                        descendants(of: content).contains(where: { $0 is NSSearchField }),
                        desc: "every settings page retains search"
                    )
                }
                guard let search = descendants(of: content).compactMap({ $0 as? NSSearchField }).first else {
                    t.expect(false, desc: "search is present")
                    return
                }
                controller.performFindAction(nil)
                guard let editor = search.currentEditor() as? NSTextView else {
                    t.expect(false, desc: "search accepts text input")
                    return
                }
                editor.insertText("bold", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                t.pump(0.2)
                t.expect(search.stringValue == "bold", desc: "native search accepts the query")
                controller.reveal(rowID: "font.weight", inCategory: "fonts")
                t.pump(0.3)
                t.expect(search.stringValue.isEmpty, desc: "revealing a setting clears search")
                t.expect(window.title == "Fonts", desc: "revealing a setting opens its category")
                controller.select(category: "not-a-settings-category")
                t.pump(0.2)
                t.expect(window.title == "Fonts", desc: "an unknown category cannot blank the detail column")
            }
        }

        UBUITestRegister("settings_reset_preview_is_inert_and_apply_restores_live_defaults") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                _ = Ubiquitty.Preferences.configureOwnDocument(std.string("[font]\nsize = 23\nfamily = \"Menlo\"\n[mac]\nfont_size = 18\n"))
                guard let controller = t.newWindowRunning(["/bin/cat"]),
                    let other = t.newWindowRunning(["/bin/cat"]),
                    let category = SettingsCatalog.categories().first(where: { $0.id == "fonts" }),
                    case .pane(let pane) = category.content,
                    let size = pane.cards.flatMap(\.rows).first(where: { $0.id == "font.size" })
                else {
                    t.expect(false, desc: "font settings and two windows are available")
                    return
                }
                defer {
                    controller.window?.close()
                    other.window?.close()
                }
                let before = String(Ubiquitty.Preferences.liveDocument().pointee)
                let proposal = SettingsResetProposal(title: "Font Size", rows: [size])
                let hosting = NSHostingController(rootView: SettingsResetSheet(proposal: proposal))
                let window = NSWindow(contentViewController: hosting)
                window.orderFront(nil)
                t.pump(0.2)
                window.close()
                t.expect(
                    String(Ubiquitty.Preferences.liveDocument().pointee) == before,
                    desc: "opening and closing the preview writes nothing"
                )
                proposal.apply()
                let values = Ubiquitty.Preferences.values().pointee
                t.expect(values.fontSize.value == nil, desc: "reset removes the override rather than writing a default")
                t.expect(String(values.fontFamily.value ?? std.string()) == "Menlo", desc: "reset preserves neighboring keys")
                for terminal in [controller, other] {
                    t.expect(
                        terminal.focusedSurfaceForTesting?.renderer?.pointSize == 18,
                        desc: "each live window keeps its platform override"
                    )
                }
                _ = Ubiquitty.Preferences.configureOwnSectionKey(std.string("mac"), std.string("font_size"), std.string("20"))
                for terminal in [controller, other] {
                    t.expect(
                        terminal.focusedSurfaceForTesting?.renderer?.pointSize == 20,
                        desc: "editing only the platform override updates every live window"
                    )
                }
                t.expect(SettingsResetProposal.customized([size]).isEmpty, desc: "the reset control no longer offers an absent override")
            }
        }

        UBUITestRegister("settings_search_reveals_custom_controls_and_expands_specifications") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let model = SettingsCatalogModel()
                let controller = SettingsWindowController()
                defer { controller.close() }
                controller.showWindow(nil)
                let hits = model.categories.settingsSearchHits()
                for (address, category) in [
                    ("font.features.specification", "font-features"), ("keys.option_as_alt", "keys"),
                    ("profiles.import", "profiles"), ("font.script-fallbacks", "font-routing"),
                ] {
                    t.expect(
                        hits.contains { $0.rowID == address && $0.categoryID == category },
                        desc: address + " has an exact search result"
                    )
                    t.expect(model.contains(rowID: address, in: category), desc: "custom addresses are accepted by navigation")
                }
                controller.reveal(rowID: "font.features.specification", inCategory: "font-features")
                t.expect(
                    t.wait(
                        until: {
                            guard let content = controller.window?.contentView else { return false }
                            return descendants(of: content).compactMap { $0 as? NSTextField }
                                .contains { $0.placeholderString == "calt liga -dlig ss01" }
                        },
                        timeout: 4
                    ),
                    desc: "search expands the advanced feature field"
                )
            }
        }

        UBUITestRegister("settings_catalog_has_reachable_unambiguous_controls") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let categories = SettingsCatalog.categories()
                t.expect(Set(categories.map(\.id)).count == categories.count, desc: "category identities are unique")
                for category in categories {
                    if let parentID = category.parentID {
                        t.expect(
                            categories.contains { $0.id == parentID && $0.parentID == nil },
                            desc: "every subpage has a visible parent"
                        )
                    }
                    if case .pane(let pane) = category.content {
                        let identities = pane.cards.flatMap(\.rows).map(\.id)
                        t.expect(Set(identities).count == identities.count, desc: "search reveal is unambiguous in " + category.id)
                    }
                }
                let hits = categories.settingsSearchHits()
                for (rowID, owner) in [
                    ("text.brighten_bold", "font-rendering"), ("underline.links", "mouse"), ("clipboard.serving", "security"),
                    ("appearance.shade_blocks", "font-rendering"), ("underline.thickness", "fonts"), ("underline.skip_ink", "fonts"),
                    ("underline.skip_ink_pad", "fonts"), ("underline.follows_ink", "fonts"),
                ] {
                    t.expect(hits.contains { $0.rowID == rowID && $0.categoryID == owner }, desc: rowID + " belongs to " + owner)
                }
                // Shaded Blocks chooses how a procedural glyph family draws, so it
                // sits directly after Braille Style in the same card.
                let shadeRowFollowsBraille = categories.contains { category in
                    guard case .pane(let pane) = category.content else { return false }
                    return pane.cards.contains { card in
                        let identities = card.rows.map(\.id)
                        guard let braille = identities.firstIndex(of: "font.braille_style") else { return false }
                        return identities.index(after: braille) < identities.endIndex
                            && identities[identities.index(after: braille)] == "appearance.shade_blocks"
                    }
                }
                t.expect(shadeRowFollowsBraille, desc: "Shaded Blocks follows Braille Style in its card")
                let rebuilt = SettingsCatalog.categories().settingsSearchHits()
                t.expect(rebuilt.map(\.id) == hits.map(\.id), desc: "refresh preserves setting addresses")
                t.expect(hits.contains { $0.categoryID == "appearance" && $0.matches("Auto") }, desc: "appearance choices are searchable")
            }
        }

        UBUITestRegister("profile_transfer_is_reviewed_and_temporary_values_do_not_persist") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.closeAllWindows()
                defer { t.closeAllWindows() }
                let name = "Shared " + UUID().uuidString
                let text =
                    "[[profiles]]\nname = \"\(name)\"\nscope = \"synced\"\nfont_size = 23\npadding_left = 31\nstartup_host = \"never-run-this\"\n"
                guard let proposal = Ubiquitty.Preferences.profileFromTransferText(std.string(text)).value,
                    let shell = TerminalWindowController.spawn(), let surface = shell.focusedSurfaceForTesting,
                    let renderer = surface.renderer
                else {
                    t.expect(false, desc: "a shared proposal and local window are available")
                    return
                }
                let originalSize = renderer.pointSize
                // A profile changes the grid fit before the next frame is submitted.
                let originalPadding = renderer.gridFitInsets(for: surface).left
                t.expect(renderer.pointSize == originalSize, desc: "reading a proposal does not apply it")
                t.expect(Profile(core: proposal).startupHost == nil, desc: "the proposal cannot launch its supplied command")
                shell.applyTemporaryProfile(proposal)
                t.expect(renderer.pointSize == 23, desc: "explicit apply changes this window's font")
                t.expect(renderer.gridFitInsets(for: surface).left == 31, desc: "explicit apply changes this window's padding")
                t.expect(
                    !Ubiquitty.Preferences.values().pointee.profiles.contains(where: { String($0.name) == name }),
                    desc: "temporary values never enter device configuration"
                )
                guard let other = TerminalWindowController.spawn(),
                    let otherRenderer = other.focusedSurfaceForTesting?.renderer
                else {
                    return
                }
                t.expect(otherRenderer.pointSize == originalSize, desc: "another window does not inherit the temporary override")
                shell.resetTemporaryProfile()
                t.expect(
                    renderer.pointSize == originalSize && renderer.gridFitInsets(for: surface).left == originalPadding,
                    desc: "reset restores inherited font and padding"
                )
            }
        }

        UBUITestRegister("settings_profiles_preserve_inheritance_through_editing") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app else { return }
                let parentName = "Settings parent " + UUID().uuidString
                let childName = "Settings child " + UUID().uuidString
                defer {
                    app.settingsDeleteProfileNamed(childName)
                    app.settingsDeleteProfileNamed(parentName)
                }
                app.settingsSaveProfile(["name": parentName, "fontSize": NSNumber(value: 19.5), "hideTitleBar": NSNumber(value: true)])
                app.settingsSaveProfile(["name": childName, "parentProfile": parentName, "startupHost": ""])
                guard let initial = app.settingsProfiles().first(where: { $0["name"] as? String == childName }) else {
                    t.expect(false, desc: "saved child is readable")
                    return
                }
                t.expect(initial["scope"] == nil, desc: "an unset scope can be read without dereferencing an empty optional")
                t.expect(initial["hideTitleBar"] == nil, desc: "reading does not materialize an inherited titlebar override")
                var draft = Profile(dict: initial)
                draft.lineSpacing = 2.5
                app.settingsSaveProfile(draft.dictionary())
                guard let saved = app.settingsProfiles().first(where: { $0["name"] as? String == childName }) else { return }
                t.expect(saved["parentProfile"] as? String == parentName, desc: "an unrelated edit preserves the parent")
                t.expect(saved["hideTitleBar"] == nil, desc: "an unrelated edit preserves titlebar inheritance")
                t.expect(saved["startupHost"] as? String == "", desc: "an explicit local-shell override survives serialization")
                let values = Ubiquitty.Preferences.values().pointee
                let resolved = Ubiquitty.Preferences.Effective.renderConfiguration(
                    values,
                    Ubiquitty.Preferences.resolvedProfile(values, std.string(childName))
                )
                t.expect(resolved.fontSizePoints == 19.5, desc: "the launch still receives the inherited font size")
                draft.hideTitleBar = false
                app.settingsSaveProfile(draft.dictionary())
                let explicit = app.settingsProfiles().first { $0["name"] as? String == childName }
                t.expect(
                    (explicit?["hideTitleBar"] as? NSNumber)?.boolValue == false,
                    desc: "an explicit false remains distinct from inheritance"
                )
            }
        }

        UBUITestRegister("settings_profile_deletion_preserves_referenced_profiles") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkProfileDeletionReferences(t) }
        }

        UBUITestRegister("settings_theme_picker_preserves_automatic_appearance") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app else { return }
                let model = ThemePickerModel()
                let initialMode = model.appearanceMode
                let initialTheme = model.activeIndex
                let initialLight = Int(Ubiquitty.SwiftBridge.systemLightTheme())
                let initialDark = Int(Ubiquitty.SwiftBridge.systemDarkTheme())
                // The document as well: choosing Light and Dark pins a theme,
                // and putting Auto back leaves that line for the scenarios
                // after this one to open their windows on.
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    app.settingsSetSystemLightTheme(initialLight)
                    app.settingsSetSystemDarkTheme(initialDark)
                    app.settingsSelectTheme(initialTheme)
                    if initialMode == 0 { app.settingsSetAppearanceMode(0) }
                    t.restoreConfiguration(saved)
                }
                model.reload()
                t.expect(
                    model.appearanceMode == initialMode && model.activeIndex == initialTheme,
                    desc: "opening the picker does not change appearance"
                )
                guard let light = model.choices(for: .light).last(where: { !$0.usesSystemAppearance }),
                    let dark = model.choices(for: .dark).last(where: { !$0.usesSystemAppearance })
                else {
                    t.expect(false, desc: "both appearance kinds have palettes")
                    return
                }
                model.setAppearanceMode(0)
                model.select(light, for: .light)
                model.select(dark, for: .dark)
                t.expect(model.appearanceMode == 0, desc: "choosing automatic palettes keeps Auto enabled")
                t.expect(
                    model.selectedIndex(for: .light) == light.id && model.selectedIndex(for: .dark) == dark.id,
                    desc: "each appearance remembers its palette"
                )
                model.setAppearanceMode(1)
                t.expect(model.activeIndex == light.id, desc: "Light uses the chosen light palette")
                model.setAppearanceMode(2)
                t.expect(model.activeIndex == dark.id, desc: "Dark uses the chosen dark palette")
                t.expect(
                    model.choices(for: .light).allSatisfy { !$0.isDark || $0.usesSystemAppearance },
                    desc: "light choices exclude fixed dark palettes"
                )
                t.expect(
                    model.choices(for: .current, query: light.name.uppercased()).contains { $0.id == light.id },
                    desc: "theme search is case insensitive"
                )
            }
        }

        UBUITestRegister("settings_system_theme_couples_automatic_appearances") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard SettingsBridge.app != nil else { return }
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                let savedAppearance = NSApp.appearance
                defer {
                    NSApp.appearance = savedAppearance
                    t.restoreConfiguration(saved)
                    SystemTheme.refresh()
                }
                let model = ThemePickerModel()
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    SystemTheme.refresh()
                    model.reload()
                    guard let system = model.themes.first(where: { $0.name == "System" }) else {
                        t.expect(false, desc: "System is registered")
                        return
                    }
                    for destination in [ThemeDestination.light, .dark] {
                        t.restoreConfiguration(saved)
                        model.setAppearanceMode(0)
                        model.reload()
                        t.expect(
                            model.choices(for: destination).contains { $0.id == system.id },
                            desc: "System is offered for either appearance"
                        )
                        model.select(system, for: destination)
                        t.expect(model.appearanceMode == 0, desc: "System preserves Auto")
                        t.expect(
                            model.theme(for: .light)?.name == "System" && model.theme(for: .dark)?.name == "System",
                            desc: "either selection sets both appearances to System"
                        )
                        t.expect(
                            settingText(.AppearanceSystemLightTheme) == "System" && settingText(.AppearanceSystemDarkTheme) == "System",
                            desc: "both System selections are persisted"
                        )
                    }
                    for mode in [1, 2] {
                        model.setAppearanceMode(mode)
                        t.expect(model.appearanceMode == mode, desc: "a fixed appearance can be selected after System")
                        let selected = model.theme(for: mode == 1 ? .light : .dark)
                        t.expect(
                            selected?.usesSystemAppearance == false && selected?.isDark == (mode == 2),
                            desc: "the fixed appearance uses a matching nonadaptive palette"
                        )
                    }
                    if appearance == .darkAqua {
                        t.expect(
                            system.ansi == [
                                0x3535_35FF, 0xFF8D_7AFF, 0x00D9_B2FF, 0xECA8_00FF,
                                0x89BB_FFFF, 0xD896_FEFF, 0x00CA_FAFF, 0xF9F1_F3FF,
                                0x9A9A_9AFF, 0xFF8D_7AFF, 0x00D9_B2FF, 0xECA8_00FF,
                                0x89BB_FFFF, 0xD896_FEFF, 0x00CA_FAFF, 0xF9F1_F3FF,
                            ],
                            desc: "System uses the balanced Xcode Dark ANSI palette"
                        )
                        t.expect(
                            system.foreground == 0xF9F1_F3FF && system.background == 0x2525_25FF && system.cursor == 0x007A_FFFF,
                            desc: "System uses the Xcode Dark foreground, background, and cursor"
                        )
                    } else {
                        t.expect(!system.isDark && system.background != 0x2525_25FF, desc: "System retains its light palette")
                    }
                }
            }
        }

        UBUITestRegister("swift_windows_apply_the_resolved_automatic_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app, let shell = TerminalWindowController.spawn(),
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { shell.window?.close() }
                let names = app.settingsThemeNames()
                let light = Int(Ubiquitty.SwiftBridge.systemLightTheme())
                let dark = Int(Ubiquitty.SwiftBridge.systemDarkTheme())
                guard names.indices.contains(light), names.indices.contains(dark) else {
                    t.expect(false, desc: "automatic light and dark themes resolve into the catalog")
                    return
                }

                TerminalWindowController.applyThemeToOpenWindows(at: light)
                t.pump(0.2)
                t.expect(
                    surface.currentThemeName == names[light],
                    desc: "the Swift window applies the resolved light theme"
                )

                TerminalWindowController.applyThemeToOpenWindows(at: dark)
                t.pump(0.2)
                t.expect(
                    surface.currentThemeName == names[dark],
                    desc: "the Swift window applies the resolved dark theme"
                )

                let savedAppearance = NSApp.appearance
                defer { NSApp.appearance = savedAppearance }
                app.settingsSetAppearanceMode(0)
                for (appearance, index, label) in [
                    (NSAppearance.Name.aqua, light, "light"),
                    (.darkAqua, dark, "dark"),
                ] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    guard let launched = TerminalWindowController.spawn(), let launchedSurface = launched.focusedSurfaceForTesting else {
                        t.expect(false, desc: "a Swift window launches under the \(label) system appearance")
                        continue
                    }
                    t.pump(0.2)
                    t.expect(
                        launchedSurface.currentThemeName == names[index],
                        desc: "a new Swift window opens with the resolved \(label) theme"
                    )
                    launched.window?.close()
                }
            }
        }

        UBUITestRegister("settings_custom_themes_rename_and_appearance_choices") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app else { return }
                let model = ThemePickerModel()
                model.reload()
                guard let light = model.choices(for: .light).first,
                    let dark = model.choices(for: .dark).first
                else {
                    t.expect(false, desc: "both appearance kinds have palettes")
                    return
                }
                let initialLight = Int(Ubiquitty.SwiftBridge.systemLightTheme())
                let initialDark = Int(Ubiquitty.SwiftBridge.systemDarkTheme())
                let lightName = uniqueName("UI Test Light", existing: model.themes.map(\.name))
                let renamedLight = uniqueName("UI Test Light Renamed", existing: model.themes.map(\.name))
                let darkName = uniqueName("UI Test Dark", existing: model.themes.map(\.name))
                defer {
                    app.settingsSetSystemLightTheme(initialLight)
                    app.settingsSetSystemDarkTheme(initialDark)
                    app.settingsDeleteThemeNamed(renamedLight)
                    app.settingsDeleteThemeNamed(lightName)
                    app.settingsDeleteThemeNamed(darkName)
                }
                @MainActor
                func save(_ theme: ThemeSnapshot, name: String, replacing originalName: String? = nil) {
                    app.settingsSaveThemeNamed(
                        name,
                        replacingName: originalName,
                        isDark: theme.isDark,
                        ansi: theme.ansi,
                        foreground: theme.foreground,
                        background: theme.background,
                        cursor: theme.cursor,
                        select: false
                    )
                }
                save(light, name: lightName)
                save(dark, name: darkName)
                model.reload()
                let customLight = model.choices(for: .light).first { $0.name == lightName }
                let customDark = model.choices(for: .dark).first { $0.name == darkName }
                t.expect(customLight != nil && customDark != nil, desc: "new custom themes appear in their appearance pickers")
                if let customLight { model.select(customLight, for: .light) }
                if let customDark { model.select(customDark, for: .dark) }
                var renamed = light
                renamed.name = renamedLight
                save(renamed, name: renamedLight, replacing: lightName)
                model.reload()
                t.expect(
                    model.choices(for: .light).contains { $0.name == renamedLight }
                        && !model.themes.contains { $0.name == lightName },
                    desc: "renaming replaces the old custom theme"
                )
                t.expect(
                    model.theme(for: .light)?.name == renamedLight
                        && model.theme(for: .dark)?.name == darkName,
                    desc: "appearance selections survive a custom theme rename"
                )
            }
        }

        UBUITestRegister("settings_text_fields_commit_when_focus_moves") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = SettingsBridge.app else { return }
                let original = app.settingsTermProgram() ?? ""
                let controller = SettingsWindowController()
                defer {
                    controller.close()
                    app.settingsSetTermProgram(original)
                }
                controller.showWindow(nil)
                controller.select(category: "terminal")
                t.pump(0.3)
                guard let window = controller.window, let content = window.contentView,
                    let field = descendants(of: content).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.placeholderString == "Ubiquitty" })
                else {
                    t.expect(false, desc: "terminal identity has a text field")
                    return
                }
                window.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { return }
                editor.insertText("Settings focus test", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                t.pump(0.1)
                controller.performFindAction(nil)
                t.pump(0.2)
                t.expect(
                    app.settingsTermProgram() == "Settings focus test",
                    desc: "moving focus commits without Return or leaving the page"
                )
            }
        }

        // The chord that makes a drag rectangular: what the picker offers, that
        // every term it offers reaches Core, and that the one term with a cost
        // the reader cannot see from its name says so.
        //
        // Driven through the catalog's own closures rather than by clicking the
        // control, because that is where both answers live: the getter reads
        // Core's effective value back, so a round-trip here is the preference
        // really moving and not a picker remembering what it was handed.
        UBUITestRegister("settings_block_select_chord_writes_and_cautions") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let rows = SettingsCatalog.categories()
                    .flatMap { category -> [SettingsRow] in
                        guard case .pane(let pane) = category.content else { return [] }
                        return pane.cards.flatMap(\.rows)
                    }
                guard let row = rows.first(where: { $0.id == "selection.block_select_modifier" }),
                    case .menu(let options, let caution, let get, let set) = row.control
                else {
                    t.expect(false, desc: "the Selection pane carries a block-select chord picker")
                    return
                }
                let chosenBefore = get()
                defer { set(chosenBefore) }

                // The terms come from Core's vocabulary, so the count is the
                // table's and a picker that grew a choice of its own fails here.
                let tokens = SettingsCatalog.terms("selection", "block_select_modifier")
                t.expect(
                    options.count == tokens.count && !tokens.isEmpty,
                    desc: "the picker offers the vocabulary's terms (\(options.count) labels, \(tokens.count) tokens)"
                )

                // Every term reaches Core and comes back. Asserted for all of
                // them rather than one: a writer that ignored its argument, or
                // an index the table and the picker number differently, would
                // pass on whichever single term happened to be selected.
                for index in options.indices {
                    set(index)
                    t.expect(get() == index, desc: "chord \(options[index]) is written and read back")
                }

                // Exactly one term cautions, and it is the one that claims
                // Control — matched by token, because the label is display text.
                let cautioning = options.indices.filter { caution?($0) != nil }
                guard let control = tokens.firstIndex(of: "ctrl+opt") else {
                    t.expect(false, desc: "the vocabulary still offers a Control chord")
                    return
                }
                t.expect(
                    cautioning == [control],
                    desc: "only the Control chord cautions (cautioned \(cautioning), Control at \(control))"
                )
                t.expect(
                    caution?(control)?.contains("shortcut menu") == true,
                    desc: "and it names what stops working: \(caution?(control) ?? "nothing")"
                )
            }
        }
    }

    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private static func sidebarScrollView(in content: NSView, search: NSSearchField) -> NSScrollView? {
        let searchFrame = search.convert(search.bounds, to: nil)
        return descendants(of: content).compactMap { $0 as? NSScrollView }
            .first {
                let frame = $0.convert($0.bounds, to: nil)
                return $0.documentView is NSTableView && frame.minX <= searchFrame.midX && frame.maxX >= searchFrame.midX
            }
    }
}

/// A view's class and its descendants', one per line, indented by depth and
/// cut at `limit` levels below the root.
@MainActor
private func classTreeLines(of view: NSView, depth: Int, limit: Int) -> [String] {
    var lines = [String(repeating: "  ", count: depth) + NSStringFromClass(type(of: view))]
    guard depth < limit else { return lines }
    for subview in view.subviews {
        lines.append(contentsOf: classTreeLines(of: subview, depth: depth + 1, limit: limit))
    }
    return lines
}

@MainActor
private func checkProfileDeletionReferences(_ t: UBUITestContext) {
    guard let app = SettingsBridge.app else { return }
    let original = String(Ubiquitty.Preferences.liveDocument().pointee)
    let savedLayouts = SessionLayout.allSessions()
    defer {
        t.restoreConfiguration(original)
        try? SessionLayout.save(savedLayouts)
    }
    let parent = "Referenced UI profile"
    let child = "Child UI profile"
    app.settingsSaveProfile(["name": parent, "fontSize": NSNumber(value: 18)])
    app.settingsSaveProfile(["name": child, "parentProfile": parent])
    let tagIndex = app.settingsTags().count
    app.settingsSaveTag(["name": "Exact UI tag", "matchProfile": parent], at: -1)
    guard let controller = t.newWindowRunning(["/bin/cat"]) else { return }
    defer { controller.window?.close() }
    controller.applyProfile(named: parent)
    let layout = LayoutSession()
    layout.identifier = "profile-reference-test"
    layout.name = "Saved UI workspace"
    let group = LayoutGroup()
    let tab = LayoutTab()
    tab.paneLayout = controller.savedPresentation(needsLocalArrangement: true).encoded()
    group.tabs = [tab]
    layout.groups = [group]
    do { try SessionLayout.save([layout]) } catch {
        t.expect(false, desc: "the reference fixture could be saved")
        return
    }
    let references = app.settingsProfileDeletionReferences(parent)
    for reference in ["Profile: " + child, "Tag: Exact UI tag", "Open terminal windows", "Saved workspace: Saved UI workspace"] {
        t.expect(references.contains(reference), desc: "deletion reports " + reference)
    }
    app.settingsDeleteProfileNamed(parent)
    t.expect(
        app.settingsProfiles().contains { $0["name"] as? String == parent },
        desc: "the operation boundary preserves a referenced profile"
    )
    controller.window?.close()
    try? SessionLayout.save([])
    app.settingsDeleteTag(at: tagIndex)
    app.settingsDeleteProfileNamed(child)
    app.settingsDeleteProfileNamed(parent)
    t.expect(
        !app.settingsProfiles().contains { $0["name"] as? String == parent },
        desc: "removing references allows deletion"
    )
}
