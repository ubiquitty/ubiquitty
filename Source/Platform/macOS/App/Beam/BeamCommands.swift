// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// BeamCommands.swift — Beam's command model + the built-in providers:
// the menu walk, the settings catalog, the usage store, and the registry
// that dedups them through Core. Views → Model → Commands; nothing here
// imports SwiftUI.
//

import AppKit
import UbiquittyCore
import UbiquittyKit

// MARK: - Commands

// Selecting a command either RUNS an effect (a menu command wraps
// NSApp.sendAction; a toggle flips a Settings value) or DRILLS into a second-level
// editor that stays inside Beam — a value list, or a numeric / free-text entry.
enum BeamAction {
    case run(() -> Void)
    case drill(BeamDrill)
}

// A drill payload, built by a provider from the live Settings getter/setter so the
// editor seeds from the current value and applies through the same write-through
// the Settings UI uses.
enum BeamDrill {
    // A value list: `current` is the live selection (marked); each option applies
    // its value inline. Used for both segmented and pull-down (menu) settings.
    case options(current: Int, options: [BeamOption])
    // A numeric editor seeded from the schema bounds (a percentage slider is
    // pre-scaled to 0…100 with unit "%", so the editor reads in whole percents).
    case number(
        current: Double,
        min: Double,
        max: Double,
        step: Double,
        unit: String,
        apply: (Double) -> Void
    )
    // A free-text editor.
    case text(current: String, placeholder: String, apply: (String) -> Void)
}

// One value in an `.options` drill.
struct BeamOption: Identifiable {
    let id = UUID()
    let label: String
    let apply: () -> Void
}

// One actionable command. `group` is the dim right-side label; `value` is the
// current setting value shown dim before the disclosure (drill commands only);
// `keywords` are extra fuzzy-match terms beyond the title; `identity` is the
// dedup key paired with the title (a selector name, or a stable settings path).
// `needsConfirm` gates a `.run` command behind a verb-titled confirmation
// alert (see commitWithConfirm) before its effect fires — Beam reaches a
// command in a few fuzzy keystrokes and one Enter, where the menu bar costs
// several aimed clicks, so a command that writes/shares/attaches/kicks a
// live connection sets this even when its menu equivalent has no prompt of its
// own (parity with the menu's OWN gating is separate: this wraps the same
// handler either way, never a new one). matchedIndices is computed per query
// on BeamResult, never stored here.
struct BeamCommand: Identifiable {
    let id = UUID()
    let title: String
    let group: String // e.g. "View ▸ Theme" or "Settings ▸ Cursor"
    let shortcut: String // glyph form of the ⌘-equivalent, or empty
    let value: String // live value preview for a drill command, or empty
    let keywords: [String] // fuzzy-match terms beyond the title (not displayed)
    let identity: String // dedup partner of the title across providers
    let needsConfirm: Bool // .run only — see field doc above
    let isDeferred: Bool // a font picker whose choices are built on demand
    let action: BeamAction
    // Raycast-style secondary actions for this row, opened with → or ⌘⏎. Empty
    // for most commands; blocks/find/settings rows carry copy / reveal actions.
    // Each reuses the options-drill machinery — an actions list is an options
    // drill whose applies do the work.
    let secondaryActions: [BeamOption]

    var isDrill: Bool {
        if case .drill = action { return true }
        return false
    }

    init(
        title: String,
        group: String,
        shortcut: String = "",
        value: String = "",
        keywords: [String] = [],
        identity: String,
        needsConfirm: Bool = false,
        isDeferred: Bool = false,
        secondaryActions: [BeamOption] = [],
        run: @escaping () -> Void
    ) {
        self.init(
            title: title,
            group: group,
            shortcut: shortcut,
            value: value,
            keywords: keywords,
            identity: identity,
            needsConfirm: needsConfirm,
            isDeferred: isDeferred,
            secondaryActions: secondaryActions,
            action: .run(run)
        )
    }

