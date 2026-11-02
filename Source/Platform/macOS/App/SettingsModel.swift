// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SettingsModel.swift — the reusable pane/card/row data model for the
// Settings window. A pane is a list of cards; a card is a titled group
// of rows; a row is a label + a control bound to a Settings getter and a
// write-through. Adding a future pane is data here, not new view code.
//
// Reads resolve through Core's key surface (SettingsValues.swift).
// Writes go through the application delegate's settings surface, which
// persists to config.toml and applies live to every window. Settings is
// the single source of truth; this layer holds no parallel store.
//

import SwiftUI

// How a category fills the detail column: a data-driven pane of cards, or a
// bespoke SwiftUI view (Themes / Keys / Profiles, which need lists + CRUD).
enum SettingsContent {
    case pane(SettingsPane)
    case custom(@MainActor () -> AnyView)
}

/// A custom control's searchable address, supplied beside its view rather than inferred from labels.
struct SettingsSearchEntry {
    let id: String
    let label: String
    var keywords: [String] = []
}

// One sidebar category.
struct SettingsCategory: Identifiable {
    enum Group: String, CaseIterable {
        case appearance, input, sessions, system
    }

    let id: String
    let title: String
    let symbol: String // SF Symbol name
    let color: Color
    let summary: String
    let group: Group
    let parentID: String?
    let content: SettingsContent
    // Category-level matches supplement the generic rows for custom controls.
    let searchKeywords: [String]
    let searchEntries: [SettingsSearchEntry]
    /// A view the window keeps above the scrolling content, or nil.
    ///
    /// For a pane whose controls are judged against a sample: the sample has
    /// to stay in view while the reader changes what it shows, and a sample
    /// inside the scroll leaves the screen exactly when it is being used.
    let pinnedHeader: (@MainActor () -> AnyView)?

    init(
        id: String,
        title: String,
        symbol: String,
        color: Color = .gray,
        summary: String = "",
        group: Group = .appearance,
        parentID: String? = nil,
        content: SettingsContent,
        searchKeywords: [String] = [],
        searchEntries: [SettingsSearchEntry] = [],
        pinnedHeader: (@MainActor () -> AnyView)? = nil
    ) {
        self.pinnedHeader = pinnedHeader
        self.id = id
        self.title = title
        self.symbol = symbol
        self.color = color
        self.summary = summary
        self.group = group
        self.parentID = parentID
        self.content = content
        self.searchKeywords = searchKeywords
        self.searchEntries = searchEntries
    }
}

/// Keeps back and forward navigation in the order settings pages were visited.
struct SettingsNavigation {
    private var entries: [String]
    private var index = 0

    init(selection: String) {
        entries = [selection]
    }

    var selection: String { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    mutating func select(_ category: String) {
        guard category != selection else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(category)
        index = entries.count - 1
    }

    mutating func goBack() {
        guard canGoBack else { return }
        index -= 1
    }

    mutating func goForward() {
        guard canGoForward else { return }
        index += 1
    }
}

// A pane renders top-to-bottom as a stack of cards.
struct SettingsPane {
    let cards: [SettingsCard]
}

// A titled group of rows drawn as one rounded "card".
struct SettingsCard: Identifiable {
    let id = UUID()
    let title: String?
    let footer: String?
    let rows: [SettingsRow]

