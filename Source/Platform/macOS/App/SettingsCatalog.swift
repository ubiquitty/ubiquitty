// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SettingsCatalog.swift — the concrete Settings content: the sidebar
// categories and the General pane, each row bound to a Settings getter
// (C++ interop) and a write-through (UBAppDelegate Settings methods).
// Everything platform-facing funnels through `app`.
//
// To add a pane later: give its category a `SettingsPane` of cards here.
// No new view code — SettingsView renders any pane from this data.
//

import AppKit
import CoreText
import SwiftUI
import UbiquittyAppBridge
import UbiquittyKit

/// The weights the two font-weight rows offer, as one list.
///
/// The first entry is the absence of a setting rather than a weight: a face
/// whose upright instance is not 400 would be moved by a number, and a face
/// with no `wght` axis cannot honour one. Spelled once because two pickers
/// read it, and a second copy would let the labels and the values drift.
enum FontWeightChoice {
    /// The label and axis value of every offered weight, in order.
    static let entries: [(label: String, weight: Int)] = [
        ("Font Default", 0),
        ("Thin", 100),
        ("Extra Light", 200),
        ("Light", 300),
        ("Regular", 400),
        ("Medium", 500),
        ("Semibold", 600),
        ("Bold", 700),
        ("Extra Bold", 800),
        ("Black", 900),
    ]

    /// The labels, for a menu control.
    static var labels: [String] { entries.map(\.label) }

    /// The row a configured weight selects.
    ///
    /// A weight the list does not name — one written by hand into the config
    /// file — selects the default row rather than an arbitrary neighbour, so
    /// the menu never claims a value the file does not hold.
    ///
    /// - Parameter weight: The configured weight.
    /// - Returns: The index to show as selected.
    static func index(of weight: Int) -> Int {
        entries.firstIndex { $0.weight == weight } ?? 0
    }

    /// The weight a row selects.
    ///
    /// - Parameter index: The chosen row.
    /// - Returns: The axis value, or zero for the face's own.
    static func weight(at index: Int) -> Int {
        index >= 0 && index < entries.count ? entries[index].weight : 0
    }
}

// Main-actor as a type: every member builds settings-UI content, and the
// file's own account of the callers - SettingsWindowController, BeamController,
// the UI-test scenarios, SettingsView's body - is a list of main-actor
// contexts. A new caller off the main actor is a build error here rather than
// a race against NSApp.
@MainActor
enum SettingsCatalog {
    // The app delegate owns the persist + apply-to-all-windows broadcast;
    // the isolation is the type's, stated once above the enum.
    private static var app: UBAppDelegate? {
        NSApp.delegate as? UBAppDelegate
    }

    // One numeric control's bounds, read from the portable Settings schema
    // (Preferences/Schema.h via the C++ bridge) so the stepper/slider min /
    // max / step / unit and the TOML parse clamp can never disagree. There is
    // no UI literal for any of these numbers — the schema row is the source.
    struct Bounds {
        var minimum: Double
        var maximum: Double
        var step: Double
        var unit: String
    }

    // Resolve `section.key` to its schema bounds. Every key the catalog asks
    // for is declared in the schema table; a missing row is a programming error
    // (a renamed key), so trap in debug and fall back to a neutral 0...1 rather
    // than paint a broken control in release.
    //
    // Nonisolated by choice where the type is main-actor: the body reads the
    // C++ schema table through the bridge and touches nothing of AppKit's, so
    // static field lists build from it without an actor hop.
    nonisolated static func bounds(_ section: String, _ key: String) -> Bounds {
        let row = section.withCString { sectionC in
            key.withCString { keyC in
                Ubiquitty.Preferences.Schema.rangeFor(sectionC, keyC)
            }
        }
        assert(row != nil, "no schema range for \(section).\(key)")
        guard let range = row?.pointee else {
            return Bounds(minimum: 0, maximum: 1, step: 0, unit: "")
        }
        return Bounds(
            minimum: range.minimum,
            maximum: range.maximum,
            step: range.step,
            unit: range.unit.map { String(cString: $0) } ?? ""
        )
    }

    // The terms of a closed-vocabulary setting, from Core's table.
    private static func vocabulary(_ section: String, _ key: String) -> [Ubiquitty.Preferences.VocabularyTerm] {
        section.withCString { sectionC in
            key.withCString { keyC in
                Array(Ubiquitty.Preferences.vocabularyFor(sectionC, keyC))
            }
        }
    }

    // The labels of a closed-vocabulary setting, read from the portable
    // vocabulary table (Preferences/Vocabulary.h via the C++ bridge) so a
    // picker offers exactly the tokens the parser accepts. A hand-written array
    // here would be a second vocabulary in a second language, with nothing
    // comparing it to the one the file is read against.
    //
    // A term's index is its enum value — pinned by test_preferences_vocabulary
    // — so the index a segmented control hands back is the value to write, and
    // no second mapping is needed here.
    static func options(_ section: String, _ key: String) -> [String] {
        let terms = vocabulary(section, key)
        assert(!terms.isEmpty, "no vocabulary for \(section).\(key)")
        return terms.map { String(cString: $0.label) }
    }

    // The same vocabulary read as the TOKENS the file holds rather than the
    // labels a reader sees. For the rows that have to recognise a particular
    // term: a label is display text and may be reworded, and a comparison
    // against one would then stop matching without failing anything, while a
    // token is what the parser accepts and cannot be reworded without moving
    // the vocabulary the comparison is read from.
    static func terms(_ section: String, _ key: String) -> [String] {
        vocabulary(section, key).map { String(cString: $0.token) }
    }

    // Build a ± stepper from a schema row (min / max / step / unit all come
    // from `bounds`).
    private static func stepper(
        _ bounds: Bounds,
        get: @escaping @MainActor () -> Double,
        set: @escaping @MainActor (Double) -> Void
    ) -> SettingsRow.Control {
        .stepper(
            min: bounds.minimum,
            max: bounds.maximum,
            step: bounds.step,
            unit: bounds.unit,
            get: get,
            set: set
        )
    }

    // Build a continuous slider from a schema row. The schema's step is a
    // stepper affordance only, so it is unused here; the unit drives the value
    // readout ("" = the percentage style the slider uses for 0...1 ranges).
    private static func slider(
        _ bounds: Bounds,
        get: @escaping @MainActor () -> Double,
        set: @escaping @MainActor (Double) -> Void
    ) -> SettingsRow.Control {
        .slider(
            min: bounds.minimum,
            max: bounds.maximum,
            unit: bounds.unit.isEmpty ? nil : bounds.unit,
            get: get,
            set: set
        )
    }