    init(
        title: String,
        group: String,
        shortcut: String = "",
        value: String = "",
        keywords: [String] = [],
        identity: String,
        isDeferred: Bool = false,
        secondaryActions: [BeamOption] = [],
        drill: BeamDrill
    ) {
        self.init(
            title: title,
            group: group,
            shortcut: shortcut,
            value: value,
            keywords: keywords,
            identity: identity,
            needsConfirm: false,
            isDeferred: isDeferred,
            secondaryActions: secondaryActions,
            action: .drill(drill)
        )
    }

    private init(
        title: String,
        group: String,
        shortcut: String,
        value: String,
        keywords: [String],
        identity: String,
        needsConfirm: Bool,
        isDeferred: Bool,
        secondaryActions: [BeamOption],
        action: BeamAction
    ) {
        self.title = title
        self.group = group
        self.shortcut = shortcut
        self.value = value
        self.keywords = keywords
        self.identity = identity
        self.needsConfirm = needsConfirm
        self.isDeferred = isDeferred
        self.secondaryActions = secondaryActions
        self.action = action
    }
}

// The engine ranks portable PaletteCommand descriptors keyed by a stable id; the
// closure-bearing effect stays here and is dispatched by that same id.
extension BeamCommand {
    // The stable dedup + dispatch key — the (title, identity) pair the registry
    // dedups on, packed into one string the Core engine round-trips.
    var paletteID: String { title + "\u{1}" + identity }

    // The Core CommandKind this maps to — the palette bridge reads it when
    // building the C++ descriptor (see PaletteBridge.coreCommand).
    var paletteKind: Ubiquitty.CommandPalette.CommandKind {
        switch action {
        case .run: return .Action
        case .drill(let drill):
            switch drill {
            case .options: return .DrillOptions
            case .number: return .DrillNumber
            case .text: return .DrillText
            }
        }
    }
}

// The seam every subsystem uses to contribute commands. A command with any
// reach is still a small local provider, not an edit to Beam — registering one is a
// single line in the registry array (see BeamController.present).
@MainActor
protocol BeamCommandProvider {
    func commands() -> [BeamCommand]
}

// A provider over an already-built array — for a command set another scope
// also consumes, so its (catalog-walk + Settings-read) build runs once.
struct PrebuiltCommandProvider: BeamCommandProvider {
    let prebuilt: [BeamCommand]
    func commands() -> [BeamCommand] { prebuilt }
}

// The [keys] catalog actions that have no menu item — keyboard-only today
// (scrolling), so the menu walk can't surface them and Beam couldn't reach them
// at all. Menu-covered actions (copy, tabs, fonts, the clears, ...) stay out:
// they'd duplicate the walked menu commands under a second identity.
// Labels come from the one Core catalog; only membership is curated here.
struct KeysActionCommandProvider: BeamCommandProvider {
    weak var windowController: NSWindowController?

    private static let keyboardOnlyTokens: Set<String> = [
        "scroll_line_up", "scroll_line_down",
        "scroll_page_up", "scroll_page_down",
        "scroll_to_top", "scroll_to_bottom",
    ]

    func commands() -> [BeamCommand] {
        guard let windowController else { return [] }
        return KeysCatalog.actionVocabulary()
            .compactMap { entry in
                let (token, label) = entry
                guard Self.keyboardOnlyTokens.contains(token) else { return nil }
                return BeamCommand(
                    title: label,
                    group: "Terminal",
                    keywords: ["scroll", "keys"],
                    identity: "keys.\(token)",
                    run: { [weak windowController] in
                        (windowController as? any BeamTerminalHost)?.performBeamKeyAction(named: token)
                    }
                )
            }
    }
}

// MARK: - Usage store (frecency)

// Per-command use timestamps, persisted so recently/frequently used commands
// float (Core owns the decay math + retention policy — UBPaletteFrecency).
// Keyed by paletteID; a run and a drill-in both count as a use.
enum BeamUsageStore {
    private static let defaultsKey = "UBBeamUsage"