    init(title: String? = nil, footer: String? = nil, rows: [SettingsRow]) {
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

// A labelled row whose trailing control is one of a fixed set of kinds.
// Each kind carries its live getter + write-through closure, so the row
// reflects Settings on open and applies immediately on change.
struct SettingsRow: Identifiable {
    enum Presentation {
        case standard
        case fontFamily
        case fontWidth
    }

    /// A nonlocalized setting address, independent of its label and category.
    let id: String
    let label: String
    let detail: String?
    let control: Control
    let presentation: Presentation
    /// Other words a reader may search for, such as "Wallpaper" for a
    /// background image: matched by search, never shown.
    let keywords: [String]
    /// Whether the control can be used right now, or nil when it always can.
    ///
    /// A row that only means something once another setting is made stays in
    /// place, dimmed, rather than appearing and disappearing: the pane keeps
    /// its shape and the reader sees what becomes available. Asked again on
    /// every preference change.
    let isEnabled: (@MainActor () -> Bool)?
    /// The detail line as it reads for the current value, or nil to show
    /// `detail`.
    ///
    /// For a choice whose terms each need a sentence: the line describes the
    /// term chosen, while `detail` stays the row's searchable description.
    let currentDetail: (@MainActor () -> String)?

    init(
        id: String,
        _ label: String,
        detail: String? = nil,
        control: Control,
        presentation: Presentation = .standard,
        keywords: [String] = [],
        isEnabled: (@MainActor () -> Bool)? = nil,
        currentDetail: (@MainActor () -> String)? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.control = control
        self.presentation = presentation
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.currentDetail = currentDetail
    }

    enum Control {
        // Build installed-font choices only when a picker or a matching Beam
        // command needs them. Catalog construction itself remains cheap.
        case deferred(@MainActor () -> Control)
        case textList(get: @MainActor () -> String, set: @MainActor (String) -> Void)
        // On/off switch.
        case toggle(get: @MainActor () -> Bool, set: @MainActor (Bool) -> Void)
        // Segmented picker over `options`, by index. `caution` is asked about
        // the index currently chosen and shows its answer under the control,
        // which is what lets a term whose cost is not visible in its name say so
        // at the moment it is picked. A detail line cannot: it is one string for
        // the row, written before anybody chose anything, so it would warn about
        // a term the reader did not take. Defaulted, the way `slider`'s unit is,
        // so the rows that need no caution name none.
        case segmented(
            options: [String],
            caution: (@MainActor (Int) -> String?)? = nil,
            get: @MainActor () -> Int,
            set: @MainActor (Int) -> Void
        )
        // Popup (pull-down) menu over `options`, by index — for lists too long
        // for a segmented control, e.g. the theme list.
        case menu(
            options: [String],
            caution: (@MainActor (Int) -> String?)? = nil,
            get: @MainActor () -> Int,
            set: @MainActor (Int) -> Void
        )
        // Continuous slider in [min, max]. `unit` nil shows the value as a
        // percentage (0..1 ranges); a non-nil unit shows the rounded value with
        // that suffix (e.g. "20 pt").
        case slider(
            min: Double,
            max: Double,
            unit: String? = nil,
            get: @MainActor () -> Double,
            set: @MainActor (Double) -> Void
        )
        // Numeric ± stepper in [min, max] with a unit suffix (e.g. "pt").
        case stepper(
            min: Double,
            max: Double,
            step: Double,
            unit: String,
            get: @MainActor () -> Double,
            set: @MainActor (Double) -> Void
        )
        // Free-text field; commits on Return / focus loss. `placeholder`
        // shows when the field reads back empty.
        case textField(
            placeholder: String,
            get: @MainActor () -> String,
            set: @MainActor (String) -> Void
        )
        // The background image's file, as a live preview of the terminal
        // over it with a chooser beneath. Spans the row's full width, because
        // a preview squeezed into the trailing column could not show what the
        // placement modes do. `get` and `set` carry the path; an empty path
        // is no image.
        case backgroundImage(
            get: @MainActor () -> String,
            set: @MainActor (String) -> Void
        )

        @MainActor
        func resolved() -> Control {
            if case .deferred(let build) = self { return build().resolved() }
            return self
        }
    }
}

// One setting flattened out of the catalog for the Settings search field. Every
// .pane row becomes a hit carrying its `rowID`, so a match can scroll to and
// pulse the exact control. Custom controls contribute explicit search entries.
// `id` is stable across keystrokes (no churn while filtering).
struct SettingsSearchHit: Identifiable {
    let id: String
    let categoryID: String
    let categoryTitle: String
    let categorySymbol: String
    let label: String
    let detail: String?
    let rowID: String?
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        if label.lowercased().contains(needle) { return true }
        if let detail, detail.lowercased().contains(needle) { return true }
        if keywords.contains(where: { $0.lowercased().contains(needle) }) { return true }
        return categoryTitle.lowercased().contains(needle)
    }
}

extension Array where Element == SettingsCategory {
    func sidebarCategoryID(for categoryID: String) -> String {
        first(where: { $0.id == categoryID })?.parentID ?? categoryID
    }

    func pathTitle(for category: SettingsCategory) -> String {
        guard let parent = first(where: { $0.id == category.parentID }) else { return category.title }
        return parent.title + " › " + category.title
    }

    // Flatten the catalog into searchable hits, in sidebar order.
    func settingsSearchHits() -> [SettingsSearchHit] {
        var hits: [SettingsSearchHit] = []
        for category in self {
            switch category.content {
            case .pane(let pane):
                for card in pane.cards {
                    for row in card.rows {
                        hits.append(
                            SettingsSearchHit(
                                id: "\(category.id):\(row.id)",
                                categoryID: category.id,
                                categoryTitle: pathTitle(for: category),
                                categorySymbol: category.symbol,
                                label: row.label,
                                detail: row.detail ?? card.title,
                                rowID: row.id,
                                keywords: row.keywords
                            )
                        )
                    }
                }
            case .custom:
                break
            }
            for entry in category.searchEntries {
                hits.append(
                    SettingsSearchHit(
                        id: "\(category.id):\(entry.id)",
                        categoryID: category.id,
                        categoryTitle: pathTitle(for: category),
                        categorySymbol: category.symbol,
                        label: entry.label,
                        detail: nil,
                        rowID: entry.id,
                        keywords: entry.keywords
                    )
                )
            }
            let hasCustomContent: Bool
            if case .custom = category.content { hasCustomContent = true } else { hasCustomContent = false }
            if hasCustomContent || !category.searchKeywords.isEmpty {
                hits.append(
                    SettingsSearchHit(
                        id: category.id,
                        categoryID: category.id,
                        categoryTitle: pathTitle(for: category),
                        categorySymbol: category.symbol,
                        label: category.title,
                        detail: category.searchKeywords.isEmpty
                            ? nil : category.searchKeywords.joined(separator: ", "),
                        rowID: nil
                    )
                )
            }
        }
        return hits
    }
}