    private static var appVersionPlaceholder: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !value.isEmpty
        {
            return value
        }
        return "0.0.0-dev"
    }

    static func categories() -> [SettingsCategory] {
        [
            SettingsCategory(
                id: "appearance",
                title: "Appearance",
                symbol: "paintpalette",
                color: .indigo,
                summary: "Choose the terminal background, background image, color theme, and command palette font.",
                group: .appearance,
                content: .pane(appearancePane()),
                searchKeywords: ["Theme", "Auto", "Light", "Dark"]
            ),
            SettingsCategory(
                id: "fonts",
                title: "Fonts",
                symbol: "textformat",
                color: .blue,
                summary: "Choose the terminal font and adjust its size, weight, spacing, underlines, and rendering.",
                group: .appearance,
                content: .pane(fontsPane()),
                pinnedHeader: { AnyView(FontSettingsPreview(kind: .font)) }
            ),
            SettingsCategory(
                id: "cursor",
                title: "Cursor",
                symbol: "rectangle.inset.filled",
                color: .orange,
                summary: "Choose the cursor shape, visibility, blinking, and movement.",
                group: .appearance,
                content: .pane(cursorPane()),
                pinnedHeader: { AnyView(FontSettingsPreview(kind: .cursor)) }
            ),
            SettingsCategory(
                id: "tabs",
                title: "Windows & Tabs",
                symbol: "macwindow",
                color: .gray,
                summary: "Customize window layout, tab behavior, and window, tab, and pane titles.",
                group: .appearance,
                content: .pane(tabsPane())
            ),
            SettingsCategory(
                id: "selection",
                title: "Selection & Clipboard",
                symbol: "text.cursor",
                color: .orange,
                summary: "Choose how text is selected, copied, and pasted.",
                group: .input,
                content: .pane(selectionPane())
            ),
            SettingsCategory(
                id: "mouse",
                title: "Mouse & Trackpad",
                symbol: "computermouse",
                color: .gray,
                summary: "Adjust the pointer, scrolling, and opening links.",
                group: .input,
                content: .pane(mousePane())
            ),
            SettingsCategory(
                id: "keys",
                title: "Keyboard",
                symbol: "keyboard",
                color: .gray,
                summary: "Set keyboard shortcuts and reusable command sequences.",
                group: .input,
                content: .custom { AnyView(KeysPane()) },
                searchKeywords: ["Key", "Shortcut", "Binding", "Action", "Option", "Alt", "Meta", "International"],
                searchEntries: [
                    .init(id: "keys.option_as_alt", label: "Use Option as Meta", keywords: ["Alt", "International"]),
                    .init(id: "keys.add-binding", label: "Add Key Binding", keywords: ["shortcut", "chord"]),
                ]
            ),
            SettingsCategory(
                id: "sessions",
                title: "Sessions",
                symbol: "rectangle.stack",
                color: .cyan,
                summary: "Configure remote connections, session restoration, profiles, and tags.",
                group: .sessions,
                content: .pane(sessionsPane())
            ),
            SettingsCategory(
                id: "terminal",
                title: "Terminal",
                symbol: "terminal",
                color: .gray,
                summary: "Configure scrollback, character encoding, and the identity reported to programs.",
                group: .sessions,
                content: .pane(terminalPane())
            ),
            SettingsCategory(
                id: "notifications",
                title: "Notifications",
                symbol: "bell.badge.fill",
                color: .red,
                summary: "Choose how the terminal gets your attention.",
                group: .system,
                content: .pane(notificationsPane())
            ),
            SettingsCategory(
                id: "accessibility",
                title: "Accessibility",
                symbol: "accessibility",
                color: .blue,
                summary: "Adjust terminal colors for your vision. Contrast and motion follow macOS accessibility settings.",
                group: .system,
                content: .pane(accessibilityPane())
            ),
            SettingsCategory(
                id: "security",
                title: "Privacy & Security",
                symbol: "hand.raised.fill",
                color: .blue,
                summary: "Protect keyboard input and manage access to your clipboard and terminal.",
                group: .system,
                content: .pane(securityPane())
            ),
            SettingsCategory(
                id: "themes",
                title: "Themes",
                symbol: "swatchpalette",
                color: .purple,
                summary: "Choose light and dark color themes, or create your own.",
                group: .appearance,
                parentID: "appearance",
                content: .custom { AnyView(ThemesPane()) },
                searchKeywords: ["Palette", "Import", "Duplicate", "Color", "Edit"],
                searchEntries: [.init(id: "themes.import", label: "Import Theme"), .init(id: "themes.new", label: "New Theme")]
            ),
            SettingsCategory(
                id: "font-features",
                title: "Font Features",
                symbol: "textformat.alt",
                color: .blue,
                summary: "Customize ligatures, alternate characters, and the features built into your font.",
                group: .appearance,
                parentID: "fonts",
                content: .custom { AnyView(FontFeaturesPane()) },
                searchKeywords: [
                    "OpenType", "OpenType Features", "Specification", "Stylistic Sets", "Ligatures", "Character Variants", "ss01", "calt",
                    "liga", "Alternates", "Variation Axes",
                ],
                searchEntries: [
                    .init(
                        id: "font.features.specification",
                        label: "OpenType Feature Specification",
                        keywords: ["calt", "liga", "ss01", "advanced"]
                    ),
                    .init(
                        id: "font.variations.specification",
                        label: "Variable Font Specification",
                        keywords: ["wght", "slnt", "axes", "variations"]
                    ),
                ],
                pinnedHeader: { AnyView(FontSettingsPreview(kind: .features)) }
            ),
            SettingsCategory(
                id: "font-routing",
                title: "Fallback Fonts",
                symbol: "arrow.triangle.branch",
                color: .blue,
                summary: "Choose which fonts draw particular characters and scripts.",
                group: .appearance,
                parentID: "fonts",
                content: .pane(fontFallbackPane()),
                searchKeywords: [
                    "Range Map", "range_map", "Fallback", "Unicode", "Code Point", "Powerline", "Nerd Font", "Symbols", "Per-Range",
                    "Override", "Script", "Route Preview Samples", "Font Routing",
                ],
                searchEntries: [
                    .init(id: "font.ranges", label: "Range Overrides", keywords: ["Unicode", "code point", "size matching"]),
                    .init(id: "font.add-range", label: "Add Font Range"),
                    .init(id: "font.script-fallbacks", label: "Script Fallbacks", keywords: ["language", "Arabic", "CJK"]),
                    .init(id: "font.fallback-order", label: "Fallback Order"),
                ],
                pinnedHeader: { AnyView(FontSettingsPreview(kind: .routing)) }
            ),
            SettingsCategory(
                id: "font-rendering",
                title: "Text & Graphics",
                symbol: "character.cursor.ibeam",
                color: .blue,
                summary: "Adjust glyph rendering, terminal graphics, Braille, and shaded blocks.",
                group: .appearance,
                parentID: "fonts",
                content: .pane(fontRenderingPane()),
                searchKeywords: ["Procedural", "Box Drawing", "Blocks", "Raster", "Glyph"],
                pinnedHeader: { AnyView(FontSettingsPreview(kind: .rendering)) }
            ),
            SettingsCategory(
                id: "window-titles",
                title: "Window Titles",
                symbol: "macwindow",
                color: .gray,
                summary: "Choose the folder icon and information shown in window titles.",
                group: .appearance,
                parentID: "tabs",
                content: .pane(windowTitlesPane())
            ),
            SettingsCategory(
                id: "tab-titles",
                title: "Tab Titles",
                symbol: "rectangle.topthird.inset.filled",
                color: .gray,
                summary: "Choose the information shown in each tab title.",
                group: .appearance,
                parentID: "tabs",
                content: .pane(tabTitlesPane())
            ),
            SettingsCategory(
                id: "pane-titles",
                title: "Pane Titles",
                symbol: "rectangle.split.2x1",
                color: .gray,
                summary: "Choose the information shown above each terminal pane.",
                group: .appearance,
                parentID: "tabs",
                content: .pane(paneTitlesPane())
            ),
            SettingsCategory(
                id: "macros",
                title: "Macros",
                symbol: "text.badge.plus",
                color: .purple,
                summary: "Create reusable text and command sequences.",
                group: .input,
                parentID: "keys",
                content: .custom { AnyView(MacrosPane()) },
                searchKeywords: ["Macro", "Text", "Command", "Sequence"],
                searchEntries: [.init(id: "macros.new", label: "New Macro")]
            ),
            SettingsCategory(
                id: "profiles",
                title: "Profiles",
                symbol: "person.crop.square.on.square.angled",
                color: .cyan,
                summary: "Save terminal configurations for different tasks and sessions.",
                group: .sessions,
                parentID: "sessions",
                content: .custom { AnyView(ProfilesPane()) },
                searchKeywords: ["Profile", "Theme", "Font", "Shell", "Directory"],
                searchEntries: [
                    .init(id: "profiles.new", label: "New Profile"), .init(id: "profiles.import", label: "Import Shared Profile"),
                    .init(id: "profiles.reset-window", label: "Reset Window Overrides"),
                ]
            ),
            SettingsCategory(
                id: "tags",
                title: "Tags",
                symbol: "tag",
                color: .orange,
                summary: "Organize sessions with named tags and colors.",
                group: .sessions,
                parentID: "sessions",
                content: .custom { AnyView(TagsPane()) },
                searchKeywords: ["Tag", "Match", "Rule", "Color"],
                searchEntries: [
                    .init(id: "tags.new", label: "New Tag"),
                    .init(
                        id: "appearance.tag_color_opacity",
                        label: "Tag Color Strength",
                        keywords: ["Opacity", "Strength", "Dim", "Tab", "Title Bar"]
                    ),
                ]
            ),
            SettingsCategory(
                id: "tektronix",
                title: "Vector Graphics",
                symbol: "scribble.variable",
                color: .green,
                summary: "Customize the colors and effects of Tektronix vector graphics.",
                group: .sessions,
                parentID: "terminal",
                content: .custom { AnyView(TektronixPane()) },
                searchKeywords: ["Tektronix", "Beam", "Background", "Bright Pen", "Glowing Vectors"]
            ),
            SettingsCategory(
                id: "platform",
                title: "Platform Overrides",
                symbol: "macwindow.on.rectangle",
                color: .gray,
                summary: "Override font and layout settings for a specific operating system.",
                group: .sessions,
                parentID: "terminal",
                content: .custom { AnyView(PlatformPane()) },
                searchKeywords: ["Platform", "Override", "macOS", "Linux", "Font", "Padding"]
            ),
            SettingsCategory(
                id: "agents",
                title: "Agents",
                symbol: "sparkles",
                color: .indigo,
                summary: "Manage access for agents that connect to your terminal.",
                group: .system,
                parentID: "security",
                content: .custom { AnyView(AgentsPane()) },
                searchKeywords: ["Agent", "Token", "Scope", "Issue", "Revoke"],
                searchEntries: [.init(id: "agents.issue", label: "Issue Agent Token")]
            ),
        ] + softwareUpdateCategories()
    }

    // Software Update exists exactly when the build has an updater, as the app
    // menu's "Check for Updates…" item does: without one, the toggle would
    // persist a choice that nothing reads.
    private static func softwareUpdateCategories() -> [SettingsCategory] {
        guard Updater.isAvailable else { return [] }
        return [
            SettingsCategory(
                id: "updates",
                title: "Software Update",
                symbol: "gear.badge",
                color: .gray,
                summary: "Choose whether Ubiquitty looks for new versions on its own.",
                group: .system,
                content: .pane(
                    SettingsPane(cards: [
                        SettingsCard(
                            title: nil,
                            footer: "To check now, choose Ubiquitty > Check for Updates.",
                            rows: [
                                SettingsRow(
                                    id: "updates.check_automatically",
                                    "Check for updates automatically",
                                    detail:
                                        "Look for a new version once a day. Ubiquitty shows what it finds and installs "
                                        + "nothing until you choose to.",
                                    control: .toggle(
                                        get: { settingBool(.UpdatesCheckAutomatically) },
                                        set: { app?.settingsSetCheckForUpdatesAutomatically($0) }
                                    )
                                )
                            ]
                        )
                    ])
                ),
                searchKeywords: ["Update", "Upgrade", "New Version", "Release"]
            )
        ]
    }

    // Family picker: a menu of installed fixed-pitch families ("System Monospaced"
    // at index 0 = the default). The control is index-based but the font is stored
    // as a family-name string, so map both ways through the captured list. If the
    // configured family isn't installed (a stale/custom name) keep it in the list
    // so the picker still shows it rather than silently snapping to the default.
    private static func fontFamilyControl() -> SettingsRow.Control {
        var names = app?.settingsMonospacedFontNames() ?? ["System Monospaced"]
        if !names.contains("GNU Unifont") {
            names.insert("GNU Unifont", at: min(1, names.count))
        }
        let current = app?.settingsFontFamily() ?? ""
        if !current.isEmpty && !names.contains(current) {
            names.append(current)
        }
        let options = names // captured immutably so get/set agree on indices
        return .menu(
            options: options,
            get: {
                let family = app?.settingsFontFamily() ?? ""
                if family.isEmpty { return 0 } // System Monospaced
                return options.firstIndex(of: family) ?? 0
            },
            set: { index in
                if index <= 0 {
                    app?.settingsSetFontFamily("") // reset to System Monospaced
                } else if index < options.count {
                    app?.settingsSetFontFamily(options[index])
                }
            }
        )
    }

    /// The live render configuration, for the proportional rows' reads.
    private static func proportionalConfiguration() -> Ubiquitty.Rendering.RenderConfiguration {
        Ubiquitty.Preferences.Effective.liveRenderConfiguration()
    }

    /// The installed proportional families, the platform's UI face first.
    ///
    /// Fixed-pitch families are left out: a proportional run set in one is
    /// the grid's own text, which the Family picker above already chooses.
    private static func proportionalFamilyControl() -> SettingsRow.Control {
        let systemLabel = "System (SF Pro Text)"
        let manager = NSFontManager.shared
        var names = manager.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), let font = NSFont(name: family, size: 12) else {
                return false
            }
            return !font.isFixedPitch
        }
        names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let current = String(proportionalConfiguration().proportionalFontFamily.string())
        if !current.isEmpty, !names.contains(current) {
            names.append(current)
        }
        let options = [systemLabel] + names
        return .menu(
            options: options,
            get: {
                let family = String(proportionalConfiguration().proportionalFontFamily.string())
                if family.isEmpty { return 0 }
                return options.firstIndex(of: family) ?? 0
            },
            set: { index in
                let family = index <= 0 || index >= options.count ? "" : options[index]
                setSetting(.FontProportionalFamily, text: family)
            }
        )
    }

    // A weight picker built from the configured family's own members. The rows
    // are captured at build time, the way the family picker's are; the Fonts
    // category rebuilds its catalogue on every visit and on a family change,
    // which is when the members can differ.
    private static func fontWeightControl(isBold: Bool) -> SettingsRow.Control {
        let family = app?.settingsFontFamily() ?? ""
        let configured = Int((isBold ? app?.settingsBoldFontWeight() : app?.settingsFontWeight()) ?? 0)
        let entries = FontWeightCatalog.entries(forFamilyNamed: family, configuredWeight: configured)
        return .menu(
            options: entries.map(\.label),
            get: {
                let current = Int((isBold ? app?.settingsBoldFontWeight() : app?.settingsFontWeight()) ?? 0)
                return FontWeightCatalog.index(of: current, in: entries)
            },
            set: { index in
                let chosen = index >= 0 && index < entries.count ? entries[index].weight : 0
                if isBold {
                    app?.settingsSetFontWeight(Int(app?.settingsFontWeight() ?? 0), bold: chosen)
                } else {
                    app?.settingsSetFontWeight(chosen, bold: Int(app?.settingsBoldFontWeight() ?? 0))
                }
            }
        )
    }

    // Symbol fallback picker. Index 0 = STIX Two Math; every
    // installed family follows.
    //
    // Membership is universal on purpose. font.symbol_fallback is a string key
    // that accepts any family name, so a picker offering a subset leaves values
    // a user can reach by hand and not by clicking — a control narrower than
    // the key it edits. Symbol coverage ORDERS the list instead: the families
    // that answer the blocks a symbol fallback exists for come first under
    // their own names, and the rest follow marked, so the ranking warns before
    // a choice rather than forbidding it.
    //
    // Labels and values are separate because the marked labels are not family
    // names; the value written is always the bare family. A configured name
    // that isn't installed is kept so the picker still shows it.
    private static let limitedSymbolCoverageMark = " — limited symbol coverage"
    private static let limitedEmojiCoverageMark = " — no pictographs"

    /// The Emoji Fallback row: every installed family, pictograph-carrying ones
    /// first under their own names and the rest after, marked.
    ///
    /// Membership rather than a filter, for the reason the symbol row offers
    /// every family: `font.emoji_fallback` accepts any family name, so a picker
    /// showing a subset would leave values reachable by hand and not by
    /// clicking. Coverage orders the list instead of gating it.
    private static func emojiFallbackFontControl() -> SettingsRow.Control {
        let covering = Set(app?.settingsEmojiFontNames() ?? [])
        var entries: [(label: String, value: String)] = [("System Emoji", "")]
        let installed = app?.settingsAllFontFamilyNames() ?? []
        for family in installed where covering.contains(family) {
            entries.append((family, family))
        }
        for family in installed where !covering.contains(family) {
            entries.append((family + limitedEmojiCoverageMark, family))
        }
        let current = app?.settingsEmojiFallbackFont() ?? ""
        if !current.isEmpty && !entries.contains(where: { $0.value == current }) {
            entries.append((current, current))
        }
        let options = entries // captured immutably so get/set agree on indices
        return .menu(
            options: options.map(\.label),
            get: {
                let family = app?.settingsEmojiFallbackFont() ?? ""
                if family.isEmpty { return 0 } // the platform's own emoji face
                return options.firstIndex(where: { $0.value == family }) ?? 0
            },
            set: { index in
                if index <= 0 {
                    app?.settingsSetEmojiFallbackFont("") // back to the platform face
                } else if index < options.count {
                    app?.settingsSetEmojiFallbackFont(options[index].value)
                }
            }
        )
    }

    private static func symbolFallbackFontControl() -> SettingsRow.Control {
        let covering = Set(app?.settingsSymbolFontNames() ?? [])
        var entries: [(label: String, value: String)] = [("Symbols Nerd Font Mono (Default)", "")]
        let installed = app?.settingsAllFontFamilyNames() ?? []
        for family in installed where covering.contains(family) {
            entries.append((family, family))
        }
        for family in installed where !covering.contains(family) {
            entries.append((family + limitedSymbolCoverageMark, family))
        }
        let current = app?.settingsSymbolFallbackFont() ?? ""
        if !current.isEmpty && !entries.contains(where: { $0.value == current }) {
            entries.append((current, current))
        }
        let options = entries // captured immutably so get/set agree on indices
        return .menu(
            options: options.map(\.label),
            get: {
                let family = app?.settingsSymbolFallbackFont() ?? ""
                if family.isEmpty { return 0 } // default technical symbol face
                return options.firstIndex(where: { $0.value == family }) ?? 0
            },
            set: { index in
                if index <= 0 {
                    app?.settingsSetSymbolFallbackFont("") // reset to the default symbol face
                } else if index < options.count {
                    app?.settingsSetSymbolFallbackFont(options[index].value)
                }
            }
        )
    }

    private static func cjkFallbackControl() -> SettingsRow.Control {
        let builtIns: [(label: String, value: String)] = [
            ("Auto (System)", ""),
            ("Simplified Chinese (zh-Hans)", "zh-Hans"),
            ("Traditional Chinese (zh-Hant)", "zh-Hant"),
            ("Japanese (ja)", "ja"),
            ("Korean (ko)", "ko"),
        ]
        var options = builtIns
        for family in app?.settingsCJKFontNames() ?? [] where !options.contains(where: { $0.value == family }) {
            options.append((family, family))
        }
        let current = app?.settingsCJKFallbackFont() ?? ""
        if !current.isEmpty && !options.contains(where: { $0.value == current }) {
            options.append((current, current))
        }
        let labels = options.map(\.label)
        return .menu(
            options: labels,
            get: {
                let value = app?.settingsCJKFallbackFont() ?? ""
                return options.firstIndex(where: { $0.value == value }) ?? 0
            },
            set: { index in
                if index >= 0 && index < options.count {
                    app?.settingsSetCJKFallbackFont(options[index].value)
                }
            }
        )
    }

    // Input character encoding ([terminal] encoding) picker. The menu lists the
    // canonical encoding names the Core registry exposes (settingsEncodingNames,
    // registry order; index 0 = UTF-8 = the default) so the UI can't drift from
    // the table. The control is index-based but the config stores the canonical
    // name, so map both ways through the captured list. A configured name the
    // registry doesn't list (an unknown/stale value) reads back as the default,
    // so the getter snaps to index 0 rather than appending an unmapped entry.
    private static func encodingControl() -> SettingsRow.Control {
        let names = app?.settingsEncodingNames() ?? ["utf-8"]
        // Friendlier labels over the technical canonical tokens; falls back to
        // the canonical name for anything not in the map.
        let labels: [String: String] = [
            "utf-8": "UTF-8 (Unicode)",
            "latin1": "Latin-1 (ISO-8859-1)",
            "iso-8859-15": "Latin-9 (ISO-8859-15)",
            "windows-1252": "Windows-1252",
            "koi8-r": "KOI8-R (Cyrillic)",
            "shift_jis": "Shift_JIS (Japanese)",
            "euc-jp": "EUC-JP (Japanese)",
            "euc-kr": "EUC-KR (Korean)",
            "gb18030": "GB18030 (Chinese)",
            "big5": "Big5 (Traditional Chinese)",
        ]
        let options = names // captured immutably so get/set agree on indices
        let display = options.map { labels[$0] ?? $0 }
        return .menu(
            options: display,
            get: {
                let name = app?.settingsEncoding() ?? ""
                if name.isEmpty { return 0 } // unset / UTF-8 default
                return options.firstIndex(of: name) ?? 0
            },
            set: { index in
                if index >= 0 && index < options.count {
                    app?.settingsSetEncoding(options[index])
                }
            }
        )
    }

    private static func fontsPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Font",
                rows: [
                    SettingsRow(
                        id: "font.family",
                        "Family",
                        detail: "Choose a fixed-pitch family. The preview uses the terminal renderer.",
                        control: .deferred { fontFamilyControl() },
                        presentation: .fontFamily
                    ),
                    SettingsRow(
                        id: "font.size",
                        "Size",
                        control: stepper(
                            bounds("font", "size"),
                            get: { settingDouble(.FontSize) },
                            set: { app?.settingsSetFontSize($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.proportional_family",
                        "Proportional Family",
                        detail:
                            "Sets the face for proportional runs, the labels a program places beside the grid with OSC 66 p=1. "
                            + "System is SF Pro Text. The Mixed Faces preview shows runs and grid text on one baseline.",
                        control: .deferred { proportionalFamilyControl() },
                        presentation: .fontFamily
                    ),
                    SettingsRow(
                        id: "font.proportional_size",
                        "Proportional Size",
                        detail:
                            "Sets the size of proportional runs in points. 0 sets them one optical step over the grid size — 13 points against a 12-point grid — because a proportional face lays down less ink per line than a monospace and reads smaller at the same size.",
                        control: stepper(
                            bounds("font", "proportional_size"),
                            get: { proportionalConfiguration().proportionalFontSizePoints },
                            set: { points in
                                setSetting(
                                    .FontProportionalSize,
                                    double: Ubiquitty.Preferences.Schema.clampToRange(points, "font", "proportional_size")
                                )
                            }
                        )
                    ),
                    SettingsRow(
                        id: "font.weight",
                        "Font Weight",
                        detail:
                            "Sets the weight of regular text from the faces available in this family.",
                        control: .deferred { fontWeightControl(isBold: false) }
                    ),
                    SettingsRow(
                        id: "font.bold_weight",
                        "Bold Weight",
                        detail:
                            "Sets the weight used when a program requests bold text.",
                        control: .deferred { fontWeightControl(isBold: true) }
                    ),
                    SettingsRow(
                        id: "font.width",
                        "Font Width",
                        detail:
                            "Sets the width of the letterforms in fonts that support it.",
                        control: stepper(
                            bounds("font", "width"),
                            get: { app?.settingsFontWidth() ?? 0 },
                            set: { app?.settingsSetFontWidth($0) }
                        ),
                        presentation: .fontWidth
                    ),
                ]
            ),
            SettingsCard(
                title: "Spacing",
                rows: [
                    SettingsRow(
                        id: "font.line_spacing",
                        "Line Spacing",
                        detail: "Adds space above the font’s natural line height.",
                        control: stepper(
                            bounds("font", "line_spacing"),
                            get: { settingDouble(.FontLineSpacing) },
                            set: { app?.settingsSetLineSpacing($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.character_spacing",
                        "Character Spacing",
                        detail:
                            "Extra space between columns. Negative values bring characters closer together. "
                            + "A font drawn through CoreText is tracked by the exact value and carries the gap "
                            + "after each glyph; GNU Unifont is a bitmap face, so it rounds the value to whole "
                            + "screen pixels and splits the gap around the glyph.",
                        control: stepper(
                            bounds("font", "character_spacing"),
                            get: { app?.settingsCharacterSpacing() ?? 0 },
                            set: { app?.settingsSetCharacterSpacing($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.baseline_offset",
                        "Baseline Offset",
                        detail: "Move the glyphs vertically within their cells without changing the line height.",
                        control: stepper(
                            bounds("font", "baseline_offset"),
                            get: { app?.settingsBaselineOffset() ?? 0 },
                            set: { app?.settingsSetBaselineOffset($0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Shaping",
                rows: [
                    SettingsRow(
                        id: "font.ligatures",
                        "Ligatures",
                        detail: "Join character sequences into ligatures, so -> becomes an arrow.",
                        control: .toggle(
                            get: { settingBool(.FontLigatures) },
                            set: { app?.settingsSetLigatures($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.zero",
                        "Slashed Zero",
                        detail: "Distinguish 0 from O when the font supports it.",
                        control: .toggle(
                            get: { app?.settingsSlashedZero() ?? false },
                            set: { app?.settingsSetSlashedZero($0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Underline",
                rows: [
                    SettingsRow(
                        id: "underline.thickness",
                        "Thickness",
                        detail: "Scale the underline weight the font provides.",
                        control: stepper(
                            bounds("underline", "thickness"),
                            get: { settingDouble(.UnderlineThickness) },
                            set: { app?.settingsSetUnderlineThickness($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.offset",
                        "Offset",
                        detail: "Move the underline this many points below the baseline. Negative values raise it.",
                        control: stepper(
                            bounds("underline", "offset"),
                            get: { settingDouble(.UnderlineOffset) },
                            set: { app?.settingsSetUnderlineOffset($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.follows_ink",
                        "Follow Ink",
                        detail: "Extend a word’s underline to where the ink of its outer letters ends, past the cell.",
                        control: .toggle(
                            get: { settingBool(.UnderlineFollowsInk) },
                            set: { app?.settingsSetUnderlineFollowsInk($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.skip_ink",
                        "Skip Ink",
                        detail: "Break the rule where descenders cross it.",
                        control: .toggle(
                            get: { settingBool(.UnderlineSkipInk) },
                            set: { app?.settingsSetUnderlineSkipInk($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.skip_ink_pad",
                        "Skip-Ink Gap",
                        detail: "Set the space cleared around descenders where they cross the underline.",
                        control: stepper(
                            bounds("underline", "skip_ink_pad"),
                            get: { settingDouble(.UnderlineSkipInkPad) },
                            set: { app?.settingsSetUnderlineSkipInkPad($0) }
                        )
                    ),
                ]
            ),
        ])
    }

    static func fontFallbackPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Fallback Fonts",
                rows: [
                    SettingsRow(
                        id: "font.match_fallback_size",
                        "Match Fallback Font Size",
                        detail: "Match fallback text to the primary font’s visible size. Range overrides can choose a different size.",
                        control: .toggle(
                            get: { settingBool(.FontMatchFallbackSize) },
                            set: { setSetting(.FontMatchFallbackSize, bool: $0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.symbol_fallback",
                        "Symbol Fallback",
                        detail:
                            "Used for symbols missing from the primary font. Bundled Nerd Font icons are the default; technical symbols also fall back to STIX Two Math.",
                        control: .deferred { symbolFallbackFontControl() },
                        presentation: .fontFamily
                    ),
                    SettingsRow(
                        id: "font.cjk_fallback",
                        "CJK Fallback",
                        detail:
                            "Regional glyph forms for unified Han. Auto uses the system cascade; language choices or font families pin CJK forms.",
                        control: .deferred { cjkFallbackControl() },
                        presentation: .fontFamily
                    ),
                    SettingsRow(
                        id: "font.emoji_fallback",
                        "Emoji Fallback",
                        detail:
                            "Choose the font for emoji. System Emoji uses the macOS default.",
                        control: .deferred { emojiFallbackFontControl() },
                        presentation: .fontFamily
                    ),
                ]
            )
        ])
    }

    private static func fontRenderingPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Character Rendering",
                rows: [
                    SettingsRow(
                        id: "text.brighten_bold",
                        "Bold Is Bright",
                        detail: "Use the bright ANSI color for bold text.",
                        control: .toggle(
                            get: { settingBool(.TextBrightenBold) },
                            set: { app?.settingsSetBrightenBold($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.braille_grid",
                        "Braille Grid",
                        detail:
                            "Draw Braille on an even dot grid for charts and images. Turn off to use the font’s glyphs.",
                        control: .toggle(
                            get: { settingBool(.FontBrailleGrid) },
                            set: { app?.settingsSetBrailleGrid($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.braille_style",
                        "Braille Style",
                        detail:
                            "Choose dot shapes and guides for unused positions. The preview shows the resulting grid.",
                        control: .menu(
                            options: ["Regular", "Outline 6 Dot", "Outline 8 Dot", "Pinpoint 6 Dot", "Pinpoint 8 Dot", "Square", "Raster"],
                            get: { settingTermIndex(.FontBrailleStyle) },
                            set: { setSetting(.FontBrailleStyle, termIndex: $0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.shade_blocks",
                        "Shaded Blocks",
                        detail: "Show ░ ▒ ▓ as a pixel pattern of the text color, as on Linux, or as a translucent fill.",
                        control: .segmented(
                            options: options("appearance", "shade_blocks"),
                            get: { settingTermIndex(.AppearanceShadeBlocks) },
                            set: { setSetting(.AppearanceShadeBlocks, termIndex: $0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.wide_glyph_boost",
                        "Wide Glyph Boost",
                        detail:
                            "Optically enlarge CJK, Hangul, and fullwidth mono glyphs inside their two-cell slot. Emoji stay on the color glyph path.",
                        control: .toggle(
                            get: { settingBool(.FontWideGlyphBoost) },
                            set: { app?.settingsSetWideGlyphBoost($0) }
                        )
                    ),
                    SettingsRow(
                        id: "font.wide_glyph_scale",
                        "Wide Glyph Scale",
                        detail: "Scale the ink of fullwidth monospace glyphs by a small factor.",
                        control: stepper(
                            bounds("font", "wide_glyph_scale"),
                            get: { settingDouble(.FontWideGlyphScale) },
                            set: { app?.settingsSetWideGlyphScale($0) }
                        )
                    ),
                ]
            )
        ])
    }

    private static func accessibilityPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Color Vision",
                footer: "High contrast follows the Increase Contrast setting in System Settings ▸ Accessibility ▸ Display, "
                    + "so Ubiquitty has no separate setting for it.",
                rows: [
                    SettingsRow(
                        id: "appearance.colorblind_mode",
                        "Colorblind Mode",
                        detail: "Remaps the active theme’s palette so hues that are easy to confuse look distinct.",
                        control: .menu(
                            options: options("appearance", "colorblind_mode"),
                            get: { settingTermIndex(.AppearanceColorblindMode) },
                            set: { app?.settingsSetColorblindMode($0) }
                        )
                    )
                ]
            )
        ])
    }

    private static func appearancePane() -> SettingsPane {
        SettingsPane(cards: [
            windowCard(),
            backgroundImageCard(),
            SettingsCard(
                title: "Command Palette",
                rows: [
                    SettingsRow(
                        id: "appearance.beam_terminal_font",
                        "Beam Uses Terminal Font",
                        detail: "Beam (⌘⇧P) uses the terminal’s font instead of the system font.",
                        control: .toggle(
                            get: { settingBool(.AppearanceBeamTerminalFont) },
                            set: { app?.settingsSetBeamTerminalFont($0) }
                        )
                    )
                ]
            ),
        ])
    }

    // The Tags pane's lead card: how strongly a tag's colour is drawn in the
    // title bar and on tabs. A catalog row in a custom pane, so it reads,
    // resets and searches as every other slider does.
    static func tagStrengthCard() -> SettingsCard {
        SettingsCard(
            rows: [
                SettingsRow(
                    id: "appearance.tag_color_opacity",
                    "Tag Color Strength",
                    detail:
                        "Sets how strongly a tag’s color fills its marks on tabs and in the window title. A loud tag’s title bar tint stays at full strength.",
                    control: slider(
                        bounds("appearance", "tag_color_opacity"),
                        get: { settingDouble(.AppearanceTagColorOpacity) },
                        set: { app?.settingsSetTagColorOpacity($0) }
                    )
                )
            ]
        )
    }

    // The Window card. Background Opacity (background alpha behind solid
    // text) and Background Blur (the behind-window material) are in every
    // build. The Blur Radius row appears only in builds that compile the
    // window-server radius in (see UBBackgroundBlur.h) — elsewhere the radius
    // is the system's and the key would persist a number nothing reads. The
    // flag is compile-time constant, so the categories()-snapshot-at-init
    // behavior is fine.
    private static func windowCard() -> SettingsCard {
        var rows: [SettingsRow] = [
            SettingsRow(
                id: "appearance.color_space",
                "Color Space",
                detail: "Display P3 renders more saturated colors; sRGB is standard.",
                control: .segmented(
                    options: options("appearance", "color_space"),
                    get: { (settingIsColorSpaceP3() ? 1 : 0) },
                    set: { app?.settingsSetColorSpaceIndex($0) }
                )
            ),

            SettingsRow(
                id: "appearance.background_opacity",
                "Background Opacity",
                detail: "Sets how strongly the theme tints the background. 0 leaves only the native material when blur is on; 1 is opaque.",
                control: slider(
                    bounds("appearance", "background_opacity"),
                    get: { settingDouble(.AppearanceBackgroundOpacity) },
                    set: { app?.settingsSetBackgroundOpacity($0) }
                )
            ),
            SettingsRow(
                id: "appearance.text_contrast",
                "Perceptual Text Contrast",
                detail:
                    "Improve faint text against each cell’s background while preserving hue. This helps when an app’s colors don’t match the terminal theme.",
                control: .toggle(
                    get: { settingBool(.AppearanceTextContrast) },
                    set: { app?.settingsSetTextContrast($0) }
                )
            ),
        ]
        rows.append(
            SettingsRow(
                id: "appearance.background_blur_enabled",
                "Background Blur",
                detail: "Blur the desktop behind the window; the background opacity sets how strongly the theme tints it.",
                control: .toggle(
                    get: { settingDouble(.AppearanceBlurRadius) > 0 },
                    set: { app?.settingsSetBackgroundBlur($0) }
                )
            )
        )
        rows.append(
            SettingsRow(
                id: "appearance.text_contrast_on_blur",
                "Text Vibrancy on Blur",
                detail:
                    "Blend text colors with the blurred backdrop. Gray text keeps a continuous brightness hierarchy; colored text gains native vibrancy.",
                control: .toggle(
                    get: { settingBool(.AppearanceTextContrastOnBlur) },
                    set: { app?.settingsSetTextContrastOnBlur($0) }
                )
            )
        )
        rows.append(
            SettingsRow(
                id: "appearance.background_vibrancy",
                "Background Vibrancy",
                detail: "Blend colored cell backgrounds with the blurred backdrop. Text and the cursor remain above the effect.",
                control: .toggle(
                    get: { settingBool(.AppearanceBackgroundVibrancy) },
                    set: { app?.settingsSetBackgroundVibrancy($0) }
                )
            )
        )
        if Ubiquitty.SwiftBridge.backgroundBlurRadiusCompiledIn() {
            rows.append(
                SettingsRow(
                    id: "appearance.blur_radius",
                    "Blur Radius",
                    detail: "Sets how strongly the desktop behind the window is blurred. 0 turns blur off.",
                    control: slider(
                        bounds("appearance", "blur_radius"),
                        get: { settingDouble(.AppearanceBlurRadius) },
                        set: { app?.settingsSetBlurRadius($0) }
                    )
                )
            )
        }
        return SettingsCard(title: "Background", rows: rows)
    }

    // The Background Image card: a live preview with its chooser, then how the
    // picture is placed and how strongly it shows. Mode and Opacity stay in
    // place, dimmed, until there is an image, so the card keeps its shape.
    // The picture lies under the theme's tint, which is why the footer and
    // the opacity detail point back at the Background card above.
    private static func backgroundImageCard() -> SettingsCard {
        let keywords = ["Background Image", "Wallpaper", "Picture", "Photo"]
        let isSet: @MainActor () -> Bool = { BackgroundImageSettings.isSet }
        return SettingsCard(
            title: "Background Image",
            footer: "The image sits behind the theme’s background color, so Background Opacity decides how much of it shows through.",
            rows: [
                SettingsRow(
                    id: "appearance.background_image",
                    "Background Image",
                    detail: "Shows a picture behind the terminal, like desktop wallpaper.",
                    control: .backgroundImage(
                        get: { BackgroundImageSettings.path },
                        set: { BackgroundImageSettings.setPath($0) }
                    ),
                    keywords: keywords
                ),
                SettingsRow(
                    id: "appearance.background_image_mode",
                    "Mode",
                    detail: "Sets how the image is placed in the window.",
                    control: .menu(
                        options: options("appearance", "background_image_mode"),
                        get: { BackgroundImageSettings.modeIndex },
                        set: { BackgroundImageSettings.setModeIndex($0) }
                    ),
                    keywords: keywords,
                    isEnabled: isSet,
                    currentDetail: { BackgroundImageSettings.modeDescription(BackgroundImageSettings.mode) }
                ),
                SettingsRow(
                    id: "appearance.background_image_opacity",
                    "Opacity",
                    detail:
                        "Sets how strongly the image shows. Below 100%, the desktop shows through it, blurred when Background Blur is on.",
                    control: slider(
                        bounds("appearance", "background_image_opacity"),
                        get: { BackgroundImageSettings.opacity },
                        set: { BackgroundImageSettings.setOpacity($0) }
                    ),
                    keywords: keywords,
                    isEnabled: isSet
                ),
            ]
        )
    }

    private static func selectionPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Selection",
                rows: [
                    SettingsRow(
                        id: "selection.copy_on_select",
                        "Copy on Select",
                        detail: "Copy the selection to the clipboard at the end of a drag.",
                        control: .toggle(
                            get: { settingBool(.SelectionCopyOnSelect) },
                            set: { app?.settingsSetCopy(onSelect: $0) }
                        )
                    ),
                    SettingsRow(
                        id: "selection.smart_double_click",
                        "Smart Double-Click",
                        detail: "Double-clicking selects a whole URL or path, not just a word.",
                        control: .toggle(
                            get: { settingBool(.SelectionSmartDoubleClick) },
                            set: { app?.settingsSetSmartDoubleClick($0) }
                        )
                    ),
                    SettingsRow(
                        id: "selection.style",
                        "Selection Color",
                        detail:
                            "System Color fills a selection with the system’s highlight color behind the text, as a text view does. Translucent Tint lays a tint over the text.",
                        control: .menu(
                            options: options("selection", "style"),
                            get: { settingTermIndex(.SelectionStyle) },
                            set: {
                                setSetting(.SelectionStyle, termIndex: $0)
                            }
                        )
                    ),
                    SettingsRow(
                        id: "selection.select_modifier",
                        "App Selection Modifier",
                        detail: "Hold while dragging to select text in apps that capture the mouse.",
                        control: .menu(
                            options: options("selection", "select_modifier"),
                            caution: { index in
                                let tokens = terms("selection", "select_modifier")
                                guard tokens.indices.contains(index) else { return nil }
                                if tokens[index] == "ctrl" {
                                    return "Control-click selects text instead of opening the shortcut menu."
                                }
                                if tokens[index] == "cmd" {
                                    return "Command-click selects text instead of opening links while the app captures the mouse."
                                }
                                return nil
                            },
                            get: { settingTermIndex(.SelectionSelectModifier) },
                            set: { setSetting(.SelectionSelectModifier, termIndex: $0) }
                        )
                    ),
                    SettingsRow(
                        id: "selection.block_select_modifier",
                        "Block Selection Modifier",
                        detail: "Hold while dragging to select a rectangle.",
                        control: .menu(
                            options: options("selection", "block_select_modifier"),
                            // Control is offered because a reader may want it, and
                            // cautioned because what it costs is not visible in the
                            // name: Control-click is how macOS opens a contextual
                            // menu everywhere else, and a chord that claims Control
                            // takes that menu away for as long as it is selected.
                            caution: { index in
                                let tokens = terms("selection", "block_select_modifier")
                                guard tokens.indices.contains(index), tokens[index] == "ctrl+opt" else {
                                    return nil
                                }
                                return "Control-click no longer opens the shortcut menu."
                            },
                            get: { settingTermIndex(.SelectionBlockSelectModifier) },
                            set: { setSetting(.SelectionBlockSelectModifier, termIndex: $0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Paste",
                footer:
                    "These settings guard against pasting commands by accident.",
                rows: [
                    SettingsRow(
                        id: "paste.confirm_multiline",
                        "Confirm Multi-Line Paste",
                        detail:
                            "Ask before pasting clipboard text that spans multiple lines, so a stray multi-line clipboard can’t run a string of commands by itself.",
                        control: .toggle(
                            get: { settingBool(.PasteConfirmMultiline) },
                            set: { app?.settingsSetConfirmMultilinePaste($0) }
                        )
                    ),
                    SettingsRow(
                        id: "paste.confirm_multiline_threshold",
                        "Confirm Above",
                        detail: "Ask only when the paste has more than this many lines. 1 asks for anything longer than a single line.",
                        control: stepper(
                            bounds("paste", "confirm_multiline_threshold"),
                            get: { settingDouble(.PasteConfirmMultilineThreshold) },
                            set: { app?.settingsSetConfirmMultilinePasteThreshold(Int($0)) }
                        )
                    ),
                ]
            ),
        ])
    }

    private static func mousePane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Pointer",
                rows: [
                    SettingsRow(
                        id: "selection.restrict_to_text",
                        "Text Cursor Only Over Text",
                        detail:
                            "Behave like a document: the pointer is a text cursor over actual text and a normal arrow over blank space — turning back into a text cursor as you drag onto text. Off keeps the classic terminal text cursor everywhere. Affects the pointer shape only; what a drag selects is unchanged.",
                        control: .toggle(
                            get: { settingBool(.SelectionRestrictToText) },
                            set: { app?.settingsSetRestrictSelection(toText: $0) }
                        )
                    )
                ]
            ),
            SettingsCard(
                title: "Mouse Wheel",
                footer:
                    "Sets how far each notch of a mouse wheel scrolls the scrollback.",
                rows: [
                    SettingsRow(
                        id: "mouse.wheel_speed",
                        "Wheel Speed",
                        detail: "Multiplies the scroll distance of each wheel notch.",
                        control: slider(
                            bounds("mouse", "wheel_speed"),
                            get: { settingDouble(.MouseWheelSpeed) },
                            set: { app?.settingsSetWheelSpeed($0) }
                        )
                    ),
                    SettingsRow(
                        id: "mouse.wheel_lines",
                        "Lines per Notch",
                        detail: "Sets how many lines a wheel notch scrolls before the speed multiplier applies.",
                        control: stepper(
                            bounds("mouse", "wheel_lines"),
                            get: { settingDouble(.MouseWheelLines) },
                            set: { app?.settingsSetWheelLines(Int($0)) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Trackpad",
                footer:
                    "Sets the two-finger scrolling speed, independent of the mouse wheel. At 1.0, content "
                    + "moves one row for each row height your fingers travel; lower values are slower.",
                rows: [
                    SettingsRow(
                        id: "mouse.trackpad_speed",
                        "Trackpad Speed",
                        detail: "Multiplies trackpad and Magic Mouse scrolling only.",
                        control: slider(
                            bounds("mouse", "trackpad_speed"),
                            get: { settingDouble(.MouseTrackpadSpeed) },
                            set: { app?.settingsSetTrackpadSpeed($0) }
                        )
                    ),
                    SettingsRow(
                        id: "mouse.scroll_bounce",
                        "Scroll Bounce",
                        detail: "Bounce at the top and bottom of scrollback in the modern renderer.",
                        control: .toggle(
                            get: { settingBool(.MouseScrollBounce) },
                            set: {
                                setSetting(.MouseScrollBounce, bool: $0)
                            }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Links",
                rows: [
                    SettingsRow(
                        id: "underline.links",
                        "Underline Links",
                        detail: "Underline hyperlinks that programs mark with OSC 8.",
                        control: .toggle(
                            get: { settingBool(.UnderlineLinks) },
                            set: { app?.settingsSetUnderlineLinks($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.link_style",
                        "Link Underline",
                        detail: "Sets the style of the link underline.",
                        control: .segmented(
                            options: ["Solid", "Dotted"],
                            get: { settingInt(.UnderlineLinkStyle) },
                            set: { app?.settingsSetLinkUnderlineStyle($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.link_color_blue",
                        "Force Link Color",
                        detail: "Render links in system blue instead of their own text color.",
                        control: .toggle(
                            get: { settingBool(.UnderlineLinkColorBlue) },
                            set: { app?.settingsSetLinkColorSystemBlue($0) }
                        )
                    ),
                    SettingsRow(
                        id: "underline.link_style_per_kind",
                        "Distinct Link Kinds",
                        detail:
                            "Underline OSC 8 link kinds differently: file links dotted, email links dashed, and web links in your link style.",
                        control: .toggle(
                            get: { settingBool(.UnderlineLinkStylePerKind) },
                            set: { app?.settingsSetLinkStylePerKind($0) }
                        )
                    ),
                    SettingsRow(
                        id: "selection.osc8_click_opens",
                        "Open Links with a Click",
                        detail:
                            "Open a hyperlink with a single click, without holding Command, and underline it when the pointer is over it. This applies to links a program marks as clickable; plain URLs and file paths found in the text still open with Command-click, and so do ssh, sftp, ftp and ftps links, which connect to a host.",
                        control: .toggle(
                            get: { settingBool(.SelectionOSC8ClickOpens) },
                            set: { app?.settingsSetOSC8ClickOpens($0) }
                        )
                    ),
                    SettingsRow(
                        id: "selection.links_override_reporting",
                        "Links Clickable Under Mouse Reporting",
                        detail:
                            "Open links with a plain click even while an app is using the mouse. Turn this off to give every click to the app; then hold Command to open a link.",
                        control: .toggle(
                            get: { settingBool(.SelectionLinksOverrideReporting) },
                            set: { app?.settingsSetLinksOverrideReporting($0) }
                        )
                    ),
                ]
            ),
        ])
    }

    // Title surfaces share the same ten parts (nine toggles plus the static
    // base text). Each row's control is a table walk so the three cards cannot
    // drift: one TitlePart array, looped once per surface, produces the 30 rows
    // the hand-spelled version listed separately.
    private enum TitleSurface: String {
        case window, tab, pane

        /// The same surface as Core's composition table names it.
        var compositionSurface: Ubiquitty.Preferences.TitleComposition.Surface {
            switch self {
            case .window: return .Window
            case .tab: return .Tab
            case .pane: return .Pane
            }
        }

        var cardTitle: String {
            switch self {
            case .window: return "Window Title"
            case .tab: return "Tab Title"
            case .pane: return "Pane Title"
            }
        }

        var footer: String? {
            switch self {
            case .pane:
                return
                    "Pane title bars follow the tab title composition until you change a control here — each control decouples independently."
            default: return nil
            }
        }
    }

    private enum TitlePart: String, CaseIterable {
        case title, directory, directoryPath, appTitle, process, arguments, shellCommand, ttyName, profileName, dimensions,
            programStatus

        var title: String {
            switch self {
            case .title: return "Title"
            case .directory: return "Working Directory"
            case .directoryPath: return "Directory Format"
            case .appTitle: return "App-Set Title"
            case .process: return "Active Process"
            case .arguments: return "Arguments"
            case .shellCommand: return "Shell Command Name"
            case .ttyName: return "TTY Name"
            case .profileName: return "Profile Name"
            case .dimensions: return "Dimensions"
            case .programStatus: return "Program Status"
            }
        }

        func detail(for surface: TitleSurface) -> String {
            switch self {
            case .title:
                return "A fixed title shown first. Leave it empty for none."
            case .directory:
                return "The current folder."
            case .directoryPath:
                return
                    "Name shows just the folder (Projects, or your user name at home). Path shows the full path from your home folder (~/Projects, or ~ at home)."
            case .appTitle:
                return "The title the running program sets via an escape sequence (OSC 0/1/2)."
            case .process:
                // copy-ok: ssh names the program in the process chain, as it appears in a title
                return "The foreground process chain, such as vim or ssh host."
            case .arguments:
                return "Include the active process’s command-line arguments."
            case .shellCommand:
                return "The session’s login shell, such as zsh."
            case .ttyName:
                return "The session’s terminal device, such as ttys003."
            case .profileName:
                return "The profile this window or tab was opened with."
            case .dimensions:
                switch surface {
                case .window: return "The grid size in columns \u{00D7} rows."
                case .tab: return "The grid size in columns \u{00D7} rows (off by default for tabs)."
                case .pane: return "The grid size in columns \u{00D7} rows (off by default for panes)."
                }
            case .programStatus:
                switch surface {
                case .window: return "The state a program reports for itself, such as Waiting or Working."
                case .tab:
                    return
                        "The state a program reports for itself, such as Waiting or Working (off by default for tabs: it changes as the program works)."
                case .pane: return "The state a program reports for itself, such as Waiting or Working."
                }
            }
        }

        /// The part as Core's composition table names it; nil for the base text,
        /// which is a string rather than a switch.
        var compositionPart: Ubiquitty.Preferences.TitleComposition.Part? {
            switch self {
            case .title: return nil
            case .directory: return .Directory
            case .directoryPath: return .DirectoryPath
            case .appTitle: return .AppTitle
            case .process: return .Process
            case .arguments: return .ProcessArguments
            case .shellCommand: return .ShellCommand
            case .ttyName: return .TTYName
            case .profileName: return .ProfileName
            case .dimensions: return .Dimensions
            case .programStatus: return .ProgramStatus
            }
        }

        /// The control for this part on a surface.
        ///
        /// Every switch reads and writes through Core's composition table, so
        /// the value a control shows is the one the weave reads, a pane that
        /// inherits the tab reads as inheriting, and the rows cannot be wired
        /// to a neighbouring key the way thirty hand-written accessors could.
        /// Each write re-weaves the open windows, whose title memos do not see
        /// a composition change on their own.
        func control(for surface: TitleSurface) -> SettingsRow.Control {
            guard let part = compositionPart else {
                return baseTextControl(for: surface)
            }
            let tableSurface = surface.compositionSurface
            let isShown: @MainActor () -> Bool = {
                Ubiquitty.Preferences.TitleComposition.effectiveBool(
                    Ubiquitty.Preferences.values().pointee,
                    tableSurface,
                    part
                )
            }
            let setShown: @MainActor (Bool) -> Void = { shown in
                guard let row = Ubiquitty.Preferences.TitleComposition.descriptorForPart(tableSurface, part) else { return }
                setSetting(row.pointee.key, bool: shown)
            }
            if self == .directoryPath {
                return .segmented(
                    options: ["Name", "Path"],
                    get: { isShown() ? 1 : 0 },
                    set: { setShown($0 == 1) }
                )
            }
            return .toggle(get: isShown, set: setShown)
        }

        /// The static text that leads a surface's title.
        ///
        /// Configured through the application's text setter; every window
        /// re-weaves its title from the configuration it then hears.
        private func baseTextControl(for surface: TitleSurface) -> SettingsRow.Control {
            switch surface {
            case .window:
                return .textField(
                    placeholder: "None",
                    get: { app?.settingsTitleWindowText() ?? "" },
                    set: { app?.settingsSetTitleWindowText($0) }
                )
            case .tab:
                return .textField(
                    placeholder: "None",
                    get: { app?.settingsTitleTabText() ?? "" },
                    set: { app?.settingsSetTitleTabText($0) }
                )
            case .pane:
                return .textField(
                    placeholder: "None",
                    get: { app?.settingsTitlePaneText() ?? "" },
                    set: { app?.settingsSetTitlePaneText($0) }
                )
            }
        }
    }

    private static func titleRows(for surface: TitleSurface) -> [SettingsRow] {
        TitlePart.allCases.map { part in
            SettingsRow(
                id: "title.\(surface.rawValue).\(part.rawValue)",
                part.title,
                detail: part.detail(for: surface),
                control: part.control(for: surface)
            )
        }
    }

    private static func tabsPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Window",
                rows: [
                    SettingsRow(
                        id: "appearance.hide_title_bar",
                        "Hide Title Bar",
                        detail:
                            "Hide the title bar and traffic-light buttons for a chromeless window (rounded corners stay). To move the window, hold Command and drag the terminal.",
                        control: .toggle(
                            get: { settingBool(.AppearanceHideTitleBar) },
                            set: { app?.settingsSetHideTitleBar($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.titlebar_style",
                        "Title Bar",
                        detail: "Themed matches the terminal background; Native shows the standard macOS vibrant title bar.",
                        control: .segmented(
                            options: options("appearance", "titlebar_style"),
                            get: { settingTermIndex(.AppearanceTitlebarStyle) },
                            set: { app?.settingsSetTitlebarStyle($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.square_bottom_corners",
                        "Square Bottom Corners",
                        detail: "Square off the window’s bottom corners. The top corners stay rounded.",
                        control: .toggle(
                            get: { settingBool(.AppearanceSquareBottomCorners) },
                            set: { app?.settingsSetSquareBottomCorners($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.pane_title_bars",
                        "Pane Title Bars",
                        detail: "Show a title bar on each split pane.",
                        control: .toggle(
                            get: { settingBool(.AppearancePaneTitleBars) },
                            set: { app?.settingsSetPaneTitleBars($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.snap_window_resize",
                        "Snap Resize to Cells",
                        detail: "Resize the window in whole-cell steps, except when it sits flush against a screen edge or the Dock.",
                        control: .toggle(
                            get: { settingBool(.AppearanceSnapWindowResize) },
                            set: { app?.settingsSetSnapWindowResize($0) }
                        )
                    ),
                    SettingsRow(
                        id: "terminal.column_mode_resizes_window",
                        "Resize on 80/132 Column Switch",
                        detail:
                            "When an app switches column mode (DECCOLM), resize the window to fit. Off keeps the window and marks the live viewport edge with a thin rule. Fullscreen always keeps the window.",
                        control: .toggle(
                            get: { settingBool(.TerminalColumnModeResizesWindow) },
                            set: { app?.settingsSetColumnModeResizesWindow($0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Content Insets",
                rows: [
                    SettingsRow(
                        id: "appearance.padding_top",
                        "Top Padding",
                        detail: "The space between the text grid and the window’s top edge.",
                        control: stepper(
                            bounds("appearance", "padding_top"),
                            get: { settingDouble(.AppearancePaddingTop) },
                            set: { app?.settingsSetWindowPaddingTop($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.padding_bottom",
                        "Bottom Padding",
                        detail: "The space between the text grid and the window’s bottom edge.",
                        control: stepper(
                            bounds("appearance", "padding_bottom"),
                            get: { settingDouble(.AppearancePaddingBottom) },
                            set: { app?.settingsSetWindowPaddingBottom($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.titleless_padding_top",
                        "Titleless Top Padding",
                        detail:
                            "The top space used only when the title bar is hidden, where the content reaches the very top edge. It defaults to the bottom padding.",
                        control: stepper(
                            bounds("appearance", "titleless_padding_top"),
                            get: { settingDouble(.AppearanceTitlelessPaddingTop) },
                            set: { app?.settingsSetTitlelessPaddingTop($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.padding_left",
                        "Left Padding",
                        detail: "The space between the text grid and the window’s left edge.",
                        control: stepper(
                            bounds("appearance", "padding_left"),
                            get: { settingDouble(.AppearancePaddingLeft) },
                            set: { app?.settingsSetWindowPaddingLeft($0) }
                        )
                    ),
                    SettingsRow(
                        id: "appearance.padding_right",
                        "Right Padding",
                        detail: "The space between the text grid and the window’s right edge.",
                        control: stepper(
                            bounds("appearance", "padding_right"),
                            get: { settingDouble(.AppearancePaddingRight) },
                            set: { app?.settingsSetWindowPaddingRight($0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Tabs",
                rows: [
                    SettingsRow(
                        id: "tabs.shortcut_hint_mode",
                        "Show Shortcut Hints",
                        detail: "Display the ⌘-number hint on each tab. On ⌘ reveals it only while Command is held.",
                        control: .segmented(
                            options: ["Off", "Always", "On ⌘"],
                            get: { settingTabShortcutHintMode() },
                            set: { app?.settingsSetTabShortcutHintMode($0) }
                        )
                    )
                ]
            ),
        ])
    }

    private static func windowTitlesPane() -> SettingsPane {
        let windowTitleRows: [SettingsRow] = {
            var rows: [SettingsRow] = [
                SettingsRow(
                    id: "appearance.folder_icon",
                    "Folder Icon",
                    detail:
                        "Show the current folder’s proxy icon in the title bar while the pointer rests on the title, or always.",
                    control: .segmented(
                        options: ["Off", "On Hover", "Always"],
                        get: {
                            guard settingBool(.AppearanceFolderIcon) else { return 0 }
                            return settingBool(.AppearanceFolderIconAlways) ? 2 : 1
                        },
                        set: {
                            app?.settingsSetFolderIcon($0 != 0)
                            app?.settingsSetFolderIconAlways($0 == 2)
                        }
                    )
                ),
                SettingsRow(
                    id: "title.directory_hidden_for",
                    "Hide Directory For",
                    detail:
                        "Leave the working directory out of window, tab, and pane titles while one of these programs runs: a multiplexer or a remote shell shows another place, or none.",
                    control: .textList(
                        get: { settingText(.TitleDirectoryHiddenFor) },
                        set: { value in
                            setSetting(.TitleDirectoryHiddenFor, text: value)
                        }
                    )
                ),
                SettingsRow(
                    id: "title.directory_hidden_in_full_screen",
                    "Hide Directory in Full-Screen Programs",
                    detail: "Leave the working directory out while a program fills the screen, as an editor or a pager does.",
                    control: .toggle(
                        get: { settingBool(.TitleDirectoryHiddenInFullScreen) },
                        set: { setSetting(.TitleDirectoryHiddenInFullScreen, bool: $0) }
                    )
                ),
                SettingsRow(
                    id: "appearance.process_icons",
                    "Process Icons",
                    detail: "Show a program’s icon before its name in window, tab, and pane titles.",
                    control: .toggle(
                        get: { settingBool(.AppearanceProcessIcons) },
                        set: { app?.settingsSetProcessIcons($0) }
                    )
                ),
            ]
            rows.append(contentsOf: titleRows(for: .window))
            return rows
        }()

        return SettingsPane(cards: [SettingsCard(title: nil, rows: windowTitleRows)])
    }

    private static func tabTitlesPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(title: nil, rows: titleRows(for: .tab))
        ])
    }

    private static func paneTitlesPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(title: nil, footer: TitleSurface.pane.footer, rows: titleRows(for: .pane))
        ])
    }

    private static func notificationsPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Notifications",
                footer:
                    "Programs post notifications with the OSC 9, 99, and 777 escape sequences, and a bell in a window that isn’t active posts one too.",
                rows: [
                    SettingsRow(
                        id: "notifications.enabled",
                        "Enable Notifications",
                        detail: "Post macOS notifications for terminal events.",
                        control: .toggle(
                            get: { settingBool(.NotificationsEnabled) },
                            set: { app?.settingsSetNotificationsEnabled($0) }
                        )
                    ),
                    SettingsRow(
                        id: "notifications.sound",
                        "Notification Sound",
                        detail: "Play the default banner sound with each notification.",
                        control: .toggle(
                            get: { settingBool(.NotificationsSound) },
                            set: { app?.settingsSetNotificationSound($0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Bell",
                rows: [
                    SettingsRow(
                        id: "bell.audible",
                        "Audible Bell",
                        detail: "Play a sound when the terminal rings the bell.",
                        control: .toggle(
                            get: { settingBool(.BellAudible) },
                            set: { app?.settingsSetBellAudible($0) }
                        )
                    ),
                    SettingsRow(
                        id: "bell.visual",
                        "Visual Bell",
                        detail: "Flash the screen instead of (or alongside) a sound.",
                        control: .toggle(
                            get: { settingBool(.BellVisual) },
                            set: { app?.settingsSetBellVisual($0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Dock",
                rows: [
                    SettingsRow(
                        id: "bell.dock_bounce",
                        "Bounce Dock Icon",
                        detail: "Bounce the Dock icon to get your attention while Ubiquitty is in the background.",
                        control: .toggle(
                            get: { settingBool(.DockBounce) },
                            set: { app?.settingsSetDockBounce($0) }
                        )
                    ),
                    SettingsRow(
                        id: "bell.dock_badge",
                        "Dock Badge",
                        detail: "Show a count badge on the Dock icon.",
                        control: .toggle(
                            get: { settingBool(.DockBadge) },
                            set: { app?.settingsSetDockBadge($0) }
                        )
                    ),
                ]
            ),
        ])
    }

    private static func terminalPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Closing",
                footer:
                    "Closing a single-pane, ungrouped local window without confirmation keeps its process for 30 seconds. Choose File ▸ Reopen Closed Window to recover it. Up to eight windows are retained. Confirmed termination ends the process immediately.",
                rows: [
                    SettingsRow(
                        id: "terminal.close_confirmation",
                        "Ask Before Closing",
                        control: .menu(
                            options: options("terminal", "close_confirmation"),
                            get: { settingTermIndex(.TerminalCloseConfirmation, fallback: 2) },
                            set: {
                                setSetting(.TerminalCloseConfirmation, termIndex: $0)
                            }
                        )
                    ),
                    SettingsRow(
                        id: "terminal.close_ignored_processes",
                        "Ignored Processes",
                        detail: "Skip confirmation for these processes when using Only for Running Processes.",
                        control: .textList(
                            get: { settingText(.TerminalCloseIgnoredProcesses) },
                            set: { value in
                                setSetting(.TerminalCloseIgnoredProcesses, text: value)
                            }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Scrollback",
                footer:
                    "How many lines of history each session keeps. Applies to new sessions.",
                rows: [
                    SettingsRow(
                        id: "terminal.scrollback_lines",
                        "History Lines",
                        detail: "The number of lines kept after they scroll off the screen.",
                        control: stepper(
                            bounds("terminal", "scrollback_lines"),
                            get: { settingDouble(.TerminalScrollbackLines) },
                            set: { app?.settingsSetScrollbackLines(Int($0)) }
                        )
                    )
                ]
            ),
            SettingsCard(
                title: "Character Encoding",
                footer:
                    "How Ubiquitty reads incoming bytes as text. UTF-8 suits almost everything; "
                    + "the older character sets are for output from older systems or locale-bound tools. "
                    + "Changes apply to open sessions right away.",
                rows: [
                    SettingsRow(
                        id: "terminal.encoding",
                        "Input Encoding",
                        detail: "The character set the terminal reads output in. UTF-8 is the default.",
                        control: encodingControl()
                    )
                ]
            ),
            SettingsCard(
                title: "Terminal Identity",
                footer:
                    "Programs read these from the TERM_PROGRAM and TERM_PROGRAM_VERSION environment variables. New tabs pick up changes.",
                rows: [
                    SettingsRow(
                        id: "terminal.term_program",
                        "Program",
                        control: .textField(
                            placeholder: "Ubiquitty",
                            get: { app?.settingsTermProgram() ?? "" },
                            set: { app?.settingsSetTermProgram($0) }
                        )
                    ),
                    SettingsRow(
                        id: "terminal.term_program_version",
                        "Version",
                        control: .textField(
                            placeholder: appVersionPlaceholder,
                            get: { app?.settingsTermProgramVersion() ?? "" },
                            set: { app?.settingsSetTermProgramVersion($0) }
                        )
                    ),
                ]
            ),
        ])
    }

    private static func securityPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Security",
                rows: [
                    SettingsRow(
                        id: "security.secure_keyboard_entry",
                        "Secure Keyboard Entry",
                        detail: "Prevent other apps from reading your keystrokes while Ubiquitty is active.",
                        control: .toggle(
                            get: { settingBool(.SecuritySecureKeyboardEntry) },
                            set: { app?.settingsSetSecureKeyboardEntry($0) }
                        )
                    ),
                    SettingsRow(
                        id: "security.password_detect",
                        "Detect Password Prompts",
                        detail: "Show a lock and hide local echo when a line ends in a password prompt.",
                        control: .toggle(
                            get: { settingBool(.SecurityPasswordDetect) },
                            set: { app?.settingsSetPasswordDetect($0) }
                        )
                    ),
                    SettingsRow(
                        id: "security.secure_keyboard_entry_at_password_prompts",
                        "Secure Keyboard Entry at Password Prompts",
                        detail: "Hold Secure Keyboard Entry while a pane is at a password prompt.",
                        control: .toggle(
                            get: { settingBool(.SecuritySecureKeyboardEntryAtPasswordPrompts) },
                            set: { app?.settingsSetSecureKeyboardEntry(atPasswordPrompts: $0) }
                        )
                    ),
                ]
            ),
            SettingsCard(
                title: "Remote Clipboard",
                footer:
                    "What a program on a remote machine finds when it reads “the clipboard.”"
                    + " A remote machine has none of its own — a headless host runs no display"
                    + " server — so a program that shells out for one finds nothing unless this"
                    + " is on.",
                rows: [
                    SettingsRow(
                        id: "clipboard.serving",
                        "Serve This Mac’s Clipboard",
                        detail:
                            "Put stand-ins for xclip, wl-paste, and pbpaste on a remote session’s PATH"
                            + " and answer them from this Mac. Every process on that machine can then"
                            + " read what you copied, for as long as the session is open — so this is"
                            + " off unless you turn it on, and a session already open keeps whatever it"
                            + " agreed to when it connected.",
                        control: .toggle(
                            // The Bool belongs to the toggle; the domain speaks
                            // Serving, so the conversion sits at the widget.
                            get: { settingBool(.ClipboardRemoteTools) },
                            set: { setSetting(.ClipboardRemoteTools, bool: $0) }
                        )
                    )
                ]
            ),
        ])
    }

    private static func sessionsPane() -> SettingsPane {
        SettingsPane(cards: [
            SettingsCard(
                title: "Remote Sessions",
                footer:
                    "When you connect to a host that doesn’t have ubiquitty-host, Ubiquitty copies the bundled "
                    + "binary for its platform over SSH. If there’s no bundled binary, or this is off, "
                    + "Ubiquitty shows manual install instructions instead.",
                rows: [
                    SettingsRow(
                        id: "session.auto_install_host",
                        "Auto-Install Host on Connect",
                        detail: "Install ubiquitty-host on a new remote machine automatically.",
                        control: .toggle(
                            get: { settingBool(.RemoteAutoInstallHost) },
                            set: { app?.settingsSetAutoInstallHost($0) }
                        )
                    )
                ]
            ),
            SettingsCard(
                title: "Session Persistence",
                footer:
                    "Experimental. Sessions keep running in the background after you quit; "
                    + "your windows, tabs, and panes return on the next launch.",
                rows: [
                    SettingsRow(
                        id: "session.persistence",
                        "Restore Last Session on Launch",
                        detail: "Keep every window and restore it when Ubiquitty opens again.",
                        control: .toggle(
                            get: { settingBool(.ExperimentalSessionPersistence) },
                            set: { app?.settingsSetSessionPersistence($0) }
                        )
                    )
                ]
            ),
        ])
    }

    private static func cursorPane() -> SettingsPane {
        let shape = SettingsRow(
            id: "cursor.shape",
            "Shape",
            control: .segmented(
                options: options("cursor", "shape"),
                get: { settingTermIndex(.CursorShape) },
                set: { app?.settingsSetCursorShape($0) }
            )
        )
        let opacity = SettingsRow(
            id: "cursor.alpha",
            "Opacity",
            detail: "Lower values let the cell show through the cursor.",
            // The schema stores alpha in 0...255 (the byte the setter
            // clamps); the slider works in the normalized 0...1 the get/
            // set divide + scale by 255, so the bounds are the schema
            // range over 255 — still one source, just rescaled here.
            control: {
                let alpha = bounds("cursor", "alpha")
                return .slider(
                    min: alpha.minimum / 255.0,
                    max: alpha.maximum / 255.0,
                    get: { settingDouble(.CursorAlpha) / 255.0 },
                    set: { app?.settingsSetCursorAlpha(Int(($0 * 255).rounded())) }
                )
            }()
        )
        let invertText = SettingsRow(
            id: "cursor.invert_text",
            "Invert Text Under Cursor",
            detail: "A block cursor inverts the character beneath it in grayscale.",
            control: .toggle(
                get: { settingBool(.CursorInvertText) },
                set: { app?.settingsSetCursorInvertText($0) }
            )
        )
        let blink = SettingsRow(
            id: "cursor.blink",
            "Blink",
            control: .toggle(
                get: { settingBool(.CursorBlink) },
                set: { app?.settingsSetCursorBlink($0) }
            )
        )
        let blinkRate = SettingsRow(
            id: "cursor.blink_rate",
            "Blink Rate",
            detail: "The length of one blink in milliseconds. Lower values blink faster.",
            control: stepper(
                bounds("cursor", "blink_rate"),
                get: { settingDouble(.CursorBlinkRate) },
                set: { app?.settingsSetCursorBlinkRate(Int($0)) }
            )
        )
        let linger = SettingsRow(
            id: "cursor.linger",
            "Linger",
            detail: "How many frames the cursor stays solid after a keystroke before it blinks.",
            control: stepper(
                bounds("cursor", "linger"),
                get: { settingDouble(.CursorLinger) },
                set: { app?.settingsSetCursorLinger(Int($0)) }
            )
        )
        let blinkAnimation = SettingsRow(
            id: "appearance.blink_animation",
            "Blink Animation",
            detail: "Fade the cursor and blinking text smoothly. Off gives a hard on/off blink.",
            control: .toggle(
                get: { settingBool(.AppearanceBlinkAnimation) },
                set: { app?.settingsSetBlinkAnimation($0) }
            )
        )
        let motion = SettingsRow(
            id: "cursor.motion",
            "Cursor Motion",
            detail:
                "Animate the caret toward its new cell — Short on small moves, Long on jumps so you can follow it, Always on both.",
            control: .segmented(
                options: options("cursor", "motion"),
                get: { settingTermIndex(.CursorMotion) },
                set: { app?.settingsSetCursorMotion($0) }
            )
        )
        return SettingsPane(cards: [
            SettingsCard(title: "Shape & Visibility", rows: [shape, opacity, invertText]),
            SettingsCard(title: "Blinking", rows: [blink, blinkRate, linger, blinkAnimation]),
            SettingsCard(title: "Movement", rows: [motion]),
        ])
    }
}