    static func record(_ paletteID: String) {
        var all =
            UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: [Double]] ?? [:]
        var stamps = all[paletteID] ?? []
        stamps.append(Date().timeIntervalSince1970)
        let cap = PaletteFrecency.maxStampsPerCommand
        if stamps.count > cap { stamps.removeFirst(stamps.count - cap) }
        all[paletteID] = stamps
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    // Every stored command's decayed score, computed once per summon.
    static func scores() -> [String: Double] {
        let all =
            UserDefaults.standard.dictionary(forKey: defaultsKey)
            as? [String: [Double]] ?? [:]
        let now = Int64(Date().timeIntervalSince1970)
        var out: [String: Double] = [:]
        out.reserveCapacity(all.count)
        for (id, stamps) in all {
            out[id] = PaletteFrecency.score(timestamps: stamps.map { Int64($0) }, now: now)
        }
        return out
    }
}

// Aggregates providers into one deduped command list. Dedup + ordering have
// one owner — Core's PaletteRegistry (earlier provider wins a collision, so
// the menu's own command shadows any duplicate); only the merged identifier
// order comes back. The local map is a lookup, not policy: its first-wins
// insert mirrors Core's rule so a kept id resolves to the same provider's
// closure that Core kept.
@MainActor
struct BeamCommandRegistry {
    private let providers: [BeamCommandProvider]

    init(_ providers: [BeamCommandProvider]) {
        self.providers = providers
    }

    func commands() -> [BeamCommand] {
        var byID: [String: BeamCommand] = [:]
        var providerCommands: [[BeamCommand]] = []
        for provider in providers {
            let commands = provider.commands()
            providerCommands.append(commands)
            for command in commands where byID[command.paletteID] == nil {
                byID[command.paletteID] = command
            }
        }
        return PaletteRegistry.mergedIdentifiers(providerCommands).compactMap { byID[$0] }
    }
}

// MARK: - Menu provider

// Submenu titles whose CONTENTS are parameter
// VALUES or debug-only entries rather than commands. The walk does not descend
// into these, so the palette keeps commands and qualitative quick switches,
// without numeric sizes, opacity values, copy styles, or the debug HUD. Font
// families enter the command list when a query needs them. Matched by the
// submenu's parent title.
private let beamSkippedSubmenuTitles: Set<String> = [
    "Style for Copy", // duplicates every theme name as a copy style
    "Font Size", // numeric sizes; Bigger/Smaller/Actual Size stay in View
    "Background Opacity", // numeric percentages
    "Metal HUD", // debug-only (CAMetalLayer list / Generate Performance Report)
]

// Walks NSApp.mainMenu recursively, collecting every item that carries an action
// + a title, skipping separators / hidden items and the value-picker / debug
// submenus above. The path of submenu titles becomes the command's group label.
// Each command's run wraps NSApp.sendAction with the REAL NSMenuItem as sender,
// so actions that dispatch on sender.tag / sender.state still work.
struct MenuCommandProvider: BeamCommandProvider {
    var includeFontMenu = false

    func commands() -> [BeamCommand] {
        guard let menu = NSApp.mainMenu else { return [] }
        var out: [BeamCommand] = []
        var seen = Set<String>()
        collect(menu, path: [], into: &out, seen: &seen)
        return out
    }

    private func collect(
        _ menu: NSMenu,
        path: [String],
        into out: inout [BeamCommand],
        seen: inout Set<String>
    ) {
        // Lazy submenus may be EMPTY until populated — run the delegate's
        // population pass directly instead of update(): update() also
        // validates every item (an app-wide validateMenuItem: cascade per
        // summon), and Beam ignores isEnabled below, so the validation half is
        // pure cost.
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden { continue }
            if let submenu = item.submenu {
                // The application menu sits under the app name; label its
                // children "Ubiquitty" rather than the (empty) bar title.
                let segment = item.title.isEmpty ? submenu.title : item.title
                // Value-picker and debug groups contain no palette commands.
                if beamSkippedSubmenuTitles.contains(segment) { continue }
                if !includeFontMenu && path == ["View"] && segment == "Font" { continue }
                collect(submenu, path: path + [segment], into: &out, seen: &seen)
                continue
            }
            // Do not gate on item.isEnabled: at Beam-summon time validateMenuItem:
            // runs in a transitional responder context, so most real commands
            // validate as disabled and would be dropped, leaving only the
            // unconditionally-enabled radio items (opacity %, font sizes). A
            // palette lists every command; applicability is resolved on invoke.
            guard let action = item.action, !item.title.isEmpty else { continue }
            // AppKit's window entries front a window; go-to owns window/tab switching.
            if menu === NSApp.windowsMenu && item.target is NSWindow { continue }
            let key = item.title + "\u{1}" + NSStringFromSelector(action)
            if !seen.insert(key).inserted { continue }
            let target = item.target
            let menuItem = item
            out.append(
                BeamCommand(
                    title: item.title,
                    group: path.joined(separator: " ▸ "),
                    shortcut: Self.shortcut(for: item),
                    identity: NSStringFromSelector(action),
                    run: { NSApp.sendAction(action, to: target, from: menuItem) }
                )
            )
        }
    }

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

// MARK: - Settings provider

// Walks the data-driven SettingsCatalog so every setting is findable and
// adjustable from Beam — the biggest gap, since no settings live in the menu bar.
// One command per setting: a toggle flips inline; an enum (segmented or menu)
// drills into a value list; a numeric (stepper/slider) drills into a number
// editor seeded from the schema bounds; a text field drills into a text editor —
// all without leaving the palette. Custom panes (Themes, Keyboard, …) open to
// their category. The group is "Settings ▸ <card>"; the category + card names
// ride as keywords so "appearance" or "layout" surfaces every row under them.
struct SettingsCommandProvider: BeamCommandProvider {
    var resolveDeferred = false

    func commands() -> [BeamCommand] {
        var out: [BeamCommand] = []
        for category in SettingsCatalog.categories() {
            switch category.content {
            case .pane(let pane):
                for card in pane.cards {
                    for row in card.rows {
                        out.append(commands(for: row, category: category, card: card))
                    }
                }
            case .custom:
                // No introspectable rows; offer one open-to-category command.
                out.append(
                    BeamCommand(
                        title: "\(category.title)…",
                        group: "Settings",
                        identity: "settings.cat.\(category.id)",
                        run: Self.navigate(category.id)
                    )
                )
            }
        }
        return out
    }

    private static func revealAction(categoryID: String, rowID: String) -> BeamOption {
        BeamOption(
            label: "Reveal in Settings",
            apply: {
                (NSApp.delegate as? UBAppDelegate)?
                    .revealSettingsRow(rowID, inCategory: categoryID)
            }
        )
    }

    private func commands(
        for row: SettingsRow,
        category: SettingsCategory,
        card: SettingsCard
    ) -> BeamCommand {
        let group = "Settings ▸ \(card.title ?? category.title)"
        let keywords = [category.title, card.title].compactMap { $0 } + row.keywords
        let base = "settings.\(row.id)"
        let reveal = [Self.revealAction(categoryID: category.id, rowID: row.id)]

        let control = resolveDeferred ? row.control.resolved() : row.control
        switch control {
        case .deferred:
            // Keep the row searchable. Beam replaces it with the real picker
            // before displaying its results or drilling into it.
            return BeamCommand(
                title: row.label,
                group: group,
                keywords: keywords,
                identity: "\(base).enum",
                isDeferred: true,
                secondaryActions: reveal,
                drill: .options(current: 0, options: [])
            )
        case .toggle(let get, let set):
            // Live state in the title; selecting it flips the value inline.
            return BeamCommand(
                title: "\(row.label): \(get() ? "On" : "Off")",
                group: group,
                keywords: keywords,
                identity: "\(base).toggle",
                secondaryActions: reveal,
                run: { set(!get()) }
            )

        case .segmented(let options, _, let get, let set):
            return enumCommand(
                label: row.label,
                group: group,
                keywords: keywords,
                identity: "\(base).enum",
                options: options,
                get: get,
                set: set,
                secondaryActions: reveal
            )

        case .menu(let options, _, let get, let set):
            return enumCommand(
                label: row.label,
                group: group,
                keywords: keywords,
                identity: "\(base).enum",
                options: options,
                get: get,
                set: set,
                secondaryActions: reveal
            )

        case .stepper(let min, let max, let step, let unit, let get, let set):
            return numberCommand(
                label: row.label,
                group: group,
                keywords: keywords,
                identity: "\(base).num",
                current: get(),
                min: min,
                max: max,
                step: step,
                unit: unit,
                apply: set,
                secondaryActions: reveal
            )

        case .slider(let min, let max, let unit, let get, let set):
            if let unit {
                return numberCommand(
                    label: row.label,
                    group: group,
                    keywords: keywords,
                    identity: "\(base).num",
                    current: get(),
                    min: min,
                    max: max,
                    step: PaletteSettings.sliderStep(from: min, to: max),
                    unit: unit,
                    apply: set,
                    secondaryActions: reveal
                )
            }
            // A unitless 0…1 slider reads as a percentage; edit in whole percents
            // and scale back on apply, matching the Settings slider's "%" readout.
            return numberCommand(
                label: row.label,
                group: group,
                keywords: keywords,
                identity: "\(base).num",
                current: get() * 100,
                min: min * 100,
                max: max * 100,
                step: 5,
                unit: "%",
                apply: { set($0 / 100) },
                secondaryActions: reveal
            )

        case .textList(let get, let set):
            return BeamCommand(
                title: row.label,
                group: group,
                value: get(),
                keywords: keywords,
                identity: "\(base).text",
                secondaryActions: reveal,
                drill: .text(current: get(), placeholder: "Process names, separated by commas", apply: set)
            )

        case .textField(let placeholder, let get, let set):
            let current = get()
            return BeamCommand(
                title: row.label,
                group: group,
                value: current,
                keywords: keywords,
                identity: "\(base).text",
                secondaryActions: reveal,
                drill: .text(current: current, placeholder: placeholder, apply: set)
            )

        case .backgroundImage(let get, let set):
            // Choosing a file is a panel, not a typed path: the palette opens
            // the same chooser the Settings button does.
            let current = get()
            return BeamCommand(
                title: "Choose \(row.label)…",
                group: group,
                value: current.isEmpty ? "None" : (current as NSString).lastPathComponent,
                keywords: keywords,
                identity: "\(base).choose",
                secondaryActions: reveal,
                run: { BackgroundImageChooser.present(currentPath: get(), choose: set) }
            )
        }
    }

    // A value-list drill, with the live selection marked + previewed.
    private func enumCommand(
        label: String,
        group: String,
        keywords: [String],
        identity: String,
        options: [String],
        get: () -> Int,
        set: @escaping (Int) -> Void,
        secondaryActions: [BeamOption] = []
    ) -> BeamCommand {
        let current = get()
        let beamOptions = options.indices.map { index in
            BeamOption(label: options[index], apply: { set(index) })
        }
        return BeamCommand(
            title: label,
            group: group,
            value: options.indices.contains(current) ? options[current] : "",
            keywords: keywords,
            identity: identity,
            secondaryActions: secondaryActions,
            drill: .options(current: current, options: beamOptions)
        )
    }

    // A numeric drill, previewing the current value with its unit.
    private func numberCommand(
        label: String,
        group: String,
        keywords: [String],
        identity: String,
        current: Double,
        min: Double,
        max: Double,
        step: Double,
        unit: String,
        apply: @escaping (Double) -> Void,
        secondaryActions: [BeamOption] = []
    ) -> BeamCommand {
        BeamCommand(
            title: label,
            group: group,
            value: PaletteSettings.valuePreview(current, step: step, unit: unit),
            keywords: keywords,
            identity: identity,
            secondaryActions: secondaryActions,
            drill: .number(
                current: current,
                min: min,
                max: max,
                step: step,
                unit: unit,
                apply: apply
            )
        )
    }

    // Open (or front) the Settings window and select a custom pane's category
    // (bespoke views can't drill). Keyed by stable category id.
    private static func navigate(_ categoryID: String) -> () -> Void {
        { (NSApp.delegate as? UBAppDelegate)?.showSettingsWindow(forCategory: categoryID) }
    }
}
